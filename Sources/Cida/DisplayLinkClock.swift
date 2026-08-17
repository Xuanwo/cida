import AppKit
import QuartzCore

struct DisplayPulse: Equatable, Sendable {
  let timestamp: CFTimeInterval
  let targetTimestamp: CFTimeInterval
  let duration: CFTimeInterval
}

@MainActor
final class DisplayLinkClock: NSObject {
  private weak var sourceView: NSView?
  private let handler: @MainActor (DisplayPulse) -> Void
  private var displayLink: CADisplayLink?

  init(
    sourceView: NSView,
    handler: @escaping @MainActor (DisplayPulse) -> Void
  ) {
    self.sourceView = sourceView
    self.handler = handler
  }

  isolated deinit {
    displayLink?.invalidate()
  }

  @discardableResult
  func start() -> Bool {
    guard displayLink == nil, let sourceView, sourceView.window != nil else { return false }

    let displayLink = sourceView.displayLink(
      target: self,
      selector: #selector(displayLinkDidFire(_:))
    )
    let maximumFramesPerSecond = Float(
      sourceView.window?.screen?.maximumFramesPerSecond ?? 60
    )
    displayLink.preferredFrameRateRange = CAFrameRateRange(
      minimum: min(30, maximumFramesPerSecond),
      maximum: maximumFramesPerSecond,
      preferred: maximumFramesPerSecond
    )
    displayLink.add(to: .main, forMode: .common)
    self.displayLink = displayLink
    return true
  }

  func invalidate() {
    displayLink?.invalidate()
    displayLink = nil
  }

  @objc
  private func displayLinkDidFire(_ displayLink: CADisplayLink) {
    handler(
      DisplayPulse(
        timestamp: displayLink.timestamp,
        targetTimestamp: displayLink.targetTimestamp,
        duration: displayLink.duration
      )
    )
  }
}
