import AppKit
import ApplicationServices
import CoreGraphics

/// A privacy permission a feature needs: whether Cida holds it, and the way
/// to ask for it (Pencil `Spec — 设置` §四). The system does not notify a
/// process when it is granted or revoked, so callers re-read `isGranted`.
struct SystemPermission: Sendable {
  let isGranted: @MainActor @Sendable () -> Bool
  let request: @MainActor @Sendable () -> Void

  /// Reading the frontmost application's selection. Asking shows the system
  /// prompt that leads to Privacy & Security › Accessibility.
  static let accessibility = SystemPermission(
    isGranted: { AXIsProcessTrusted() },
    request: {
      _ = AXIsProcessTrustedWithOptions(
        ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
  )

  /// Capturing the screen. The system shows its own prompt only the first
  /// time it is asked, so asking also opens Privacy & Security › Screen
  /// Recording, where the switch lives.
  static let screenRecording = SystemPermission(
    isGranted: { CGPreflightScreenCaptureAccess() },
    request: {
      guard !CGRequestScreenCaptureAccess() else { return }
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
      {
        NSWorkspace.shared.open(url)
      }
    }
  )

  /// Design fixtures and UI automation pin the state so they do not depend
  /// on the host.
  static func fixed(granted: Bool) -> SystemPermission {
    SystemPermission(isGranted: { granted }, request: {})
  }

  /// Posted by the system when the list of applications allowed to use
  /// accessibility changes.
  static let accessibilityDidChangeNotification = Notification.Name("com.apple.accessibility.api")
}
