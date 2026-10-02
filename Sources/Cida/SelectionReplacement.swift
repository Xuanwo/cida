import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// A captured selection keeps its raw text even when its field cannot safely be edited.
@MainActor
protocol SelectionReplacementTarget: AnyObject {
  var text: String { get }
  var isCurrent: Bool { get }
  func replace(with text: String) async -> SelectionReplacementOutcome
  func stopObserving()
}

enum SelectionReplacementOutcome: Equatable {
  case replaced
  case unchanged
  case unavailable
  /// A paste was dispatched, but the application did not confirm the expected text.
  case unconfirmed

  var note: String {
    switch self {
    case .replaced: "已替换 · ⌘Z 撤销"
    case .unchanged: "无需修改 · 原文未变"
    case .unavailable: "编辑位置已变化或无法直接替换，请复制结果后手动使用。"
    case .unconfirmed: "替换结果未确认，请先检查原文；结果仍可复制，不会自动重试。"
    }
  }
}

/// Owns only the temporary pasteboard write. A timeout must not restore old data that a
/// delayed paste consumer could still read. A newer clipboard owner is never overwritten.
@MainActor
struct SelectionPaste {
  var pasteboard: NSPasteboard = .general
  var deadline: Duration = .seconds(1)

  func perform(
    text: String, isCurrent: () -> Bool, post: () -> Bool, didReplace: () -> Bool
  ) async -> SelectionReplacementOutcome {
    guard isCurrent(), !Task.isCancelled else { return .unavailable }
    let saved = PasteboardSnapshot(of: pasteboard)
    guard isCurrent(), !Task.isCancelled else { return .unavailable }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    pasteboard.setData(Data(), forType: PasteboardSnapshot.transientType)
    let ownedCount = pasteboard.changeCount
    guard post() else {
      if pasteboard.changeCount == ownedCount { saved.restore(to: pasteboard) }
      return .unavailable
    }
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: deadline)
    repeat {
      if didReplace() {
        if pasteboard.changeCount == ownedCount { saved.restore(to: pasteboard) }
        return .replaced
      }
      // Once dispatched, cancellation cannot recall a paste. Still observe it before
      // deciding whether the old clipboard can be restored.
      try? await Task.sleep(for: .milliseconds(20))
    } while clock.now < end && !Task.isCancelled
    return .unconfirmed
  }
}

/// Captures and validates the actual foreground editor. It never moves focus or changes
/// the selection. AX calls have short per-message timeouts and tree traversal is bounded.
@MainActor
final class AccessibilitySelectionTarget: SelectionReplacementTarget {
  let text: String
  private let processIdentifier: pid_t
  private let application: AXUIElement
  private let element: AXUIElement
  private let originalValue: String?
  private let originalRange: NSRange?
  private let editable: Bool
  private var invalidated = false
  private var monitor: Any?
  private var activationObserver: NSObjectProtocol?
  private var validationTask: Task<Void, Never>?

  private init(
    text: String, processIdentifier: pid_t, application: AXUIElement, element: AXUIElement
  ) {
    self.text = text
    self.processIdentifier = processIdentifier
    self.application = application
    self.element = element
    originalValue = Self.attribute(element, kAXValueAttribute) as? String
    originalRange = Self.selectedRange(element)
    let role = Self.attribute(element, kAXRoleAttribute) as? String
    var settable = DarwinBoolean(false)
    AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
    editable = [kAXTextAreaRole, kAXTextFieldRole].contains(role ?? "") && settable.boolValue
    monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
      [weak self] _ in self?.invalidated = true
    }
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.invalidated = true }
    }
    validationTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard let self, !Task.isCancelled else { return }
        if !isCurrent { invalidated = true; return }
      }
    }
  }

  static func capture() -> AccessibilitySelectionTarget? {
    guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
      let frontmost = NSWorkspace.shared.frontmostApplication,
      frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return nil }
    let app = AXUIElementCreateApplication(frontmost.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 0.03)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    guard let element = focusedElement(in: app),
      attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
      let text = attribute(element, kAXSelectedTextAttribute) as? String,
      SelectedText.normalized(text) != nil
    else { return nil }
    return AccessibilitySelectionTarget(
      text: text, processIdentifier: frontmost.processIdentifier, application: app, element: element)
  }

  var isCurrent: Bool {
    guard !invalidated, editable, !IsSecureEventInputEnabled(),
      NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
      let current = Self.focusedElement(in: application), CFEqual(current, element),
      let originalRange, let originalValue,
      originalRange.location <= (originalValue as NSString).length,
      originalRange.length <= (originalValue as NSString).length - originalRange.location,
      (originalValue as NSString).substring(with: originalRange) == text,
      Self.selectedRange(element) == originalRange,
      Self.attribute(element, kAXSelectedTextAttribute) as? String == text,
      Self.attribute(element, kAXValueAttribute) as? String == originalValue
    else { return false }
    return true
  }

  func replace(with output: String) async -> SelectionReplacementOutcome {
    guard isCurrent, let originalValue, let originalRange else { return .unavailable }
    if output == text { return .unchanged }
    let expected = (originalValue as NSString).replacingCharacters(in: originalRange, with: output)
    let outcome = await SelectionPaste().perform(
      text: output, isCurrent: { self.isCurrent },
      post: {
        guard self.isCurrent else { return false }
        self.stopObserving()
        // PID-directed delivery cannot paste into another app after a focus handoff.
        return TextEditingCommand.post(character: "v", to: self.processIdentifier)
      },
      didReplace: { Self.attribute(self.element, kAXValueAttribute) as? String == expected })
    return outcome
  }

  func stopObserving() {
    validationTask?.cancel()
    validationTask = nil
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    activationObserver = nil
  }

  private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(element, 0.03)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
  }

  private static func selectedRange(_ element: AXUIElement) -> NSRange? {
    guard let value = attribute(element, kAXSelectedTextRangeAttribute),
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length > 0
    else { return nil }
    return NSRange(location: range.location, length: range.length)
  }

  private static func focusedElement(in app: AXUIElement) -> AXUIElement? {
    if let value = attribute(app, kAXFocusedUIElementAttribute),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    {
      return (value as! AXUIElement)
    }
    // Chromium may initially omit the root focused-element attribute. Only an explicitly
    // focused text field counts; never guess by its text or choose the first editor.
    let end = ContinuousClock.now.advanced(by: .milliseconds(120))
    var remaining = 100
    func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
      guard depth < 18, remaining > 0, ContinuousClock.now < end else { return nil }
      remaining -= 1
      let role = attribute(element, kAXRoleAttribute) as? String
      if [kAXTextAreaRole, kAXTextFieldRole].contains(role ?? ""),
        attribute(element, kAXFocusedAttribute) as? Bool == true { return element }
      for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = find(child, depth: depth + 1) { return found }
      }
      return nil
    }
    return find(app, depth: 0)
  }
}
