import AppKit
import CoreText
import SwiftUI
import XCTest

@testable import Cida

/// How the panel's content reports and takes its height, and where its text sits
/// (`Design/spec/panel.md` §二, `Design/spec/streaming-motion.md`). Every window here stays
/// hidden.
@MainActor
final class PanelGeometryTests: XCTestCase {
  private var retainedWindows: [NSWindow] = []

  override func setUp() async throws {
    try await super.setUp()
    FontRegistrar.registerBundledFonts()
    CidaMotion.reducesMotionOverride = false
  }

  override func tearDown() async throws {
    CidaMotion.reducesMotionOverride = nil
    for window in retainedWindows {
      window.orderOut(nil)
      window.contentView = nil
    }
    retainedWindows.removeAll()
    try await super.tearDown()
  }

  private func host(
    _ model: AppModel,
    height: CGFloat = 700,
    onHeight: @escaping @MainActor (CGFloat, Bool) -> Void = { _, _ in }
  ) -> NSHostingView<PanelView> {
    let hostingView = NSHostingView(
      rootView: PanelView(model: model, heightBudget: .automation, onContentHeightChange: onHeight))
    hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: height)
    let window = CidaWindow(
      contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    retainedWindows.append(window)
    hostingView.layoutSubtreeIfNeeded()
    return hostingView
  }

  private func pump(until condition: () -> Bool, timeout: TimeInterval = 2) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
  }

  private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ([view] + view.subviews.flatMap { views(NSView.self, in: $0) }).compactMap { $0 as? T }
  }

  private func composer(in view: NSView) throws -> NSTextView {
    try XCTUnwrap(
      views(NSTextView.self, in: view).first { $0.accessibilityIdentifier() == "composer-input" })
  }

  // MARK: - Height changes

  /// The panel appears at its height at once; every later change, whatever causes it, animates.
  func testEveryHeightChangeAnimatesExceptTheFirstLayout() throws {
    let model = AppModel(inputText: "", service: ImmediateStreamingService())
    var reports: [(height: CGFloat, animated: Bool)] = []
    let hostingView = host(model) { reports.append(($0, $1)) }
    pump { !reports.isEmpty }
    XCTAssertEqual(reports.first?.height ?? 0, 113, accuracy: 0.5)
    XCTAssertEqual(reports.first?.animated, false)

    let input = try composer(in: hostingView)
    input.insertText("One\nTwo", replacementRange: NSRange(location: 0, length: 0))
    pump { reports.last.map { abs($0.height - 138) < 0.5 } ?? false }

    model.present(
      CidaUpdateDriver.foundMessage(
        version: "1.1.0", currentVersion: "1.0.0", notes: ["开机启动时不再弹出面板。"]),
      handler: PanelMessageHandler(choose: { _ in }, dismiss: {}))
    pump { reports.last.map { $0.height > 63 + 50 + 44 } ?? false }
    let messageHeight = try XCTUnwrap(reports.last?.height)

    model.clearPanelMessage()
    pump { reports.last.map { abs($0.height - 138) < 0.5 } ?? false }

    XCTAssertEqual(reports.last?.height ?? 0, 138, accuracy: 0.5)
    XCTAssertGreaterThan(messageHeight, 63 + 50 + 44, "The notes' paper has its height at once")
    XCTAssertEqual(reports.dropFirst().filter { !$0.animated }.count, 0, "\(reports)")
  }

  /// Notes longer than the panel allows scroll inside a paper at the cap; the panel stops at its
  /// budget without measuring the notes first.
  func testLongUpdateNotesScrollAtThePanelsCap() {
    let model = AppModel(inputText: "", service: ImmediateStreamingService())
    var reports: [CGFloat] = []
    _ = host(model) { height, _ in reports.append(height) }
    model.present(
      CidaUpdateDriver.foundMessage(
        version: "1.1.0", currentVersion: "1.0.0",
        notes: (1...60).map { "第 \($0) 条更新说明。" }),
      handler: PanelMessageHandler(choose: { _ in }, dismiss: {}))
    pump { (reports.last ?? 0) > 400 }

    XCTAssertEqual(reports.last ?? 0, PanelHeightBudget.automation.panelMaxHeight, accuracy: 0.5)
  }

  /// A new record's document is laid out in the update that shows it, so the pane never shows
  /// the previous document or an empty one at the wrong height while a coalesced layout waits.
  func testANewRecordIsLaidOutInTheUpdateThatShowsIt() throws {
    let model = AppModel(inputText: ResultRecord.designLongInput)
    model.setResultForTesting(ResultRecord.designLong())
    let hostingView = host(model)
    var scrollView: ResultScrollView? { views(ResultScrollView.self, in: hostingView).first }
    pump { (scrollView?.container.naturalTextHeight ?? 0) > 400 }
    let container = try XCTUnwrap(scrollView?.container)
    let replacements = container.fullReplacementCount

    let record = ResultRecord(
      mode: .translate, source: ResultRecord.designLongInput, outputLanguage: .chinese)
    model.setResultForTesting(record)
    model.setGenerationStateForTesting(.waiting(entryID: record.id))
    pump { container.fullReplacementCount > replacements }

    XCTAssertFalse(container.needsFullTextLayout)
    XCTAssertEqual(container.naturalTextHeight, CidaDesign.Typography.resultLineHeightCJK)
    XCTAssertEqual(scrollView?.contentView.bounds.minY ?? -1, 0)
    hostingView.layoutSubtreeIfNeeded()
    XCTAssertEqual(scrollView?.frame.height ?? 0, CidaDesign.Typography.resultLineHeightCJK)
  }

  /// Returning from a message rebuilds the result pane; its first layout is not deferred.
  func testARebuiltResultPaneIsLaidOutOnItsFirstUpdate() {
    let model = AppModel(inputText: "Source")
    model.setResultForTesting(ResultRecord.designCompleted(mode: .translate))
    let hostingView = host(model)
    pump { !views(ResultScrollView.self, in: hostingView).isEmpty }
    model.present(
      CidaUpdateDriver.readyMessage(version: "1.1.0"),
      handler: PanelMessageHandler(choose: { _ in }, dismiss: {}))
    pump { views(ResultScrollView.self, in: hostingView).isEmpty }

    model.clearPanelMessage()
    pump { !views(ResultScrollView.self, in: hostingView).isEmpty }
    let container = views(ResultScrollView.self, in: hostingView).first?.container
    XCTAssertEqual(container?.needsFullTextLayout, false)
    XCTAssertGreaterThan(container?.naturalTextHeight ?? 0, CidaDesign.Typography.resultLineHeight)
  }

  /// While the panel's frame shrinks to the content, what it shows below the content is the
  /// bottom pane's own surface.
  func testTheSpaceBelowTheContentIsTheBottomPanesSurface() throws {
    let withResult = AppModel(inputText: "Source")
    withResult.setResultForTesting(ResultRecord.designCompleted(mode: .translate))
    let paper = host(withResult, height: 600)
    let empty = host(AppModel(inputText: "", service: ImmediateStreamingService()), height: 600)
    pump { !views(ResultScrollView.self, in: paper).isEmpty }

    try assertColor(at: NSPoint(x: 16, y: 590), in: paper, is: CidaDesign.Palette.surfacePaper)
    try assertColor(at: NSPoint(x: 16, y: 590), in: empty, is: CidaDesign.Palette.surface)
  }

  /// Within a few steps per channel: the cached bitmap is in the display's colour space.
  private func assertColor(
    at point: NSPoint, in view: NSView, is token: CidaColorToken,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let found = try color(at: point, in: view)
    for shift: UInt32 in [16, 8, 0] {
      let a = Int((found >> shift) & 0xff)
      let b = Int((token.hex >> shift) & 0xff)
      XCTAssertLessThanOrEqual(
        abs(a - b), 4, String(format: "#%06X vs #%06X", found, token.hex), file: file, line: line)
    }
  }

  // MARK: - Text positions

  /// Typed source text and the placeholder share one line box: the first character does not
  /// move the line.
  func testTypedSourceTextSitsWhereThePlaceholderIs() throws {
    let placeholder = "输入内容，回车翻译…"
    let model = AppModel(inputText: "", service: ImmediateStreamingService())
    let hostingView = host(model, height: 113)
    pump { false }
    let placeholderInk = try inkRows(in: hostingView)

    let input = try composer(in: hostingView)
    input.insertText(placeholder, replacementRange: NSRange(location: 0, length: 0))
    pump { model.inputText == placeholder }
    pump { false }
    let typedInk = try inkRows(in: hostingView)

    XCTAssertEqual(typedInk.top, placeholderInk.top, accuracy: 0.6)
    XCTAssertEqual(typedInk.bottom, placeholderInk.bottom, accuracy: 0.6)
  }

  /// The waiting caret and the caret after the first glyph sit at the same height in the line:
  /// the board's caret, 4 pt below the baseline.
  func testTheCaretKeepsItsHeightWhenTheFirstGlyphArrives() {
    for language in [Language.english, .chinese] {
      let container = ResultTextContainer(frame: NSRect(x: 0, y: 0, width: 720, height: 40))
      container.language = language
      container.replaceText("")
      container.setStreaming(true)
      _ = container.updateDocumentLayout()
      container.updateStreamingCaretFrame()
      let waiting = container.streamingCaretFrame

      container.append(language == .chinese ? "译" : "A", isStreaming: true)
      _ = container.updateDocumentLayout()
      let writing = container.streamingCaretFrame

      XCTAssertEqual(writing.minY, waiting.minY, accuracy: 0.01, "\(language)")
      XCTAssertEqual(
        container.naturalTextHeight, ResultTextStyle.lineHeight(for: language),
        "The waiting line already has the result's line height")
      let font = CidaDesign.appKitResult(for: language)
      let baseline =
        CidaDesign.halfLeading(of: font, lineHeight: ResultTextStyle.lineHeight(for: language))
        + font.ascender
      XCTAssertEqual(waiting.maxY, baseline + ResultTextStyle.caretDescent, accuracy: 0.01)
    }
  }

  /// The Chinese result face sets a full-width mark next to another at half width (`chws`).
  func testChinesePunctuationUsesContextualHalfWidthSpacing() {
    for language in [Language.chinese, .english] {
      let font = CidaDesign.appKitResult(for: language)
      let text = "好。「好」"
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [.font: font]))
      let periodAdvance =
        CTLineGetOffsetForStringIndex(line, 2, nil) - CTLineGetOffsetForStringIndex(line, 1, nil)
      XCTAssertEqual(periodAdvance, CidaDesign.Typography.resultSizeCJK / 2, accuracy: 0.6, "\(language)")
    }
  }

  // MARK: - Pixels

  private func bitmap(of view: NSView) throws -> NSBitmapImageRep {
    view.layoutSubtreeIfNeeded()
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
  }

  private func color(at point: NSPoint, in view: NSView) throws -> UInt32 {
    let rep = try bitmap(of: view)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    let color = try XCTUnwrap(
      rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
    func byte(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
    return byte(color.redComponent) << 16 | byte(color.greenComponent) << 8 | byte(color.blueComponent)
  }

  /// The first and last rows (in points) with ink in the source pane's text column.
  private func inkRows(in view: NSView) throws -> (top: CGFloat, bottom: CGFloat) {
    let rep = try bitmap(of: view)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    var rows: [Int] = []
    for y in Int(10 * scale)..<Int(56 * scale) {
      for x in Int(28 * scale)..<Int(260 * scale) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        if c.redComponent + c.greenComponent + c.blueComponent < 2.6 {
          rows.append(y)
          break
        }
      }
    }
    let top = try XCTUnwrap(rows.first)
    let bottom = try XCTUnwrap(rows.last)
    return (CGFloat(top) / scale, CGFloat(bottom) / scale)
  }
}
