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

    /// How many levels per colour channel the picture is reduced to, with an ordered dither,
    /// or 0 to leave the colours as drawn. Bars and Waves, Ambience and Battery use the skin's
    /// own palette as it is; Alchemy's fading trails get the dither.
    var ditherLevels: Float {
        self == .alchemy ? 6 : 0
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
/// The look is deliberately '90s and '00s: every visual is drawn small, at the skin's own pixel
/// size, with hard edges, in the 24-colour palette the skin gives the main window's analyzer
/// (`viscolor.txt`), and is scaled up with no smoothing. Every visual is one fragment function
/// with the same inputs: `Uniforms` (the small picture's size, time, bass/mid/treble levels, a
/// beat pulse), the 19 analyzer bars, the 76-sample waveform, the palette and the bar peaks.
/// Hand-written for now; a MilkDrop-style preset engine may come later and would slot in as one
/// more "visual" fed by the same inputs (see docs/ARCHITECTURE.md).
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
        float levels;
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

    // The skin's viscolor.txt: 0 background, 2...17 the analyzer from top to bottom,
    // 18...22 the oscilloscope, 23 the peak caps.
    static float3 ramp(constant float4 *palette, float t) {
        // 0 is the bottom of the analyzer, 1 the top.
        return palette[2 + int(clamp(1.0 - t, 0.0, 1.0) * 15.0 + 0.5)].rgb;
    }

    static float waveSample(constant float *wave, float x) {
        float f = clamp(x, 0.0, 1.0) * 75.0;
        int i = int(floor(f));
        int j = min(i + 1, 75);
        return mix(wave[i], wave[j], f - float(i));
    }

    static float barLevel(constant float *bars, float x) {
        float f = clamp(x, 0.0, 1.0) * 18.0;
        int i = int(floor(f));
        int j = min(i + 1, 18);
        return mix(bars[i], bars[j], f - float(i));
    }

    // MARK: Bars and Waves

    // The analyzer as chunky segments with falling peak caps, under an oscilloscope.
    fragment float4 bars_and_waves(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]],
                                   constant float *bars [[buffer(1)]],
                                   constant float *wave [[buffer(2)]],
                                   constant float4 *palette [[buffer(3)]],
                                   constant float *peaks [[buffer(4)]]) {
        float2 res = u.resolution;
        float2 px = floor(in.uv * res);
        float3 color = palette[0].rgb;

        float scopeHeight = floor(res.y * 0.4);
        if (px.y >= scopeHeight + 2.0) {
            float rows = res.y - scopeHeight - 2.0;
            float up = res.y - 1.0 - px.y;
            float columnWidth = res.x / 19.0;
            int column = clamp(int(floor(px.x / columnWidth)), 0, 18);
            float inside = px.x - float(column) * columnWidth;
            bool columnGap = inside >= columnWidth - 1.0 || inside < 0.0;
            float segment = 3.0;
            bool segmentGap = fmod(up, segment) >= segment - 1.0;
            float segments = floor(rows / segment);
            float index = floor(up / segment);
            if (!columnGap && !segmentGap && index < segments) {
                if (index < bars[column] * segments) color = ramp(palette, (index + 0.5) / segments);
                float peak = floor(peaks[column] * segments);
                if (peak > 1.0 && index == peak - 1.0) color = palette[23].rgb;
            }
        } else if (px.y < scopeHeight) {
            // The waveform, joined up from one column to the next.
            float middle = scopeHeight * 0.5;
            float amplitude = middle - 1.0;
            float a = middle - waveSample(wave, px.x / (res.x - 1.0)) * amplitude;
            float b = middle - waveSample(wave, (px.x + 1.0) / (res.x - 1.0)) * amplitude;
            if (px.y + 0.5 >= min(a, b) - 0.5 && px.y + 0.5 <= max(a, b) + 0.5) {
                color = palette[18 + min(4, int(abs(px.y - middle) / (amplitude / 5.0)))].rgb;
            }
        }
        return float4(color, 1);
    }

    // MARK: Ambience

    // The old plasma: a few sine waves added up and run through the palette, which turns
    // with the music. Bands of the analyzer stretch each wave.
    fragment float4 ambience(VertexOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             constant float *bars [[buffer(1)]],
                             constant float *wave [[buffer(2)]],
                             constant float4 *palette [[buffer(3)]],
                             constant float *peaks [[buffer(4)]]) {
        float2 px = floor(in.uv * u.resolution);
        float2 p = px / u.resolution.y * 6.0;
        float t = u.time * 0.5;
        float v = sin(p.x * (1.0 + bars[2]) + t)
                + sin(p.y * (1.2 + bars[6]) - t * 1.3)
                + sin((p.x + p.y) * (0.8 + bars[10]) + t * 0.7)
                + sin(length(p - float2(u.resolution.x / u.resolution.y * 3.0, 3.0)) * (1.6 + 2.0 * u.bass) - t * 1.5);
        float shade = fract(v * 0.125 + 0.5 + u.time * 0.04 + u.beat * 0.12);
        // Up the palette and back down it, so the colours don't jump where it wraps.
        float color = abs(shade * 2.0 - 1.0);
        return float4(ramp(palette, color), 1);
    }

    // MARK: Battery

    // A tunnel of rings and spokes rushing toward you, lit by the bars around the circle.
    fragment float4 battery(VertexOut in [[stage_in]],
                            constant Uniforms &u [[buffer(0)]],
                            constant float *bars [[buffer(1)]],
                            constant float *wave [[buffer(2)]],
                            constant float4 *palette [[buffer(3)]],
                            constant float *peaks [[buffer(4)]]) {
        float2 p = (floor(in.uv * u.resolution) + 0.5 - u.resolution * 0.5) / u.resolution.y;
        float r = length(p);
        float a = atan2(p.y, p.x);
        float3 color = palette[0].rgb;
        if (r > 0.02) {
            float depth = 0.3 / r;
            float z = depth - u.time * (0.9 + 0.6 * u.energy) - u.beat * 0.15;
            float level = barLevel(bars, abs(a) / 3.14159265);
            float band = abs(fract(z) - 0.5) * 2.0;
            float ring = step(0.9 - 0.08 * u.beat, band);
            float spokeAngle = a / 6.2831853 * 14.0 + u.time * 0.05;
            float spoke = step(0.93, abs(sin(spokeAngle * 3.14159265)));
            if (ring + spoke > 0.0) {
                color = ramp(palette, clamp(0.15 + level * 1.1 + 0.2 * u.beat, 0.0, 1.0));
            }
            if (r < 0.05 && u.beat > 0.3) color = palette[23].rgb;
        }
        return float4(color, 1);
    }

    // MARK: Alchemy

    // One step of the feedback loop: the last frame, zoomed, turned and faded, with a
    // ring drawn from the waveform on top.
    fragment float4 alchemy_step(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 constant float *bars [[buffer(1)]],
                                 constant float *wave [[buffer(2)]],
                                 constant float4 *palette [[buffer(3)]],
                                 constant float *peaks [[buffer(4)]],
                                 texture2d<float> previous [[texture(0)]]) {
        constexpr sampler smp(address::mirrored_repeat, filter::linear);
        float aspect = u.resolution.x / u.resolution.y;
        float2 p = (in.uv - 0.5) * float2(aspect, 1.0);

        float zoom = 0.985 - 0.02 * u.bass - 0.03 * u.beat;
        float angle = 0.012 * sin(u.time * 0.4) + 0.025 * (u.mid - 0.25);
        float c = cos(angle), s = sin(angle);
        float2 q = float2(c * p.x - s * p.y, s * p.x + c * p.y) * zoom;
        q += 0.004 * float2(sin(p.y * 6.0 + u.time), cos(p.x * 6.0 - u.time));
        float3 color = previous.sample(smp, q / float2(aspect, 1.0) + 0.5).rgb * 0.93;

        float r = length(p);
        float m = abs(atan2(p.y, p.x) / 3.14159265);
        float ring = 0.17 + 0.06 * u.bass;
        float d = abs(r - ring - waveSample(wave, m) * 0.35);
        // The ring's colour walks up the palette as the song gets louder.
        float3 ink = ramp(palette, clamp(0.25 + 0.6 * u.energy * 3.0 + 0.3 * m, 0.0, 1.0));
        if (d < 1.5 / u.resolution.y) color = max(color, ink);
        if (u.beat > 0.5 && abs(r - 0.04 - 0.2 * (1.0 - u.beat)) < 1.5 / u.resolution.y) color = max(color, palette[23].rgb);
        return float4(color, 1);
    }

    // Draws the small picture at full size with no smoothing, and, for the visuals that
    // ask, in a few levels per colour with an ordered dither.
    constant float bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};

    fragment float4 present(VertexOut in [[stage_in]],
                            constant Uniforms &u [[buffer(0)]],
                            texture2d<float> image [[texture(0)]]) {
        constexpr sampler smp(filter::nearest);
        float3 color = image.sample(smp, in.uv).rgb;
        if (u.levels > 1.0) {
            float2 cell = floor(in.uv * u.resolution);
            int index = (int(cell.y) & 3) * 4 + (int(cell.x) & 3);
            float threshold = (bayer[index] + 0.5) / 16.0 - 0.5;
            color = floor(color * (u.levels - 1.0) + 0.5 + threshold) / (u.levels - 1.0);
        }
        return float4(clamp(color, 0.0, 1.0), 1);
    }
    """
}
