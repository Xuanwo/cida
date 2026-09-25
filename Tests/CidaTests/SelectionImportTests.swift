import Foundation
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
    let selection = await SelectedText.read(from: FixedSelectedTextSource(delay: .seconds(2)))
    XCTAssertNil(selection)
    XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))

    let answered = await SelectedText.read(from: FixedSelectedTextSource(delay: .zero))
    XCTAssertEqual(answered, "selected")
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
  let delay: Duration
  var readDeadline: Duration { .milliseconds(100) }

  func currentSelection() async -> String? {
    try? await Task.sleep(for: delay)
    return "selected"
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
