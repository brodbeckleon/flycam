// Upstream MetalSplatter 1.0.1 shader sources (MetalSplatter/Resources/*), verbatim.
// Embedded as strings so that they can be compiled at runtime without the Metal Toolchain and
// without locating a resource bundle (VENDORED.md).

enum EmbeddedShaderSources {
    /// (file name, contents) in dependency order.
    static let files: [(String, String)] = [
        ("ShaderCommon.h", #"""
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

constant const int kMaxViewCount = 2;
constant static const half kBoundsRadius = 3;
constant static const half kBoundsRadiusSquared = kBoundsRadius*kBoundsRadius;

// Spherical Harmonics constants
// These are normalization factors for SH basis functions
constant const float SH_C0 = 0.28209479177387814f;  // 1/(2*sqrt(pi))
constant const float SH_C1 = 0.4886025119029199f;   // sqrt(3/(4*pi))

constant const float SH_C2_0 =  1.0925484305920792f;  //  0.5 * sqrt(15/pi)
constant const float SH_C2_1 = -1.0925484305920792f;  // -0.5 * sqrt(15/pi)
constant const float SH_C2_2 =  0.31539156525252005f; //  0.25 * sqrt(5/pi)
constant const float SH_C2_3 = -1.0925484305920792f;  // -0.5 * sqrt(15/pi)
constant const float SH_C2_4 =  0.5462742152960396f;  //  0.25 * sqrt(15/pi)

constant const float SH_C3_0 = -0.5900435899266435f;  // -0.25 * sqrt(35/(2*pi))
constant const float SH_C3_1 =  2.890611442640554f;   //  0.5 * sqrt(105/pi)
constant const float SH_C3_2 = -0.4570457994644658f;  // -0.25 * sqrt(21/(2*pi))
constant const float SH_C3_3 =  0.3731763325901154f;  //  0.25 * sqrt(7/pi)
constant const float SH_C3_4 = -0.4570457994644658f;  // -0.25 * sqrt(21/(2*pi))
constant const float SH_C3_5 =  1.445305721320277f;   //  0.25 * sqrt(105/pi)
constant const float SH_C3_6 = -0.5900435899266435f;  // -0.25 * sqrt(35/(2*pi))

// Spherical harmonics degree enum - must match Swift SHDegree
enum SHDegree: uint8_t
{
    SHDegree0 = 0,  // 1 coefficient (DC only)
    SHDegree1 = 1,  // 4 coefficients
    SHDegree2 = 2,  // 9 coefficients
    SHDegree3 = 3   // 16 coefficients
};

enum BufferIndex: int32_t
{
    BufferIndexUniforms    = 0,
    BufferIndexChunks      = 1,
    BufferIndexSplatIndex  = 2,
};

typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 viewMatrix;
    packed_float3 cameraPosition;  // World-space camera position for SH evaluation
    uint _padding0;                // Padding for alignment
    uint2 screenSize;

    // Precomputed values for covariance projection (derived from projectionMatrix and screenSize)
    float focalX;                  // screenSize.x * projectionMatrix[0][0] / 2
    float focalY;                  // screenSize.y * projectionMatrix[1][1] / 2
    float tanHalfFovX;             // 1 / projectionMatrix[0][0]
    float tanHalfFovY;             // 1 / projectionMatrix[1][1]

    uint chunkCount;

    /*
     The first N splats are represented as 2N primitives and 4N vertex indices. The remainder are represented
     as instances of these first N. This allows us to limit the size of the indexed array (and associated memory),
     but also avoid the performance penalty of a very large number of instances.
     */
    uint splatCount;
    uint indexedSplatCount;
} Uniforms;

typedef struct
{
    Uniforms uniforms[kMaxViewCount];
} UniformsArray;

// Keep in sync with EncodedSplatPoint
typedef struct
{
    packed_float3 position;
    packed_half4 color;
    packed_half3 covA;
    packed_half3 covB;
} Splat;

// Keep in sync with Swift: ChunkedSplatIndex
typedef struct
{
    uint16_t chunkIndex;
    uint16_t _padding;
    uint32_t splatIndex;
} ChunkedSplatIndex;

// Information about a single chunk, used in the chunk table
typedef struct
{
    device Splat* splats;
    device half* shCoefficients;   // Null for SH degree 0, otherwise higher-order SH coefficients
    uint32_t splatCount;
    SHDegree shDegree;             // Spherical harmonics degree for this chunk
    uint8_t enabled;               // Non-zero = enabled for rendering
    uint8_t _shPadding[2];         // Padding for alignment
} ChunkInfo;

typedef struct
{
    float4 position [[position]];
    half2 relativePosition; // Ranges from -kBoundsRadius to +kBoundsRadius
    half4 color;
} FragmentIn;

"""#),
        ("SplatProcessing.h", #"""
#import "ShaderCommon.h"

// MARK: - Spherical Harmonics

/// Evaluates spherical harmonics to compute view-dependent color.
half3 evaluateSH(float3 dir,
                 half3 sh0,
                 device const half* shCoeffs,
                 SHDegree shDegree,
                 uint splatIndex);

// MARK: - Covariance

float3 calcCovariance2D(float3 viewPos,
                        packed_half3 cov3Da,
                        packed_half3 cov3Db,
                        float4x4 viewMatrix,
                        float focalX,
                        float focalY,
                        float tanHalfFovX,
                        float tanHalfFovY);

void decomposeCovariance(float3 cov2D, thread float2 &v1, thread float2 &v2);

// MARK: - Vertex Processing

/// Vertex processing with spherical harmonics evaluation.
/// All splats use this path - splat.color contains raw SH0 coefficients.
/// For SH degree 0, shCoefficients can be nullptr.
FragmentIn splatVertex(Splat splat,
                       Uniforms uniforms,
                       uint relativeVertexIndex,
                       device const half* shCoefficients,
                       SHDegree shDegree,
                       uint splatIndex);

// MARK: - Fragment Processing

half splatFragmentAlpha(half2 relativePosition, half splatAlpha);

"""#),
        ("SplatProcessing.metal", #"""
#import "SplatProcessing.h"

// MARK: - Color Space Conversion

/// Converts sRGB color to linear color space.
/// This is needed because Metal with sRGB framebuffers expects linear input,
/// while SH evaluation produces sRGB output (matching the reference implementation).
inline half3 sRGBToLinear(half3 srgb) {
    // Using gamma 2.2 approximation (standard for 3DGS training)
    return pow(srgb, half3(2.2h));
}

// MARK: - Spherical Harmonics Evaluation

/// Evaluates spherical harmonics to compute view-dependent color.
/// - Parameters:
///   - dir: Normalized view direction vector (from camera to splat)
///   - sh0: DC term (raw SH band 0 coefficients, RGB)
///   - shCoeffs: Pointer to higher-order SH coefficients (can be null for degree 0)
///   - shDegree: The SH degree (0-3)
///   - splatIndex: Index of the splat (for computing offset into shCoeffs)
/// - Returns: Final RGB color after SH evaluation
inline half3 evaluateSH(float3 dir,
                        half3 sh0,
                        device const half* shCoeffs,
                        SHDegree shDegree,
                        uint splatIndex) {
    // Degree 0 (constant/ambient)
    float3 result = SH_C0 * float3(sh0);

    if (shDegree >= SHDegree1 && shCoeffs != nullptr) {
        float x = dir.x, y = dir.y, z = dir.z;

        // Calculate offset: SH1=3, SH2=8, SH3=15 coefficients (each is RGB triplet)
        uint coeffsPerSplat = (shDegree == SHDegree1) ? 3 :
                              (shDegree == SHDegree2) ? 8 : 15;
        device const packed_half3* sh = (device const packed_half3*)(shCoeffs + splatIndex * coeffsPerSplat * 3);

        // Degree 1: 3 basis functions
        result -= SH_C1 * y * float3(sh[0]);
        result += SH_C1 * z * float3(sh[1]);
        result -= SH_C1 * x * float3(sh[2]);

        if (shDegree >= SHDegree2) {
            float xx = x * x, yy = y * y, zz = z * z;
            float xy = x * y, yz = y * z, xz = x * z;
            float xxMinusYy = xx - yy;
            float xxPlusYy = xx + yy;

            // Degree 2: 5 basis functions
            result += SH_C2_0 * xy * float3(sh[3]);
            result += SH_C2_1 * yz * float3(sh[4]);
            result += SH_C2_2 * (2.0f * zz - xxPlusYy) * float3(sh[5]);
            result += SH_C2_3 * xz * float3(sh[6]);
            result += SH_C2_4 * xxMinusYy * float3(sh[7]);

            if (shDegree >= SHDegree3) {
                float zz4MinusXxYy = 4.0f * zz - xxPlusYy;

                // Degree 3: 7 basis functions
                result += SH_C3_0 * y * (3.0f * xx - yy) * float3(sh[8]);
                result += SH_C3_1 * xy * z * float3(sh[9]);
                result += SH_C3_2 * y * zz4MinusXxYy * float3(sh[10]);
                result += SH_C3_3 * z * (2.0f * zz - 3.0f * xxPlusYy) * float3(sh[11]);
                result += SH_C3_4 * x * zz4MinusXxYy * float3(sh[12]);
                result += SH_C3_5 * z * xxMinusYy * float3(sh[13]);
                result += SH_C3_6 * x * (xx - 3.0f * yy) * float3(sh[14]);
            }
        }
    }

    // Add 0.5 bias and clamp to non-negative (critical for correct colors)
    return half3(max(result + 0.5f, 0.0f));
}

// MARK: - Covariance Projection

float3 calcCovariance2D(float3 viewPos,
                        packed_half3 cov3Da,
                        packed_half3 cov3Db,
                        float4x4 viewMatrix,
                        float focalX,
                        float focalY,
                        float tanHalfFovX,
                        float tanHalfFovY) {
    float invViewPosZ = 1 / viewPos.z;
    float invViewPosZSquared = invViewPosZ * invViewPosZ;

    float limX = 1.3f * tanHalfFovX;
    float limY = 1.3f * tanHalfFovY;
    viewPos.x = clamp(viewPos.x * invViewPosZ, -limX, limX) * viewPos.z;
    viewPos.y = clamp(viewPos.y * invViewPosZ, -limY, limY) * viewPos.z;

    float3x3 J = float3x3(
        focalX * invViewPosZ, 0, 0,
        0, focalY * invViewPosZ, 0,
        -(focalX * viewPos.x) * invViewPosZSquared, -(focalY * viewPos.y) * invViewPosZSquared, 0
    );
    float3x3 W = float3x3(viewMatrix[0].xyz, viewMatrix[1].xyz, viewMatrix[2].xyz);
    float3x3 T = J * W;
    float3x3 Vrk = float3x3(
        cov3Da.x, cov3Da.y, cov3Da.z,
        cov3Da.y, cov3Db.x, cov3Db.y,
        cov3Da.z, cov3Db.y, cov3Db.z
    );
    float3x3 cov = T * Vrk * transpose(T);

    // Apply low-pass filter: every Gaussian should be at least
    // one pixel wide/high. Discard 3rd row and column.
    cov[0][0] += 0.3;
    cov[1][1] += 0.3;
    return float3(cov[0][0], cov[0][1], cov[1][1]);
}

// cov2D is a flattened 2d covariance matrix. Given
// covariance = | a b |
//              | c d |
// (where b == c because the Gaussian covariance matrix is symmetric),
// cov2D = ( a, b, d )
void decomposeCovariance(float3 cov2D, thread float2 &v1, thread float2 &v2) {
    float a = cov2D.x;
    float b = cov2D.y;
    float d = cov2D.z;
    float det = a * d - b * b; // matrix is symmetric, so "c" is same as "b"
    float trace = a + d;

    float mean = 0.5 * trace;
    float dist = max(0.1, sqrt(mean * mean - det)); // based on https://github.com/graphdeco-inria/diff-gaussian-rasterization/blob/main/cuda_rasterizer/forward.cu

    // Eigenvalues
    float lambda1 = mean + dist;
    float lambda2 = mean - dist;

    float2 eigenvector1;
    if (b == 0) {
        eigenvector1 = (a > d) ? float2(1, 0) : float2(0, 1);
    } else {
        eigenvector1 = normalize(float2(b, d - lambda2));
    }

    // Gaussian axes are orthogonal
    float2 eigenvector2 = float2(eigenvector1.y, -eigenvector1.x);

    v1 = eigenvector1 * sqrt(lambda1);
    v2 = eigenvector2 * sqrt(lambda2);
}

FragmentIn splatVertex(Splat splat,
                       Uniforms uniforms,
                       uint relativeVertexIndex,
                       device const half* shCoefficients,
                       SHDegree shDegree,
                       uint splatIndex) {
    FragmentIn out;

    float4 viewPosition4 = uniforms.viewMatrix * float4(splat.position, 1);
    float3 viewPosition3 = viewPosition4.xyz;

    // Early cull: skip splats behind or at the camera plane
    // (In view space, camera looks down -z, so z >= 0 means behind camera)
    if (viewPosition3.z >= 0) {
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    half3 srgbColor;
    if (shDegree == SHDegree0) {
        // Fast path for SH0
        srgbColor = half3(max(SH_C0 * float3(splat.color.rgb) + 0.5f, 0.0f));
    } else {
        float3 worldPosition = float3(splat.position);
        float3 viewDir = normalize(worldPosition - float3(uniforms.cameraPosition));
        srgbColor = evaluateSH(viewDir, splat.color.rgb, shCoefficients, shDegree, splatIndex);
    }

    float3 cov2D = calcCovariance2D(viewPosition3, splat.covA, splat.covB,
                                    uniforms.viewMatrix,
                                    uniforms.focalX, uniforms.focalY,
                                    uniforms.tanHalfFovX, uniforms.tanHalfFovY);

    float2 axis1;
    float2 axis2;
    decomposeCovariance(cov2D, axis1, axis2);

    float4 projectedCenter = uniforms.projectionMatrix * viewPosition4;

    float bounds = 1.2 * projectedCenter.w;
    if (projectedCenter.z < 0.0 ||
        projectedCenter.z > projectedCenter.w ||
        projectedCenter.x < -bounds ||
        projectedCenter.x > bounds ||
        projectedCenter.y < -bounds ||
        projectedCenter.y > bounds) {
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    const half2 relativeCoordinatesArray[] = { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } };
    half2 relativeCoordinates = relativeCoordinatesArray[relativeVertexIndex];
    half2 screenSizeFloat = half2(uniforms.screenSize.x, uniforms.screenSize.y);
    half2 projectedScreenDelta =
        (relativeCoordinates.x * half2(axis1) + relativeCoordinates.y * half2(axis2))
        * 2
        * kBoundsRadius
        / screenSizeFloat;

    out.position = float4(projectedCenter.x + projectedScreenDelta.x * projectedCenter.w,
                          projectedCenter.y + projectedScreenDelta.y * projectedCenter.w,
                          projectedCenter.z,
                          projectedCenter.w);
    out.relativePosition = kBoundsRadius * relativeCoordinates;

    // Convert from sRGB to linear to match Metal expectations for shader color output
    out.color = half4(sRGBToLinear(srgbColor), splat.color.a);
    return out;
}

half splatFragmentAlpha(half2 relativePosition, half splatAlpha) {
    half negativeMagnitudeSquared = -dot(relativePosition, relativePosition);
    return (negativeMagnitudeSquared < -kBoundsRadiusSquared) ? 0 : exp(0.5 * negativeMagnitudeSquared) * splatAlpha;
}

"""#),
        ("SingleStageRenderPath.metal", #"""
#include "SplatProcessing.h"

vertex FragmentIn singleStageSplatVertexShader(uint vertexID [[vertex_id]],
                                               uint instanceID [[instance_id]],
                                               ushort amplificationID [[amplification_id]],
                                               device const ChunkInfo* chunks [[ buffer(BufferIndexChunks) ]],
                                               constant ChunkedSplatIndex* splatIndexArray [[ buffer(BufferIndexSplatIndex) ]],
                                               constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]]) {
    Uniforms uniforms = uniformsArray.uniforms[min(int(amplificationID), kMaxViewCount)];

    uint splatID = instanceID * uniforms.indexedSplatCount + (vertexID / 4);
    if (splatID >= uniforms.splatCount) {
        FragmentIn out;
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    ChunkedSplatIndex idx = splatIndexArray[splatID];

    // Bounds check chunk index
    if (idx.chunkIndex >= uniforms.chunkCount) {
        FragmentIn out;
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    ChunkInfo chunk = chunks[idx.chunkIndex];

    // Bounds check local splat index; protects against transient stale indices.
    if (idx.splatIndex >= chunk.splatCount) {
        FragmentIn out;
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    if (!chunk.enabled) {
        FragmentIn out;
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    Splat splat = chunk.splats[idx.splatIndex];

    return splatVertex(splat, uniforms, vertexID % 4,
                       chunk.shCoefficients, chunk.shDegree,
                       idx.splatIndex);
}

fragment half4 singleStageSplatFragmentShader(FragmentIn in [[stage_in]]) {
    half alpha = splatFragmentAlpha(in.relativePosition, in.color.a);
    return half4(alpha * in.color.rgb, alpha);
}

"""#),
        ("MultiStageRenderPath.metal", #"""
#include "SplatProcessing.h"

typedef struct
{
    half4 color [[raster_order_group(0)]];
    float depth [[raster_order_group(0)]];
} FragmentValues;

typedef struct
{
    FragmentValues values [[imageblock_data]];
} FragmentStore;

typedef struct
{
    half4 color [[color(0)]];
    float depth [[depth(any)]];
} FragmentOut;

kernel void initializeFragmentStore(imageblock<FragmentValues, imageblock_layout_explicit> blockData,
                                    ushort2 localThreadID [[thread_position_in_threadgroup]]) {
    threadgroup_imageblock FragmentValues *values = blockData.data(localThreadID);
    values->color = { 0, 0, 0, 0 };
    values->depth = 0;
}

vertex FragmentIn multiStageSplatVertexShader(uint vertexID [[vertex_id]],
                                              uint instanceID [[instance_id]],
                                              ushort amplificationID [[amplification_id]],
                                              device const ChunkInfo* chunks [[ buffer(BufferIndexChunks) ]],
                                              constant ChunkedSplatIndex* splatIndexArray [[ buffer(BufferIndexSplatIndex) ]],
                                              constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]]) {
    Uniforms uniforms = uniformsArray.uniforms[min(int(amplificationID), kMaxViewCount)];

    uint splatID = instanceID * uniforms.indexedSplatCount + (vertexID / 4);
    if (splatID >= uniforms.splatCount) {
        FragmentIn out;
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    ChunkedSplatIndex idx = splatIndexArray[splatID];

    // Bounds check chunk index
    if (idx.chunkIndex >= uniforms.chunkCount) {
        FragmentIn out;
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    ChunkInfo chunk = chunks[idx.chunkIndex];

    // Bounds check local splat index; protects against transient stale indices.
    if (idx.splatIndex >= chunk.splatCount) {
        FragmentIn out;
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    if (!chunk.enabled) {
        FragmentIn out;
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    Splat splat = chunk.splats[idx.splatIndex];

    return splatVertex(splat, uniforms, vertexID % 4,
                       chunk.shCoefficients, chunk.shDegree,
                       idx.splatIndex);
}

fragment FragmentStore multiStageSplatFragmentShader(FragmentIn in [[stage_in]],
                                                     FragmentValues previousFragmentValues [[imageblock_data]]) {
    FragmentStore out;

    half alpha = splatFragmentAlpha(in.relativePosition, in.color.a);
    half4 colorWithPremultipliedAlpha = half4(in.color.rgb * alpha, alpha);

    half oneMinusAlpha = 1 - alpha;

    half4 previousColor = previousFragmentValues.color;
    out.values.color = previousColor * oneMinusAlpha + colorWithPremultipliedAlpha;

    float previousDepth = previousFragmentValues.depth;
    float depth = in.position.z;
    out.values.depth = previousDepth * oneMinusAlpha + depth * alpha;

    return out;
}

/// Generate a single triangle covering the entire screen
vertex FragmentIn postprocessVertexShader(uint vertexID [[vertex_id]]) {
    FragmentIn out;

    float4 position;
    position.x = (vertexID == 2) ? 3.0 : -1.0;
    position.y = (vertexID == 0) ? -3.0 : 1.0;
    position.zw = 1.0;

    out.position = position;
    return out;
}

fragment FragmentOut postprocessFragmentShader(FragmentValues fragmentValues [[imageblock_data]]) {
    FragmentOut out;
    out.depth = (fragmentValues.color.a == 0) ? 0 : fragmentValues.depth / fragmentValues.color.a;
    out.color = fragmentValues.color;
    return out;
}

fragment half4 postprocessFragmentShaderNoDepth(FragmentValues fragmentValues [[imageblock_data]]) {
    return fragmentValues.color;
}

"""#),
    ]
}
