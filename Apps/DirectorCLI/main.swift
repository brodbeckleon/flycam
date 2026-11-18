// director-cli: headless front end of DirectorCore. No window is ever opened.

import Foundation
import DirectorCore
import FlyCamKit

let usageText = """
director-cli \(DirectorCore.version)

Usage:
  director-cli render-transition <sessionA> <sessionB> <splat.ply> --out <file.mp4>
        [--duration 1.2] [--pre 0.5] [--post 0.5] [--fps <n>] [--start <t>] [--bitrate <bps>]
      Renders a take from session A to session B through the splat, offscreen, to an MP4.
      Also writes <file.mp4>.json with the per-frame weights and virtual camera.
  director-cli verify-transition <sessionA> <sessionB> <splat.ply> <file.mp4> [--min-psnr 35]
      Compares the endpoints of a rendered take with the source videos and checks that the middle
      frame shows the splat. Exit code 1 when a check fails.
  director-cli make-fixture <dir> [--frames 60] [--fps 30] [--spacing 0.04]
      Writes a generated splat (synthetic room) and two tripod sessions rendered from it.
  director-cli render-frame <splat.ply> <session> --frame <i> --out <file.png> [--depth <file.f32>]
      Renders the splat from the pose and intrinsics of frame i (Phase 3 overlay / refine_pose export).
  director-cli inspect <session>
      Prints a summary of a session folder.
  director-cli bench [--gaussians 1500000] [--width 1920] [--height 1080] [--frames 120]
      Offscreen render speed (splat pass + depth pass + mix) of a generated splat with an orbiting camera.
"""

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    options[key] = argv[i + 1]
                    i += 2
                } else {
                    options[key] = ""
                    i += 1
                }
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func double(_ k: String) throws -> Double? {
        guard let v = options[k] else { return nil }
        guard let d = Double(v) else { throw CLIError.usage("--\(k) needs a number, got \(v)") }
        return d
    }

    func url(_ i: Int) -> URL { URL(fileURLWithPath: positional[i]) }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case failed(String)
    var description: String {
        switch self {
        case .usage(let s): return "\(s)\n\n\(usageText)"
        case .failed(let s): return s
        }
    }
}

func run() async throws -> Int32 {
    var argv = Array(CommandLine.arguments.dropFirst())
    guard let cmd = argv.first else { print(usageText); return 2 }
    argv.removeFirst()
    let args = Args(argv)

    switch cmd {
    case "render-transition":
        guard args.positional.count == 3, let out = args.options["out"] else {
            throw CLIError.usage("render-transition needs <sessionA> <sessionB> <splat.ply> --out <file.mp4>")
        }
        var o = OfflineTransitionOptions()
        if let v = try args.double("duration") { o.config.duration = v }
        if let v = try args.double("pre") { o.pre = v }
        if let v = try args.double("post") { o.post = v }
        if let v = try args.double("fps") { o.fps = v }
        if let v = try args.double("start") { o.startTime = v }
        if let v = try args.double("bitrate") { o.bitRate = Int(v) }
        let outURL = URL(fileURLWithPath: out)
        let started = Date()
        let r = try await OfflineTransition.render(sessionA: args.url(0), sessionB: args.url(1), splat: args.url(2),
                                                   out: outURL, options: o) { done, total in
            if done % 10 == 0 || done == total {
                FileHandle.standardError.write("\rframe \(done)/\(total)".data(using: .utf8)!)
            }
        }
        FileHandle.standardError.write("\n".data(using: .utf8)!)
        print("wrote \(r.output.path) (\(r.log.count) frames, take at frame \(r.takeFrame), landing at frame \(r.landingFrame), "
              + "time base \(r.timeBase), \(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        print("wrote \(r.output.path).json")
        return 0

    case "verify-transition":
        guard args.positional.count == 4 else {
            throw CLIError.usage("verify-transition needs <sessionA> <sessionB> <splat.ply> <file.mp4>")
        }
        let report = try await TransitionVerification.verify(sessionA: args.url(0), sessionB: args.url(1),
                                                            splat: args.url(2), video: args.url(3))
        print(report.summary)
        let failures = report.failures(minPSNR: try args.double("min-psnr") ?? 35)
        if failures.isEmpty {
            print("verify-transition: PASS")
            return 0
        }
        for f in failures { print("FAIL: \(f)") }
        return 1

    case "make-fixture":
        guard args.positional.count == 1 else { throw CLIError.usage("make-fixture needs <dir>") }
        let frames = Int(try args.double("frames") ?? 60)
        let fps = try args.double("fps") ?? 30
        let spacing = Float(try args.double("spacing") ?? 0.04)
        let (splat, a, b) = try await SyntheticSession.writeTwoCameraFixture(to: args.url(0), frameCount: frames, fps: fps,
                                                                              spacing: spacing, context: try MetalContext.shared())
        print("splat:     \(splat.path)")
        print("session A: \(a.path)")
        print("session B: \(b.path)")
        return 0

    case "render-frame":
        guard args.positional.count == 2, let out = args.options["out"], let fs = args.options["frame"], let i = Int(fs) else {
            throw CLIError.usage("render-frame needs <splat.ply> <session> --frame <i> --out <file.png>")
        }
        let ctx = try MetalContext.shared()
        let scene = try await SplatScene.load(url: args.url(0), context: ctx)
        let frames = try SessionIO.readFrames(args.url(1))
        guard i >= 0 && i < frames.count else { throw CLIError.failed("frame \(i) out of range (0..<\(frames.count))") }
        var cam = frames[i].camera
        if let o = try SessionIO.readPoseOverride(args.url(1)) { cam.c2w = Mat4(columnMajor: o.c2w) }
        let targets = try SplatRenderTargets(context: ctx, width: cam.intrinsics.width, height: cam.intrinsics.height)
        try scene.renderSettled(camera: cam, targets: targets)
        try ImageExport.writePNG(renderTargets: targets, to: URL(fileURLWithPath: out), context: ctx)
        print("wrote \(out)")
        if let d = args.options["depth"] {
            try Readback.writeF32(try Readback.r32Float(targets.depth, context: ctx), to: URL(fileURLWithPath: d))
            print("wrote \(d) (float32 little-endian, \(cam.intrinsics.height) x \(cam.intrinsics.width), metres along the viewing axis, 0 = empty)")
        }
        return 0

    case "inspect":
        guard args.positional.count == 1 else { throw CLIError.usage("inspect needs <session>") }
        let s = try await RecordedSource(folder: args.url(0))
        print("session   \(s.name)  kind \(s.meta.kind.rawValue)  device \(s.meta.deviceModel)  iOS \(s.meta.osVersion)")
        print("frames    \(s.frameCount)  \(s.width)x\(s.height) @ \(s.meta.videoFormat.fps) fps  video frames \(s.video.frameCount)")
        if let r = s.availableTimes { print("time      \(r.lowerBound) ... \(r.upperBound) (\(s.timeBase))") }
        print("floor_y   \(s.floorY.map { String($0) } ?? "null")  clock_offset \(s.meta.clockOffset.map { String($0) } ?? "null")")
        print("override  \(s.poseOverride != nil ? "pose_override.json" : "none")")
        return 0

    case "bench":
        let n = Int(try args.double("gaussians") ?? 1_500_000)
        let w = Int(try args.double("width") ?? 1920), h = Int(try args.double("height") ?? 1080)
        let frames = Int(try args.double("frames") ?? 120)
        let ctx = try MetalContext.shared()
        // Gaussians spread through a 6 x 3 x 6 m room volume, small and fairly opaque (worst case for overdraw is a
        // trained splat; this measures throughput).
        var rng = SystemRandomNumberGenerator()
        var gs = [Gaussian]()
        gs.reserveCapacity(n)
        for _ in 0..<n {
            let p = SIMD3<Float>(Float.random(in: -3...3, using: &rng), Float.random(in: -1.3...1.5, using: &rng), Float.random(in: -4...2, using: &rng))
            gs.append(Gaussian(position: p, color: SIMD3(Float.random(in: 0...1, using: &rng), 0.5, 0.5), opacity: 0.6,
                               radius: Float.random(in: 0.005...0.03, using: &rng)))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flycam-bench.ply")
        try GaussianPLY.write(gs, to: url)
        let scene = try await SplatScene.load(url: url, context: ctx)
        try? FileManager.default.removeItem(at: url)
        let targets = try SplatRenderTargets(context: ctx, width: w, height: h)
        let comp = try Compositor(context: ctx)
        let out = try ctx.makeTexture(.bgra8Unorm_srgb, width: w, height: h, usage: [.renderTarget, .shaderRead])
        let k = Intrinsics(fx: Double(w) * 0.75, fy: Double(w) * 0.75, cx: Double(w) / 2 + 12.5, cy: Double(h) / 2 - 7.5, width: w, height: h)
        var times = [Double]()
        var skipped = 0
        for i in 0..<(frames + 10) {
            let a = Double(i) * 0.02
            let cam = PinholeCamera(intrinsics: k, c2w: Mat4.lookAt(eye: Vec3(3.5 * sin(a), 0.2, -1 + 3.5 * cos(a)), target: Vec3(0, -0.3, -1)))
            let t0 = MonotonicClock.now()
            let cb = ctx.queue.makeCommandBuffer()!
            if !(try scene.encode(camera: cam, targets: targets, commandBuffer: cb)) { skipped += 1 }
            comp.encodeMix(videoA: nil, render: targets, videoB: nil, weights: .renderOnly, output: out, commandBuffer: cb)
            try ctx.commitAndWait(cb)
            if i >= 10 { times.append(MonotonicClock.now() - t0) }
        }
        times.sort()
        let mean = times.reduce(0, +) / Double(times.count)
        print(String(format: "bench: %d Gaussians, %dx%d, %d frames: mean %.2f ms, median %.2f ms, p95 %.2f ms (%.0f fps at the mean), %d skipped by MetalSplatter",
                     scene.splatCount, w, h, times.count, mean * 1000, times[times.count / 2] * 1000,
                     times[Int(Double(times.count) * 0.95)] * 1000, 1 / mean, skipped))
        return 0

    case "-h", "--help", "help":
        print(usageText)
        return 0

    default:
        throw CLIError.usage("unknown command \(cmd)")
    }
}

let sem = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
    do {
        exitCode = try await run()
    } catch {
        FileHandle.standardError.write("director-cli: \(error)\n".data(using: .utf8)!)
        exitCode = 1
    }
    sem.signal()
}
sem.wait()
exit(exitCode)
