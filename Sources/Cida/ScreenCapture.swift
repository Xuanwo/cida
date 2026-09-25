import AppKit
import ScreenCaptureKit

enum ScreenCaptureError: Error {
  case displayUnavailable
}

/// Freezes the screen the capture shortcut lets the user frame text on
/// (`Design/spec/panel.md` §一 截图翻译): the whole of a display at its native
/// pixel size, without the pointer, through ScreenCaptureKit. Needs the
/// Screen Recording permission.
struct SystemScreenCaptureSource {
  @MainActor
  func captureScreen(_ screen: NSScreen) async throws -> CGImage {
    guard
      let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? CGDirectDisplayID
    else {
      throw ScreenCaptureError.displayUnavailable
    }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
      throw ScreenCaptureError.displayUnavailable
    }
    let configuration = SCStreamConfiguration()
    configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
    configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
    configuration.showsCursor = false
    configuration.captureResolution = .best
    return try await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(display: display, excludingWindows: []),
      configuration: configuration)
  }
}
