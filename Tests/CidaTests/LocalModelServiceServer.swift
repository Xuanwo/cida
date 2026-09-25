import Foundation

@testable import Cida

/// Runs `Fixtures/model_service_mock.py` on a loopback port for one test: it answers in the
/// planned format and records the last request it received.
final class LocalModelServiceServer: @unchecked Sendable {
  struct Plan: Encodable {
    var format: ModelRequestFormat = .chatCompletions
    var chunks: [String] = []
    var stream = true
    var status = 200
    var errorBody: String?
    var streamError: String?
    var delay = 0.02

    private enum CodingKeys: String, CodingKey {
      case format, chunks, stream, status, errorBody, streamError, delay
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(format.rawValue, forKey: .format)
      try container.encode(chunks, forKey: .chunks)
      try container.encode(stream, forKey: .stream)
      try container.encode(status, forKey: .status)
      try container.encodeIfPresent(errorBody, forKey: .errorBody)
      try container.encodeIfPresent(streamError, forKey: .streamError)
      try container.encode(delay, forKey: .delay)
    }
  }

  struct RecordedRequest {
    let path: String
    /// Header names are lowercased.
    let headers: [String: String]
    let body: JSONValue
  }

  let baseURL: URL
  private let process: Process
  private let recordURL: URL

  init(plan: Plan) throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/model_service_mock.py")
    recordURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("cida-model-request-\(UUID().uuidString).json")

    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      fixtureURL.path,
      recordURL.path,
      String(decoding: try JSONEncoder().encode(plan), as: UTF8.self),
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    self.process = process

    let data = output.fileHandleForReading.availableData
    guard
      let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first,
      let port = Int(line)
    else {
      process.terminate()
      throw MockServerError.failedToStart
    }
    baseURL = URL(string: "http://127.0.0.1:\(port)")!
  }

  /// The path each format's services use, so recorded requests show which was called.
  func endpoint(for format: ModelRequestFormat) -> URL {
    switch format {
    case .chatCompletions: baseURL.appendingPathComponent("v1/chat/completions")
    case .responses: baseURL.appendingPathComponent("v1/responses")
    case .anthropicMessages: baseURL.appendingPathComponent("v1/messages")
    }
  }

  func recordedRequest() throws -> RecordedRequest {
    let document = try parseRecord(Data(contentsOf: recordURL))
    var headers: [String: String] = [:]
    for member in document["headers"]?.objectValue?.members ?? [] {
      headers[member.key] = member.value.stringValue
    }
    return RecordedRequest(
      path: document["path"]?.stringValue ?? "",
      headers: headers,
      body: document["body"] ?? .null
    )
  }

  func stop() {
    if process.isRunning {
      process.terminate()
      // `waitUntilExit` spins the current run loop, which a test's cooperative thread lacks.
      let deadline = Date().addingTimeInterval(3)
      while process.isRunning, Date() < deadline { usleep(10_000) }
    }
    try? FileManager.default.removeItem(at: recordURL)
  }

  enum MockServerError: Error {
    case failedToStart
    case unreadableRecord
  }

  private func parseRecord(_ data: Data) throws -> JSONValue {
    guard let value = JSONValue.parse(data) else { throw MockServerError.unreadableRecord }
    return value
  }
}
