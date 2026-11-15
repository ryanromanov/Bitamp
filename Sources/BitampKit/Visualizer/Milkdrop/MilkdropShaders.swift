/// The Metal side of the MilkDrop engine. Everything the preset's code decides is worked out
/// on the CPU; the GPU only blits the warped mesh, draws coloured triangles and does the final
/// composite.
enum MilkdropShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct MilkVertex {
        float2 position;
        float2 uv;
        float4 color;
    };

    struct MilkOut {
        float4 position [[position]];
        float2 uv;
        float4 color;
    };

    vertex MilkOut milk_vertex(uint vid [[vertex_id]], constant MilkVertex *vertices [[buffer(0)]]) {
        MilkOut out;
        out.position = float4(vertices[vid].position, 0, 1);
        out.uv = vertices[vid].uv;
        out.color = vertices[vid].color;
        return out;
    }

    /// The warped copy of the last frame, faded by the decay in the vertex colour.
    fragment float4 milk_warp(MilkOut in [[stage_in]], texture2d<float> last [[texture(0)]], sampler smp [[sampler(0)]]) {
        float4 texel = last.sample(smp, in.uv);
        return float4(in.color.rgb * texel.rgb, 1);
    }

    fragment float4 milk_flat(MilkOut in [[stage_in]]) {
        return in.color;
    }

    struct MilkComposite {
        float echoZoom;
        float echoAlpha;
        float echoOrient;
        float gamma;
        float brighten;
        float darken;
        float solarize;
        float invert;
    };

    fragment float4 milk_composite(MilkOut in [[stage_in]], texture2d<float> frame [[texture(0)]],
                                   sampler smp [[sampler(0)]], constant MilkComposite &c [[buffer(0)]]) {
        float2 uv = in.uv;
        float3 color = frame.sample(smp, uv).rgb;
        if (c.echoAlpha > 0.001) {
            float2 e = (uv - 0.5) / max(c.echoZoom, 0.001) + 0.5;
            int orient = int(c.echoOrient + 0.5);
            if (orient == 1 || orient == 3) e.x = 1 - e.x;
            if (orient == 2 || orient == 3) e.y = 1 - e.y;
            color = mix(color, frame.sample(smp, e).rgb, c.echoAlpha);
        }
        color *= c.gamma;
        if (c.brighten > 0.5) color = sqrt(max(color, 0.0));
        if (c.darken > 0.5) color = color * color;
        if (c.solarize > 0.5) color = color * (1 - color) * 4;
        if (c.invert > 0.5) color = 1 - color;
        return float4(saturate(color), 1);
    }
    struct UserVertex {
        float2 position;
        float2 uv;
        float2 uvOrig;
        float2 radAng;
        float4 color;
    };

    struct UserWarpOut {
        float4 position [[position]];
        float4 color [[user(locn0)]];
        float4 uv [[user(locn1)]];
        float2 radAng [[user(locn2)]];
    };

    vertex UserWarpOut milk_user_vertex_warp(uint vid [[vertex_id]], constant UserVertex *v [[buffer(0)]]) {
        UserWarpOut out;
        out.position = float4(v[vid].position, 0, 1);
        out.color = v[vid].color;
        out.uv = float4(v[vid].uv, v[vid].uvOrig);
        out.radAng = v[vid].radAng;
        return out;
    }

    struct UserCompOut {
        float4 position [[position]];
        float4 color [[user(locn0)]];
        float2 uv [[user(locn1)]];
        float2 radAng [[user(locn2)]];
    };

    vertex UserCompOut milk_user_vertex_comp(uint vid [[vertex_id]], constant UserVertex *v [[buffer(0)]]) {
        UserCompOut out;
        out.position = float4(v[vid].position, 0, 1);
        out.color = v[vid].color;
        out.uv = v[vid].uv;
        out.radAng = v[vid].radAng;
        return out;
    }
    """
}
