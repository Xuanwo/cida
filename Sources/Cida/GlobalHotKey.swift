import Carbon.HIToolbox
import Foundation

final class GlobalHotKey: @unchecked Sendable {
  private var hotKeyReference: EventHotKeyRef?
  private var eventHandlerReference: EventHandlerRef?
  private let action: @MainActor @Sendable () -> Void

  init?(action: @escaping @MainActor @Sendable () -> Void) {
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

    let hotKeyID = EventHotKeyID(
      signature: Self.fourCharacterCode("CIDA"),
      id: 1
    )
    let registrationStatus = RegisterEventHotKey(
      UInt32(kVK_Space),
      UInt32(optionKey),
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyReference
    )

    guard registrationStatus == noErr else {
      if let eventHandlerReference {
        RemoveEventHandler(eventHandlerReference)
      }
      return nil
    }
  }

  deinit {
    if let hotKeyReference {
      UnregisterEventHotKey(hotKeyReference)
    }
    if let eventHandlerReference {
      RemoveEventHandler(eventHandlerReference)
    }
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
