import AppKit
import SwiftUI

struct PromptTextEditor: NSViewRepresentable {
  static let font = CidaDesign.appKitBody(CidaDesign.Typography.bodySize)
  static let lineHeight = CidaDesign.Typography.bodyLineHeight

  @Binding var text: String
  let accessibilityLabel: String
  let accessibilityIdentifier: String
  var focusRequest = 0
  var onEscape: () -> Void = {}
  var onApply: () -> Void = {}

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = OverlayScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true

    let textView = PromptNativeTextView()
    textView.delegate = context.coordinator
    textView.string = text
    textView.allowsUndo = true
    textView.isRichText = false
    textView.importsGraphics = false
    textView.drawsBackground = false
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainerInset = NSSize(width: 14, height: 14)
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.focusRingType = .none
    textView.insertionPointColor = CidaDesign.Palette.accent.appKit
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.setAccessibilityLabel(accessibilityLabel)
    textView.setAccessibilityIdentifier(accessibilityIdentifier)

    applyTypography(to: textView)
    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    context.coordinator.text = $text
    if textView.string != text {
      textView.string = text
      textView.undoManager?.removeAllActions()
      applyTypography(to: textView)
    }
    textView.setAccessibilityLabel(accessibilityLabel)
    textView.setAccessibilityIdentifier(accessibilityIdentifier)
    if let native = textView as? PromptNativeTextView {
      native.onEscape = onEscape
      native.onApply = onApply
    }
    if context.coordinator.focusRequest != focusRequest {
      context.coordinator.focusRequest = focusRequest
      DispatchQueue.main.async { [weak textView] in
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
      }
    }
  }

  private func applyTypography(to textView: NSTextView) {
    // Prompts use the panel's input typography so sustained editing remains comfortable.
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.minimumLineHeight = Self.lineHeight
    paragraphStyle.maximumLineHeight = Self.lineHeight

    let attributes: [NSAttributedString.Key: Any] = [
      .font: Self.font,
      .foregroundColor: CidaDesign.Palette.textInk.appKit,
      .paragraphStyle: paragraphStyle,
    ]

    textView.defaultParagraphStyle = paragraphStyle
    textView.typingAttributes = attributes
    textView.textStorage?.setAttributes(
      attributes,
      range: NSRange(location: 0, length: textView.string.utf16.count)
    )
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var focusRequest = 0

    init(text: Binding<String>) {
      self.text = text
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
    }
  }
}

@MainActor
private final class PromptNativeTextView: NSTextView {
  private let localUndoManager = UndoManager()
  override var undoManager: UndoManager? { localUndoManager }
  var onEscape: () -> Void = {}
  var onApply: () -> Void = {}
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53, !hasMarkedText() {
      onEscape()
      return
    }
    if event.keyCode == 36, event.modifierFlags.contains(.command) {
      onApply()
      return
    }
    super.keyDown(with: event)
  }
}
