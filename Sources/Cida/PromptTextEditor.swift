import AppKit
import SwiftUI

struct PromptTextEditor: NSViewRepresentable {
  @Binding var text: String
  let accessibilityLabel: String
  let accessibilityIdentifier: String

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true

    let textView = NSTextView()
    textView.delegate = context.coordinator
    textView.string = text
    textView.isRichText = false
    textView.importsGraphics = false
    textView.drawsBackground = false
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainerInset = NSSize(width: 12, height: 8)
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.focusRingType = .none
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
      applyTypography(to: textView)
    }
    textView.setAccessibilityLabel(accessibilityLabel)
    textView.setAccessibilityIdentifier(accessibilityIdentifier)
  }

  private func applyTypography(to textView: NSTextView) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.minimumLineHeight = 20
    paragraphStyle.maximumLineHeight = 20

    let attributes: [NSAttributedString.Key: Any] = [
      .font: CidaDesign.appKitBody(12.5),
      .foregroundColor: CidaDesign.Palette.textPrimary.appKit,
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

    init(text: Binding<String>) {
      self.text = text
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
    }
  }
}
