import AppKit
import XCTest

@testable import Cida

@MainActor
final class SelectionImprovementTests: XCTestCase {
  func testOnlyCompleteOutputReplacesTheRawSelectionAndCanBeOpenedWithoutAnotherRequest() async throws {
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let target = ReplacementTarget(text: "  bad sentence 👋\n")
    let operation = SelectionImprovement(service: ControlledService(stream: stream), capture: { target })
    operation.trigger(settings: CidaSettings())
    continuation.yield("Better")
    await Task.yield()
    XCTAssertTrue(target.writes.isEmpty)
    continuation.yield(" sentence 👋")
    continuation.finish()
    try await wait { !operation.isRunning }
    XCTAssertEqual(target.writes, ["  Better sentence 👋\n"])
    let record = try XCTUnwrap(operation.result)
    let model = AppModel(service: ImmediateStreamingService())
    operation.onResult = { model.importImprovementResult($0) }
    operation.performFeedbackAction()
    XCTAssertEqual(model.mode, .improve)
    XCTAssertEqual(model.inputText, target.text)
    XCTAssertTrue(model.result === record)
    XCTAssertFalse(model.isProcessing)
    XCTAssertFalse(model.isResultStale)
    XCTAssertEqual(model.resultNote?.kind, .replacement)
  }

  /// A completed improvement is handed over with its source (`Design/spec/notes.md` §四), even
  /// when the replacement could not be confirmed: the model's work is worth keeping either way.
  func testACompletedImprovementIsHandedOverWithItsSource() async throws {
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let target = ReplacementTarget(text: "bad sentence")
    let operation = SelectionImprovement(service: ControlledService(stream: stream), capture: { target })
    var generated: [(String, String)] = []
    operation.onGenerated = { generated.append(($0, $1)) }
    operation.trigger(settings: CidaSettings())
    target.isCurrent = false
    continuation.yield("Better sentence")
    continuation.finish()
    try await wait { !operation.isRunning }

    XCTAssertEqual(generated.map(\.0), ["bad sentence"])
    XCTAssertEqual(generated.map(\.1), ["Better sentence"])
  }

  /// A failed request has no result to keep.
  func testAFailedImprovementIsNotHandedOver() async throws {
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let target = ReplacementTarget(text: "bad sentence")
    let operation = SelectionImprovement(service: ControlledService(stream: stream), capture: { target })
    var generated: [(String, String)] = []
    operation.onGenerated = { generated.append(($0, $1)) }
    operation.trigger(settings: CidaSettings())
    continuation.yield("Partial")
    continuation.finish(throwing: ModelServiceError.emptyResult)
    try await wait { !operation.isRunning }

    XCTAssertTrue(generated.isEmpty)
  }

  func testCancellationDropsLateOutputAndFreesTheNextRequest() async throws {
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let target = ReplacementTarget(text: "source")
    let operation = SelectionImprovement(service: ControlledService(stream: stream), capture: { target })
    var feedback: ImprovementFeedback?
    operation.onFeedback = { feedback = $0 }
    operation.trigger(settings: CidaSettings())
    await Task.yield()
    operation.trigger(settings: CidaSettings())
    XCTAssertFalse(operation.isRunning)
    XCTAssertEqual(feedback?.text, "已取消")
    continuation.yield("Too late")
    continuation.finish()
    await Task.yield()
    XCTAssertTrue(target.writes.isEmpty)
    XCTAssertNil(operation.result)
    XCTAssertTrue(target.stopped)
  }

  func testChangedTargetKeepsCompleteResultForManualUse() async throws {
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let target = ReplacementTarget(text: "source")
    let operation = SelectionImprovement(service: ControlledService(stream: stream), capture: { target })
    operation.trigger(settings: CidaSettings())
    target.isCurrent = false
    continuation.yield("Result")
    continuation.finish()
    try await wait { !operation.isRunning }
    XCTAssertTrue(target.writes.isEmpty)
    XCTAssertEqual(operation.result?.result, "Result")
    XCTAssertEqual(operation.result?.replacementNote, SelectionReplacementOutcome.unavailable.note)
  }

  func testFailureAndEmptyOutputNeverPaste() async throws {
    for fails in [false, true] {
      let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
      let target = ReplacementTarget(text: "source")
      let operation = SelectionImprovement(service: ControlledService(stream: stream), capture: { target })
      operation.trigger(settings: CidaSettings())
      if fails {
        continuation.yield("Partial")
        continuation.finish(throwing: ModelServiceError.emptyResult)
      } else {
        continuation.yield(" \n")
        continuation.finish()
      }
      try await wait { !operation.isRunning }
      XCTAssertTrue(target.writes.isEmpty)
      guard case .failed = operation.result?.phase else { return XCTFail("Expected failure") }
    }
  }

  func testEmptySelectionDoesNotStartARequest() {
    let operation = SelectionImprovement(service: ImmediateStreamingService(), capture: { nil })
    var feedback: ImprovementFeedback?
    operation.onFeedback = { feedback = $0 }
    operation.trigger(settings: CidaSettings())
    XCTAssertFalse(operation.isRunning)
    XCTAssertNil(operation.result)
    XCTAssertEqual(feedback?.text, "请先选中要改进的文字")
  }

  func testDelayedPasteRestoresOnlyAfterConsumptionAndPreservesAllClipboardTypes() async {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let custom = NSPasteboard.PasteboardType("test.custom")
    board.setString("Original", forType: .string)
    board.setData(Data([1, 2]), forType: custom)
    var consumed: String?
    var checks = 0
    let outcome = await SelectionPaste(pasteboard: board).perform(
      text: "Replacement", isCurrent: { true }, post: { true }, didReplace: {
        checks += 1
        if checks == 4 { consumed = board.string(forType: .string) }
        return consumed == "Replacement"
      })
    XCTAssertEqual(outcome, .replaced)
    XCTAssertEqual(consumed, "Replacement")
    XCTAssertEqual(board.string(forType: .string), "Original")
    XCTAssertEqual(board.data(forType: custom), Data([1, 2]))
  }

  func testUnconfirmedPasteLeavesResultAndDoesNotRestoreOldClipboard() async {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString("Original", forType: .string)
    var posts = 0
    let outcome = await SelectionPaste(pasteboard: board, deadline: .milliseconds(30)).perform(
      text: "Replacement", isCurrent: { true }, post: { posts += 1; return true }, didReplace: { false })
    XCTAssertEqual(outcome, .unconfirmed)
    XCTAssertEqual(posts, 1)
    XCTAssertEqual(board.string(forType: .string), "Replacement")
  }

  func testUserClipboardWriteWinsAndInvalidTargetNeverTouchesClipboard() async {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString("Original", forType: .string)
    let unavailable = await SelectionPaste(pasteboard: board).perform(
      text: "Replacement", isCurrent: { false }, post: { XCTFail("No paste"); return true },
      didReplace: { true })
    XCTAssertEqual(unavailable, .unavailable)
    XCTAssertEqual(board.string(forType: .string), "Original")
    let replaced = await SelectionPaste(pasteboard: board).perform(
      text: "Replacement", isCurrent: { true }, post: { true }, didReplace: {
        board.clearContents()
        board.setString("User copy", forType: .string)
        return true
      })
    XCTAssertEqual(replaced, .replaced)
    XCTAssertEqual(board.string(forType: .string), "User copy")
  }

  func testShortcutMigrationKeepsExistingAssignmentsAndExplicitNoneRoundTrips() throws {
    let decoder = JSONDecoder()
    XCTAssertEqual(try decoder.decode(CidaSettings.self, from: Data("{}".utf8)).improvementShortcut, .optionF)
    var old = CidaSettings()
    old.shortcut = .optionF
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    object.removeValue(forKey: "improvementShortcut")
    let migrated = try decoder.decode(CidaSettings.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(migrated.shortcut, .optionF)
    XCTAssertNil(migrated.improvementShortcut)
    XCTAssertTrue(migrated.hasValidShortcuts)
    var cleared = CidaSettings()
    cleared.improvementShortcut = nil
    XCTAssertNil(try decoder.decode(CidaSettings.self, from: JSONEncoder().encode(cleared)).improvementShortcut)
    let model = AppModel()
    XCTAssertFalse(model.setShortcut(.optionA, for: .improveSelection))
    XCTAssertFalse(model.setShortcut(.optionD.addingShift, for: .improveSelection))
    XCTAssertTrue(model.setShortcut(nil, for: .improveSelection))
    XCTAssertTrue(model.setShortcut(.optionF, for: .captureText))
  }

  private func wait(_ condition: () -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(condition())
  }
}

private struct ControlledService: TextProcessingService {
  let stream: AsyncThrowingStream<String, Error>
  func stream(_ request: ProcessingRequest, settings: CidaSettings) -> AsyncThrowingStream<String, Error> { stream }
}

@MainActor
private final class ReplacementTarget: SelectionReplacementTarget {
  let text: String
  var isCurrent = true
  var writes: [String] = []
  var stopped = false
  init(text: String) { self.text = text }
  func replace(with text: String) async -> SelectionReplacementOutcome {
    guard isCurrent else { return .unavailable }
    writes.append(text)
    return .replaced
  }
  func stopObserving() { stopped = true }
}
