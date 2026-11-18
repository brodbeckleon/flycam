# Vendored MetalSplatter

Upstream: https://github.com/scier/MetalSplatter, tag `1.0.1`, commit `71ff248e3016ac43c0a9271e322538421b28c360`
(MIT licence, `LICENSE`). Consumed by project.yml as a local Swift package at that pinned version.

## Why vendored

This Mac has Xcode 27.2 without the Metal Toolchain component (`xcodebuild` fails with
"cannot execute tool 'metal' due to missing Metal Toolchain"), and installing it is outside what
Track M may install. Upstream compiles its shaders at build time (`resources: [.process("Resources")]`),
so the unmodified package cannot be built here.

## Changes against upstream

1. `Package.swift`: only the `PLYIO`, `SplatIO` and `MetalSplatter` targets (no tests, sample renderer,
   converter or swift-argument-parser); `spz-swift` pinned to exactly 2.1.0.
2. `MetalSplatter/Resources/*` (the shaders) are embedded verbatim as string constants in
   `MetalSplatter/Sources/EmbeddedShaderSources.swift`; the target has no resources. With resources, Xcode
   copies `MetalSplatter_MetalSplatter.bundle` into apps and test bundles but not into the DirectorCore
   framework that links MetalSplatter statically, so `Bundle.module` crashed in the tests.
3. `SplatRenderer.init` concatenates the shader sources (`ShaderCommon.h`, `SplatProcessing.h`,
   `SplatProcessing.metal`, `SingleStageRenderPath.metal`, `MultiStageRenderPath.metal`, local includes removed)
   and compiles them with `MTLDevice.makeLibrary(source:options:)` (fast math, as upstream's build setting).
4. The loggers in `SplatRenderer` and `MetalBuffer` use a fixed subsystem instead of `Bundle.module.bundleIdentifier`.

No change to the rendering itself. Depth output was already available upstream: `render(...depthTexture:)`
stores the alpha-weighted NDC depth of the splats (high-quality depth path) with store action `.store`, so
DirectorCore reads it in a later pass without a fork.

## Going back to upstream

When the Metal Toolchain is installed (`xcodebuild -downloadComponent MetalToolchain`), project.yml can point
at `https://github.com/scier/MetalSplatter.git` with `exactVersion: 1.0.1` again; DirectorCore needs no change.
