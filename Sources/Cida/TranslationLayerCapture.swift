import AppKit
import CoreImage
import ScreenCaptureKit

struct LayerMotionUpdate: Sendable {
  let reference: Int
  let time: TimeInterval
  let offsets: [CGFloat?]
}

/// A window-only stream never includes Cida's overlay. Mutable image state lives exclusively
/// on `queue`; lifecycle calls and results belong to the pane session on the main actor.
final class LayerMotionCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.xuanwo.cida.layer-motion", qos: .userInitiated)
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let receive: @MainActor @Sendable (LayerMotionUpdate?) -> Void
  private var stream: SCStream?
  private var image: LayerMotionImage?
  private var imageTime: TimeInterval = 0
  private var frames: [CGRect] = []
  private var tracking: LayerMotionReference?
  private var reference = 0
  private var stopped = false

  private init(receive: @escaping @MainActor @Sendable (LayerMotionUpdate?) -> Void) {
    self.receive = receive
  }

  @MainActor
  static func start(
    windowID: CGWindowID, pane: CGRect,
    receive: @escaping @MainActor @Sendable (LayerMotionUpdate?) -> Void
  ) async throws -> LayerMotionCapture? {
    // AX-only users retain the existing settled-position fallback, without a new prompt.
    guard CGPreflightScreenCaptureAccess() else { return nil }
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: { $0.windowID == windowID }),
      window.frame.contains(pane), pane.width >= 32, pane.height >= 12
    else { return nil }
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = pane.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    configuration.width = Int(pane.width)
    configuration.height = Int(pane.height)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    configuration.queueDepth = 3
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    let capture = LayerMotionCapture(receive: receive)
    let stream = SCStream(
      filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: capture)
    capture.stream = stream
    try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
    try await stream.startCapture()
    return capture
  }

  func setReference(_ frames: [CGRect], revision: Int) {
    queue.async { [self] in
      guard !stopped else { return }
      self.frames = frames
      reference = revision
      tracking = image.map { LayerMotionReference(image: $0, frames: frames, time: imageTime) }
    }
  }

  @MainActor func stop() {
    queue.async { [self] in
      stopped = true
      image = nil
      tracking = nil
    }
    let stream = stream
    self.stream = nil
    Task { try? await stream?.stopCapture() }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    Task { @MainActor [receive] in receive(nil) }
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    guard !stopped, type == .screen, sample.isValid,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let rawStatus = attachments.first?[.status] as? Int,
      let status = SCFrameStatus(rawValue: rawStatus)
    else { return }
    if status == .idle, image != nil {
      imageTime = sample.presentationTimeStamp.seconds
      tracking?.confirmUnchanged(at: imageTime)
      deliver(at: imageTime)
      return
    }
    guard status == .complete, let buffer = sample.imageBuffer else { return }
    let source = CIImage(cvPixelBuffer: buffer)
    guard let cg = context.createCGImage(source, from: source.extent), let image = LayerMotionImage(image: cg) else { return }
    let unchanged = self.image.map { $0.width == image.width && $0.height == image.height && $0.pixels == image.pixels } ?? false
    self.image = image
    imageTime = sample.presentationTimeStamp.seconds
    if tracking == nil, !frames.isEmpty {
      tracking = LayerMotionReference(image: image, frames: frames, time: sample.presentationTimeStamp.seconds)
    } else {
      tracking?.update(image: image, time: sample.presentationTimeStamp.seconds, unchanged: unchanged)
    }
    deliver(at: sample.presentationTimeStamp.seconds)
  }

  private func deliver(at time: TimeInterval) {
    let update = LayerMotionUpdate(reference: reference, time: time, offsets: tracking?.offsets ?? [])
    Task { @MainActor [receive] in receive(update) }
  }
}
