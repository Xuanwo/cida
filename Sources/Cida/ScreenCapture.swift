import AppKit
import ImageIO
import ScreenCaptureKit

/// Where the capture shortcut gets the frozen screen it lets the user frame
/// text on (Pencil `Spec — 面板模型` §一 截图翻译).
protocol ScreenCaptureSource: Sendable {
  /// The whole of `screen` at its native pixel size, without the pointer.
  @MainActor func captureScreen(_ screen: NSScreen) async throws -> CGImage
}

enum ScreenCaptureError: Error {
  case displayUnavailable
  case unreadableImage
}

/// Captures a display through ScreenCaptureKit; needs the Screen Recording
/// permission.
struct SystemScreenCaptureSource: ScreenCaptureSource {
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

/// Isolated UI automation cannot hold the Screen Recording permission; it
/// freezes a fixture image instead, and the rest of the capture path runs
/// as in production.
struct FixtureScreenCaptureSource: ScreenCaptureSource {
  let imageURL: URL

  @MainActor
  func captureScreen(_ screen: NSScreen) async throws -> CGImage {
    guard
      let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw ScreenCaptureError.unreadableImage
    }
    return image
  }
}
