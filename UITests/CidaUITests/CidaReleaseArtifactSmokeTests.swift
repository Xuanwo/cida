import XCTest

@MainActor
final class CidaReleaseArtifactSmokeTests: XCTestCase {
  private var app: XCUIApplication!

  func testSignedReleaseArtifactRunsTheProductionTranslationFlow() throws {
    continueAfterFailure = false

    let environment = ProcessInfo.processInfo.environment
    let workRoot = environment["CIDA_UI_TEST_WORK_ROOT"] ?? "/Users/admin/cida-ui-test-work"
    let appPath =
      environment["CIDA_UI_TEST_APP_PATH"]
      ?? "\(workRoot)/ReleaseArtifact/Cida.app"
    let endpoint: String
    if let configuredEndpoint = environment["CIDA_UI_TEST_ENDPOINT"] {
      endpoint = configuredEndpoint
    } else {
      let port = try String(
        contentsOfFile: "\(workRoot)/mock-port",
        encoding: .utf8
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      endpoint = "http://127.0.0.1:\(port)/v1/chat/completions"
    }
    let settingsNamespace =
      "com.xuanwo.Cida.Automation.ReleaseSmoke."
      + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    app = XCUIApplication(url: URL(fileURLWithPath: appPath))
    app.launchEnvironment["CIDA_ISOLATED_AUTOMATION"] = "1"
    app.launchArguments = [
      "--e2e-testing",
      "--automation-settings-namespace",
      settingsNamespace,
      "--automation-openai-endpoint",
      endpoint,
    ]
    app.launch()
    addTeardownBlock { [app] in app?.terminate() }

    XCTAssertTrue(app.dialogs["cida-panel"].waitForExistence(timeout: 10))
    let composer = app.textViews["composer-input"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["action-translate"].waitForExistence(timeout: 5))

    composer.click()
    composer.typeText("CIDA_RELEASE_ARTIFACT_SMOKE")
    XCTAssertEqual(composer.value as? String, "CIDA_RELEASE_ARTIFACT_SMOKE")
    composer.typeKey(.return, modifierFlags: [])

    let completedResult = app.textViews.matching(
      NSPredicate(format: "identifier == %@ AND value CONTAINS %@", "result-text", "CIDA_UI_E2E_COMPLETE")
    ).firstMatch
    XCTAssertTrue(completedResult.waitForExistence(timeout: 30))
    XCTAssertTrue(app.buttons["bar-action-copy"].waitForExistence(timeout: 5))
    XCTAssertEqual(composer.value as? String, "CIDA_RELEASE_ARTIFACT_SMOKE")
  }
}
