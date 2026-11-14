/// The full-window visualizer's visuals. The raw value is what's saved in preferences.
enum FullVisual: String, CaseIterable {
    case barsAndWaves, ambience, battery, alchemy

    var title: String {
        switch self {
        case .barsAndWaves: return "Bars and Waves"
        case .ambience: return "Ambience"
        case .battery: return "Battery"
        case .alchemy: return "Alchemy"
        }
    }

    /// The single fragment shader that draws it, or nil for one that feeds back on itself.
    var shader: String? {
        switch self {
        case .barsAndWaves: return "bars_and_waves"
        case .ambience: return "ambience"
        case .battery: return "battery"
        case .alchemy: return nil
        }
    }
}

/// Metal source for the full-window visualizer's visuals, compiled when the window first
/// opens (`MTLDevice.makeLibrary(source:)`), so SwiftPM needs no .metal build step.
///
/// Every visual is one fragment function with the same inputs: `Uniforms` (time, size,
/// bass/mid/treble levels and a beat pulse), the 19 analyzer bars and the 76-sample
/// waveform. Hand-written for now; a MilkDrop-style preset engine may come later and would
/// slot in as one more "visual" fed by the same inputs (see docs/ARCHITECTURE.md).
enum VisualizerShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 resolution;
        float time;
        float bass;
        float mid;
        float treble;
        float beat;
        float energy;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut vis_vertex(uint id [[vertex_id]]) {
        // One oversized triangle that covers the screen.
        float2 p = float2((id << 1) & 2, id & 2);
        VertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0, 1);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    static float3 hsv(float h, float s, float v) {
        float3 k = clamp(abs(fract(h + float3(0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
        return v * mix(float3(1), k, s);
    }

    // A smoothly interpolated bar level at x in 0...1.
    static float barLevel(constant float *bars, float x) {
        float f = clamp(x, 0.0, 1.0) * 18.0;
        int i = int(floor(f));
        int j = min(i + 1, 18);
        float t = f - float(i);
        t = t * t * (3.0 - 2.0 * t);
        return mix(bars[i], bars[j], t);
    }

    static float waveSample(constant float *wave, float x) {
        float f = clamp(x, 0.0, 1.0) * 75.0;
        int i = int(floor(f));
        int j = min(i + 1, 75);
        return mix(wave[i], wave[j], f - float(i));
    }

    // MARK: Bars and Waves

    fragment float4 bars_and_waves(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]],
                                   constant float *bars [[buffer(1)]],
                                   constant float *wave [[buffer(2)]]) {
        float2 uv = in.uv;
        float aspect = u.resolution.x / u.resolution.y;

        // Background: a dark gradient that breathes with the bass.
        float3 base = hsv(0.62 + 0.05 * sin(u.time * 0.1), 0.7, 0.10 + 0.10 * u.bass + 0.10 * u.beat);
        float3 color = base * (1.1 - 0.6 * length(uv - 0.5));

        // Mirrored bars rising from the center line.
        float x = abs(uv.x - 0.5) * 2.0;           // 0 in the middle, 1 at the edges
        float level = barLevel(bars, x);
        float columns = 38.0;
        float cell = fract(x * columns);
        float gap = smoothstep(0.0, 0.12, cell) * smoothstep(1.0, 0.88, cell);
        float centerDistance = abs(uv.y - 0.5) * 2.0;
        float height = level * 0.85;
        float inside = step(centerDistance, height);
        float tip = smoothstep(0.06, 0.0, abs(centerDistance - height));
        float3 barColor = hsv(0.55 + 0.45 * x + u.time * 0.02, 0.75, 0.55 + 0.45 * (1.0 - centerDistance));
        color += barColor * inside * gap * 0.75;
        color += float3(1.0) * tip * gap * level * 0.6;

        // The waveform across the middle, with a glow.
        float w = waveSample(wave, uv.x) * (0.18 + 0.1 * u.energy);
        float line = abs(uv.y - 0.5 - w);
        float glow = 0.004 / (line + 0.004) * 0.5 + 0.0006 / (line * line + 0.0006) * 0.0;
        color += hsv(0.12 + u.time * 0.03, 0.4, 1.0) * glow * (0.5 + 0.5 * u.mid);

        color += u.beat * 0.06;
        return float4(color, 1);
    }

    // MARK: Ambience

    fragment float4 ambience(VertexOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             constant float *bars [[buffer(1)]],
                             constant float *wave [[buffer(2)]]) {
        float aspect = u.resolution.x / u.resolution.y;
        float2 p = (in.uv - 0.5) * float2(aspect, 1.0);
        float t = u.time * 0.18;

        float3 color = hsv(0.7 + 0.1 * sin(t), 0.6, 0.06 + 0.04 * u.bass);
        for (int i = 0; i < 7; i++) {
            float fi = float(i);
            float2 center = float2(sin(t * (0.7 + 0.13 * fi) + fi * 2.1) * 0.55 * aspect,
                                   cos(t * (0.5 + 0.11 * fi) + fi * 1.3) * 0.42);
            float band = barLevel(bars, fi / 6.0);
            float radius = 0.16 + 0.22 * band + 0.08 * u.beat;
            float d = length(p - center) / radius;
            float falloff = exp(-d * d * 1.6);
            float3 tint = hsv(fract(0.58 + fi * 0.13 + t * 0.4), 0.7, 1.0);
            color += tint * falloff * (0.35 + 0.65 * band);
        }
        // Soft vignette and a flash on the beat.
        color *= 1.0 - 0.5 * dot(p, p) / (aspect * aspect * 0.25);
        color += u.beat * 0.05;
        // A gentle tone map so overlapping blobs don't clip to white.
        color = 1.0 - exp(-color * 1.4);
        return float4(color, 1);
    }

    // MARK: Battery

    // A tunnel of rings and spokes rushing toward you, lit by the bars around the circle.
    fragment float4 battery(VertexOut in [[stage_in]],
                            constant Uniforms &u [[buffer(0)]],
                            constant float *bars [[buffer(1)]],
                            constant float *wave [[buffer(2)]]) {
        float aspect = u.resolution.x / u.resolution.y;
        float2 p = (in.uv - 0.5) * float2(aspect, 1.0);
        float r = length(p);
        float a = atan2(p.y, p.x);

        float depth = 0.3 / (r + 0.03);
        float z = depth - u.time * (0.9 + 0.6 * u.energy) - u.beat * 0.15;
        float level = barLevel(bars, abs(a) / 3.14159265);

        float band = abs(fract(z) - 0.5) * 2.0;
        float ring = smoothstep(0.82, 1.0, band);
        float spokeAngle = a / 6.2831853 * 14.0 + depth * 0.06 * sin(u.time * 0.4) + u.time * 0.05;
        float spoke = smoothstep(0.88, 1.0, abs(sin(spokeAngle * 3.14159265)));

        float3 tint = hsv(fract(0.02 * depth + u.time * 0.04 + level * 0.25), 0.8, 1.0);
        float lit = (ring + 0.7 * spoke) * (0.25 + 1.3 * level + 0.5 * u.beat);
        float fade = smoothstep(0.0, 0.18, r) * smoothstep(1.1, 0.4, r);
        float3 color = tint * lit * fade;
        color += hsv(0.6 + u.time * 0.03, 0.5, 1.0) * (0.015 / (r + 0.02)) * (0.4 + u.beat + u.bass);
        color = 1.0 - exp(-color * 1.5);
        return float4(color, 1);
    }

    // MARK: Alchemy

    // One step of the feedback loop: the last frame, zoomed, turned and faded, with a
    // ring drawn from the waveform on top.
    fragment float4 alchemy_step(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 constant float *bars [[buffer(1)]],
                                 constant float *wave [[buffer(2)]],
                                 texture2d<float> previous [[texture(0)]]) {
        constexpr sampler smp(address::mirrored_repeat, filter::linear);
        float aspect = u.resolution.x / u.resolution.y;
        float2 p = (in.uv - 0.5) * float2(aspect, 1.0);

        float zoom = 0.985 - 0.02 * u.bass - 0.03 * u.beat;
        float angle = 0.012 * sin(u.time * 0.4) + 0.025 * (u.mid - 0.25);
        float c = cos(angle), s = sin(angle);
        float2 q = float2(c * p.x - s * p.y, s * p.x + c * p.y) * zoom;
        q += 0.004 * float2(sin(p.y * 6.0 + u.time), cos(p.x * 6.0 - u.time));
        float3 old = previous.sample(smp, q / float2(aspect, 1.0) + 0.5).rgb;
        old = (old * 0.96 + old.gbr * 0.04) * 0.955;

        float r = length(p);
        float theta = atan2(p.y, p.x);
        float m = abs(theta / 3.14159265);
        float ring = 0.17 + 0.06 * u.bass;
        float d = abs(r - ring - waveSample(wave, m) * 0.35);
        float ink = 0.006 / (d + 0.006);
        float3 tint = hsv(fract(u.time * 0.05 + m * 0.5), 0.8, 1.0);
        float3 color = old + tint * ink * (0.25 + 0.6 * u.energy) * 0.35;
        color += hsv(fract(u.time * 0.1 + 0.3), 0.6, 1.0) * u.beat * exp(-r * r * 18.0) * 0.25;
        return float4(color, 1);
    }

    fragment float4 present(VertexOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler smp(filter::linear);
        float3 color = image.sample(smp, in.uv).rgb;
        return float4(1.0 - exp(-color * 1.3), 1);
    }
    """
}
