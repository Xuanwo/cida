import Foundation
import XCTest

struct E2EEnvironment {
  let workRoot: String
  let sourceRoot: String
  let appPath: String
  let endpoint: String
  let controlBaseURL: String
  let recordPath: String
  /// The scenario server route the app reads selections from
  /// (`--automation-selection-endpoint`).
  var selectionEndpoint: String {
    "\(controlBaseURL)/automation/selection"
  }
  /// Directory exported to the host with the run; per-launch lifecycle logs land here.
  var lifecycleLogDirectory: String {
    (recordPath as NSString).deletingLastPathComponent + "/lifecycle"
  }

  init() throws {
    let environment = ProcessInfo.processInfo.environment
    workRoot = environment["CIDA_UI_TEST_WORK_ROOT"] ?? "/Users/admin/cida-ui-test-work"
    sourceRoot = environment["CIDA_UI_TEST_SOURCE_ROOT"] ?? "/Users/admin/cida-work"
    appPath =
      environment["CIDA_UI_TEST_APP_PATH"]
      ?? "\(workRoot)/ReleaseArtifact/Cida.app"
    recordPath =
      environment["CIDA_UI_TEST_RECORD_PATH"]
      ?? "/Volumes/My Shared Files/artifacts/openai-request.json"

    let port: String
    if let endpoint = environment["CIDA_UI_TEST_ENDPOINT"],
      let components = URLComponents(string: endpoint),
      let endpointPort = components.port
    {
      port = String(endpointPort)
      self.endpoint = endpoint
    } else {
      port = try String(
        contentsOfFile: "\(workRoot)/mock-port",
        encoding: .utf8
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      endpoint = "http://127.0.0.1:\(port)/v1/chat/completions"
    }
    controlBaseURL = "http://127.0.0.1:\(port)"
  }

  func uniqueSettingsNamespace(for testName: String) -> String {
    let safeName = testName.replacingOccurrences(
      of: "[^A-Za-z0-9]",
      with: "",
      options: .regularExpression
    )
    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    return "com.xuanwo.Cida.Automation.\(safeName).\(nonce)"
  }

  func resetSettings(namespace: String) {
    _ = try? ProcessRunner.run(
      "/usr/bin/defaults",
      arguments: ["delete", namespace]
    )
    _ = try? ProcessRunner.run(
      "/usr/bin/security",
      arguments: [
        "delete-generic-password",
        "-s", namespace,
        "-a", "provider-api-key",
      ]
    )
  }
}

enum ProcessRunner {
  @discardableResult
  static func run(
    _ executable: String,
    arguments: [String],
    standardInput: Data? = nil,
    acceptsNonzeroExit: Bool = false
  ) throws -> Data {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = error
    if let standardInput {
      let input = Pipe()
      process.standardInput = input
      try process.run()
      input.fileHandleForWriting.write(standardInput)
      try input.fileHandleForWriting.close()
    } else {
      try process.run()
    }
    process.waitUntilExit()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = error.fileHandleForReading.readDataToEndOfFile()
    if process.terminationStatus != 0, !acceptsNonzeroExit {
      let message = String(data: errorData, encoding: .utf8) ?? ""
      throw ProcessRunnerError.failed(
        executable: executable,
        status: process.terminationStatus,
        message: message
      )
    }
    return outputData
  }
}

enum ProcessRunnerError: Error, CustomStringConvertible {
  case failed(executable: String, status: Int32, message: String)

  var description: String {
    switch self {
    case .failed(let executable, let status, let message):
      "\(executable) exited with \(status): \(message)"
    }
  }
}
