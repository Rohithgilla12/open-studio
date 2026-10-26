// Sources/Recording/CameraFeed.swift (new; absorbs CameraCapture from Camera.swift).
//
// One AVCaptureSession per camera device in the process, shared by leases. The bubble and the
// recorder each hold a lease; the session runs while any lease is alive and stops when the last
// one goes. Nobody else configures the device, so the bubble always shows the format and frame
// rate the recorder writes.

import CoreMedia
import Foundation
public import QuartzCore

/// A claim on a running camera. Holding one keeps the camera lit.
public final class CameraLease: Sendable {
    /// nil for `.none`. Throws `.cameraNotFound` or `.captureFailedToStart`, as `start` does today.
    /// Acquiring a device that already has a feed shares it: no reconfiguration, no flash of the
    /// camera light, no second session competing for `activeFormat`.
    @MainActor
    public static func acquire(_ selection: CameraSelection) throws(RecordingError) -> CameraLease? {
        fatalError("not implemented")
    }

    /// A layer that shows the feed, mirrored like a mirror. Build one per bubble window. The type
    /// is a plain `CALayer` so no AVFoundation type crosses the module boundary, as with
    /// `PreviewPlayer.surface`.
    @MainActor
    public func makePreviewSurface() -> CALayer { fatalError("not implemented") }

    /// `.lost` once, when the device is unplugged, the session is interrupted, or it fails. Every
    /// lease of the feed sees it. The feed does not restart itself; a new `acquire` does.
    public var events: AsyncStream<CameraFeedEvent> { fatalError("not implemented") }

    /// Idempotent. `deinit` releases too, so a dropped lease never keeps the camera lit.
    public func release() { fatalError("not implemented") }

    /// The writer's size and rate. Chosen once per feed by `CameraFormat.plan`.
    var plan: CameraFormat.Plan { fatalError("not implemented") }
    var deviceName: String { fatalError("not implemented") }

    /// Routes the feed's data output to `consumer` on the sink's queue, so camera buffers arrive on
    /// the same executor as screen and audio buffers, as today. One consumer at a time; a second
    /// attach replaces the first. Detaching leaves the preview running.
    func attach(on queue: DispatchSerialQueue, _ consumer: @escaping (CMSampleBuffer, CMClock?) -> Void) {
        fatalError("not implemented")
    }

    func detach() { fatalError("not implemented") }
}

public enum CameraFeedEvent: Sendable, Equatable {
    case lost(String)
}

/// The process's feeds, keyed by `AVCaptureDevice.uniqueID`. Main-actor state: leases are taken
/// and dropped from the UI and from `RecordingSession.start`, which hops here for it.
@MainActor
enum CameraFeeds {
    // private static var running: [String: Feed] = [:]
    //
    // final class Feed {
    //     let session: AVCaptureSession       // one device input, one AVCaptureVideoDataOutput
    //     let plan: CameraFormat.Plan          // activeFormat and frame duration locked once
    //     var leases: Int
    //     var consumer: ((CMSampleBuffer, CMClock?) -> Void, DispatchSerialQueue)?
    // }
    //
    // Preview layers attach with AVCaptureVideoPreviewLayer(session:). Whether one session drives
    // a preview layer and a data output at once without changing the data output's rate is the
    // open measurement in spike/camera-preview (Camera not authorized for this run).
}
