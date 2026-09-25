import AppKit
import Carbon.HIToolbox

/// A key combination that works from any application: showing the panel or
/// capturing text on screen (`Design/spec/settings.md` §四). It always carries ⌘,
/// ⌥ or ⌃, so plain typing in another application can never trigger it.
struct GlobalShortcut: Equatable, Hashable, Sendable {
  struct Modifiers: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    static let control = Modifiers(rawValue: 1 << 0)
    static let option = Modifiers(rawValue: 1 << 1)
    static let shift = Modifiers(rawValue: 1 << 2)
    static let command = Modifiers(rawValue: 1 << 3)
    /// At least one of these makes a combination a shortcut.
    static let required: Modifiers = [.control, .option, .command]

    init(rawValue: UInt8) {
      self.rawValue = rawValue
    }

    init(_ flags: NSEvent.ModifierFlags) {
      var modifiers = Modifiers()
      if flags.contains(.control) { modifiers.insert(.control) }
      if flags.contains(.option) { modifiers.insert(.option) }
      if flags.contains(.shift) { modifiers.insert(.shift) }
      if flags.contains(.command) { modifiers.insert(.command) }
      self = modifiers
    }

    var eventFlags: NSEvent.ModifierFlags {
      var flags: NSEvent.ModifierFlags = []
      if contains(.control) { flags.insert(.control) }
      if contains(.option) { flags.insert(.option) }
      if contains(.shift) { flags.insert(.shift) }
      if contains(.command) { flags.insert(.command) }
      return flags
    }

    var carbonFlags: UInt32 {
      var flags: UInt32 = 0
      if contains(.control) { flags |= UInt32(controlKey) }
      if contains(.option) { flags |= UInt32(optionKey) }
      if contains(.shift) { flags |= UInt32(shiftKey) }
      if contains(.command) { flags |= UInt32(cmdKey) }
      return flags
    }

    /// In the order macOS prints them: ⌃ ⌥ ⇧ ⌘.
    var symbols: [String] {
      var symbols: [String] = []
      if contains(.control) { symbols.append("⌃") }
      if contains(.option) { symbols.append("⌥") }
      if contains(.shift) { symbols.append("⇧") }
      if contains(.command) { symbols.append("⌘") }
      return symbols
    }
  }

  let keyCode: UInt16
  let modifiers: Modifiers

  static let optionSpace = GlobalShortcut(keyCode: UInt16(kVK_Space), modifiers: .option)
  static let optionS = GlobalShortcut(keyCode: UInt16(kVK_ANSI_S), modifiers: .option)

  init(keyCode: UInt16, modifiers: Modifiers) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  /// The combination a key press describes, or nil when the press is a bare
  /// modifier or lacks ⌘, ⌥ and ⌃.
  init?(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
    let modifiers = Modifiers(modifierFlags)
    guard
      !modifiers.isDisjoint(with: .required),
      !Self.modifierKeyCodes.contains(Int(keyCode))
    else {
      return nil
    }
    self.init(keyCode: keyCode, modifiers: modifiers)
  }

  /// The chip text: modifier symbols, then the key, separated by spaces.
  var displayText: String {
    (modifiers.symbols + [keyDisplayName]).joined(separator: " ")
  }

  var keyDisplayName: String {
    if let name = Self.specialKeyNames[Int(keyCode)] {
      return name
    }
    return Self.character(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
  }

  /// What the menu bar item shows: an empty equivalent when the key has no
  /// menu representation.
  var menuKeyEquivalent: String {
    if let scalar = Self.menuFunctionKeys[Int(keyCode)] {
      return String(Character(scalar))
    }
    if keyCode == UInt16(kVK_Space) { return " " }
    return Self.character(for: keyCode)?.lowercased() ?? ""
  }

  var menuModifierMask: NSEvent.ModifierFlags {
    modifiers.eventFlags
  }

  private static let modifierKeyCodes: Set<Int> = [
    kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option,
    kVK_RightOption, kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
  ]

  private static let specialKeyNames: [Int: String] = [
    kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
    kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
    kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖",
    kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "?",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11",
    kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
    kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
  ]

  private static let menuFunctionKeys: [Int: Unicode.Scalar] = [
    kVK_Return: "\r", kVK_ANSI_KeypadEnter: "\u{3}", kVK_Tab: "\t", kVK_Delete: "\u{8}",
    kVK_ForwardDelete: Unicode.Scalar(NSDeleteFunctionKey)!, kVK_Escape: "\u{1B}",
    kVK_LeftArrow: Unicode.Scalar(NSLeftArrowFunctionKey)!,
    kVK_RightArrow: Unicode.Scalar(NSRightArrowFunctionKey)!,
    kVK_UpArrow: Unicode.Scalar(NSUpArrowFunctionKey)!,
    kVK_DownArrow: Unicode.Scalar(NSDownArrowFunctionKey)!,
    kVK_Home: Unicode.Scalar(NSHomeFunctionKey)!, kVK_End: Unicode.Scalar(NSEndFunctionKey)!,
    kVK_PageUp: Unicode.Scalar(NSPageUpFunctionKey)!,
    kVK_PageDown: Unicode.Scalar(NSPageDownFunctionKey)!,
    kVK_F1: Unicode.Scalar(NSF1FunctionKey)!, kVK_F2: Unicode.Scalar(NSF2FunctionKey)!,
    kVK_F3: Unicode.Scalar(NSF3FunctionKey)!, kVK_F4: Unicode.Scalar(NSF4FunctionKey)!,
    kVK_F5: Unicode.Scalar(NSF5FunctionKey)!, kVK_F6: Unicode.Scalar(NSF6FunctionKey)!,
    kVK_F7: Unicode.Scalar(NSF7FunctionKey)!, kVK_F8: Unicode.Scalar(NSF8FunctionKey)!,
    kVK_F9: Unicode.Scalar(NSF9FunctionKey)!, kVK_F10: Unicode.Scalar(NSF10FunctionKey)!,
    kVK_F11: Unicode.Scalar(NSF11FunctionKey)!, kVK_F12: Unicode.Scalar(NSF12FunctionKey)!,
    kVK_F13: Unicode.Scalar(NSF13FunctionKey)!, kVK_F14: Unicode.Scalar(NSF14FunctionKey)!,
    kVK_F15: Unicode.Scalar(NSF15FunctionKey)!, kVK_F16: Unicode.Scalar(NSF16FunctionKey)!,
    kVK_F17: Unicode.Scalar(NSF17FunctionKey)!, kVK_F18: Unicode.Scalar(NSF18FunctionKey)!,
    kVK_F19: Unicode.Scalar(NSF19FunctionKey)!, kVK_F20: Unicode.Scalar(NSF20FunctionKey)!,
  ]

  /// The unmodified character the current keyboard layout assigns to a key.
  private static func character(for keyCode: UInt16) -> String? {
    guard
      let inputSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
        .takeRetainedValue(),
      let layoutPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
    else {
      return nil
    }
    let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
    return layoutData.withUnsafeBytes { bytes -> String? in
      guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
        return nil
      }
      var deadKeyState: UInt32 = 0
      var length = 0
      var characters = [UniChar](repeating: 0, count: 4)
      let status = UCKeyTranslate(
        layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
        UInt32(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length,
        &characters)
      guard status == noErr, length > 0 else { return nil }
      let text = String(utf16CodeUnits: characters, count: length)
      return text.unicodeScalars.allSatisfy({ $0.properties.isWhitespace || $0.value < 0x20 })
        ? nil : text
    }
  }
}

extension GlobalShortcut: Codable {
  private enum CodingKeys: String, CodingKey {
    case keyCode
    case modifiers
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    keyCode = try container.decode(UInt16.self, forKey: .keyCode)
    modifiers = Modifiers(rawValue: try container.decode(UInt8.self, forKey: .modifiers))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(keyCode, forKey: .keyCode)
    try container.encode(modifiers.rawValue, forKey: .modifiers)
  }
}

/// What a global shortcut does; each action has its own combination in
/// Settings, and no two actions may share one.
enum GlobalShortcutAction: CaseIterable, Sendable {
  /// Shows or hides the panel, bringing in the frontmost selection.
  case showPanel
  /// Freezes the screen, lets the user frame some text, and translates it.
  case captureText

  var defaultShortcut: GlobalShortcut {
    switch self {
    case .showPanel: .optionSpace
    case .captureText: .optionS
    }
  }
}

// MARK: - Text form

/// The command line's spelling of a combination (`Design/spec/configuration.md` §三):
/// lowercase modifiers joined by `+` in the order ⌃ ⌥ ⇧ ⌘, then the key, as in `option+space`
/// or `control+option+t`. Keys are named by their position on a US keyboard, so the text means
/// the same key whatever layout is active.
extension GlobalShortcut {
  init?(configurationText text: String) {
    let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let keyName = parts.last, !keyName.isEmpty,
      let keyCode = Self.keyCodesByName[keyName]
    else {
      return nil
    }
    var modifiers = Modifiers()
    for name in parts.dropLast() {
      guard let modifier = Self.modifiersByName[name] else { return nil }
      modifiers.insert(modifier)
    }
    guard !modifiers.isDisjoint(with: .required) else { return nil }
    self.init(keyCode: keyCode, modifiers: modifiers)
  }

  var configurationText: String {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("control") }
    if modifiers.contains(.option) { parts.append("option") }
    if modifiers.contains(.shift) { parts.append("shift") }
    if modifiers.contains(.command) { parts.append("command") }
    parts.append(Self.keyNamesByCode[keyCode] ?? "key\(keyCode)")
    return parts.joined(separator: "+")
  }

  private static let modifiersByName: [String: Modifiers] = [
    "control": .control, "ctrl": .control, "⌃": .control,
    "option": .option, "opt": .option, "alt": .option, "⌥": .option,
    "shift": .shift, "⇧": .shift,
    "command": .command, "cmd": .command, "⌘": .command,
  ]

  /// Canonical names first; `keyCodesByName` also accepts the aliases after them.
  private static let keyNames: [(name: String, keyCode: Int)] = [
    ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
    ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
    ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
    ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
    ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
    ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
    ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),
    ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
    ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
    ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
    ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("[", kVK_ANSI_LeftBracket),
    ("]", kVK_ANSI_RightBracket), ("\\", kVK_ANSI_Backslash), (";", kVK_ANSI_Semicolon),
    ("'", kVK_ANSI_Quote), (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period),
    ("/", kVK_ANSI_Slash), ("`", kVK_ANSI_Grave),
    ("space", kVK_Space), ("return", kVK_Return), ("tab", kVK_Tab), ("delete", kVK_Delete),
    ("forward-delete", kVK_ForwardDelete), ("escape", kVK_Escape),
    ("left", kVK_LeftArrow), ("right", kVK_RightArrow), ("up", kVK_UpArrow),
    ("down", kVK_DownArrow), ("home", kVK_Home), ("end", kVK_End),
    ("page-up", kVK_PageUp), ("page-down", kVK_PageDown),
    ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4), ("f5", kVK_F5),
    ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8), ("f9", kVK_F9), ("f10", kVK_F10),
    ("f11", kVK_F11), ("f12", kVK_F12), ("f13", kVK_F13), ("f14", kVK_F14),
    ("f15", kVK_F15), ("f16", kVK_F16), ("f17", kVK_F17), ("f18", kVK_F18),
    ("f19", kVK_F19), ("f20", kVK_F20),
    // Aliases.
    ("enter", kVK_Return), ("esc", kVK_Escape), ("backspace", kVK_Delete),
  ]

  private static let keyCodesByName: [String: UInt16] = Dictionary(
    keyNames.map { ($0.name, UInt16($0.keyCode)) }, uniquingKeysWith: { first, _ in first })

  private static let keyNamesByCode: [UInt16: String] = Dictionary(
    keyNames.map { (UInt16($0.keyCode), $0.name) }, uniquingKeysWith: { first, _ in first })
}
