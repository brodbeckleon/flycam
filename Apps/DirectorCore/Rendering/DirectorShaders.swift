// Metal shader source of DirectorCore, compiled at runtime by MetalContext.
// Colour convention: all intermediate layers are linear light (rgba16Float, premultiplied alpha);
// video textures are sampled through `_srgb` views and the program output is written to a `_srgb` target.

enum DirectorShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct DepthParams {
    float near;
    float far;
    float minAlpha;
    float pad;
};

// Converts the splat pass depth (alpha-weighted NDC depth from MetalSplatter, clip z in [0, 1] with
// z = 0 at `near`, see FlyCamKit PinholeCamera.projectionMatrix) to metric depth along the viewing
// axis. Writes 0 where the splat has no content (alpha below minAlpha).
kernel void linearizeDepth(depth2d<float, access::read> depthTex [[texture(0)]],
                           texture2d<half, access::read> colorTex [[texture(1)]],
                           texture2d<float, access::write> outTex [[texture(2)]],
                           constant DepthParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
    float a = float(colorTex.read(gid).a);
    float d = depthTex.read(gid);
    float z = 0.0;
    if (a >= p.minAlpha && d > 0.0 && d < 1.0) {
        z = p.far * p.near / (p.far - d * (p.far - p.near));
    }
    outTex.write(float4(z, 0, 0, 0), gid);
}

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

// One triangle covering the target; uv (0, 0) is the top-left corner of the image.
vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid == 2) ? 3.0 : -1.0, (vid == 1) ? 3.0 : -1.0);
    FullscreenOut o;
    o.position = float4(p, 0, 1);
    o.uv = float2((p.x + 1) * 0.5, 1 - (p.y + 1) * 0.5);
    return o;
}

// Video frame pass: resamples a video frame (sampled as sRGB -> linear) into a linear layer.
fragment half4 videoFragment(FullscreenOut in [[stage_in]],
                             texture2d<float> video [[texture(0)]],
                             sampler s [[sampler(0)]]) {
    float4 c = video.sample(s, in.uv);
    return half4(half3(c.rgb), 1);
}

struct MixParams {
    float videoA;
    float render;
    float videoB;
    float pad;
    float4 background;   // linear, behind the splat where it has no content
};

// Final mix: videoA * wA + (splat over background) * wR + videoB * wB.
fragment half4 mixFragment(FullscreenOut in [[stage_in]],
                           texture2d<float> layerA [[texture(0)]],
                           texture2d<float> layerR [[texture(1)]],
                           texture2d<float> layerB [[texture(2)]],
                           constant MixParams &p [[buffer(0)]],
                           sampler s [[sampler(0)]]) {
    float3 c = float3(0);
    if (p.videoA > 0) { c += p.videoA * layerA.sample(s, in.uv).rgb; }
    if (p.render > 0) {
        float4 r = layerR.sample(s, in.uv);
        c += p.render * (r.rgb + (1 - r.a) * p.background.rgb);
    }
    if (p.videoB > 0) { c += p.videoB * layerB.sample(s, in.uv).rgb; }
    return half4(half3(c), 1);
}
"""#
}
