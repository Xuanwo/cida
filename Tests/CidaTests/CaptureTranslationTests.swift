import AppKit
import Carbon.HIToolbox
import XCTest

@testable import Cida

/// The capture shortcut (`Design/spec/panel.md` §一 截图翻译).
@MainActor
final class CaptureTranslationTests: XCTestCase {
  // MARK: - Paragraphs from recognized lines

  func testWrappedLinesJoinTheWayTheirLanguageWraps() {
    let text = RecognizedTextLayout.text(from: [
      line("The new storage engine keeps every", row: 0),
      line("write in an append-only log and com-", row: 1),
      line("pacts it in the background.", row: 2),
      line("我们的系统采用了全新的存储", row: 4),
      line("引擎，显著提升了读写性能。", row: 5),
    ])
    XCTAssertEqual(
      text,
      "The new storage engine keeps every write in an append-only log and compacts it in the background.\n"
        + "我们的系统采用了全新的存储引擎，显著提升了读写性能。")
  }

  func testLinesOnOneRowReadLeftToRightAndBlankCapturesHaveNoText() {
    let text = RecognizedTextLayout.text(from: [
      line("改进", row: 0, x: 0.3),
      line("翻译", row: 0, x: 0.1),
      line("复制结果", row: 0, x: 0.7),
    ])
    XCTAssertEqual(text, "翻译 改进 复制结果")
    XCTAssertNil(RecognizedTextLayout.text(from: []))
    XCTAssertNil(RecognizedTextLayout.text(from: [line("   ", row: 0)]))
  }

  /// Geometry Vision reported for a Slack message: rows at the usual line
  /// pitch, where only the long bullet reaches the right edge.
  func testLinesThatEndShortOrStartAListItemKeepTheirLineBreaks() {
    let text = RecognizedTextLayout.text(from: [
      RecognizedLine(
        text: "But here's a more verbose summary:",
        frame: CGRect(x: 0, y: 0.034, width: 0.161, height: 0.114)),
      RecognizedLine(
        text: "Symptom (job j1, build 455b291a07, 10 workers × 32Gi, from the job registry events):",
        frame: CGRect(x: 0, y: 0.235, width: 0.552, height: 0.12)),
      RecognizedLine(
        text: "• Memory stayed bounded: shuffle workers peaked at about 16 GiB.",
        frame: CGRect(x: 0.004, y: 0.382, width: 0.304, height: 0.104)),
      RecognizedLine(
        text: "• About 11 to 12 minutes in (19:28:32 to 19:30:02 UTC), workers 8, 4, 6 and 3 "
          + "stopped heartbeating. Their last snapshots showed about 0.01 CPU cores and memory "
          + "down to 1 to 2 GiB, meaning they'd left the in-memory stage.",
        frame: CGRect(x: 0.004, y: 0.527, width: 0.994, height: 0.12)),
      RecognizedLine(
        text: "• The other workers kept running at about 1.2 to 1.6 cores. Only one shuffle completed.",
        frame: CGRect(x: 0.004, y: 0.676, width: 0.388, height: 0.119)),
      RecognizedLine(
        text: "• At 19:33:46 UTC, worker 2 failed the job: Index job failed: worker 8 timed out during shuffling.",
        frame: CGRect(x: 0.004, y: 0.823, width: 0.424, height: 0.104)),
    ])
    XCTAssertEqual(
      text?.components(separatedBy: "\n").map { String($0.prefix(12)) },
      ["But here's a", "Symptom (job", "• Memory sta", "• About 11 t", "• The other ", "• At 19:33:4"])
  }

  func testChineseLinesBreakWhereTheyEndShortAndJoinWhereTheyWrap() {
    let text = RecognizedTextLayout.text(from: [
      line("明天的评审改到下午三点。", row: 0, width: 0.24),
      line("我们的系统采用了全新的存储引擎，显著提升了读写性", row: 1, width: 0.48),
      line("能，也降低了成本。", row: 2, width: 0.18),
      line("1. 先合并存储引擎的改动", row: 3, width: 0.26),
      line("2. 再发布新版本", row: 4, width: 0.16),
    ])
    XCTAssertEqual(
      text,
      "明天的评审改到下午三点。\n我们的系统采用了全新的存储引擎，显著提升了读写性能，也降低了成本。\n"
        + "1. 先合并存储引擎的改动\n2. 再发布新版本")
  }

  /// Rows 0.04 tall at a 0.06 pitch: consecutive rows leave a 0.02 gap, a
  /// skipped row a 0.08 gap, which starts a paragraph.
  private func line(
    _ text: String, row: Int, x: CGFloat = 0.1, width: CGFloat = 0.15
  ) -> RecognizedLine {
    RecognizedLine(
      text: text, frame: CGRect(x: x, y: 0.1 + CGFloat(row) * 0.06, width: width, height: 0.04))
  }

  // MARK: - Framing geometry

  func testSelectionMapsOntoTheFrozenImagePixels() {
    let rect = CaptureGeometry.pixelRect(
      for: CGRect(x: 100, y: 600, width: 300, height: 100),
      in: CGSize(width: 1440, height: 900),
      imageSize: CGSize(width: 2880, height: 1800))
    XCTAssertEqual(rect, CGRect(x: 200, y: 400, width: 600, height: 200), "Top-left origin, 2x")

    let clamped = CaptureGeometry.selection(
      from: CGPoint(x: 1400, y: 20), to: CGPoint(x: 1500, y: -40),
      within: CGRect(x: 0, y: 0, width: 1440, height: 900))
    XCTAssertEqual(clamped, CGRect(x: 1400, y: 0, width: 40, height: 20))
  }

  func testTheSheetShowsTheFramedPartOfTheFrozenScreen() {
    let rect = CaptureGeometry.contentsRect(
      for: CGRect(x: 144, y: 450, width: 288, height: 90), in: CGSize(width: 1440, height: 900))
    XCTAssertEqual(rect.minX, 0.1, accuracy: 0.0001)
    XCTAssertEqual(rect.minY, 0.5, accuracy: 0.0001, "Bottom-left origin, like the view")
    XCTAssertEqual(rect.width, 0.2, accuracy: 0.0001)
    XCTAssertEqual(rect.height, 0.1, accuracy: 0.0001)
  }

  func testLightScreensAreVeiledWithPaperAndDarkOnesWithInk() throws {
    let light = try XCTUnwrap(Self.filledImage(gray: 0.96))
    let dark = try XCTUnwrap(Self.filledImage(gray: 0.12))
    XCTAssertEqual(CaptureVeil(forScreen: light), .paper)
    XCTAssertEqual(CaptureVeil(forScreen: dark), .ink)
    XCTAssertEqual(CaptureVeil.averageLuminance(of: light), 0.96, accuracy: 0.02)
    XCTAssertEqual(CaptureVeil(averageLuminance: 0.49), .ink)
    XCTAssertEqual(CaptureVeil(averageLuminance: 0.5), .paper)
  }

  private static func filledImage(gray: CGFloat) -> CGImage? {
    guard
      let context = CGContext(
        data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else {
      return nil
    }
    context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
    return context.makeImage()
  }

  // MARK: - The panel after a capture

  func testRecognizedTextReplacesTheSourceAndIsTranslatedAtOnce() async throws {
    let model = AppModel(
      mode: .improve, inputText: "Previous source",
      service: DelayedStreamingService(chunks: ["译文"], delay: .milliseconds(20)))
    let replacementRevision = model.inputReplacementRevision

    model.importCapturedText("Recognized text")

    XCTAssertEqual(model.inputText, "Recognized text")
    XCTAssertEqual(model.inputReplacementRevision, replacementRevision + 1)
    XCTAssertEqual(model.mode, .translate)
    XCTAssertEqual(model.result?.source, "Recognized text")
    try await waitUntil { model.result?.phase == .completed }
  }

  func testACaptureWithoutTextClearsTheSourceAndSupersedesARunningRequest() async throws {
    let model = AppModel(service: DelayedStreamingService(chunks: ["Slow"], delay: .seconds(5)))
    model.inputText = "Running source"
    XCTAssertTrue(model.submit())
    let running = try XCTUnwrap(model.result)

    model.importCapturedText(nil)

    XCTAssertEqual(model.inputText, "")
    XCTAssertFalse(model.isProcessing, "The superseded request no longer holds the panel")
    XCTAssertFalse(model.result === running)
    XCTAssertEqual(model.result?.phase, .unrecognized)
    XCTAssertEqual(model.resultNote?.kind, .unrecognized)
    XCTAssertEqual(model.resultNote?.text, "截图里没有识别到文字")
    XCTAssertFalse(model.canCopyResult)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertFalse(model.isProcessing)
    XCTAssertEqual(model.result?.phase, .unrecognized)
  }

  // MARK: - Shortcuts

  func testTheTwoGlobalShortcutsCannotShareACombination() {
    var applied: [(GlobalShortcut?, GlobalShortcutAction)] = []
    let model = AppModel(
      saveSettings: { _ in },
      applyGlobalShortcut: { shortcut, action in
        applied.append((shortcut, action))
        return true
      })
    XCTAssertEqual(model.settings.captureShortcut, GlobalShortcut.optionS)

    XCTAssertFalse(model.setShortcut(.optionA, for: .captureText))
    XCTAssertFalse(model.setShortcut(.optionS, for: .showPanel))
    XCTAssertTrue(applied.isEmpty, "A combination the other shortcut holds is never registered")

    let recorded = GlobalShortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: [.control, .option])
    XCTAssertTrue(model.setShortcut(recorded, for: .captureText))
    XCTAssertEqual(model.settings.captureShortcut, recorded)
    XCTAssertEqual(model.settings.shortcut, GlobalShortcut.optionA)
    XCTAssertEqual(applied.map(\.1), [.captureText])
  }

  /// Someone who only captures text clears the other two (`Design/spec/settings.md` §四).
  func testAShortcutCanBeLeftUnsetAndFreesItsCombination() throws {
    var applied: [(GlobalShortcut?, GlobalShortcutAction)] = []
    let model = AppModel(
      saveSettings: { _ in },
      applyGlobalShortcut: { shortcut, action in
        applied.append((shortcut, action))
        return true
      })
    XCTAssertTrue(model.setShortcut(nil, for: .showPanel))
    XCTAssertTrue(model.setShortcut(nil, for: .translationLayer), "Two unset shortcuts share nothing")
    XCTAssertNil(model.settings.shortcut)
    XCTAssertNil(model.settings.layerShortcut)
    XCTAssertEqual(applied.map(\.1), [.showPanel, .translationLayer])
    XCTAssertTrue(applied.allSatisfy { $0.0 == nil }, "Clearing releases the hot key")
    XCTAssertTrue(model.setShortcut(.optionA, for: .captureText), "⌥A is free once cleared")

    // null is a cleared shortcut; a missing key is still the default.
    let data = try JSONEncoder().encode(model.settings)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertTrue(json["shortcut"] is NSNull)
    let decoded = try JSONDecoder().decode(CidaSettings.self, from: data)
    XCTAssertNil(decoded.shortcut)
    XCTAssertEqual(decoded.captureShortcut, GlobalShortcut.optionA)
    XCTAssertNil(decoded.layerShortcut)
    XCTAssertEqual(
      try JSONDecoder().decode(CidaSettings.self, from: Data("{}".utf8)).shortcut,
      GlobalShortcut.optionA)
  }

  func testTheCommandLineWritesNoneForAnUnsetShortcut() throws {
    var configuration = EditableConfiguration(
      settings: CidaSettings(), launchAtLogin: false)
    try ConfigurationField.shortcut.apply("none", to: &configuration)
    try ConfigurationField.layerShortcut.apply("NONE", to: &configuration)
    XCTAssertNil(configuration.settings.shortcut)
    XCTAssertNil(configuration.settings.layerShortcut)
    XCTAssertNoThrow(try ConfigurationField.validate(configuration))
    XCTAssertEqual(
      ConfigurationField.shortcut.jsonValue(in: configuration, hasAPIKey: false), .string("none"))
    XCTAssertEqual(
      ConfigurationField.layerShortcut.displayValue(in: configuration, hasAPIKey: false), "none")
    ConfigurationField.shortcut.reset(in: &configuration)
    XCTAssertEqual(configuration.settings.shortcut, GlobalShortcut.optionA)
  }

  func testRecordingEitherShortcutSuspendsBothUntilItEnds() {
    var suspensions: [Bool] = []
    let model = AppModel(saveSettings: { _ in }, suspendGlobalShortcuts: { suspensions.append($0) })

    model.recordingShortcut = .captureText
    model.recordingShortcut = .showPanel
    model.recordingShortcut = nil

    XCTAssertEqual(suspensions, [true, false])
  }

  func testSettingsWithoutACaptureShortcutDecodeToOptionSAndACustomOneRoundTrips() throws {
    let legacy = try JSONDecoder().decode(
      CidaSettings.self, from: Data(#"{"shortcut":{"keyCode":49,"modifiers":2}}"#.utf8))
    XCTAssertEqual(legacy.captureShortcut, GlobalShortcut.optionS)

    var settings = CidaSettings()
    settings.captureShortcut = GlobalShortcut(
      keyCode: UInt16(kVK_ANSI_2), modifiers: [.command, .shift])
    let decoded = try JSONDecoder().decode(
      CidaSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(decoded.captureShortcut, settings.captureShortcut)
  }

  // MARK: - Recognition

  /// Real Vision recognition, so the first run in a process includes the
  /// model load.
  func testRecognitionReadsChineseAndEnglishIntoLines() async throws {
    let image = try XCTUnwrap(
      Self.renderedText([
        "我们的系统采用了全新的存储引擎。",
        "",
        "The engine keeps every write in a log.",
        "Symptom (job 42, 10 workers × 32Gi, from the registry):",
      ]))

    let text = try await TextRecognizer.recognizeText(in: image)

    let lines = try XCTUnwrap(text).components(separatedBy: "\n")
    XCTAssertEqual(lines.count, 3, "Three lines: \(text ?? "")")
    XCTAssertTrue(lines[0].contains("存储引擎"), lines[0])
    XCTAssertTrue(lines[1].contains("engine keeps every write"), lines[1])
    // English keeps its own punctuation next to Chinese.
    XCTAssertTrue(lines[2].hasPrefix("Symptom (job 42"), lines[2])
    XCTAssertTrue(lines[2].hasSuffix("registry):"), lines[2])
    let blank = try XCTUnwrap(Self.renderedText([]))
    let nothing = try await TextRecognizer.recognizeText(in: blank)
    XCTAssertNil(nothing)
  }

  private static func renderedText(_ lines: [String]) -> CGImage? {
    let width = 1400
    let height = 360
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else {
      return nil
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black,
    ]
    for (index, line) in lines.enumerated() {
      (line as NSString).draw(
        at: NSPoint(x: 40, y: CGFloat(height) - 90 - CGFloat(index) * 60),
        withAttributes: attributes)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      if clock.now >= deadline {
        XCTFail("Timed out waiting for condition")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
