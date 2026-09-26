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
  /// The menu bar mark; XCUI may report it as a status item or as its button.
  var statusItem: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "cida-status-item").firstMatch
  }
  var resultText: XCUIElement { app.textViews["result-text"] }
  /// Settings is titled after its tab, so it is found by its identifier.
  var settingsWindow: XCUIElement { app.windows["settings-window"] }
  /// The capture shortcut's full-screen layer, a borderless panel like the
  /// main one.
  var captureOverlay: XCUIElement { app.dialogs["capture-overlay"] }
  var captureCanvas: XCUIElement { element(identifier: "capture-overlay-canvas") }

  /// Drags a frame on the capture overlay around `rect`, given in screen
  /// coordinates as XCUI reports element frames.
  func frameCapture(around rect: CGRect) {
    let canvas = captureCanvas.frame
    func offset(_ x: CGFloat, _ y: CGFloat) -> CGVector {
      CGVector(dx: (x - canvas.minX) / canvas.width, dy: (y - canvas.minY) / canvas.height)
    }
    let origin = captureCanvas.coordinate(withNormalizedOffset: offset(rect.minX, rect.minY))
    origin.press(
      forDuration: 0.1,
      thenDragTo: captureCanvas.coordinate(withNormalizedOffset: offset(rect.maxX, rect.maxY)))
  }

  func resultNote(_ kind: String) -> XCUIElement {
    element(identifier: "result-note-\(kind)")
  }

  // Settings' 模型 group (`Design/spec/configuration.md` §四).
  var modelOnboarding: XCUIElement { element(identifier: "settings-model-onboarding") }
  var modelOnboardingCaption: XCUIElement {
    element(identifier: "settings-model-onboarding-caption")
  }
  /// A combined row: its text is the element's value.
  var modelStatus: XCUIElement { element(identifier: "settings-model-status") }
  var modelSummary: XCUIElement { element(identifier: "settings-model-summary") }
  var modelFailure: XCUIElement { element(identifier: "settings-model-failure") }
  var modelCheckButton: XCUIElement { app.buttons["settings-model-check"] }
  var copyConfigurationPromptButton: XCUIElement {
    app.buttons["settings-copy-configuration-prompt"]
  }

  /// The executable inside the artifact, which is also its command line.
  var executablePath: String { "\(environment.appPath)/Contents/MacOS/Cida" }

  /// Runs the artifact's command line against this instance's settings, the way an AI
  /// assistant configures Cida; a running instance hears the change. The scenario server runs
  /// it, because a process this sandboxed runner started would keep its settings in the
  /// runner's container.
  @discardableResult
  func runCommandLine(_ arguments: [String], standardInput: String? = nil) throws
    -> ScenarioServerClient.CommandLineResult
  {
    let result = try ScenarioServerClient(baseURL: environment.controlBaseURL).runCommandLine(
      executable: executablePath, namespace: settingsNamespace, arguments: arguments,
      standardInput: standardInput)
    XCTContext.runActivity(named: "Cida \(arguments.joined(separator: " "))") { activity in
      let attachment = XCTAttachment(
        string: "exit \(result.status)\n\(result.output)\(result.errorOutput)")
      attachment.name = "command-line"
      attachment.lifetime = .keepAlways
      activity.add(attachment)
    }
    return result
  }

  /// Points this instance at the loopback scenario server through the command line.
  func configureModelService(model: String = "cida-ui-mock-model") throws {
    let result = try runCommandLine([
      "config", "set", "endpoint=\(environment.endpoint)", "format=chat-completions",
      "model=\(model)",
    ])
    XCTAssertEqual(result.status, 0, result.errorOutput)
  }

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

  /// Shows one of Settings' tabs: `model`, `translation`, `shortcuts` or `general`.
  func showSettingsTab(_ tab: String, title: String) {
    let button = settingsWindow.buttons["settings-tab-\(tab)"]
    XCTAssertTrue(button.waitForExistence(timeout: 3))
    button.click()
    XCTAssertTrue(waitForTitle(title, of: settingsWindow, timeout: 3), "The title names the tab")
  }

  func waitForTitle(_ title: String, of window: XCUIElement, timeout: TimeInterval) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "title == %@", title), object: window)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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

  /// Whether the menu bar caret breathes: its accessibility value says 正在生成.
  func waitForStatusItem(breathing: Bool, timeout: TimeInterval = 3) -> Bool {
    wait(
      description: "status item \(breathing ? "breathing" : "resting")",
      timeout: timeout,
      sample: { self.statusItem.value as? String },
      matches: { ($0 == "正在生成") == breathing },
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

  /// A static text's string, which XCUI reports as its value or, failing that, its label.
  func waitForText(
    containing fragment: String,
    in element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    wait(
      description: "text containing '\(fragment)' for \(element.identifier)",
      timeout: timeout,
      sample: { (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label },
      matches: { $0.contains(fragment) },
      describe: { $0 }
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

/// The UI test host standing in for the application the user works in: its
/// editor holds the selection the global shortcut reads, and its window is
/// what the capture shortcut freezes.
@MainActor
final class SourceApplication {
  let app = XCUIApplication()

  var editor: XCUIElement { app.textViews.firstMatch }
  var captureText: XCUIElement { app.staticTexts["source-capture-text"] }
  var blankArea: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "source-blank").firstMatch
  }

  /// Launches with a window: an earlier journey's termination can leave saved
  /// state that reopens the app without one.
  func launch() {
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    if !editor.waitForExistence(timeout: 5) {
      app.typeKey("n", modifierFlags: .command)
    }
    XCTAssertTrue(editor.waitForExistence(timeout: 10), "The source application shows its editor")
  }

  /// Replaces the editor's text with `text` and selects all of it.
  func select(_ text: String) {
    editor.click()
    editor.typeKey("a", modifierFlags: .command)
    editor.typeText(text)
    editor.typeKey("a", modifierFlags: .command)
  }

  /// Leaves the caret in the editor with nothing selected.
  func clearSelection() {
    editor.click()
    editor.typeKey(.rightArrow, modifierFlags: [])
  }

  /// A global shortcut pressed while this application is in front.
  func press(_ key: XCUIKeyboardKey, modifierFlags: XCUIElement.KeyModifierFlags) {
    app.typeKey(key, modifierFlags: modifierFlags)
  }

  func press(_ key: String, modifierFlags: XCUIElement.KeyModifierFlags) {
    app.typeKey(key, modifierFlags: modifierFlags)
  }
}

