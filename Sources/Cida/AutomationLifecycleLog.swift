import AppKit

/// Appends timestamped panel and activation events to a file while the app
/// runs under isolated automation (`--automation-lifecycle-log <path>`).
///
/// A non-activating panel's key status and the app's activation state are
/// invisible to XCUI, so a failed journey cannot otherwise tell "the panel
/// never showed" from "the panel hid because it resigned key". Production
/// launches never create one.
@MainActor
final class AutomationLifecycleLog {
  private let handle: FileHandle
  private let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private var observers: [NSObjectProtocol] = []

  init?(url: URL) {
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: url.path, contents: nil),
      let handle = try? FileHandle(forWritingTo: url)
    else {
      return nil
    }
    self.handle = handle
  }

  func record(_ event: String, panel: NSWindow? = nil) {
    var fields = [
      timestampFormatter.string(from: Date()),
      event,
      "appActive=\(NSApp.isActive)",
      "policy=\(NSApp.activationPolicy().rawValue)",
    ]
    if let panel {
      fields.append("panelVisible=\(panel.isVisible)")
      fields.append("panelKey=\(panel.isKeyWindow)")
      fields.append("panelAlpha=\(panel.alphaValue)")
      fields.append("panelFrame=\(NSStringFromRect(panel.frame))")
      // Typing reaches the source only while the composer is first responder;
      // XCUI can only say that the panel has keyboard focus.
      fields.append(
        "firstResponder=\(panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
      if let content = panel.contentView {
        fields.append("contentFrame=\(NSStringFromRect(content.frame))")
        if let hosting = content.subviews.first {
          fields.append("hostingFrame=\(NSStringFromRect(hosting.frame))")
        }
      }
    }
    if let frontmost = NSWorkspace.shared.frontmostApplication {
      fields.append("frontmost=\(frontmost.bundleIdentifier ?? frontmost.localizedName ?? "?")")
    }
    handle.write(Data((fields.joined(separator: " ") + "\n").utf8))
  }

  /// Logs every activation and key-window transition of the app and `panel`.
  func observe(panel: NSWindow) {
    let center = NotificationCenter.default
    let panelEvents: [(Notification.Name, String)] = [
      (NSWindow.didBecomeKeyNotification, "panel-did-become-key"),
      (NSWindow.didResignKeyNotification, "panel-did-resign-key"),
      (NSWindow.didResizeNotification, "panel-did-resize"),
    ]
    for (name, event) in panelEvents {
      observers.append(
        center.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.record(event, panel: panel) }
        })
    }
    let appEvents: [(Notification.Name, String)] = [
      (NSApplication.didBecomeActiveNotification, "app-did-become-active"),
      (NSApplication.didResignActiveNotification, "app-did-resign-active"),
      (NSApplication.didHideNotification, "app-did-hide"),
    ]
    for (name, event) in appEvents {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.record(event, panel: panel) }
        })
    }
  }
}
