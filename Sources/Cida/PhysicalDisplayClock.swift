import CDisplayClock
import CoreGraphics

private final class PhysicalDisplayClockCallbackBridge: @unchecked Sendable {
  let handler: @Sendable (CFTimeInterval) -> Void

  init(handler: @escaping @Sendable (CFTimeInterval) -> Void) {
    self.handler = handler
  }
}

private func physicalDisplayClockCallback(
  _ context: UnsafeMutableRawPointer?,
  _ callbackTimeSeconds: Double
) {
  guard let context else { return }
  Unmanaged<PhysicalDisplayClockCallbackBridge>
    .fromOpaque(context)
    .takeUnretainedValue()
    .handler(callbackTimeSeconds)
}

final class PhysicalDisplayClock: @unchecked Sendable {
  private let callbackBridge: PhysicalDisplayClockCallbackBridge
  private var rawClock: OpaquePointer?

  init?(
    displayID: CGDirectDisplayID,
    handler: @escaping @Sendable (CFTimeInterval) -> Void
  ) {
    let callbackBridge = PhysicalDisplayClockCallbackBridge(handler: handler)
    guard
      let rawClock = cida_display_clock_create(
        displayID,
        physicalDisplayClockCallback,
        Unmanaged.passUnretained(callbackBridge).toOpaque()
      )
    else {
      return nil
    }
    self.callbackBridge = callbackBridge
    self.rawClock = rawClock
  }

  deinit {
    invalidate()
  }

  @discardableResult
  func start() -> Bool {
    guard let rawClock else { return false }
    return cida_display_clock_start(rawClock)
  }

  func invalidate() {
    guard let rawClock else { return }
    cida_display_clock_destroy(rawClock)
    self.rawClock = nil
  }
}
