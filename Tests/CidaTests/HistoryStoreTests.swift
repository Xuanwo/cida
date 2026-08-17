import CSQLite
import Foundation
import XCTest

@testable import Cida

@MainActor
final class HistoryStoreTests: XCTestCase {
  func testRoundTripPreservesOrderContentAndTerminalState() throws {
    let temporaryDirectory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let store = try HistoryStore(
      databaseURL: temporaryDirectory.appending(path: "History.sqlite3"),
      deltaFlushDelay: .seconds(30)
    )
    let first = HistoryEntry(
      mode: .translate,
      source: "持久化原文",
      result: "",
      detail: "中文 → English",
      timestamp: "19:20",
      reportedSourceCharacterCount: 6,
      state: .streaming
    )
    let second = HistoryEntry(
      mode: .improve,
      source: "Second source",
      result: "Second result",
      detail: "English",
      timestamp: "19:21",
      state: .failed
    )

    store.insert(HistoryPersistenceRecord(first))
    store.appendResult(entryID: first.id, delta: "Persisted ")
    store.appendResult(entryID: first.id, delta: "result")
    store.updateState(entryID: first.id, state: .completed)
    store.insert(HistoryPersistenceRecord(second))
    store.flush()

    let restored = try store.load()
    XCTAssertEqual(restored.map(\.id), [first.id, second.id])
    XCTAssertEqual(restored[0].source, "持久化原文")
    XCTAssertEqual(restored[0].result, "Persisted result")
    XCTAssertEqual(restored[0].state, .completed)
    XCTAssertEqual(restored[0].reportedSourceCharacterCount, 6)
    XCTAssertEqual(restored[1].result, "Second result")
    XCTAssertEqual(restored[1].state, .failed)
  }

  func testRestartRecoversInterruptedStreamAsCancelled() throws {
    let temporaryDirectory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let databaseURL = temporaryDirectory.appending(path: "History.sqlite3")
    let entry = HistoryEntry(
      mode: .translate,
      source: "Interrupted source",
      result: "",
      detail: "English → 中文",
      timestamp: "19:22",
      state: .streaming
    )

    do {
      let store = try HistoryStore(databaseURL: databaseURL, deltaFlushDelay: .seconds(30))
      store.insert(HistoryPersistenceRecord(entry))
      store.appendResult(entryID: entry.id, delta: "Partial response")
      store.flush()
    }

    let reopenedStore = try HistoryStore(databaseURL: databaseURL)
    let restored = try XCTUnwrap(reopenedStore.load().first)
    XCTAssertEqual(restored.id, entry.id)
    XCTAssertEqual(restored.result, "Partial response")
    XCTAssertEqual(restored.state, .cancelled)
  }

  func testStreamingDeltasDoNotRewriteTheLargeSourceRow() throws {
    let temporaryDirectory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let databaseURL = temporaryDirectory.appending(path: "History.sqlite3")
    let store = try HistoryStore(
      databaseURL: databaseURL,
      deltaFlushDelay: .seconds(30)
    )
    let entry = HistoryEntry(
      mode: .translate,
      source: String(repeating: "S", count: 1_000_000),
      result: "",
      detail: "中文 → English",
      timestamp: "19:22",
      reportedSourceCharacterCount: 1_000_000,
      state: .streaming
    )

    store.insert(HistoryPersistenceRecord(entry))
    store.appendResult(entryID: entry.id, delta: "Streamed result")
    store.flush()

    XCTAssertEqual(
      try textValue(
        "SELECT result FROM history_entries WHERE id = '\(entry.id.uuidString)'",
        at: databaseURL
      ),
      ""
    )
    XCTAssertEqual(
      try textValue(
        "SELECT result FROM history_result_overrides WHERE entry_id = '\(entry.id.uuidString)'",
        at: databaseURL
      ),
      "Streamed result"
    )
    XCTAssertEqual(try store.load().first?.result, "Streamed result")
  }

  func testMalformedRowsAreSkippedWithoutBlockingHistoryLoading() throws {
    let temporaryDirectory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let databaseURL = temporaryDirectory.appending(path: "History.sqlite3")
    let validEntry = HistoryEntry(
      mode: .translate,
      source: "Valid source",
      result: "Valid result",
      detail: "English → 中文",
      timestamp: "19:23"
    )

    do {
      let store = try HistoryStore(databaseURL: databaseURL)
      store.insert(HistoryPersistenceRecord(validEntry))
      store.flush()
    }
    try executeSQL(
      """
      INSERT INTO history_entries (
        id, sort_order, mode, source, result, detail, timestamp,
        source_character_count, result_character_count, state, created_at, updated_at
      ) VALUES (
        'invalid-id', 1, 'translate', 'Damaged source', 'Damaged result',
        '中文 → English', '19:24', NULL, NULL, 'completed', 0, 0
      )
      """,
      at: databaseURL
    )

    let reopenedStore = try HistoryStore(databaseURL: databaseURL)
    let restored = try reopenedStore.load()
    XCTAssertEqual(restored.map(\.id), [validEntry.id])
  }

  func testRecentAndEarlierPagesKeepTheCompleteDatabaseOutOfTheViewGraph() throws {
    let temporaryDirectory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let store = try HistoryStore(
      databaseURL: temporaryDirectory.appending(path: "History.sqlite3")
    )
    let entries = (0..<10).map { index in
      HistoryEntry(
        mode: .translate,
        source: "Source \(index)",
        result: "Result \(index)",
        detail: "中文 → English",
        timestamp: "19:25"
      )
    }
    for entry in entries {
      store.insert(HistoryPersistenceRecord(entry))
    }
    store.flush()

    let recent = try store.loadRecent(limit: 3)
    XCTAssertEqual(recent.entries.map(\.id), entries[7...].map(\.id))
    XCTAssertEqual(recent.totalCount, 10)
    XCTAssertEqual(recent.oldestSortOrder, 7)
    XCTAssertTrue(recent.hasMoreBefore)

    let earlier = try store.loadBefore(sortOrder: 7, limit: 3)
    XCTAssertEqual(earlier.entries.map(\.id), entries[4...6].map(\.id))
    XCTAssertEqual(earlier.totalCount, 10)
    XCTAssertEqual(earlier.oldestSortOrder, 4)
    XCTAssertTrue(earlier.hasMoreBefore)
  }

  func testHistoryPagesStopBeforeExceedingTheMaterializedPayloadBudget() throws {
    let temporaryDirectory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let store = try HistoryStore(
      databaseURL: temporaryDirectory.appending(path: "History.sqlite3"),
      materializedPageByteBudget: 1_200
    )
    let entries = (0..<5).map { index in
      HistoryEntry(
        mode: .translate,
        source: "Source \(index)",
        result: String(repeating: Character(String(index)), count: 800),
        detail: "中文 → English",
        timestamp: "19:26",
        reportedResultCharacterCount: 800
      )
    }
    for entry in entries {
      store.insert(HistoryPersistenceRecord(entry))
    }
    store.flush()

    let recent = try store.loadRecent(limit: 5)
    XCTAssertEqual(recent.entries.map(\.id), [entries[4].id])
    XCTAssertEqual(recent.totalCount, 5)
    XCTAssertEqual(recent.oldestSortOrder, 4)
    XCTAssertTrue(recent.hasMoreBefore)

    let earlier = try store.loadBefore(sortOrder: 4, limit: 5)
    XCTAssertEqual(earlier.entries.map(\.id), [entries[3].id])
    XCTAssertEqual(earlier.oldestSortOrder, 3)
    XCTAssertTrue(earlier.hasMoreBefore)
  }

  func testModelPersistsTheCompleteSmoothedStream() async throws {
    let temporaryDirectory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let store = try HistoryStore(
      databaseURL: temporaryDirectory.appending(path: "History.sqlite3"),
      deltaFlushDelay: .seconds(30)
    )
    let chunks = ["Database", " backed", " history"]
    let model = AppModel(
      entries: [],
      service: PersistedStreamingService(chunks: chunks),
      streamPresentationPolicy: .fastTests,
      historyPersistence: store
    )

    await model.process(text: "Persist this request")
    model.flushHistoryPersistence()

    let restored = try XCTUnwrap(store.load().last)
    XCTAssertEqual(restored.id, model.entries.last?.id)
    XCTAssertEqual(restored.source, "Persist this request")
    XCTAssertEqual(restored.result, chunks.joined())
    XCTAssertEqual(restored.state, .completed)
  }

  private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "cida-history-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }

  private func executeSQL(_ sql: String, at databaseURL: URL) throws {
    var connection: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &connection) == SQLITE_OK, let connection else {
      throw NSError(domain: "HistoryStoreTests", code: 1)
    }
    defer { sqlite3_close(connection) }

    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
      sqlite3_free(errorMessage)
      throw NSError(
        domain: "HistoryStoreTests",
        code: Int(result),
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
  }

  private func textValue(_ sql: String, at databaseURL: URL) throws -> String? {
    var connection: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &connection) == SQLITE_OK, let connection else {
      throw NSError(domain: "HistoryStoreTests", code: 1)
    }
    defer { sqlite3_close(connection) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw NSError(domain: "HistoryStoreTests", code: 2)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    guard let value = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: value)
  }
}

private struct PersistedStreamingService: TextProcessingService {
  let chunks: [String]

  func stream(
    _ request: ProcessingRequest,
    settings: CidaSettings
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      for chunk in chunks {
        continuation.yield(chunk)
      }
      continuation.finish()
    }
  }
}
