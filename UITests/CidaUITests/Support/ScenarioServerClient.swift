import Foundation

struct ScenarioRequestState: Decodable {
  let requestID: Int
  let scenario: String
  let status: String
  let chunksSent: Int
}

private struct ScenarioServerState: Decodable {
  let requests: [ScenarioRequestState]
}

final class ScenarioServerClient {
  private let baseURL: String

  init(baseURL: String) {
    self.baseURL = baseURL
  }

  func reset() throws {
    _ = try request(path: "/control/reset", body: [:])
  }

  func releaseFirstByte(for scenario: String) throws {
    _ = try request(
      path: "/control/release-first-byte",
      body: ["scenario": scenario]
    )
  }

  func state() throws -> [ScenarioRequestState] {
    let data = try ProcessRunner.run(
      "/usr/bin/curl",
      arguments: [
        "--fail",
        "--silent",
        "--show-error",
        "--max-time", "3",
        "\(baseURL)/control/state",
      ]
    )
    return try JSONDecoder().decode(ScenarioServerState.self, from: data).requests
  }

  @discardableResult
  func wait(
    for scenario: String,
    status: String? = nil,
    minimumChunks: Int = 0,
    timeout: TimeInterval = 8
  ) throws -> ScenarioRequestState? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let request = try state().last(where: {
        $0.scenario == scenario && $0.chunksSent >= minimumChunks
      }) {
        if status == nil || request.status == status {
          return request
        }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return nil
  }

  private func request(path: String, body: [String: String]) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: body)
    return try ProcessRunner.run(
      "/usr/bin/curl",
      arguments: [
        "--fail",
        "--silent",
        "--show-error",
        "--max-time", "3",
        "-H", "Content-Type: application/json",
        "--data-binary", "@-",
        "\(baseURL)\(path)",
      ],
      standardInput: payload
    )
  }
}
