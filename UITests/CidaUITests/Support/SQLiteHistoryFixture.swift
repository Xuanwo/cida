import Foundation

struct HistoryFixtureEntry: Encodable {
  let id: UUID
  let sortOrder: Int
  let mode: String
  let source: String
  let result: String
  let detail: String
  let timestamp: String
  let sourceCharacterCount: Int
  let resultCharacterCount: Int
  let state: String

  init(
    id: UUID = UUID(),
    sortOrder: Int,
    mode: String = "translate",
    source: String,
    result: String,
    detail: String = "English → 中文",
    timestamp: String = "12:00",
    sourceCharacterCount: Int? = nil,
    resultCharacterCount: Int? = nil,
    state: String = "completed"
  ) {
    self.id = id
    self.sortOrder = sortOrder
    self.mode = mode
    self.source = source
    self.result = result
    self.detail = detail
    self.timestamp = timestamp
    self.sourceCharacterCount = sourceCharacterCount ?? source.utf16.count
    self.resultCharacterCount = resultCharacterCount ?? result.utf16.count
    self.state = state
  }
}

enum SQLiteHistoryFixture {
  static func seed(
    _ entries: [HistoryFixtureEntry],
    at databasePath: String,
    controlBaseURL: String
  ) throws {
    try post(
      [
        "databasePath": databasePath,
        "entries": entries.map { entry in
          [
            "id": entry.id.uuidString,
            "sortOrder": entry.sortOrder,
            "mode": entry.mode,
            "source": entry.source,
            "result": entry.result,
            "detail": entry.detail,
            "timestamp": entry.timestamp,
            "sourceCharacterCount": entry.sourceCharacterCount,
            "resultCharacterCount": entry.resultCharacterCount,
            "state": entry.state,
          ] as [String: Any]
        },
      ],
      to: "\(controlBaseURL)/control/seed-history"
    )
  }

  static func scalar(
    _ sql: String,
    at databasePath: String,
    controlBaseURL: String
  ) throws -> String {
    let data = try post(
      ["databasePath": databasePath, "sql": sql],
      to: "\(controlBaseURL)/control/query-history"
    )
    let response = try JSONDecoder().decode(SQLiteQueryResponse.self, from: data)
    return response.value
  }

  @discardableResult
  private static func post(_ body: [String: Any], to url: String) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: body)
    return try ProcessRunner.run(
      "/usr/bin/curl",
      arguments: [
        "--fail",
        "--silent",
        "--show-error",
        "--max-time", "5",
        "-H", "Content-Type: application/json",
        "--data-binary", "@-",
        url,
      ],
      standardInput: payload
    )
  }
}

private struct SQLiteQueryResponse: Decodable {
  let value: String
}
