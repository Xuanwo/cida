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
    let subjects = [
      "The storage engine preserves every write in an append-only log before compacting old records in the background.",
      "Morning sunlight reaches the library through tall windows while readers quietly browse the shelves for books.",
      "A mountain trail follows the river past ancient trees and crosses a narrow wooden bridge beside the waterfall.",
      "Our deployment checklist requires a signed package, passing integration tests, and an independent review of the changes.",
      "Fresh vegetables arrive at the market each Saturday, where farmers explain how the seasonal crops were grown.",
      "The orchestra rehearsed the final movement slowly, giving each musician time to hear the neighboring instruments.",
      "Network requests share a bounded connection pool so that bursts of activity cannot exhaust the available sockets.",
      "Students measured the shadow at noon and compared their observations with predictions from a simple geometric model.",
      "The bakery opens before dawn to prepare warm bread, fruit pastries, and a fresh pot of coffee for commuters.",
      "Each archived photograph includes a date, a location, and a short description provided by its original owner.",
      "A small telescope reveals bright planets above the city when clear weather allows an uninterrupted view of the sky.",
      "Database snapshots retain the versions needed by active readers while background maintenance reclaims obsolete files.",
      "The design team compared three navigation layouts and recorded where participants expected to find their saved work.",
      "Water from the hillside flows into a reservoir that supplies nearby gardens throughout the dry summer months.",
      "A written emergency plan identifies the responsible people and explains how to restore essential services safely.",
      "The research vessel returned with samples collected at several depths, each labeled carefully before analysis.",
    ]
    let english = subjects.enumerated().map { index, text in "CIDA LAYER PARAGRAPH \(index + 1). \(text)" }
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
      // Selection journeys for selections Accessibility cannot give.
      HStack(spacing: 16) {
        CopyOnlyText(
          text: "CIDA_E2E_SELECTION_DRAWN", copied: "CIDA_E2E_SELECTION_DRAWN",
          identifier: "source-drawn-text", accessibility: .noSelectedText)
        CopyOnlyText(
          text: "CIDA_E2E_SELECTION_BESIDE", copied: "CIDA_E2E_SELECTION_BESIDE",
          identifier: "source-beside-text", accessibility: .emptySelection(holding: ""))
        CopyOnlyText(
          text: "CIDA_E2E_LINE", copied: "CIDA_E2E_LINE\n",
          identifier: "source-line-copy", accessibility: .emptySelection(holding: "CIDA_E2E_LINE"),
          selectsOnClick: false)
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
  enum Accessibility {
    /// No selected text at all, like a custom-drawn application.
    case noSelectedText
    /// An empty selection in a field holding `text`: Telegram Desktop's
    /// empty message field while a message is selected, or an editor that
    /// copies its whole line when nothing is selected (VS Code).
    case emptySelection(holding: String)
  }

  let text: String
  let copied: String
  let identifier: String
  let accessibility: Accessibility
  var selectsOnClick = true

  func makeNSView(context: Context) -> CopyOnlyTextView {
    let view: CopyOnlyTextView
    switch accessibility {
    case .noSelectedText:
      view = CopyOnlyTextView(text: text, copied: copied, selectsOnClick: selectsOnClick)
    case .emptySelection(let held):
      view = EmptySelectionFieldView(
        text: text, copied: copied, selectsOnClick: selectsOnClick, held: held)
    }
    view.setAccessibilityIdentifier(identifier)
    return view
  }

  func updateNSView(_ view: CopyOnlyTextView, context: Context) {}
}

class CopyOnlyTextView: NSView {
  let text: String
  private let copied: String
  /// Whether a click selects the text.
  private let selectsOnClick: Bool
  private var isSelected = false

  init(text: String, copied: String, selectsOnClick: Bool) {
    self.text = text
    self.copied = copied
    self.selectsOnClick = selectsOnClick
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { nil }

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

/// Answers that nothing is selected, yet copies.
final class EmptySelectionFieldView: CopyOnlyTextView {
  private let held: String

  init(text: String, copied: String, selectsOnClick: Bool, held: String) {
    self.held = held
    super.init(text: text, copied: copied, selectsOnClick: selectsOnClick)
  }

  required init?(coder: NSCoder) { nil }

  override func accessibilityRole() -> NSAccessibility.Role? { .textField }

  override func accessibilityValue() -> Any? { held }

  override func accessibilitySelectedText() -> String? { "" }

  override func accessibilitySelectedTextRange() -> NSRange { NSRange(location: 0, length: 0) }
}
