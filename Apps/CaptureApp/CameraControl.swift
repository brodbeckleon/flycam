// Locked exposure, white balance and focus through ARKit's primary capture device (plan.md Phase 1).
// Verify on the device: docs/track-m/manual-tests.md, Phase 1.

import Foundation
import ARKit
import AVFoundation
import FlyCamKit

final class CameraControl {
    private(set) var device: AVCaptureDevice?

    /// Must be called after the configuration was chosen and before or after `session.run`.
    func attach(to configuration: ARWorldTrackingConfiguration.Type = ARWorldTrackingConfiguration.self) {
        device = configuration.configurableCaptureDeviceForPrimaryCamera
    }

    var isAvailable: Bool { device != nil }

    struct Ranges {
        var iso: ClosedRange<Float>
        var shutter: ClosedRange<Double>
    }

    var ranges: Ranges? {
        guard let d = device else { return nil }
        let f = d.activeFormat
        return Ranges(iso: f.minISO...f.maxISO,
                      shutter: f.minExposureDuration.seconds...min(f.maxExposureDuration.seconds, 1.0 / 15))
    }

    /// Current values as reported by the device.
    func currentSettings(locked: Bool) -> CameraSettings {
        guard let d = device else { return CameraSettings(locked: false) }
        let tt = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
        return CameraSettings(locked: locked, iso: Double(d.iso), shutter: d.exposureDuration.seconds,
                              wbTemperature: Double(tt.temperature), wbTint: Double(tt.tint))
    }

    /// Locks exposure, white balance and focus at their current values.
    func lockCurrent() throws {
        guard let d = device else { return }
        try d.lockForConfiguration()
        defer { d.unlockForConfiguration() }
        if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
        if d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }
        if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
    }

    /// Applies manual values (nil = leave unchanged) and locks focus. Used by the UI and by
    /// `set_camera_settings` from the Mac (one phone's values pushed to all, plan.md Phase 5).
    func apply(lock: Bool, iso: Double?, shutter: Double?, wbTemperature: Double?, wbTint: Double?) throws {
        guard let d = device else { return }
        try d.lockForConfiguration()
        defer { d.unlockForConfiguration() }
        if !lock {
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            return
        }
        if iso != nil || shutter != nil, d.isExposureModeSupported(.custom) {
            let f = d.activeFormat
            let isoValue = iso.map { Float($0).clamped(f.minISO, f.maxISO) } ?? AVCaptureDevice.currentISO
            let dur = shutter.map { CMTime(seconds: $0, preferredTimescale: 1_000_000) } ?? AVCaptureDevice.currentExposureDuration
            d.setExposureModeCustom(duration: dur, iso: isoValue, completionHandler: nil)
        } else if d.isExposureModeSupported(.locked) {
            d.exposureMode = .locked
        }
        if wbTemperature != nil || wbTint != nil, d.isWhiteBalanceModeSupported(.locked) {
            let current = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
            let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: wbTemperature.map(Float.init) ?? current.temperature,
                tint: wbTint.map(Float.init) ?? current.tint)
            var gains = d.deviceWhiteBalanceGains(for: tt)
            let maxGain = d.maxWhiteBalanceGain
            gains.redGain = gains.redGain.clamped(1, maxGain)
            gains.greenGain = gains.greenGain.clamped(1, maxGain)
            gains.blueGain = gains.blueGain.clamped(1, maxGain)
            d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        } else if d.isWhiteBalanceModeSupported(.locked) {
            d.whiteBalanceMode = .locked
        }
        if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
    }
}

private extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
