// LiveSource: one phone of a DirectorServer served through FrameSource (plan.md Phase 5). Times are Mac clock.

import Foundation
import FlyCamKit

public final class LiveSource: FrameSource {
    public let server: DirectorServer
    public let cameraID: UInt16
    /// Frozen pose for a fixed phone (pose_override.json / Phase 3 refinement). nil = per-frame pose from the header.
    public var poseOverride: Mat4?
    public var floorY: Double?

    public init(server: DirectorServer, cameraID: UInt16, poseOverride: Mat4? = nil, floorY: Double? = nil) {
        self.server = server
        self.cameraID = cameraID
        self.poseOverride = poseOverride
        self.floorY = floorY
    }

    public var name: String { server.cameraInfo(cameraID).map { "\($0.hello.deviceModel) (\(cameraID))" } ?? "camera \(cameraID)" }

    private var latest: StoredFrame<LiveFrame>? { server.withStore { $0.rings[cameraID]?.frames.last } }

    public var width: Int { Int(latest?.payload.header.width ?? 0) }
    public var height: Int { Int(latest?.payload.header.height ?? 0) }
    public var fps: Double { server.cameraInfo(cameraID)?.hello.videoFormat.fps ?? 0 }

    public var availableTimes: ClosedRange<Double>? {
        server.withStore { s in
            guard let r = s.rings[cameraID], let a = r.oldestTime, let b = r.newestTime else { return nil }
            return a...b
        }
    }

    public func frame(nearest time: Double) throws -> SourceFrame? {
        guard let f = server.withStore({ $0.rings[cameraID]?.nearest(to: time) }) else { return nil }
        let h = f.payload.header
        let c2w = poseOverride ?? h.c2wMatrix
        return SourceFrame(cameraID: cameraID, index: Int(h.frameIndex), time: f.macTime, phoneTime: h.timestamp,
                           camera: PinholeCamera(intrinsics: h.intrinsics, c2w: c2w), tracking: h.tracking,
                           pixelBuffer: f.payload.pixelBuffer)
    }
}
