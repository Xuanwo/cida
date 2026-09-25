import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Sits invisibly behind the shortcut chip and, while recording, holds the
/// window's first responder so the next key press becomes the shortcut.
/// Escape and losing the first responder end the recording unchanged; a
/// press without ⌘, ⌥ or ⌃ is reported and recording continues.
struct ShortcutCaptureView: NSViewRepresentable {
  @Binding var isRecording: Bool
  let onCapture: @MainActor (GlobalShortcut) -> Void
  let onInvalidPress: @MainActor () -> Void

  func makeNSView(context: Context) -> ShortcutCaptureNSView {
    ShortcutCaptureNSView()
  }

  func updateNSView(_ view: ShortcutCaptureNSView, context: Context) {
    view.onCapture = onCapture
    view.onInvalidPress = onInvalidPress
    view.onEnd = { isRecording = false }
    view.wantsKeyFocus = isRecording
  }
}

final class ShortcutCaptureNSView: NSView {
  var onCapture: @MainActor (GlobalShortcut) -> Void = { _ in }
  var onInvalidPress: @MainActor () -> Void = {}
  var onEnd: @MainActor () -> Void = {}

  /// Recording holds the keyboard. SwiftUI may set this before the view is in a window (the
  /// Settings content sits in a scroll view that attaches it later), so the view takes the focus
  /// again once it arrives in one.
  var wantsKeyFocus = false {
    didSet { applyKeyFocus() }
  }

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyKeyFocus()
  }

  private func applyKeyFocus() {
    guard let window else { return }
    if wantsKeyFocus {
      if window.firstResponder !== self {
        window.makeFirstResponder(self)
      }
    } else if window.firstResponder === self {
      window.makeFirstResponder(nil)
    }
  }

  override func keyDown(with event: NSEvent) {
    _ = record(event)
  }

  /// ⌘ combinations reach the window as key equivalents before any menu
  /// sees them, so the recorder claims them here.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self else { return false }
    return record(event)
  }

  override func resignFirstResponder() -> Bool {
    let onEnd = onEnd
    // The responder change can arrive inside a SwiftUI update; the binding
    // is written on the next turn of the run loop.
    Task { @MainActor in onEnd() }
    return true
  }

  @discardableResult
  func record(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == UInt16(kVK_Escape), flags.subtracting(.function).isEmpty {
      onEnd()
      return true
    }
    guard let shortcut = GlobalShortcut(keyCode: event.keyCode, modifierFlags: flags) else {
      onInvalidPress()
      return true
    }
    onCapture(shortcut)
    onEnd()
    return true
  }
}
