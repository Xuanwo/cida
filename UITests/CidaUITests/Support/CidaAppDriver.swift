import AppKit
import Foundation
import XCTest

@MainActor
final class CidaAppDriver {
  let environment: E2EEnvironment
  let databasePath: String
  let settingsNamespace: String
  private(set) var app: XCUIApplication

  init(
    environment: E2EEnvironment,
    databasePath: String,
    settingsNamespace: String
  ) {
    self.environment = environment
    self.databasePath = databasePath
    self.settingsNamespace = settingsNamespace
    app = XCUIApplication(url: URL(fileURLWithPath: environment.appPath))
  }

  var window: XCUIElement { app.windows["辞达"] }
  var composer: XCUIElement { app.textViews["composer-input"] }
  var submitButton: XCUIElement { app.buttons["composer-submit-button"] }
  var history: XCUIElement { app.scrollViews["history-scroll-view"] }

  var currentHistoryEntry: XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
        "history-entry-",
        "当前历史记录"
      )
    ).firstMatch
  }

  func settingsProviderMenu(in settingsWindow: XCUIElement? = nil) -> XCUIElement {
    let root = settingsWindow ?? app.windows["设置"]
    return root.menuButtons.matching(
      NSPredicate(
        format: "identifier == %@ AND label IN %@",
        "settings-provider-menu",
        ["DeepSeek", "OpenAI"]
      )
    ).firstMatch
  }

  func launch(
    endpointOverride: Bool = true,
    additionalArguments: [String] = []
  ) {
    app = XCUIApplication(url: URL(fileURLWithPath: environment.appPath))
    app.launchEnvironment["CIDA_ISOLATED_AUTOMATION"] = "1"
    app.launchArguments = [
      "--e2e-testing",
      "--automation-history-database",
      databasePath,
      "--automation-settings-namespace",
      settingsNamespace,
    ]
    if endpointOverride {
      app.launchArguments += ["--automation-openai-endpoint", environment.endpoint]
    }
    app.launchArguments += additionalArguments
    app.launch()
    app.activate()

    XCTAssertTrue(waitForForeground(timeout: 10))
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
    XCTAssertTrue(history.waitForExistence(timeout: 5))
  }

  func terminate() {
    guard app.state != .notRunning else { return }
    app.terminate()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
  }

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

  @discardableResult
  func submit(_ text: String, expectsStreamingState: Bool = false) -> String {
    paste(text)
    XCTAssertEqual(textValue(in: composer), text)
    return submitCurrentComposer(expectsStreamingState: expectsStreamingState)
  }

  @discardableResult
  func submitCurrentComposer(expectsStreamingState: Bool = false) -> String {
    let previousCurrentEntry = currentHistoryEntry
    let previousCurrentIdentifier =
      previousCurrentEntry.exists
      ? previousCurrentEntry.identifier
      : nil
    XCTAssertTrue(submitButton.isEnabled)
    submitButton.click()
    XCTAssertTrue(
      waitForTextValue("", in: composer, timeout: 1),
      "An accepted submission must clear the composer immediately"
    )
    if expectsStreamingState {
      XCTAssertTrue(waitForLabel("停止生成", in: submitButton, timeout: 3))
    }
    let identifier = waitForNewCurrentHistoryEntry(
      excluding: previousCurrentIdentifier,
      timeout: 5
    )
    XCTAssertNotNil(identifier)
    guard let identifier else { return "" }

    XCTAssertTrue(
      waitForCurrentExpandedEntry(identifier, timeout: 2),
      "The submitted entry must become the expanded current record"
    )
    if let previousCurrentIdentifier, previousCurrentIdentifier != identifier {
      XCTAssertTrue(
        waitForFoldedEntry(previousCurrentIdentifier, timeout: 2),
        "The former automatic current record must fold when a new submission is accepted"
      )
    }

    return String(identifier.dropFirst("history-entry-".count))
  }

  func waitForCurrentExpandedEntry(
    _ identifier: String,
    timeout: TimeInterval
  ) -> Bool {
    let suffix = String(identifier.dropFirst("history-entry-".count))
    let entry = element(identifier: identifier)
    let source = element(identifier: "history-source-\(suffix)")
    let result = app.textViews["history-result-\(suffix.uppercased())"]
    let foldedCard = element(identifier: "history-expand-\(suffix)")
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if entry.exists,
        entry.label.hasPrefix("当前历史记录"),
        source.exists,
        result.exists,
        !foldedCard.exists
      {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return false
  }

  func waitForFoldedEntry(
    _ identifier: String,
    timeout: TimeInterval
  ) -> Bool {
    let suffix = String(identifier.dropFirst("history-entry-".count))
    let entry = element(identifier: identifier)
    let foldedCard = element(identifier: "history-expand-\(suffix)")
    let result = app.textViews["history-result-\(suffix.uppercased())"]
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if entry.exists,
        entry.value as? String == "collapsed",
        foldedCard.exists,
        !result.exists
      {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return false
  }

  func result(containing marker: String) -> XCUIElement {
    app.textViews.matching(
      NSPredicate(format: "value CONTAINS %@", marker)
    ).firstMatch
  }

  func historyEntryCount() -> Int {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "history-entry-")
    ).count
  }

  func waitForNewCurrentHistoryEntry(
    excluding previousIdentifier: String?,
    timeout: TimeInterval
  ) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let entry = currentHistoryEntry
      if entry.exists {
        let identifier = entry.identifier
        if identifier != previousIdentifier {
          return identifier
        }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return nil
  }

  func visibleHistoryEntryCount() -> Int {
    let entries = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "history-entry-")
    )
    return (0..<entries.count).reduce(into: 0) { count, index in
      let intersection = entries.element(boundBy: index).frame.intersection(history.frame)
      if intersection.height > 8, intersection.width > 100 {
        count += 1
      }
    }
  }

  func element(identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == %@", identifier)
    ).firstMatch
  }

  func configureOpenAI(
    endpoint: String,
    model: String = "cida-ui-mock-model",
    apiKey: String = "sk-isolated-ui-test"
  ) {
    let settingsButton = app.buttons["model-settings-button"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
    settingsButton.click()
    let settingsWindow = app.windows["设置"]
    XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))

    let providerMenu = settingsProviderMenu(in: settingsWindow)
    XCTAssertTrue(providerMenu.waitForExistence(timeout: 5))
    if providerMenu.label != "OpenAI" {
      providerMenu.click()
      let openAIItem = app.menuItems["OpenAI"]
      XCTAssertTrue(openAIItem.waitForExistence(timeout: 5))
      openAIItem.click()
    }

    replaceText(in: app.textFields["settings-openai-endpoint"], with: endpoint)
    replaceText(in: app.textFields["settings-model"], with: model)
    replaceText(in: app.secureTextFields["settings-api-key-editor"], with: apiKey)
    settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(settingsWindow.waitForNonExistence(timeout: 3))
  }

  func waitForValue(
    _ expectedValue: String,
    in element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if element.value as? String == expectedValue { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    } while Date() < deadline
    return false
  }

  func textValue(in element: XCUIElement) -> String {
    element.value as? String ?? ""
  }

  func waitForTextValue(
    _ expectedValue: String,
    in element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if textValue(in: element) == expectedValue { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return false
  }

  func waitForLabel(
    _ expectedLabel: String,
    in element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    let predicate = NSPredicate(format: "label == %@", expectedLabel)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  func waitForFrameHeight(
    atLeast minimumHeight: CGFloat? = nil,
    atMost maximumHeight: CGFloat? = nil,
    in element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let height = element.frame.height
      if minimumHeight.map({ height >= $0 }) ?? true,
        maximumHeight.map({ height <= $0 }) ?? true
      {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return false
  }

  func waitForPasteboard(_ expected: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if NSPasteboard.general.string(forType: .string) == expected { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return false
  }

  func attachWindowScreenshot(named name: String, to activity: XCTActivity) {
    let attachment = XCTAttachment(screenshot: window.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    activity.add(attachment)
  }

  private func waitForForeground(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if app.state == .runningForeground { return true }
      app.activate()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
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
      databasePath: e2eEnvironment.uniqueDatabasePath(for: name),
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
