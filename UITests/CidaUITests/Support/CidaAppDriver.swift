import AppKit
import Foundation
import XCTest

@MainActor
final class CidaAppDriver {
  let environment: E2EEnvironment
  let databasePath: String
  private(set) var app: XCUIApplication

  init(environment: E2EEnvironment, databasePath: String) {
    self.environment = environment
    self.databasePath = databasePath
    app = XCUIApplication(url: URL(fileURLWithPath: environment.appPath))
  }

  var window: XCUIElement { app.windows["辞达"] }
  var composer: XCUIElement { app.textViews["composer-input"] }
  var submitButton: XCUIElement { app.buttons["composer-submit-button"] }
  var history: XCUIElement { app.scrollViews["history-scroll-view"] }

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
    let existing = historyEntryIdentifiers()
    paste(text)
    XCTAssertEqual(composer.value as? String, text)
    XCTAssertTrue(submitButton.isEnabled)
    submitButton.click()
    if expectsStreamingState {
      XCTAssertTrue(waitForLabel("停止生成", in: submitButton, timeout: 3))
    }
    let identifier = waitForNewHistoryEntry(excluding: existing, timeout: 5)
    XCTAssertNotNil(identifier)
    return identifier.map { String($0.dropFirst("history-entry-".count)) } ?? ""
  }

  func result(containing marker: String) -> XCUIElement {
    app.textViews.matching(
      NSPredicate(format: "value CONTAINS %@", marker)
    ).firstMatch
  }

  func historyEntryIdentifiers() -> Set<String> {
    let entries = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "history-entry-")
    )
    return Set(entries.allElementsBoundByIndex.map(\.identifier))
  }

  func waitForNewHistoryEntry(
    excluding existingIdentifiers: Set<String>,
    timeout: TimeInterval
  ) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let identifier = historyEntryIdentifiers().first(where: {
        !existingIdentifiers.contains($0)
      }) {
        return identifier
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
    let predicate = NSPredicate(format: "value == %@", expectedValue)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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
    e2eEnvironment.resetProductionSettings()
    scenarioServer = ScenarioServerClient(baseURL: e2eEnvironment.controlBaseURL)
    try scenarioServer.reset()
    driver = CidaAppDriver(
      environment: e2eEnvironment,
      databasePath: e2eEnvironment.uniqueDatabasePath(for: name)
    )
  }

  override func tearDown() async throws {
    driver?.terminate()
    e2eEnvironment?.resetProductionSettings()
    try await super.tearDown()
  }
}
