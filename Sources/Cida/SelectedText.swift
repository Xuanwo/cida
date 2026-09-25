import AppKit
import ApplicationServices
import os

/// Where the global shortcut gets the text selected in the application the
/// user summoned the panel from (`Design/spec/panel.md` §一 带入选区).
protocol SelectedTextSource: Sendable {
  /// How long the shortcut waits for a selection before it shows the panel
  /// without one.
  var readDeadline: Duration { get }

  /// The selection, trimmed, or nil when there is none or it cannot be read.
  @MainActor func currentSelection() async -> String?
}

enum SelectedText {
  /// Trims the edges the way the source pane shows it; a selection of only
  /// whitespace is no selection.
  static func normalized(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }

  /// Reads the selection but gives up at the source's deadline: an
  /// application that does not answer must not hold the panel back. A late
  /// answer is dropped.
  @MainActor
  static func read(from source: any SelectedTextSource) async -> String? {
    await withCheckedContinuation { continuation in
      let isResumed = OSAllocatedUnfairLock(initialState: false)
      let resume: @Sendable (String?) -> Void = { selection in
        let isFirst = isResumed.withLock { resumed in
          defer { resumed = true }
          return !resumed
        }
        if isFirst {
          continuation.resume(returning: selection)
        }
      }
      let deadline = source.readDeadline
      Task { @MainActor in
        resume(await source.currentSelection())
      }
      Task {
        try? await Task.sleep(for: deadline)
        resume(nil)
      }
    }
  }
}

/// Reads the focused element of the frontmost application through the
/// Accessibility API. It never simulates ⌘C and never touches the
/// pasteboard, so applications that do not expose their selection this way
/// simply have none.
struct AccessibilitySelectedTextSource: SelectedTextSource {
  var readDeadline: Duration { .milliseconds(150) }

  /// Each Accessibility message gets at most this long; the read deadline
  /// bounds the whole exchange.
  private static let messagingTimeout: Float = 0.1

  @MainActor
  func currentSelection() async -> String? {
    guard
      AXIsProcessTrusted(),
      let application = NSWorkspace.shared.frontmostApplication,
      application.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else {
      return nil
    }
    let processIdentifier = application.processIdentifier
    let selection = await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInteractive).async {
        continuation.resume(returning: Self.readSelection(of: processIdentifier))
      }
    }
    return SelectedText.normalized(selection)
  }

  private static func readSelection(of processIdentifier: pid_t) -> String? {
    let application = AXUIElementCreateApplication(processIdentifier)
    AXUIElementSetMessagingTimeout(application, messagingTimeout)
    // Electron applications build their accessibility tree only for clients
    // that ask for it; the first read after this may still find nothing.
    AXUIElementSetAttributeValue(
      application, "AXManualAccessibility" as CFString, kCFBooleanTrue)

    var focusedValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
      let focusedValue,
      CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
    else {
      return nil
    }
    let focused = focusedValue as! AXUIElement
    AXUIElementSetMessagingTimeout(focused, messagingTimeout)
    if stringValue(of: focused, attribute: kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
      return nil
    }
    return stringValue(of: focused, attribute: kAXSelectedTextAttribute)
  }

  private static func stringValue(of element: AXUIElement, attribute: String) -> String? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    else {
      return nil
    }
    return value as? String
  }
}
