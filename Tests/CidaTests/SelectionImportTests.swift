import AppKit
import XCTest

@testable import Cida

/// The global shortcut's selection import (`Design/spec/panel.md` §一 带入选区).
@MainActor
final class SelectionImportTests: XCTestCase {
  func testSelectionIsTrimmedAndBlankSelectionsAreNoSelection() {
    XCTAssertEqual(SelectedText.normalized("  storage engine\n"), "storage engine")
    XCTAssertEqual(SelectedText.normalized("第一段\n\n第二段"), "第一段\n\n第二段")
    XCTAssertNil(SelectedText.normalized(" \n\t "))
    XCTAssertNil(SelectedText.normalized(""))
    XCTAssertNil(SelectedText.normalized(nil))
  }

  func testNewSelectionReplacesTheSourceAndIsTranslatedAtOnce() async throws {
    let service = RecordingStreamingService()
    let model = AppModel(mode: .improve, inputText: "Previous source", service: service)
    model.stageInputDocument("A staged large document")
    let replacementRevision = model.inputReplacementRevision

    XCTAssertTrue(model.importSelection("The storage engine is new."))

    XCTAssertEqual(model.inputText, "The storage engine is new.")
    XCTAssertEqual(model.currentInputDocument, "The storage engine is new.")
    XCTAssertEqual(model.inputReplacementRevision, replacementRevision + 1)
    XCTAssertEqual(model.mode, .translate)
    let record = try XCTUnwrap(model.result)
    XCTAssertEqual(record.source, "The storage engine is new.")
    XCTAssertEqual(record.phase, .streaming)
    try await waitUntil { record.phase == .completed }
    XCTAssertEqual(
      service.requests,
      [
        ProcessingRequest(
          text: "The storage engine is new.", mode: .translate,
          myLanguage: "简体中文", foreignLanguage: "English")
      ])
  }

  func testTheSameSelectionAgainKeepsTheEditedSourceAndTheResult() async throws {
    let service = RecordingStreamingService()
    let model = AppModel(service: service)
    XCTAssertTrue(model.importSelection("storage engine"))
    let record = try XCTUnwrap(model.result)
    try await waitUntil { record.phase == .completed }
    model.inputText = "storage engine, with more context"
    let replacementRevision = model.inputReplacementRevision

    XCTAssertFalse(model.importSelection("storage engine"))

    XCTAssertEqual(model.inputText, "storage engine, with more context")
    XCTAssertEqual(model.inputReplacementRevision, replacementRevision)
    XCTAssertTrue(model.result === record)
    XCTAssertEqual(service.requests.count, 1, "No second request for the same selection")
  }

  func testNoSelectionForgetsTheLastOneSoItCanBeBroughtInAgain() async throws {
    let service = RecordingStreamingService()
    let model = AppModel(service: service)
    XCTAssertTrue(model.importSelection("storage engine"))
    try await waitUntil { model.result?.phase == .completed }
    model.inputText = "typed by hand"

    XCTAssertFalse(model.importSelection(nil))
    XCTAssertEqual(model.inputText, "typed by hand", "No selection leaves the panel as it is")

    XCTAssertTrue(model.importSelection("storage engine"))
    XCTAssertEqual(model.inputText, "storage engine")
    try await waitUntil { model.result?.phase == .completed }
    XCTAssertEqual(service.requests.map(\.text), ["storage engine", "storage engine"])
  }

  func testANewSelectionSupersedesARunningRequestThatStaysStoppable() async throws {
    let model = AppModel(service: DelayedStreamingService(chunks: ["Slow"], delay: .seconds(5)))
    XCTAssertTrue(model.importSelection("first selection"))
    let first = try XCTUnwrap(model.result)
    try await waitUntil { first.result == "Slow" }

    XCTAssertTrue(model.importSelection("second selection"), "A running request does not block it")
    let second = try XCTUnwrap(model.result)
    XCTAssertFalse(first === second)
    XCTAssertEqual(second.source, "second selection")
    XCTAssertEqual(model.generationState, .waiting(entryID: second.id))
    // The superseded request winds down on its own; it must leave the new
    // one running and stoppable.
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(model.isProcessing)
    XCTAssertEqual(first.result, "Slow", "The superseded record is no longer written to")

    model.cancelProcessing()
    try await waitUntil { !model.isProcessing }
    XCTAssertEqual(second.phase, .stopped)
  }

  func testSelectionReadGivesUpAtTheSourceDeadline() async {
    let clock = ContinuousClock()
    let startedAt = clock.now
    let copier = RecordingCopier()
    let selection = await SelectedText.read(
      from: FixedSelectedTextSource(answer: .unreadable(.attributeUnsupported), delay: .seconds(2)), copyingWith: copier)
    XCTAssertNil(selection)
    XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
    XCTAssertEqual(copier.copies, 0, "An application too slow to answer is not asked to copy")

    let answered = await SelectedText.read(
      from: FixedSelectedTextSource(answer: .selection("selected")), copyingWith: copier)
    XCTAssertEqual(answered, "selected")
  }

  /// §一 复制兜底: whatever the focused element cannot give is copied,
  /// except where Cida must not look.
  func testASelectionTheFocusedElementCannotGiveIsCopied() async {
    let copier = RecordingCopier(copied: "copied")
    let read = await SelectedText.read(
      from: FixedSelectedTextSource(answer: .selection("read")), copyingWith: copier)
    XCTAssertEqual(read, "read")
    XCTAssertEqual(copier.copies, 0)

    let withheld = await SelectedText.read(
      from: FixedSelectedTextSource(answer: .withheld), copyingWith: copier)
    XCTAssertNil(withheld)
    XCTAssertEqual(copier.copies, 0, "A password field or Cida itself is never copied")

    let unreadable = await SelectedText.read(
      from: FixedSelectedTextSource(answer: .unreadable(.attributeUnsupported)), copyingWith: copier)
    XCTAssertEqual(unreadable, "copied")
    XCTAssertEqual(copier.copies, 1)

    // Telegram Desktop: the focus stays in the empty message field while
    // text in a message is selected.
    let beside = await SelectedText.read(
      from: FixedSelectedTextSource(answer: .nothingSelected(elementText: "")),
      copyingWith: copier)
    XCTAssertEqual(beside, "copied")
    XCTAssertEqual(copier.copies, 2)
  }

  /// With nothing selected, VS Code copies the line the cursor is on.
  func testACopiedLineOfTheFocusedElementIsNoSelection() async {
    let copier = RecordingCopier(copied: "let engine = Engine()")
    let line = await SelectedText.read(
      from: FixedSelectedTextSource(
        answer: .nothingSelected(elementText: "import Storage\nlet engine = Engine()\n")),
      copyingWith: copier)
    XCTAssertNil(line)
    XCTAssertEqual(copier.copies, 1)

    let unknown = await SelectedText.read(
      from: FixedSelectedTextSource(answer: .nothingSelected(elementText: nil)),
      copyingWith: copier)
    XCTAssertEqual(unknown, "let engine = Engine()", "An element that holds no text rules nothing out")
  }

  func testCopiedSelectionIsTakenAndThePasteboardPutBack() async throws {
    let pasteboard = privatePasteboard()
    let custom = NSPasteboard.PasteboardType("io.xuanwo.cida.test.custom")
    let first = NSPasteboardItem()
    first.setString("what the user copied", forType: .string)
    first.setData(Data([1, 2, 3]), forType: custom)
    let second = NSPasteboardItem()
    second.setString("second item", forType: .string)
    pasteboard.clearContents()
    pasteboard.writeObjects([first, second])

    let copier = PasteboardSelectionCopier(pasteboardName: pasteboard.name) {
      pasteboard.clearContents()
      pasteboard.setString("  the selection \n", forType: .string)
      return true
    }
    let copied = await copier.copySelection()

    XCTAssertEqual(copied, "the selection")
    let items = try XCTUnwrap(pasteboard.pasteboardItems)
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items[0].string(forType: .string), "what the user copied")
    XCTAssertEqual(items[0].data(forType: custom), Data([1, 2, 3]))
    XCTAssertEqual(items[1].string(forType: .string), "second item")
    XCTAssertTrue(
      pasteboard.types?.contains(PasteboardSnapshot.transientType) ?? false,
      "Clipboard managers are told not to record the contents again")
  }

  func testNothingCopiedLeavesThePasteboardUntouched() async {
    let pasteboard = privatePasteboard()
    pasteboard.clearContents()
    pasteboard.setString("what the user copied", forType: .string)
    let changeCount = pasteboard.changeCount

    let copier = PasteboardSelectionCopier(
      copyDeadline: .milliseconds(50), pasteboardName: pasteboard.name
    ) { true }
    let copied = await copier.copySelection()

    XCTAssertNil(copied)
    XCTAssertEqual(pasteboard.changeCount, changeCount)
    XCTAssertEqual(pasteboard.string(forType: .string), "what the user copied")
  }

  func testCopiedFilesAreNoSelectionAndAnEmptyPasteboardStaysEmpty() async {
    let pasteboard = privatePasteboard()
    pasteboard.clearContents()

    let copier = PasteboardSelectionCopier(pasteboardName: pasteboard.name) {
      pasteboard.clearContents()
      pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/report.txt") as NSURL])
      return true
    }
    let copied = await copier.copySelection()

    XCTAssertNil(copied, "Files copied in Finder are not text to translate")
    XCTAssertEqual(pasteboard.pasteboardItems?.count ?? 0, 0)
  }

  func testACopyAfterTheDeadlineIsStillPutBack() async throws {
    let pasteboard = privatePasteboard()
    pasteboard.clearContents()
    pasteboard.setString("what the user copied", forType: .string)

    let copier = PasteboardSelectionCopier(
      copyDeadline: .milliseconds(30), lateCopyWindow: .seconds(1), pasteboardName: pasteboard.name
    ) {
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(120))
        pasteboard.clearContents()
        pasteboard.setString("late selection", forType: .string)
      }
      return true
    }
    let copied = await copier.copySelection()
    XCTAssertNil(copied, "A copy after the deadline is not waited for")

    try await waitUntil {
      pasteboard.string(forType: .string) == "what the user copied"
    }
  }

  func testNoCommandSentLeavesThePasteboardUntouched() async {
    let pasteboard = privatePasteboard()
    pasteboard.clearContents()
    pasteboard.setString("what the user copied", forType: .string)
    let changeCount = pasteboard.changeCount

    let copier = PasteboardSelectionCopier(pasteboardName: pasteboard.name) { false }
    let copied = await copier.copySelection()

    XCTAssertNil(copied, "Secure input is on")
    XCTAssertEqual(pasteboard.changeCount, changeCount)
  }

  private func privatePasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard(name: .init("io.xuanwo.cida.tests.\(UUID().uuidString)"))
    addTeardownBlock { @MainActor in pasteboard.releaseGlobally() }
    return pasteboard
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

private struct FixedSelectedTextSource: SelectedTextSource {
  let answer: SelectionAnswer
  var delay: Duration = .zero
  var readDeadline: Duration { .milliseconds(100) }

  func currentSelection() async -> SelectionAnswer {
    try? await Task.sleep(for: delay)
    return answer
  }
}

@MainActor
private final class RecordingCopier: SelectionCopier {
  private let copied: String
  private(set) var copies = 0

  init(copied: String = "copied") {
    self.copied = copied
  }

  func copySelection() async -> String? {
    copies += 1
    return copied
  }
}

private final class RecordingStreamingService: TextProcessingService, @unchecked Sendable {
  private let lock = NSLock()
  private var recordedRequests: [ProcessingRequest] = []

  var requests: [ProcessingRequest] {
    lock.withLock { recordedRequests }
  }

  func stream(
    _ request: ProcessingRequest,
    settings: CidaSettings
  ) -> AsyncThrowingStream<String, Error> {
    lock.withLock { recordedRequests.append(request) }
    return AsyncThrowingStream { continuation in
      continuation.yield("Translated")
      continuation.finish()
    }
  }
}
