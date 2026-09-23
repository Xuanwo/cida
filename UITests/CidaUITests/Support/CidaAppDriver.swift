import AppKit
import Foundation
import XCTest

/// Drives the floating panel of a signed Release artifact through XCUI. The
/// element names match the accessibility identifiers of `PanelView`.
@MainActor
final class CidaAppDriver {
  let environment: E2EEnvironment
  let settingsNamespace: String
  private(set) var app: XCUIApplication

  init(
    environment: E2EEnvironment,
    settingsNamespace: String
  ) {
    self.environment = environment
    self.settingsNamespace = settingsNamespace
    app = XCUIApplication(url: URL(fileURLWithPath: environment.appPath))
  }

  /// AppKit exposes an `NSPanel` to XCUI as a dialog, not a window.
  var panel: XCUIElement { app.dialogs["cida-panel"] }
  var composer: XCUIElement { app.textViews["composer-input"] }
  var controlBar: XCUIElement { element(identifier: "control-bar") }
  var translateAction: XCUIElement { app.buttons["action-translate"] }
  var improveAction: XCUIElement { app.buttons["action-improve"] }
  var stopButton: XCUIElement { app.buttons["bar-action-stop"] }
  var copyButton: XCUIElement { app.buttons["bar-action-copy"] }
  var copiedButton: XCUIElement { app.buttons["bar-action-copied"] }
  var resultPane: XCUIElement { element(identifier: "result-pane") }
  var resultText: XCUIElement { app.textViews["result-text"] }
  var settingsWindow: XCUIElement { app.windows["设置"] }

  func resultNote(_ kind: String) -> XCUIElement {
    element(identifier: "result-note-\(kind)")
  }

  func settingsProviderMenu(in settingsWindow: XCUIElement? = nil) -> XCUIElement {
    let root = settingsWindow ?? self.settingsWindow
    return root.menuButtons.matching(
      NSPredicate(
        format: "identifier == %@ AND label IN %@",
        "settings-provider-menu",
        Self.providerLabels
      )
    ).firstMatch
  }

  /// `ModelProvider.displayName` of every preset plus the custom entry.
  static let providerLabels = ["DeepSeek", "OpenAI", "Moonshot", "智谱 GLM", "自定义（OpenAI 兼容）"]
  static let customProviderLabel = "自定义（OpenAI 兼容）"

  var readinessRow: XCUIElement { element(identifier: "settings-readiness") }

  func launch(
    endpointOverride: Bool = true,
    additionalArguments: [String] = []
  ) {
    app = XCUIApplication(url: URL(fileURLWithPath: environment.appPath))
    app.launchEnvironment["CIDA_ISOLATED_AUTOMATION"] = "1"
    app.launchArguments = [
      "--e2e-testing",
      "--automation-settings-namespace",
      settingsNamespace,
      "--automation-lifecycle-log",
      "\(environment.lifecycleLogDirectory)/\(settingsNamespace).log",
    ]
    if endpointOverride {
      app.launchArguments += ["--automation-openai-endpoint", environment.endpoint]
    }
    app.launchArguments += additionalArguments
    app.launch()

    XCTAssertTrue(waitForRunning(timeout: 10))
    XCTAssertTrue(panel.waitForExistence(timeout: 10))
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertTrue(translateAction.waitForExistence(timeout: 5))
  }

  func terminate() {
    guard app.state != .notRunning else { return }
    app.terminate()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
  }

  // MARK: - Panel lifecycle

  func hidePanel() {
    composer.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(panel.waitForNonExistence(timeout: 3), "Escape hides the panel")
  }

  func showPanel() {
    app.typeKey(.space, modifierFlags: .option)
    XCTAssertTrue(panel.waitForExistence(timeout: 5), "Option-Space shows the panel")
    XCTAssertTrue(composer.waitForExistence(timeout: 3))
  }

  func openSettings() {
    composer.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
  }

  // MARK: - Source

  func paste(_ value: String, into element: XCUIElement? = nil) {
    let target = element ?? composer
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString(value, forType: .string))
    target.click()
    target.typeKey("v", modifierFlags: .command)
  }

  func replaceText(in element: XCUIElement, with value: String) {
    XCTAssertTrue(element.waitForExistence(timeout: 5))
    element.click()
    element.typeKey("a", modifierFlags: .command)
    if value.isEmpty {
      element.typeKey(.delete, modifierFlags: [])
    } else {
      element.typeText(value)
    }
  }

  func replaceSource(with value: String) {
    composer.click()
    composer.typeKey("a", modifierFlags: .command)
    composer.typeKey(.delete, modifierFlags: [])
    if !value.isEmpty {
      paste(value)
    }
    XCTAssertTrue(waitForTextValue(value, in: composer, timeout: 2))
  }

  // MARK: - Submit

  /// Replaces the source with `text` and presses ⏎. The source stays in the
  /// editor and the result pane appears with the streaming caret.
  func submit(_ text: String, expectsStreamingState: Bool = false) {
    replaceSource(with: text)
    submitCurrentSource(expectsStreamingState: expectsStreamingState)
  }

  func submitCurrentSource(expectsStreamingState: Bool = false) {
    let source = textValue(in: composer)
    composer.click()
    composer.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(resultPane.waitForExistence(timeout: 5), "⏎ opens the result pane")
    XCTAssertEqual(textValue(in: composer), source, "The source stays after ⏎")
    if expectsStreamingState {
      XCTAssertTrue(stopButton.waitForExistence(timeout: 3), "The slot shows 停止 while streaming")
    }
  }

  func waitForCompletion(timeout: TimeInterval = 8) {
    XCTAssertTrue(copyButton.waitForExistence(timeout: timeout), "复制结果 appears once done")
    XCTAssertFalse(stopButton.exists)
  }

  func result(containing marker: String) -> XCUIElement {
    app.textViews.matching(
      NSPredicate(format: "identifier == %@ AND value CONTAINS %@", "result-text", marker)
    ).firstMatch
  }

  func element(identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == %@", identifier)
    ).firstMatch
  }

  /// Points Settings at a custom (OpenAI-compatible) endpoint.
  func configureCustomEndpoint(
    endpoint: String,
    model: String = "cida-ui-mock-model",
    apiKey: String = "sk-isolated-ui-test"
  ) {
    openSettings()
    let providerMenu = settingsProviderMenu(in: settingsWindow)
    XCTAssertTrue(providerMenu.waitForExistence(timeout: 5))
    if providerMenu.label != Self.customProviderLabel {
      providerMenu.click()
      let customItem = app.menuItems[Self.customProviderLabel]
      XCTAssertTrue(customItem.waitForExistence(timeout: 5))
      customItem.click()
    }

    replaceText(in: app.textFields["settings-endpoint"], with: endpoint)
    replaceText(in: app.textFields["settings-model"], with: model)
    replaceText(in: app.secureTextFields["settings-api-key-editor"], with: apiKey)
    settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(settingsWindow.waitForNonExistence(timeout: 3))
  }

  // MARK: - Waits

  func waitForValue(
    _ expectedValue: String,
    in element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    wait(
      description: "value '\(expectedValue)' for \(element.identifier)",
      timeout: timeout,
      sample: { element.value as? String },
      matches: { $0 == expectedValue },
      describe: { $0 ?? "nil" }
    )
  }

  func textValue(in element: XCUIElement) -> String {
    element.value as? String ?? ""
  }

  func waitForTextValue(
    _ expectedValue: String,
    in element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    wait(
      description: "text '\(expectedValue)' for \(element.identifier)",
      timeout: timeout,
      sample: { self.textValue(in: element) },
      matches: { $0 == expectedValue },
      describe: { $0 }
    )
  }

  func waitForLabel(
    _ expectedLabel: String,
    in element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    wait(
      description: "label '\(expectedLabel)' for \(element.identifier)",
      timeout: timeout,
      sample: { element.label },
      matches: { $0 == expectedLabel },
      describe: { $0 }
    )
  }

  func waitForFrameHeight(
    atLeast minimumHeight: CGFloat? = nil,
    atMost maximumHeight: CGFloat? = nil,
    in element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    wait(
      description: "frame height for \(element.identifier)",
      timeout: timeout,
      sample: { element.frame.height },
      matches: { height in
        (minimumHeight.map { height >= $0 } ?? true)
          && (maximumHeight.map { height <= $0 } ?? true)
      },
      describe: { String(format: "%.2f", $0) }
    )
  }

  /// Polls `exists` every 20 ms. `XCUIElement.waitForExistence` samples about
  /// once per second, which misses the 800 ms `✓ 已复制` state.
  func waitForExistence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
    wait(
      description: "\(element) to exist",
      timeout: timeout,
      sample: { element.exists },
      matches: { $0 },
      describe: { $0 ? "exists" : "missing" }
    )
  }

  func waitForPasteboard(_ expected: String, timeout: TimeInterval) -> Bool {
    wait(
      description: "pasteboard value",
      timeout: timeout,
      sample: { NSPasteboard.general.string(forType: .string) },
      matches: { $0 == expected },
      describe: { $0 ?? "nil" }
    )
  }

  func attachPanelScreenshot(named name: String, to activity: XCTActivity) {
    let attachment = XCTAttachment(screenshot: panel.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    activity.add(attachment)
  }

  /// A menu-bar app never runs in the foreground; the process just has to be
  /// running with its panel on screen.
  private func waitForRunning(timeout: TimeInterval) -> Bool {
    wait(
      description: "application running state",
      timeout: timeout,
      sample: { () -> XCUIApplication.State in self.app.state },
      matches: { (state: XCUIApplication.State) in
        state == .runningForeground || state == .runningBackground
      },
      describe: { (state: XCUIApplication.State) in String(describing: state) }
    )
  }

  private func wait<Value>(
    description: String,
    timeout: TimeInterval,
    sample: () -> Value,
    matches: (Value) -> Bool,
    describe: (Value) -> String
  ) -> Bool {
    let result = PollingWaiter().wait(
      timeout: timeout,
      sample: sample,
      matches: matches,
      describe: describe
    )
    guard !result.matched else { return true }

    XCTContext.runActivity(named: "Timed out waiting for \(description)") { activity in
      let attachment = XCTAttachment(
        string: "timeout=\(timeout)s elapsed=\(result.elapsed)s\n\(result.diagnosticDescription)"
      )
      attachment.name = "polling-timeline"
      attachment.lifetime = .keepAlways
      activity.add(attachment)
    }
    return false
  }
}

@MainActor
class CidaReleaseUITestCase: XCTestCase {
  private(set) var e2eEnvironment: E2EEnvironment!
  private(set) var scenarioServer: ScenarioServerClient!
  private(set) var driver: CidaAppDriver!

  override func setUp() async throws {
    try await super.setUp()
    continueAfterFailure = false
    e2eEnvironment = try E2EEnvironment()
    scenarioServer = ScenarioServerClient(baseURL: e2eEnvironment.controlBaseURL)
    try scenarioServer.reset()
    let settingsNamespace = e2eEnvironment.uniqueSettingsNamespace(for: name)
    e2eEnvironment.resetSettings(namespace: settingsNamespace)
    driver = CidaAppDriver(
      environment: e2eEnvironment,
      settingsNamespace: settingsNamespace
    )
  }

  override func tearDown() async throws {
    driver?.terminate()
    if let driver {
      e2eEnvironment?.resetSettings(namespace: driver.settingsNamespace)
    }
    try await super.tearDown()
  }
}
