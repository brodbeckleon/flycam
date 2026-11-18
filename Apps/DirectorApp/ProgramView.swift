// Program output and the Phase 0 splat viewer, drawn with MTKView. All rendering is DirectorCore's.

import SwiftUI
import MetalKit
import DirectorCore
import FlyCamKit

struct ProgramView: NSViewRepresentable {
    @ObservedObject var model: DirectorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: model.context?.device)
        v.colorPixelFormat = .bgra8Unorm_srgb
        v.framebufferOnly = false
        v.autoResizeDrawable = false
        v.drawableSize = CGSize(width: 1920, height: 1080)
        v.preferredFramesPerSecond = 60
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let model: DirectorModel
        private var renderer: ProgramRenderer?
        private var frameNumber = 0

        init(model: DirectorModel) { self.model = model }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let ctx = model.context, let src = model.sources[model.controller.program], src.width > 0 else { return }
            if view.drawableSize != CGSize(width: src.width, height: src.height) {
                view.drawableSize = CGSize(width: src.width, height: src.height)
                return
            }
            if renderer == nil || renderer!.width != src.width || renderer!.height != src.height || renderer!.scene !== model.scene {
                renderer = try? ProgramRenderer(context: ctx, scene: model.scene, width: src.width, height: src.height,
                                                settled: false, floorY: model.floorY)
            }
            guard let renderer, let drawable = view.currentDrawable else { return }
            let t = model.now()
            let state = model.controller.state(at: t)
            do {
                try renderer.render(state: state, time: t, sources: model.sources, controller: model.controller,
                                    output: drawable.texture, frameNumber: frameNumber)
            } catch {
                DispatchQueue.main.async { self.model.message = "render: \(error)" }
            }
            frameNumber += 1
            let cb = ctx.queue.makeCommandBuffer()!
            cb.present(drawable)
            cb.commit()
            DispatchQueue.main.async { self.model.syncState() }
        }
    }
}

/// Phase 0 viewer: the splat with an orbit camera (drag to orbit, scroll to zoom) and explicit intrinsics.
struct SplatViewer: NSViewRepresentable {
    @ObservedObject var model: DirectorModel
    var intrinsics = Intrinsics(fx: 1400, fy: 1400, cx: 975, cy: 530, width: 1920, height: 1080)

    func makeCoordinator() -> Coordinator { Coordinator(model: model, intrinsics: intrinsics) }

    func makeNSView(context: Context) -> MTKView {
        let v = OrbitMTKView(frame: .zero, device: model.context?.device)
        v.colorPixelFormat = .bgra8Unorm_srgb
        v.framebufferOnly = false
        v.autoResizeDrawable = false
        v.drawableSize = CGSize(width: intrinsics.width, height: intrinsics.height)
        v.delegate = context.coordinator
        v.orbit = context.coordinator
        return v
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let model: DirectorModel
        let intrinsics: Intrinsics
        var yaw = 0.0, pitch = -0.2, distance = 3.0
        var target = Vec3(0, -0.6, -1.6)
        private var targets: SplatRenderTargets?
        private var compositor: Compositor?
        private var lastFrameTime = MonotonicClock.now()
        var fps = 0.0

        init(model: DirectorModel, intrinsics: Intrinsics) {
            self.model = model
            self.intrinsics = intrinsics
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let ctx = model.context, let scene = model.scene, let drawable = view.currentDrawable else { return }
            if targets == nil { targets = try? SplatRenderTargets(context: ctx, width: intrinsics.width, height: intrinsics.height) }
            if compositor == nil { compositor = try? Compositor(context: ctx) }
            guard let targets, let compositor else { return }
            let eye = target + Vec3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch)) * distance
            let cam = PinholeCamera(intrinsics: intrinsics, c2w: Mat4.lookAt(eye: eye, target: target))
            let cb = ctx.queue.makeCommandBuffer()!
            _ = try? scene.encode(camera: cam, targets: targets, commandBuffer: cb)
            compositor.encodeMix(videoA: nil, render: targets, videoB: nil, weights: .renderOnly,
                                 output: drawable.texture, commandBuffer: cb)
            cb.present(drawable)
            cb.commit()
            let now = MonotonicClock.now()
            fps = 0.9 * fps + 0.1 / max(now - lastFrameTime, 1e-4)
            lastFrameTime = now
        }
    }
}

final class OrbitMTKView: MTKView {
    weak var orbit: SplatViewer.Coordinator?
    override func mouseDragged(with event: NSEvent) {
        orbit?.yaw -= Double(event.deltaX) * 0.01
        orbit?.pitch = max(-1.4, min(1.4, (orbit?.pitch ?? 0) + Double(event.deltaY) * 0.01))
    }
    override func scrollWheel(with event: NSEvent) {
        orbit?.distance = max(0.3, (orbit?.distance ?? 3) * (1 - Double(event.scrollingDeltaY) * 0.01))
    }
}
