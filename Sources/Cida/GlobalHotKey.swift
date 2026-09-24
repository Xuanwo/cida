import Carbon.HIToolbox
import Foundation

/// The system-wide hot key that shows the panel. It is registered with
/// Carbon, which delivers the press to this process whichever application
/// is active. `update(to:)` swaps the combination; a combination the system
/// or another application already holds is refused and the old one stays.
final class GlobalHotKey: @unchecked Sendable {
  private(set) var shortcut: GlobalShortcut
  private var hotKeyReference: EventHotKeyRef?
  private var eventHandlerReference: EventHandlerRef?
  private let action: @MainActor @Sendable () -> Void

  init?(shortcut: GlobalShortcut, action: @escaping @MainActor @Sendable () -> Void) {
    self.shortcut = shortcut
    self.action = action

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )

    let handlerStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      Self.eventHandler,
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandlerReference
    )
    guard handlerStatus == noErr else { return nil }

    guard let reference = Self.register(shortcut) else {
      if let eventHandlerReference {
        RemoveEventHandler(eventHandlerReference)
      }
      return nil
    }
    hotKeyReference = reference
  }

  deinit {
    if let hotKeyReference {
      UnregisterEventHotKey(hotKeyReference)
    }
    if let eventHandlerReference {
      RemoveEventHandler(eventHandlerReference)
    }
  }

  /// Re-registers the hot key for a new combination. Returns false, with the
  /// previous combination still active, when the system refuses the new one.
  func update(to newShortcut: GlobalShortcut) -> Bool {
    guard newShortcut != shortcut else { return true }
    if let hotKeyReference {
      UnregisterEventHotKey(hotKeyReference)
    }
    if let reference = Self.register(newShortcut) {
      hotKeyReference = reference
      shortcut = newShortcut
      return true
    }
    hotKeyReference = Self.register(shortcut)
    return false
  }

  private static func register(_ shortcut: GlobalShortcut) -> EventHotKeyRef? {
    let hotKeyID = EventHotKeyID(
      signature: fourCharacterCode("CIDA"),
      id: 1
    )
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(shortcut.keyCode),
      shortcut.modifiers.carbonFlags,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &reference
    )
    guard status == noErr else { return nil }
    return reference
  }

  private static let eventHandler: EventHandlerUPP = { _, _, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<GlobalHotKey>
      .fromOpaque(userData)
      .takeUnretainedValue()
    hotKey.performAction()
    return noErr
  }

  private func performAction() {
    let action = action
    Task { @MainActor in
      action()
    }
  }

  private static func fourCharacterCode(_ value: String) -> FourCharCode {
    value.utf8.reduce(0) { result, character in
      (result << 8) + FourCharCode(character)
    }
  }
}
