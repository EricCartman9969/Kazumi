#include <metal_stdlib>
using namespace metal;

struct PresentVertex {
    float4 position [[position]];
    float2 uv;
};

// Full-screen triangle; the viewport does the aspect fit.
vertex PresentVertex anime4k_present_vertex(uint vid [[vertex_id]]) {
    const float2 uv = float2((vid << 1) & 2, vid & 2);
    PresentVertex out;
    out.position = float4(uv * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
    out.uv = uv;
    return out;
}

fragment float4 anime4k_present_fragment(PresentVertex in [[stage_in]],
                                         texture2d<float> frame [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(saturate(frame.sample(s, in.uv).rgb), 1.0f);
}
