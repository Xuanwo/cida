import AppKit
import SwiftUI

/// The application the user works in when they summon Cida. Selection
/// journeys select text in its editor or in its views that only copy;
/// capture journeys frame its line of text or its empty area on the real
/// screen.
@main
struct CidaUITestHost: App {
  var body: some Scene {
    WindowGroup("Source application") {
      SourceView()
    }
    .windowResizability(.contentSize)
  }
}

private struct SourceView: View {
  /// English paragraphs, and one in the user's own language after the third, which ⌥D turns
  /// into the foreign language.
  static let layerParagraphs: [String] = {
    let english = (1...16).map { number in
      "CIDA LAYER PARAGRAPH \(number). The storage engine keeps every write in an append-only log and compacts it in the background."
    }
    return Array(english[..<3]) + ["CIDA LAYER PARAGRAPH 17. 存储引擎把每次写入都追加到只追加的日志里，并在后台压缩它。"]
      + Array(english[3...])
  }()

  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text("CIDA CAPTURE SCENARIO")
        .font(.system(size: 40, weight: .semibold))
        .foregroundStyle(.black)
        .accessibilityIdentifier("source-capture-text")
      TextEditor(text: $text)
        .font(.system(size: 16))
        .frame(height: 96)
        .border(Color.gray.opacity(0.3))
        .accessibilityIdentifier("source-editor")
      // Selection journeys for applications Accessibility cannot read.
      HStack(spacing: 24) {
        CopyOnlyText(
          text: "CIDA_E2E_SELECTION_DRAWN", copied: "CIDA_E2E_SELECTION_DRAWN",
          identifier: "source-drawn-text", answersSelection: false)
        CopyOnlyText(
          text: "CIDA_E2E_LINE", copied: "CIDA_E2E_WHOLE_LINE",
          identifier: "source-line-copy", answersSelection: true)
      }
      .frame(height: 32)
      Rectangle()
        .fill(Color.white)
        .frame(height: 180)
        .accessibilityElement()
        .accessibilityIdentifier("source-blank")
      // The translation layer's journey: a pane of paragraphs that scrolls.
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          ForEach(Self.layerParagraphs, id: \.self) { paragraph in
            Text(paragraph)
              .font(.system(size: 15))
              .foregroundStyle(.black)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(.vertical, 8)
      }
      .frame(height: 240)
      .accessibilityIdentifier("source-article")
    }
    .padding(40)
    .frame(width: 760)
    .background(Color.white)
  }
}

/// Text drawn by the view itself, the way a custom-drawn application shows
/// it: clicking it selects it all, and Edit › Copy (⌘C) copies `copied`.
private struct CopyOnlyText: NSViewRepresentable {
  let text: String
  let copied: String
  let identifier: String
  /// Whether Accessibility is told the selection is empty, like an editor
  /// that copies its whole line on ⌘C when nothing is selected (VS Code);
  /// otherwise the view offers no selected text at all.
  let answersSelection: Bool

  func makeNSView(context: Context) -> CopyOnlyTextView {
    let view =
      answersSelection
      ? EmptySelectionFieldView(text: text, copied: copied)
      : CopyOnlyTextView(text: text, copied: copied)
    view.setAccessibilityIdentifier(identifier)
    return view
  }

  func updateNSView(_ view: CopyOnlyTextView, context: Context) {}
}

class CopyOnlyTextView: NSView {
  let text: String
  private let copied: String
  private var isSelected = false

  init(text: String, copied: String) {
    self.text = text
    self.copied = copied
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { nil }

  /// Whether a click selects the text.
  var selectsOnClick: Bool { true }

  override var acceptsFirstResponder: Bool { true }

  /// The journey clicks it while Cida is in front; the click must focus it,
  /// not only bring the window forward.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    isSelected = selectsOnClick
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    if isSelected {
      NSColor.selectedTextBackgroundColor.setFill()
      bounds.fill()
    }
    (text as NSString).draw(
      at: NSPoint(x: 6, y: 6),
      withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black])
  }

  @objc func copy(_ sender: Any?) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(copied, forType: .string)
  }

  override func isAccessibilityElement() -> Bool { true }

  override func accessibilityRole() -> NSAccessibility.Role? { .group }
}

/// Answers that nothing is selected, yet copies its whole line.
final class EmptySelectionFieldView: CopyOnlyTextView {
  override var selectsOnClick: Bool { false }

  override func accessibilityRole() -> NSAccessibility.Role? { .textField }

  override func accessibilityValue() -> Any? { text }

  override func accessibilitySelectedText() -> String? { "" }

  override func accessibilitySelectedTextRange() -> NSRange { NSRange(location: 0, length: 0) }
}
