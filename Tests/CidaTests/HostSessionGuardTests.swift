import Foundation
import XCTest

final class HostSessionGuardTests: XCTestCase {
  func testIsolatedGuardAllowsConcurrentUserSessionChanges() throws {
    let before = snapshot(
      frontmost: application(
        bundleIdentifier: "com.openai.codex",
        executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
        processIdentifier: 10
      ),
      pasteboardChangeCount: 100,
      productionCidaApplications: [
        application(
          bundleIdentifier: "com.xuanwo.Cida",
          executablePath: "/Applications/Cida.app/Contents/MacOS/Cida",
          processIdentifier: 20
        )
      ]
    )
    let after = snapshot(
      frontmost: application(
        bundleIdentifier: "com.google.Chrome",
        executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        processIdentifier: 30
      ),
      pasteboardChangeCount: 105,
      productionCidaApplications: []
    )

    let result = try runGuard(
      before: before,
      after: after,
      observations: [snapshot(), snapshot()],
      clipboardIsolated: true,
      monitorHealthy: true
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.report["passed"] as? Bool, true)
    XCTAssertEqual(result.report["hostUserActivityObserved"] as? Bool, true)
    XCTAssertEqual(result.report["frontmostApplicationChanged"] as? Bool, true)
    XCTAssertEqual(result.report["pasteboardUnchanged"] as? Bool, false)
    XCTAssertEqual(result.report["productionCidaProcessesUnchanged"] as? Bool, false)
    XCTAssertEqual(result.report["monitorCoverageComplete"] as? Bool, true)
    XCTAssertEqual(result.report["testArtifactProcessObserved"] as? Bool, false)
  }

  func testGuardRejectsAnExactArtifactProcessObservedBetweenSnapshots() throws {
    let testArtifact = application(
      bundleIdentifier: "com.xuanwo.Cida",
      executablePath: "/tmp/ReleaseArtifact/Cida.app/Contents/MacOS/Cida",
      processIdentifier: 40
    )
    let observation = snapshot(monitoredArtifactApplications: [testArtifact])

    let result = try runGuard(
      before: snapshot(),
      after: snapshot(),
      observations: [snapshot(), observation, snapshot()],
      clipboardIsolated: true,
      monitorHealthy: true
    )

    XCTAssertEqual(result.exitCode, 1)
    XCTAssertEqual(result.report["passed"] as? Bool, false)
    XCTAssertEqual(result.report["monitorSampleCount"] as? Int, 3)
    XCTAssertEqual(result.report["testArtifactProcessObserved"] as? Bool, true)
    let observed = try XCTUnwrap(
      result.report["observedTestArtifactApplications"] as? [[String: Any]]
    )
    XCTAssertEqual(observed.count, 1)
    XCTAssertEqual(
      observed.first?["executablePath"] as? String, testArtifact["executablePath"] as? String)
  }

  func testGuardRejectsAnUnhealthyIsolationMonitor() throws {
    let result = try runGuard(
      before: snapshot(),
      after: snapshot(),
      observations: [snapshot()],
      clipboardIsolated: true,
      monitorHealthy: false
    )

    XCTAssertEqual(result.exitCode, 1)
    XCTAssertEqual(result.report["passed"] as? Bool, false)
    XCTAssertEqual(result.report["monitorHealthy"] as? Bool, false)
  }

  func testGuardRejectsIncompleteMonitorCoverage() throws {
    let result = try runGuard(
      before: snapshot(),
      after: snapshot(),
      observations: [snapshot()],
      clipboardIsolated: true,
      monitorHealthy: true
    )

    XCTAssertEqual(result.exitCode, 1)
    XCTAssertEqual(result.report["passed"] as? Bool, false)
    XCTAssertEqual(result.report["monitorHealthy"] as? Bool, true)
    XCTAssertEqual(result.report["monitorCoverageComplete"] as? Bool, false)
  }

  private func runGuard(
    before: [String: Any],
    after: [String: Any],
    observations: [[String: Any]],
    clipboardIsolated: Bool,
    monitorHealthy: Bool
  ) throws -> (exitCode: Int32, report: [String: Any]) {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("cida-host-session-guard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let beforeURL = temporaryDirectory.appendingPathComponent("before.json")
    let afterURL = temporaryDirectory.appendingPathComponent("after.json")
    let observationsURL = temporaryDirectory.appendingPathComponent("observations.jsonl")
    let reportURL = temporaryDirectory.appendingPathComponent("report.json")
    try writeJSON(before, to: beforeURL)
    try writeJSON(after, to: afterURL)
    let observationData = try observations.reduce(into: Data()) { data, observation in
      data.append(try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]))
      data.append(Data("\n".utf8))
    }
    try observationData.write(to: observationsURL)

    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      repositoryRoot.appendingPathComponent("scripts/e2e/compare-host-session.py").path,
      beforeURL.path,
      afterURL.path,
      reportURL.path,
      "--monitor-observations",
      observationsURL.path,
    ]
    if clipboardIsolated {
      process.arguments?.append("--clipboard-isolated")
    }
    if monitorHealthy {
      process.arguments?.append("--monitor-healthy")
    }
    try process.run()
    process.waitUntilExit()

    let report = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any]
    )
    return (process.terminationStatus, report)
  }

  private func writeJSON(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: url)
  }

  private func snapshot(
    frontmost: [String: Any]? = nil,
    pasteboardChangeCount: Int = 1,
    productionCidaApplications: [[String: Any]] = [],
    monitoredArtifactApplications: [[String: Any]] = [],
    frontmostApplicationMatchesMonitoredArtifact: Bool = false
  ) -> [String: Any] {
    [
      "capturedAt": "2026-08-17T00:00:00Z",
      "frontmostApplication": frontmost ?? NSNull(),
      "frontmostApplicationMatchesMonitoredArtifact":
        frontmostApplicationMatchesMonitoredArtifact,
      "monitoredArtifactApplications": monitoredArtifactApplications,
      "pasteboardChangeCount": pasteboardChangeCount,
      "productionCidaApplications": productionCidaApplications,
    ]
  }

  private func application(
    bundleIdentifier: String,
    executablePath: String,
    processIdentifier: Int
  ) -> [String: Any] {
    [
      "bundleIdentifier": bundleIdentifier,
      "executablePath": executablePath,
      "processIdentifier": processIdentifier,
    ]
  }
}
