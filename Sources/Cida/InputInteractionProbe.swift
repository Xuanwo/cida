import AppKit
import Foundation

struct InputInteractionProbeReport: Codable, Equatable, Sendable {
  let clickHitComposer: Bool
  let firstResponderAccepted: Bool
  let nativeInput: String
  let modelInput: String
  let applicationActivationObserved: Bool
  let probeWindowBecameKey: Bool
  let passed: Bool
}

@MainActor
final class InputInteractionProbe: NSObject {
  private static let expectedInput = "Release input works"

  private let outputURL: URL
  private let window: NSWindow
  private let model: AppModel
  private var applicationActivationObserved = false
  private var probeWindowBecameKey = false

  init(outputURL: URL, window: NSWindow, model: AppModel) {
    self.outputURL = outputURL
    self.window = window
    self.model = model
    super.init()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func run() {
    applicationActivationObserved = NSApp.isActive
    probeWindowBecameKey = window.isKeyWindow
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidActivate(_:)),
      name: NSApplication.didBecomeActiveNotification,
      object: NSApp
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeKey(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: window
    )

    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(80))
      self?.performInteraction()
    }
  }

  @objc
  private func applicationDidActivate(_ notification: Notification) {
    applicationActivationObserved = true
  }

  @objc
  private func windowDidBecomeKey(_ notification: Notification) {
    probeWindowBecameKey = true
  }

  private func performInteraction() {
    window.contentView?.layoutSubtreeIfNeeded()
    guard let input = composerInput(in: window.contentView) else {
      finish(clickHitComposer: false, firstResponderAccepted: false, nativeInput: "")
      return
    }

    let clickPoint = input.convert(NSPoint(x: 12, y: 12), to: nil)
    let clickHitComposer = window.contentView?.hitTest(clickPoint) === input
    if clickHitComposer {
      sendClick(at: clickPoint)
    }
    let firstResponderAccepted =
      window.firstResponder === input || window.makeFirstResponder(input)
    if firstResponderAccepted {
      sendKeyEvents(Self.expectedInput)
    }

    Task { @MainActor [weak self, weak input] in
      try? await Task.sleep(for: .milliseconds(80))
      guard let self else { return }
      self.finish(
        clickHitComposer: clickHitComposer,
        firstResponderAccepted: firstResponderAccepted,
        nativeInput: input?.string ?? ""
      )
    }
  }

  private func sendClick(at point: NSPoint) {
    let eventNumber = 1
    guard
      let down = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: eventNumber,
        clickCount: 1,
        pressure: 1
      ),
      let up = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: eventNumber,
        clickCount: 1,
        pressure: 0
      )
    else {
      return
    }
    NSApp.postEvent(up, atStart: true)
    window.sendEvent(down)
  }

  private func sendKeyEvents(_ value: String) {
    for character in value {
      let text = String(character)
      guard
        let event = NSEvent.keyEvent(
          with: .keyDown,
          location: .zero,
          modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber,
          context: nil,
          characters: text,
          charactersIgnoringModifiers: text,
          isARepeat: false,
          keyCode: 0
        )
      else {
        continue
      }
      window.sendEvent(event)
    }
  }

  private func finish(
    clickHitComposer: Bool,
    firstResponderAccepted: Bool,
    nativeInput: String
  ) {
    applicationActivationObserved = applicationActivationObserved || NSApp.isActive
    probeWindowBecameKey = probeWindowBecameKey || window.isKeyWindow
    let modelInput = model.inputText
    let passed =
      clickHitComposer
      && firstResponderAccepted
      && nativeInput == Self.expectedInput
      && modelInput == Self.expectedInput
      && !applicationActivationObserved
      && !probeWindowBecameKey
    let report = InputInteractionProbeReport(
      clickHitComposer: clickHitComposer,
      firstResponderAccepted: firstResponderAccepted,
      nativeInput: nativeInput,
      modelInput: modelInput,
      applicationActivationObserved: applicationActivationObserved,
      probeWindowBecameKey: probeWindowBecameKey,
      passed: passed
    )

    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(report).write(to: outputURL, options: .atomic)
    } catch {
      fputs("Failed to write input interaction report: \(error)\n", stderr)
    }
    NSApp.terminate(nil)
  }

  private func composerInput(in view: NSView?) -> NSTextView? {
    guard let view else { return nil }
    if let textView = view as? NSTextView,
      textView.accessibilityIdentifier() == "composer-input"
    {
      return textView
    }
    for child in view.subviews {
      if let input = composerInput(in: child) {
        return input
      }
    }
    return nil
  }
}
