import Carbon.HIToolbox
import Foundation

/// One system-wide hot key. It is registered with Carbon, which delivers the
/// press to this process whichever application is active. `update(to:)`
/// swaps the combination; a combination the system, another application or
/// another of Cida's hot keys already holds is refused and the old one stays.
/// Each instance answers only presses of its own registration, so several
/// can live side by side.
final class GlobalHotKey: @unchecked Sendable {
  private(set) var shortcut: GlobalShortcut
  private let identifier: UInt32
  private var hotKeyReference: EventHotKeyRef?
  private var eventHandlerReference: EventHandlerRef?
  private let action: @MainActor @Sendable () -> Void

  nonisolated(unsafe) private static var nextIdentifier: UInt32 = 1

  init?(shortcut: GlobalShortcut, action: @escaping @MainActor @Sendable () -> Void) {
    self.shortcut = shortcut
    self.action = action
    identifier = Self.nextIdentifier
    Self.nextIdentifier += 1

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

    guard let reference = Self.register(shortcut, identifier: identifier) else {
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
    let wasRegistered = hotKeyReference != nil
    unregister()
    if let reference = Self.register(newShortcut, identifier: identifier) {
      if wasRegistered {
        hotKeyReference = reference
      } else {
        UnregisterEventHotKey(reference)
      }
      shortcut = newShortcut
      return true
    }
    if wasRegistered {
      hotKeyReference = Self.register(shortcut, identifier: identifier)
    }
    return false
  }

  /// While suspended the combination reaches the active application like any
  /// other key press, e.g. the Settings recorder.
  func setSuspended(_ isSuspended: Bool) {
    if isSuspended {
      unregister()
    } else if hotKeyReference == nil {
      hotKeyReference = Self.register(shortcut, identifier: identifier)
    }
  }

  private func unregister() {
    if let hotKeyReference {
      UnregisterEventHotKey(hotKeyReference)
      self.hotKeyReference = nil
    }
  }

  private static func register(_ shortcut: GlobalShortcut, identifier: UInt32) -> EventHotKeyRef? {
    let hotKeyID = EventHotKeyID(
      signature: signature,
      id: identifier
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

  /// Every instance's handler sees every press; the ones that are not its
  /// own pass on to the next handler.
  private static let eventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &hotKeyID
    )
    let hotKey = Unmanaged<GlobalHotKey>
      .fromOpaque(userData)
      .takeUnretainedValue()
    guard status == noErr, hotKeyID.signature == signature, hotKeyID.id == hotKey.identifier
    else {
      return OSStatus(eventNotHandledErr)
    }
    hotKey.performAction()
    return noErr
  }

  private func performAction() {
    let action = action
    Task { @MainActor in
      action()
    }
  }

  private static let signature = fourCharacterCode("CIDA")

  private static func fourCharacterCode(_ value: String) -> FourCharCode {
    value.utf8.reduce(0) { result, character in
      (result << 8) + FourCharCode(character)
    }
  }
}
