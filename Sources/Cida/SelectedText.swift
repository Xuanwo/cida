import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// What the frontmost application says about its selection.
enum SelectionAnswer: Equatable, Sendable {
  /// The focused element's selection, trimmed.
  case selection(String)
  /// The focused element has nothing selected. The selection can still be
  /// somewhere else: Telegram Desktop keeps the focus in its message field
  /// while text in a message is selected. `elementText` is the text the
  /// element holds, nil when it does not say.
  case nothingSelected(elementText: String?)
  /// The application cannot say what is selected: it has no focused
  /// element, or its focused element does not offer `kAXSelectedText`. The
  /// error is what Accessibility reported.
  case unreadable(AXError)
  /// There is nothing to bring in and nothing to copy: a password field,
  /// Cida itself, no Accessibility permission, or no answer in time.
  case withheld
}

/// Where the global shortcut first asks for the text selected in the
/// application the user summoned the panel from (`Design/spec/panel.md` §一
/// 带入选区).
protocol SelectedTextSource: Sendable {
  /// How long the shortcut waits for an answer before it treats the
  /// selection as empty.
  var readDeadline: Duration { get }

  @MainActor func currentSelection() async -> SelectionAnswer
}

/// Gets the selection out of an application whose focused element cannot
/// give it, by having the application copy it (`Design/spec/panel.md` §一 复制兜底).
protocol SelectionCopier: Sendable {
  /// The copied text, trimmed, or nil when the application copied nothing
  /// that reads as text. The pasteboard is left as it was.
  @MainActor func copySelection() async -> String?
}

extension SelectionAnswer: CustomStringConvertible {
  var description: String {
    switch self {
    case .selection: "selection"
    case .nothingSelected: "none"
    case .unreadable(let error): "unreadable(\(error.rawValue))"
    case .withheld: "withheld"
    }
  }
}

extension Duration {
  var milliseconds: Int64 {
    components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
  }
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

  /// Reads the selection through `source`, and copies it through `copier`
  /// when the focused element has none to give. `record` hears how the
  /// selection was found.
  @MainActor
  static func read(
    from source: any SelectedTextSource, copyingWith copier: any SelectionCopier,
    record: (String) -> Void = { _ in }
  ) async -> String? {
    let clock = ContinuousClock()
    let startedAt = clock.now
    let answer = await answer(from: source)
    record("selection-answer \(answer) ms=\(startedAt.duration(to: clock.now).milliseconds)")
    let elementText: String?
    switch answer {
    case .selection(let selection):
      return selection
    case .withheld:
      return nil
    case .unreadable:
      elementText = nil
    case .nothingSelected(let text):
      elementText = text
    }
    let copiedAt = clock.now
    let copied = await copier.copySelection()
    // With nothing selected, VS Code copies the line the cursor is on, and
    // that line is in the element's own text; a selection somewhere else is
    // not.
    let isElementLine = copied.map { elementText?.contains($0) ?? false } ?? false
    record(
      "selection-copied found=\(copied != nil) element-line=\(isElementLine) ms=\(copiedAt.duration(to: clock.now).milliseconds)"
    )
    return isElementLine ? nil : copied
  }

  /// Asks `source` but gives up at its deadline: an application that does
  /// not answer must not hold the panel back, and one that is that slow would
  /// not copy in time either, so it is not asked to. A late answer is
  /// dropped.
  @MainActor
  static func answer(from source: any SelectedTextSource) async -> SelectionAnswer {
    await withCheckedContinuation { continuation in
      let isResumed = OSAllocatedUnfairLock(initialState: false)
      let resume: @Sendable (SelectionAnswer) -> Void = { answer in
        let isFirst = isResumed.withLock { resumed in
          defer { resumed = true }
          return !resumed
        }
        if isFirst {
          continuation.resume(returning: answer)
        }
      }
      let deadline = source.readDeadline
      Task { @MainActor in
        resume(await source.currentSelection())
      }
      Task {
        try? await Task.sleep(for: deadline)
        resume(.withheld)
      }
    }
  }
}

/// Reads the focused element of the frontmost application through the
/// Accessibility API.
struct AccessibilitySelectedTextSource: SelectedTextSource {
  var readDeadline: Duration { .milliseconds(150) }

  /// Each Accessibility message gets at most this long; the read deadline
  /// bounds the whole exchange.
  private static let messagingTimeout: Float = 0.1

  @MainActor
  func currentSelection() async -> SelectionAnswer {
    guard
      AXIsProcessTrusted(),
      let application = NSWorkspace.shared.frontmostApplication,
      application.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else {
      return .withheld
    }
    let processIdentifier = application.processIdentifier
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInteractive).async {
        continuation.resume(returning: Self.readSelection(of: processIdentifier))
      }
    }
  }

  private static func readSelection(of processIdentifier: pid_t) -> SelectionAnswer {
    let application = AXUIElementCreateApplication(processIdentifier)
    AXUIElementSetMessagingTimeout(application, messagingTimeout)
    // Electron applications build their accessibility tree only for clients
    // that ask for it; the first read after this may still find nothing.
    AXUIElementSetAttributeValue(
      application, "AXManualAccessibility" as CFString, kCFBooleanTrue)

    var focusedValue: CFTypeRef?
    let focusedError = AXUIElementCopyAttributeValue(
      application, kAXFocusedUIElementAttribute as CFString, &focusedValue)
    guard
      focusedError == .success,
      let focusedValue,
      CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
    else {
      return .unreadable(focusedError)
    }
    let focused = focusedValue as! AXUIElement
    AXUIElementSetMessagingTimeout(focused, messagingTimeout)
    var subrole: CFTypeRef?
    if AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
      == .success, subrole as? String == kAXSecureTextFieldSubrole
    {
      return .withheld
    }
    var selected: CFTypeRef?
    switch AXUIElementCopyAttributeValue(
      focused, kAXSelectedTextAttribute as CFString, &selected)
    {
    case .success:
      guard let text = selected as? String else { return .unreadable(.illegalArgument) }
      if let selection = SelectedText.normalized(text) {
        return .selection(selection)
      }
      return .nothingSelected(elementText: heldText(of: focused))
    // The element has the attribute but nothing in it: nothing is selected.
    case .noValue:
      return .nothingSelected(elementText: heldText(of: focused))
    case let error:
      return .unreadable(error)
    }
  }

  private static func heldText(of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
    else {
      return nil
    }
    return value as? String
  }
}

/// Sends ⌘C to the frontmost application and takes the text it copies, then
/// puts the pasteboard back the way it was (`Design/spec/panel.md` §一 复制兜底).
struct PasteboardSelectionCopier: SelectionCopier {
  /// How long the application gets to copy before the selection counts as
  /// empty.
  var copyDeadline: Duration = .milliseconds(150)
  /// How long a copy that arrives after the deadline is still put back.
  var lateCopyWindow: Duration = .seconds(1)
  var pasteboardName: NSPasteboard.Name = .general
  /// Sends the copy command; false when it could not be sent.
  var postCopyCommand: @MainActor @Sendable () -> Bool = CopyCommand.post

  @MainActor
  func copySelection() async -> String? {
    let pasteboard = NSPasteboard(name: pasteboardName)
    let snapshot = PasteboardSnapshot(of: pasteboard)
    let changeCount = pasteboard.changeCount
    guard postCopyCommand() else { return nil }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: copyDeadline)
    // The application clears the pasteboard before it writes, so a changed
    // count with no types yet means the copy is still being written.
    while pasteboard.changeCount == changeCount || pasteboard.types?.isEmpty != false,
      clock.now < deadline
    {
      try? await Task.sleep(for: .milliseconds(5))
    }
    guard pasteboard.changeCount != changeCount else {
      putBackLateCopy(on: pasteboard, after: changeCount, restoring: snapshot)
      return nil
    }
    let text = Self.copiedText(on: pasteboard)
    snapshot.restore(to: pasteboard)
    return text
  }

  /// Only text counts: files copied in Finder also carry their names as
  /// text, and an image is not a selection to translate.
  @MainActor
  static func copiedText(on pasteboard: NSPasteboard) -> String? {
    let copiesFiles = pasteboard.canReadObject(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    guard !copiesFiles else { return nil }
    return SelectedText.normalized(pasteboard.string(forType: .string))
  }

  /// A slow application may copy after the deadline. One change within the
  /// window is taken to be that copy and put back; any other count means
  /// someone else wrote to the pasteboard, and that is left alone.
  @MainActor
  private func putBackLateCopy(
    on pasteboard: NSPasteboard, after changeCount: Int, restoring snapshot: PasteboardSnapshot
  ) {
    let window = lateCopyWindow
    Task { @MainActor in
      let clock = ContinuousClock()
      let end = clock.now.advanced(by: window)
      while pasteboard.changeCount == changeCount, clock.now < end {
        try? await Task.sleep(for: .milliseconds(20))
      }
      guard pasteboard.changeCount == changeCount + 1 else { return }
      snapshot.restore(to: pasteboard)
    }
  }
}

/// Every item on the pasteboard with the data of each of its types, so that
/// it can be written back unchanged.
struct PasteboardSnapshot {
  /// Tells clipboard managers not to record a write
  /// (http://nspasteboard.org): the contents put back are already in their
  /// history.
  static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

  private let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

  @MainActor
  init(of pasteboard: NSPasteboard) {
    items = (pasteboard.pasteboardItems ?? []).map { item in
      item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
  }

  @MainActor
  func restore(to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    guard !items.isEmpty else { return }
    let restored = items.map { entries in
      let item = NSPasteboardItem()
      for entry in entries {
        item.setData(entry.data, forType: entry.type)
      }
      return item
    }
    restored[0].setData(Data(), forType: Self.transientType)
    pasteboard.writeObjects(restored)
  }
}

/// ⌘C as the frontmost application receives it from the keyboard.
enum CopyCommand {
  /// Posts ⌘C with only ⌘ held: the user is still holding the shortcut's ⌥,
  /// and ⌥⌘C is a different command (Finder's Copy as Pathname). Nothing is
  /// posted while secure input is on, when keystrokes are not meant to be
  /// seen or synthesized.
  @MainActor
  static func post() -> Bool {
    guard !IsSecureEventInputEnabled() else { return false }
    let source = CGEventSource(stateID: .privateState)
    let keyCode = CGKeyCode(keyCode(typing: "c") ?? kVK_ANSI_C)
    guard
      let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    else {
      return false
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cgSessionEventTap)
    up.post(tap: .cgSessionEventTap)
    return true
  }

  /// The key that types `character` with ⌘ held in the current keyboard
  /// layout: C is not on the same key in Dvorak, and "Dvorak - QWERTY ⌘"
  /// moves it back only while ⌘ is down.
  private static func keyCode(typing character: Character) -> Int? {
    guard
      let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else {
      return nil
    }
    let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
    let commandState = UInt32((cmdKey >> 8) & 0xFF)
    return layoutData.withUnsafeBytes { buffer -> Int? in
      guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
        return nil
      }
      for keyCode in 0..<128 {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
          layout, UInt16(keyCode), UInt16(kUCKeyActionDown), commandState,
          UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
          &deadKeyState, characters.count, &length, &characters)
        if status == noErr, length == 1,
          String(utf16CodeUnits: characters, count: 1) == String(character)
        {
          return keyCode
        }
      }
      return nil
    }
  }
}
