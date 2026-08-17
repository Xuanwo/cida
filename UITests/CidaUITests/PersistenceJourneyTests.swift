import XCTest

@MainActor
final class PersistenceJourneyTests: CidaReleaseUITestCase {
  func testCompletedHistorySurvivesTerminationAndASecondSubmissionAppends() throws {
    driver.launch()
    _ = driver.submit("CIDA_E2E_RESULT_A")
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_RESULT_A_COMPLETE").waitForExistence(timeout: 8)
    )
    XCTAssertTrue(driver.waitForLabel("翻译", in: driver.submitButton, timeout: 3))
    driver.terminate()

    XCTAssertEqual(
      try SQLiteHistoryFixture.scalar(
        "SELECT COUNT(*) FROM history_entries;",
        at: driver.databasePath,
        controlBaseURL: e2eEnvironment.controlBaseURL
      ),
      "1"
    )
    XCTAssertEqual(
      try SQLiteHistoryFixture.scalar(
        "SELECT state FROM history_entries ORDER BY sort_order DESC LIMIT 1;",
        at: driver.databasePath,
        controlBaseURL: e2eEnvironment.controlBaseURL
      ),
      "completed"
    )
    XCTAssertTrue(
      try SQLiteHistoryFixture.scalar(
        "SELECT COALESCE(r.result, h.result) FROM history_entries h "
          + "LEFT JOIN history_result_overrides r ON r.entry_id = h.id "
          + "ORDER BY h.sort_order DESC LIMIT 1;",
        at: driver.databasePath,
        controlBaseURL: e2eEnvironment.controlBaseURL
      ).contains("CIDA_E2E_RESULT_A_COMPLETE")
    )

    driver.launch()
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_RESULT_A_COMPLETE").waitForExistence(timeout: 5)
    )
    _ = driver.submit("CIDA_E2E_DELAYED_RESULT_B", expectsStreamingState: true)
    XCTAssertNotNil(
      try scenarioServer.wait(
        for: "CIDA_E2E_DELAYED_RESULT_B",
        status: "headers-sent",
        timeout: 5
      )
    )
    try scenarioServer.releaseFirstByte(for: "CIDA_E2E_DELAYED_RESULT_B")
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_RESULT_B_COMPLETE").waitForExistence(timeout: 8)
    )
    driver.terminate()
    XCTAssertEqual(
      try SQLiteHistoryFixture.scalar(
        "SELECT COUNT(*) FROM history_entries;",
        at: driver.databasePath,
        controlBaseURL: e2eEnvironment.controlBaseURL
      ),
      "2"
    )
  }

  func testOpenAIEndpointModelAndAPIKeyPersistThenClearAcrossRelaunch() {
    driver.launch(endpointOverride: false)
    driver.configureOpenAI(
      endpoint: e2eEnvironment.endpoint,
      model: "cida-persisted-model",
      apiKey: "sk-cida-persisted-e2e"
    )
    driver.terminate()

    driver.launch(endpointOverride: false)
    let settingsButton = driver.app.buttons["model-settings-button"]
    settingsButton.click()
    let settingsWindow = driver.app.windows["设置"]
    XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
    XCTAssertEqual(driver.settingsProviderMenu(in: settingsWindow).label, "OpenAI")
    XCTAssertEqual(
      driver.app.textFields["settings-openai-endpoint"].value as? String,
      e2eEnvironment.endpoint
    )
    XCTAssertEqual(
      driver.app.textFields["settings-model"].value as? String,
      "cida-persisted-model"
    )
    let apiKey = driver.app.secureTextFields["settings-api-key-editor"]
    XCTAssertTrue(apiKey.waitForExistence(timeout: 3))
    XCTAssertNotEqual(apiKey.value as? String, "")
    driver.replaceText(in: apiKey, with: "")
    settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    driver.terminate()

    driver.launch(endpointOverride: false)
    driver.app.buttons["model-settings-button"].click()
    XCTAssertTrue(driver.app.windows["设置"].waitForExistence(timeout: 5))
    XCTAssertEqual(
      driver.app.secureTextFields["settings-api-key-editor"].value as? String,
      ""
    )
  }
}
