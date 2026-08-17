import CSQLite
import Foundation

struct HistoryPersistenceRecord: Equatable, Sendable {
  let id: UUID
  let mode: ProcessingMode
  let source: String
  let result: String
  let detail: String
  let timestamp: String
  let reportedSourceCharacterCount: Int?
  let reportedResultCharacterCount: Int?
  let state: HistoryEntryState

  init(_ entry: HistoryEntry) {
    id = entry.id
    mode = entry.mode
    source = entry.source
    result = entry.result
    detail = entry.detail
    timestamp = entry.timestamp
    reportedSourceCharacterCount = entry.reportedSourceCharacterCount
    reportedResultCharacterCount = entry.reportedResultCharacterCount
    state = entry.state
  }

  var historyEntry: HistoryEntry {
    HistoryEntry(
      id: id,
      mode: mode,
      source: source,
      result: result,
      detail: detail,
      timestamp: timestamp,
      reportedSourceCharacterCount: reportedSourceCharacterCount,
      reportedResultCharacterCount: reportedResultCharacterCount,
      state: state
    )
  }
}

protocol HistoryPersisting: AnyObject, Sendable {
  func insert(_ record: HistoryPersistenceRecord)
  func appendResult(entryID: UUID, delta: String)
  func updateState(entryID: UUID, state: HistoryEntryState)
  func flush()
}

struct HistoryPage: Sendable {
  let entries: [HistoryEntry]
  let oldestSortOrder: Int64?
  let totalCount: Int
  let hasMoreBefore: Bool
}

protocol HistoryPageLoading: AnyObject, Sendable {
  func loadBefore(sortOrder: Int64, limit: Int) throws -> HistoryPage
}

final class HistoryStore: HistoryPersisting, HistoryPageLoading, @unchecked Sendable {
  private static let schemaVersion = 2

  private let database: OpaquePointer
  private let queue = DispatchQueue(label: "com.xuanwo.Cida.history-store", qos: .background)
  private let queueKey = DispatchSpecificKey<Void>()
  private let deltaFlushDelay: DispatchTimeInterval
  private let materializedPageByteBudget: Int
  private var pendingDeltas: [UUID: String] = [:]
  private var pendingFlushes: [UUID: DispatchWorkItem] = [:]

  static func openProduction() throws -> HistoryStore {
    let fileManager = FileManager.default
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = applicationSupport.appending(
      path: SettingsStore.storageNamespace,
      directoryHint: .isDirectory
    )
    return try HistoryStore(databaseURL: directory.appending(path: "History.sqlite3"))
  }

  init(
    databaseURL: URL,
    deltaFlushDelay: DispatchTimeInterval = .seconds(1),
    materializedPageByteBudget: Int = 16 * 1_024 * 1_024
  ) throws {
    self.deltaFlushDelay = deltaFlushDelay
    self.materializedPageByteBudget = max(1, materializedPageByteBudget)
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var connection: OpaquePointer?
    let openResult = sqlite3_open_v2(
      databaseURL.path,
      &connection,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard openResult == SQLITE_OK, let connection else {
      let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
      if let connection {
        sqlite3_close(connection)
      }
      throw HistoryStoreError.openFailed(message)
    }
    database = connection
    queue.setSpecific(key: queueKey, value: ())

    do {
      sqlite3_busy_timeout(database, 2_000)
      try execute("PRAGMA journal_mode = WAL")
      try execute("PRAGMA synchronous = NORMAL")
      try migrateIfNeeded()
    } catch {
      sqlite3_close(database)
      throw error
    }
  }

  deinit {
    let close = {
      self.flushAllPendingLocked()
      sqlite3_close(self.database)
    }
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      close()
    } else {
      queue.sync(execute: close)
    }
  }

  func load() throws -> [HistoryEntry] {
    try queue.sync {
      try execute("UPDATE history_entries SET state = 'cancelled' WHERE state = 'streaming'")
      let statement = try prepare(
        """
        SELECT h.id, h.mode, h.source, COALESCE(r.result, h.result), h.detail, h.timestamp,
               h.source_character_count, h.result_character_count, h.state
        FROM history_entries AS h
        LEFT JOIN history_result_overrides AS r ON r.entry_id = h.id
        ORDER BY h.sort_order ASC
        """
      )
      defer { sqlite3_finalize(statement) }

      var entries: [HistoryEntry] = []
      var stepResult = sqlite3_step(statement)
      while stepResult == SQLITE_ROW {
        if let id = UUID(uuidString: textColumn(statement, 0)),
          let mode = ProcessingMode(rawValue: textColumn(statement, 1)),
          let state = HistoryEntryState(rawValue: textColumn(statement, 8))
        {
          let record = HistoryPersistenceRecord(
            id: id,
            mode: mode,
            source: textColumn(statement, 2),
            result: textColumn(statement, 3),
            detail: textColumn(statement, 4),
            timestamp: textColumn(statement, 5),
            reportedSourceCharacterCount: optionalIntegerColumn(statement, 6),
            reportedResultCharacterCount: optionalIntegerColumn(statement, 7),
            state: state
          )
          entries.append(record.historyEntry)
        }
        stepResult = sqlite3_step(statement)
      }
      guard stepResult == SQLITE_DONE else {
        throw currentError(operation: "load history")
      }
      return entries
    }
  }

  func loadRecent(limit: Int) throws -> HistoryPage {
    try queue.sync {
      try execute("UPDATE history_entries SET state = 'cancelled' WHERE state = 'streaming'")
      return try loadPageLocked(before: nil, limit: limit)
    }
  }

  func loadBefore(sortOrder: Int64, limit: Int) throws -> HistoryPage {
    try queue.sync {
      try loadPageLocked(before: sortOrder, limit: limit)
    }
  }

  func insert(_ record: HistoryPersistenceRecord) {
    queue.async { [self] in
      do {
        try upsertLocked(record)
      } catch {
        report(error)
      }
    }
  }

  func appendResult(entryID: UUID, delta: String) {
    guard !delta.isEmpty else { return }
    queue.async { [self] in
      pendingDeltas[entryID, default: ""].append(contentsOf: delta)
      guard pendingFlushes[entryID] == nil else { return }
      let work = DispatchWorkItem { [weak self] in
        self?.flushPendingDeltaLocked(entryID)
      }
      pendingFlushes[entryID] = work
      queue.asyncAfter(deadline: .now() + deltaFlushDelay, execute: work)
    }
  }

  func updateState(entryID: UUID, state: HistoryEntryState) {
    queue.async { [self] in
      flushPendingDeltaLocked(entryID)
      do {
        let statement = try prepare(
          "UPDATE history_entries SET state = ?, updated_at = ? WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(state.rawValue, to: 1, in: statement)
        try bind(Date().timeIntervalSince1970, to: 2, in: statement)
        try bind(entryID.uuidString, to: 3, in: statement)
        try stepToCompletion(statement, operation: "update history state")
      } catch {
        report(error)
      }
    }
  }

  func flush() {
    let work = { self.flushAllPendingLocked() }
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      work()
    } else {
      queue.sync(execute: work)
    }
  }

  private func migrateIfNeeded() throws {
    let version = try integerResult(for: "PRAGMA user_version")
    guard version <= Self.schemaVersion else {
      throw HistoryStoreError.unsupportedSchema(version)
    }
    guard version < Self.schemaVersion else { return }

    try execute("BEGIN IMMEDIATE")
    do {
      if version == 0 {
        try execute(
          """
          CREATE TABLE history_entries (
            id TEXT PRIMARY KEY NOT NULL,
            sort_order INTEGER NOT NULL UNIQUE,
            mode TEXT NOT NULL,
            source TEXT NOT NULL,
            result TEXT NOT NULL,
            detail TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            source_character_count INTEGER,
            result_character_count INTEGER,
            state TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
          )
          """
        )
      }
      try execute(
        """
        CREATE TABLE IF NOT EXISTS history_result_overrides (
          entry_id TEXT PRIMARY KEY NOT NULL,
          result TEXT NOT NULL
        )
        """
      )
      try execute("PRAGMA user_version = \(Self.schemaVersion)")
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func loadPageLocked(before sortOrder: Int64?, limit: Int) throws -> HistoryPage {
    let boundedLimit = max(1, limit)
    let statement = try prepare(
      """
      SELECT h.sort_order, h.id, h.mode, h.source, COALESCE(r.result, h.result),
             h.detail, h.timestamp, h.source_character_count,
             h.result_character_count, h.state
      FROM history_entries AS h
      LEFT JOIN history_result_overrides AS r ON r.entry_id = h.id
      \(sortOrder == nil ? "" : "WHERE h.sort_order < ?")
      ORDER BY h.sort_order DESC
      LIMIT ?
      """
    )
    defer { sqlite3_finalize(statement) }

    var bindIndex: Int32 = 1
    if let sortOrder {
      try bind(sortOrder, to: bindIndex, in: statement)
      bindIndex += 1
    }
    try bind(Int64(boundedLimit), to: bindIndex, in: statement)

    var descendingEntries: [HistoryEntry] = []
    descendingEntries.reserveCapacity(boundedLimit)
    var oldestSortOrder: Int64?
    var materializedPayloadBytes = 0
    var stoppedAtByteBudget = false
    var stepResult = sqlite3_step(statement)
    while stepResult == SQLITE_ROW {
      let rowPayloadBytes =
        Int(sqlite3_column_bytes(statement, 3))
        + Int(sqlite3_column_bytes(statement, 4))
        + Int(sqlite3_column_bytes(statement, 5))
        + Int(sqlite3_column_bytes(statement, 6))
      if !descendingEntries.isEmpty,
        materializedPayloadBytes + rowPayloadBytes > materializedPageByteBudget
      {
        stoppedAtByteBudget = true
        break
      }
      let currentSortOrder = sqlite3_column_int64(statement, 0)
      oldestSortOrder = min(oldestSortOrder ?? currentSortOrder, currentSortOrder)
      if let id = UUID(uuidString: textColumn(statement, 1)),
        let mode = ProcessingMode(rawValue: textColumn(statement, 2)),
        let state = HistoryEntryState(rawValue: textColumn(statement, 9))
      {
        descendingEntries.append(
          HistoryEntry(
            id: id,
            mode: mode,
            source: textColumn(statement, 3),
            result: textColumn(statement, 4),
            detail: textColumn(statement, 5),
            timestamp: textColumn(statement, 6),
            reportedSourceCharacterCount: optionalIntegerColumn(statement, 7),
            reportedResultCharacterCount: optionalIntegerColumn(statement, 8),
            state: state
          )
        )
      }
      materializedPayloadBytes += rowPayloadBytes
      stepResult = sqlite3_step(statement)
    }
    guard stoppedAtByteBudget || stepResult == SQLITE_DONE else {
      throw currentError(operation: "load history page")
    }

    let totalCount = try integerResult(for: "SELECT COUNT(*) FROM history_entries")
    return HistoryPage(
      entries: descendingEntries.reversed(),
      oldestSortOrder: oldestSortOrder,
      totalCount: totalCount,
      hasMoreBefore: (oldestSortOrder ?? 0) > 0
    )
  }

  private func upsertLocked(_ record: HistoryPersistenceRecord) throws {
    let statement = try prepare(
      """
      INSERT INTO history_entries (
        id, sort_order, mode, source, result, detail, timestamp,
        source_character_count, result_character_count, state, created_at, updated_at
      ) VALUES (
        ?, COALESCE((SELECT MAX(sort_order) + 1 FROM history_entries), 0),
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      )
      ON CONFLICT(id) DO UPDATE SET
        mode = excluded.mode,
        source = excluded.source,
        result = excluded.result,
        detail = excluded.detail,
        timestamp = excluded.timestamp,
        source_character_count = excluded.source_character_count,
        result_character_count = excluded.result_character_count,
        state = excluded.state,
        updated_at = excluded.updated_at
      """
    )
    defer { sqlite3_finalize(statement) }
    let now = Date().timeIntervalSince1970
    try bind(record.id.uuidString, to: 1, in: statement)
    try bind(record.mode.rawValue, to: 2, in: statement)
    try bind(record.source, to: 3, in: statement)
    try bind(record.result, to: 4, in: statement)
    try bind(record.detail, to: 5, in: statement)
    try bind(record.timestamp, to: 6, in: statement)
    try bind(record.reportedSourceCharacterCount, to: 7, in: statement)
    try bind(record.reportedResultCharacterCount, to: 8, in: statement)
    try bind(record.state.rawValue, to: 9, in: statement)
    try bind(now, to: 10, in: statement)
    try bind(now, to: 11, in: statement)
    try stepToCompletion(statement, operation: "insert history")
    try deleteResultOverrideLocked(entryID: record.id)
  }

  private func flushPendingDeltaLocked(_ entryID: UUID) {
    pendingFlushes.removeValue(forKey: entryID)?.cancel()
    guard let delta = pendingDeltas.removeValue(forKey: entryID), !delta.isEmpty else { return }
    do {
      let seedStatement = try prepare(
        """
        INSERT OR IGNORE INTO history_result_overrides (entry_id, result)
        SELECT id, result FROM history_entries WHERE id = ?
        """
      )
      defer { sqlite3_finalize(seedStatement) }
      try bind(entryID.uuidString, to: 1, in: seedStatement)
      try stepToCompletion(seedStatement, operation: "seed streamed history result")

      let statement = try prepare(
        "UPDATE history_result_overrides SET result = result || ? WHERE entry_id = ?"
      )
      defer { sqlite3_finalize(statement) }
      try bind(delta, to: 1, in: statement)
      try bind(entryID.uuidString, to: 2, in: statement)
      try stepToCompletion(statement, operation: "append history result")
    } catch {
      report(error)
    }
  }

  private func deleteResultOverrideLocked(entryID: UUID) throws {
    let statement = try prepare(
      "DELETE FROM history_result_overrides WHERE entry_id = ?"
    )
    defer { sqlite3_finalize(statement) }
    try bind(entryID.uuidString, to: 1, in: statement)
    try stepToCompletion(statement, operation: "reset streamed history result")
  }

  private func flushAllPendingLocked() {
    for entryID in Array(pendingDeltas.keys) {
      flushPendingDeltaLocked(entryID)
    }
  }

  private func execute(_ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message =
        errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(database))
      sqlite3_free(errorMessage)
      throw HistoryStoreError.sqlite(message)
    }
  }

  private func integerResult(for sql: String) throws -> Int {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw currentError(operation: "read schema version")
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw currentError(operation: "prepare statement")
    }
    return statement
  }

  private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else {
      throw currentError(operation: "bind text")
    }
  }

  private func bind(_ value: Int?, to index: Int32, in statement: OpaquePointer) throws {
    let result =
      value.map { sqlite3_bind_int64(statement, index, sqlite3_int64($0)) }
      ?? sqlite3_bind_null(statement, index)
    guard result == SQLITE_OK else {
      throw currentError(operation: "bind integer")
    }
  }

  private func bind(_ value: Double, to index: Int32, in statement: OpaquePointer) throws {
    guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
      throw currentError(operation: "bind number")
    }
  }

  private func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer) throws {
    guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
      throw currentError(operation: "bind integer")
    }
  }

  private func stepToCompletion(_ statement: OpaquePointer, operation: String) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw currentError(operation: operation)
    }
  }

  private func textColumn(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let value = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: value)
  }

  private func optionalIntegerColumn(_ statement: OpaquePointer, _ index: Int32) -> Int? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return Int(exactly: sqlite3_column_int64(statement, index))
  }

  private func currentError(operation: String) -> HistoryStoreError {
    .sqlite("\(operation): \(String(cString: sqlite3_errmsg(database)))")
  }

  private func report(_ error: Error) {
    fputs("History persistence failed: \(error)\n", stderr)
  }
}

extension HistoryPersistenceRecord {
  fileprivate init(
    id: UUID,
    mode: ProcessingMode,
    source: String,
    result: String,
    detail: String,
    timestamp: String,
    reportedSourceCharacterCount: Int?,
    reportedResultCharacterCount: Int?,
    state: HistoryEntryState
  ) {
    self.id = id
    self.mode = mode
    self.source = source
    self.result = result
    self.detail = detail
    self.timestamp = timestamp
    self.reportedSourceCharacterCount = reportedSourceCharacterCount
    self.reportedResultCharacterCount = reportedResultCharacterCount
    self.state = state
  }
}

enum HistoryStoreError: Error, Equatable {
  case openFailed(String)
  case sqlite(String)
  case unsupportedSchema(Int)
}
