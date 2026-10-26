// Sketch. Module Recording. One camera, one AVCaptureSession, two consumers.
//
//   CameraFeed (owned by Studio while the bubble is up, or by osrec for a take)
//     AVCaptureSession
//       AVCaptureDeviceInput(device)              activeFormat per CameraFormat.plan, as today
//       AVCaptureVideoPreviewLayer                 ◀── the bubble, aspect fill, mirrored
//       AVCaptureVideoDataOutput (recorder's)      ◀── attached by prepare(), removed by cancel/stop/discard,
//                                                      delegate on the CaptureSink queue, as today
//
// The feed is the only place a camera is resolved and opened. `CameraCapture` is deleted; its
// session setup, format pinning, and lost-camera notifications move here.

import AVFoundation
public import Foundation

/// A running camera. Opening one lights the camera and asks for Camera permission if needed, so
/// Studio opens it when the person chooses a camera on Home (the bubble appears) and closes it when
/// they choose None or leave for the editor. The light being on means the bubble is up.
///
/// `@unchecked Sendable` for the AVFoundation objects, each configured in `open` and then only
/// started, stopped, and handed to one preview layer and one data output.
public final class CameraFeed: @unchecked Sendable {
    public let selection: CameraSelection
    public let device: CameraInfo

    /// Resolves the selection as `CaptureSources.resolve(_:)` does today (`.cameraNotFound`,
    /// `.captureFailedToStart`), configures the session, and starts it. `startRunning` takes a few
    /// hundred milliseconds (documented and seen in the camera design); it runs off the main thread
    /// and this returns once frames can flow.
    public static func open(_ selection: CameraSelection) async throws(RecordingError) -> CameraFeed {
        fatalError("not implemented")
    }

    /// A layer showing the live camera, for the bubble. One per feed; the caller sets its frame,
    /// gravity (`.resizeAspectFill`), and mirroring. Rendering a preview alongside a data output on
    /// one session is AVFoundation's documented session model (inferred, not measured here:
    /// `spike/camera-share.swift` counts data-output frames with and without the layer when run
    /// from a terminal with Camera access).
    @MainActor public var previewLayer: AVCaptureVideoPreviewLayer { fatalError("not implemented") }

    /// What the bubble shows beside the picture. `lost` after a disconnect, interruption, or
    /// runtime error; the picture freezes or goes black and the bubble labels it.
    public enum Health: Sendable, Equatable {
        case running
        case lost(String)
    }

    public var health: AsyncStream<Health> { fatalError("not implemented") }

    /// Stops the session. Idempotent. A feed attached to a live recorder is not closed by Studio:
    /// the recorder holds it until its take ends, and the bubble's layer keeps showing it.
    public func close() {
        fatalError("not implemented")
    }

    /// The recorder's side. Adds a video data output delivering on `queue` through
    /// `beginConfiguration`/`commitConfiguration`, which AVFoundation allows on a running session
    /// (documented; measured by the spike's phase 3 when run). At most one recorder at a time: a
    /// second attach throws `.captureFailedToStart`.
    func attachRecorder(
        queue: DispatchSerialQueue, onFrame: @escaping (CMSampleBuffer, CMClock?) -> Void,
        onLost: @escaping @Sendable (String) -> Void
    ) throws(RecordingError) -> RecorderAttachment {
        fatalError("not implemented")
    }

    /// Returned by `attachRecorder`; `detach()` removes the output and is idempotent. Dropping the
    /// attachment without detaching is a programmer error caught by a `deinit` assertion.
    final class RecorderAttachment {
        func detach() { fatalError("not implemented") }
    }
}

// What happens in each case the brief names:
// - Change camera on Home: Studio closes the old feed and opens the new one; the bubble swaps its
//   layer. Not possible during a take: Home is hidden and `readiness` is `.busy`.
// - Unplugged mid-take: the feed reports `.lost`; the recorder ends `camera.mov` where it was
//   (today's `cameraLost` path, unchanged); the bubble shows "Camera disconnected". The screen,
//   audio, and events carry on. After the take, Home re-lists cameras and reopens a feed for the
//   preference, or none.
// - No camera but "bubble on": not a state. The bubble is the feed is the chosen camera. A person
//   who wants to see themselves without recording themselves is an open question, not v1.
