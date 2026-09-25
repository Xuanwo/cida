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
    let scrollView = OverlayScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
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
    textView.textContainerInset = NSSize(width: 14, height: 14)
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
    // The prompt sheet: Inter 13 on 1.6 lines in ink, like text on paper
    // (`Design/spec/settings.md`).
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.minimumLineHeight = 21
    paragraphStyle.maximumLineHeight = 21

    let attributes: [NSAttributedString.Key: Any] = [
      .font: CidaDesign.appKitBody(13),
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

    init(text: Binding<String>) {
      self.text = text
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
    }
  }
}
