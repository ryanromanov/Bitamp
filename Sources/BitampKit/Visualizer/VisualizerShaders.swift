/// The full-window visualizer's visuals. The raw value is what's saved in preferences.
enum FullVisual: String, CaseIterable {
    case barsAndWaves, plasma, starspray, solarSailing, starfield, alchemy

    var title: String {
        switch self {
        case .barsAndWaves: return "Bars and Waves"
        case .plasma: return "Plasma"
        case .starspray: return "Starspray"
        case .solarSailing: return "Solar Sailing"
        case .starfield: return "Starfield"
        case .alchemy: return "Alchemy"
        }
    }

    /// How many levels per colour channel the picture is reduced to, with an ordered dither,
    /// or 0 to leave the colours as drawn. Bars and Waves, Plasma, Starspray, Solar Sailing and Starfield use the skin's
    /// own palette as it is; Alchemy's fading trails get the dither.
    var ditherLevels: Float {
        self == .alchemy ? 6 : 0
    }

    /// The single fragment shader that draws it, or nil for one that feeds back on itself.
    var shader: String? {
        switch self {
        case .barsAndWaves: return "bars_and_waves"
        case .plasma: return "plasma"
        case .starspray: return "starspray"
        case .solarSailing: return "solar_sailing"
        case .starfield: return "starfield"
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
        float travel;
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

    // A 4 by 4 ordered-dither threshold between 0 and 1 for a pixel, for the cheap two-tone
    // gradients of the era.
    constant float bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};

    static float dither4(float2 px) {
        return (bayer[(int(px.y) & 3) * 4 + (int(px.x) & 3)] + 0.5) / 16.0;
    }

    static float hash(float n) {
        return fract(sin(n * 127.1) * 43758.5453);
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

    // MARK: Plasma

    // The old plasma: a few sine waves added up and run through the palette, which turns
    // with the music. Bands of the analyzer stretch each wave.
    fragment float4 plasma(VertexOut in [[stage_in]],
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

    // MARK: Starspray and Solar Sailing

    // Streaking through the stars. The vanishing point wanders and the whole sky rolls; the
    // streaks lengthen with the music and the beat sends out a checkered shockwave and
    // flashes the glow at the far end. Each star has a band of the analyzer of its own,
    // chosen at random so the sky fills evenly, and takes its colour from how loud that band
    // is. Stars never switch on and off with the music: that looked like flicker.
    //
    // Real perspective: a star sits off to the side of the ship's path by a fixed amount
    // (rho) and is at some distance (depth, 1 far, 0 near). Where it shows on the screen is
    // rho over depth, so far stars are small, dim and nearly still, and speed up and
    // brighten as they come close. Streaks are how far it moved in a moment, so they're
    // short far away and long near the edge. `rhoMin` and `rhoSpan` say how far to the side
    // the stars can be: Solar Sailing has them well spread; Starspray keeps them closer to
    // the middle, so the streaks gather there more.
    static float4 streak_sky(float2 uv,
                             constant Uniforms &u,
                             constant float *bars,
                             constant float4 *palette,
                             float rhoMin, float rhoSpan) {
        float2 res = u.resolution;
        float2 px = floor(uv * res);
        float2 pixelCenter = px + 0.5;
        float t = u.time;
        float2 vanishing = floor(res * 0.5) + 0.5
                         + float2(sin(t * 0.31) * res.x * 0.07, cos(t * 0.23) * res.y * 0.07);
        float roll = sin(t * 0.17) * 0.7 + u.travel * 0.04;
        float3 color = palette[0].rgb;

        // The glow at the far end: a two-tone dithered gradient that swells with the bass.
        float r = length(pixelCenter - vanishing);
        float glow = (0.04 + 0.3 * u.bass + 0.4 * u.beat) * exp(-r * r / (res.y * res.y * 0.0125));
        if (glow > dither4(px)) color = ramp(palette, 0.2);
        // The shockwave, a checkered ring that runs out from the middle on every beat.
        if (u.beat > 0.04) {
            float ring = (1.0 - u.beat) * res.y * 0.9;
            if (abs(r - ring) < 0.8 && ((int(px.x) + int(px.y)) & 1) == 0) color = ramp(palette, 0.6);
        }

        float k = res.y * 0.1;
        float lag = 0.02 + 0.05 * u.energy + 0.05 * u.beat;
        for (int i = 0; i < 160; i++) {
            float fi = float(i);
            bool dust = i >= 120;
            float level = bars[min(int(hash(fi + 41.0) * 19.0), 18)];
            float angle = hash(fi + 1.0) * 6.2831853 + roll;
            float2 direction = float2(cos(angle), sin(angle));
            float rho = rhoMin + rhoSpan * hash(fi + 3.0);
            float speed = dust ? 0.15 : 0.5 + 0.8 * hash(fi + 13.0);
            float along = fract(hash(fi + 29.0) - u.travel * speed);
            float depth = 0.03 + 0.97 * pow(along, 1.5);
            float tailDepth = min(depth + (dust ? 0.0 : lag), 1.0);
            float2 head = vanishing + direction * (rho * k / depth);
            float2 tail = vanishing + direction * (rho * k / tailDepth);
            float2 trail = head - tail;
            float length2 = dot(trail, trail);
            float t01 = length2 > 0.0 ? clamp(dot(pixelCenter - tail, trail) / length2, 0.0, 1.0) : 1.0;
            float d = length(pixelCenter - (tail + trail * t01));
            // A star always lights the pixel it's in, so a far one that has hardly moved
            // can't slip between pixels and wink out.
            bool onHead = all(px == floor(head));
            if (onHead || d < (depth < 0.3 ? 0.75 : 0.55)) {
                if (depth > 0.6 || dust) {
                    color = ramp(palette, 0.05 + 0.25 * level);
                } else if (depth < 0.18 && (t01 > 0.8 || onHead)) {
                    color = palette[23].rgb;
                } else {
                    float brightness = clamp(0.15 + level * 0.9 + (0.6 - depth) * 0.5, 0.0, 1.0);
                    color = ramp(palette, (t01 > 0.8 || onHead) ? brightness : brightness * 0.6);
                }
            }
        }
        return float4(color, 1);
    }

    fragment float4 solar_sailing(VertexOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]],
                                  constant float *bars [[buffer(1)]],
                                  constant float *wave [[buffer(2)]],
                                  constant float4 *palette [[buffer(3)]],
                                  constant float *peaks [[buffer(4)]]) {
        return streak_sky(in.uv, u, bars, palette, 0.2, 0.8);
    }

    fragment float4 starspray(VertexOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              constant float *bars [[buffer(1)]],
                              constant float *wave [[buffer(2)]],
                              constant float4 *palette [[buffer(3)]],
                              constant float *peaks [[buffer(4)]]) {
        return streak_sky(in.uv, u, bars, palette, 0.1, 0.5);
    }

    // MARK: Starfield

    // The same flight, with stars instead of streaks. Far stars are single pixels; nearer
    // ones grow into plus signs and then glinting four- and eight-point sparkles, and some
    // flare a size on the beat. They swing round in a slow spiral. Behind them a sky of
    // twinkling dots, and now and then a shooting star.
    fragment float4 starfield(VertexOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              constant float *bars [[buffer(1)]],
                              constant float *wave [[buffer(2)]],
                              constant float4 *palette [[buffer(3)]],
                              constant float *peaks [[buffer(4)]]) {
        float2 res = u.resolution;
        float2 px = floor(in.uv * res);
        float t = u.time;
        float2 vanishing = floor(res * 0.5) + float2(floor(sin(t * 0.2) * res.x * 0.05), floor(cos(t * 0.15) * res.y * 0.05));
        float scale = res.y * 0.9;
        float3 color = palette[0].rgb;

        // The sky: dots that twinkle, each at its own pace.
        float sky = hash(px.x * 1.37 + px.y * 91.71);
        if (sky > 0.991) {
            float twinkle = fract(sky * 311.0 + t * (0.25 + sky * 0.5));
            color = twinkle < 0.12 ? palette[23].rgb : ramp(palette, 0.06 + 0.1 * twinkle);
        }

        for (int i = 0; i < 150; i++) {
            float fi = float(i);
            int band = min(int(hash(fi + 41.0) * 19.0), 18);
            float level = bars[band];
            float speed = 0.2 + 0.3 * hash(fi + 13.0);
            float z = fract(hash(fi + 29.0) - u.travel * speed);
            float angle = hash(fi + 1.0) * 6.2831853 + (1.0 - z) * 1.1 + u.travel * 0.02;
            float2 position = floor(vanishing + float2(cos(angle), sin(angle)) * ((1.0 - z) * (1.0 - z) * 0.85) * scale);
            float2 d = px - position;
            float ax = abs(d.x), ay = abs(d.y);
            if (ax > 4.0 || ay > 4.0) continue;

            int size = z > 0.65 ? 0 : z > 0.4 ? 1 : z > 0.2 ? 2 : 3;
            if (u.beat > 0.5 && size < 3 && hash(fi + 5.0) < 0.5) size += 1;
            bool glint = fract(hash(fi + 9.0) + t * 0.5) < 0.2;
            float arm = size == 0 ? 0.0 : size == 1 ? 1.0 : size == 2 ? 2.0 : 4.0;
            bool onAxis = (ax == 0.0 && ay <= arm) || (ay == 0.0 && ax <= arm);
            bool diagonal = (size >= 3 && ax == ay && ax <= 2.0) || (size == 2 && glint && ax == 1.0 && ay == 1.0);
            if (!onAxis && !diagonal) continue;
            if (ax == 0.0 && ay == 0.0) {
                color = size >= 1 ? palette[23].rgb : ramp(palette, clamp(0.2 + level, 0.0, 1.0));
            } else {
                float edge = max(ax, ay) / max(arm, 1.0);
                color = ramp(palette, clamp((edge > 0.6 ? 0.1 : 0.3) + level * 0.8, 0.0, 1.0));
            }
        }

        // A shooting star every few seconds.
        float period = t / 6.5 + 0.3;
        float along = fract(period) / 0.1;
        if (along < 1.0) {
            float2 direction = normalize(float2(1.0, 0.6));
            float2 start = float2(res.x * (0.1 + 0.5 * hash(floor(period))), res.y * 0.08);
            float2 head = start + direction * along * res.x * 0.5;
            for (int j = 0; j < 8; j++) {
                if (all(px == floor(head - direction * float(j) * 1.6))) {
                    color = j == 0 ? palette[23].rgb : ramp(palette, 0.75 - 0.08 * float(j));
                }
            }
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
