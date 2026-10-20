import XCTest

/// Exercises the production Sparkle driver against a signed loopback feed and archive. The
/// fixture is a separate identity copied from the exact Release artifact inside the Tart guest.
@MainActor
final class UpdateJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private var environment: E2EEnvironment!
  private var originalPIDs: [Int] = []

  override func tearDown() {
    app?.terminate()
    super.tearDown()
  }

  func testUpdateInstallsAndRelaunchesAfterOneConfirmation() throws {
    try launchUpdateFixture()
    showUpdate()
    capture("update-found-commands")
    // Return keeps its default even after Tab changes native button focus.
    app.typeKey(.tab, modifierFlags: [])
    app.typeKey(.tab, modifierFlags: [])
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(app.buttons["bar-action-stop"].waitForExistence(timeout: 10))
    capture("update-downloading-stop")
    _ = try control("release")
    try waitForInstalledVersion()
    XCTAssertFalse(app.dialogs["cida-panel"].exists, "An update relaunch stays in the menu bar")
  }

  func testLeavingDownloadRequiresAnotherInstallCommand() throws {
    try launchUpdateFixture()
    showUpdate()
    app.buttons["message-choice-0"].click()
    XCTAssertTrue(app.buttons["bar-action-stop"].waitForExistence(timeout: 10))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(app.dialogs["cida-panel"].waitForNonExistence(timeout: 5))
    _ = try control("release")
    XCTAssertTrue(waitUntil(timeout: 30) {
      ((try? self.control("state", get: true)["completedDownloads"] as? Int) ?? 0) > 0
    })
    // Refocusing a pending download must not restore consent to restart.
    openGeneralSettings()
    app.buttons["settings-check-for-updates"].click()
    let downloaded = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND value CONTAINS %@", "message-statement", "已下载")).firstMatch
    XCTAssertTrue(downloaded.waitForExistence(timeout: 30))
    XCTAssertEqual(try control("state", get: true)["version"] as? String, "1")
    capture("update-downloaded-deferred")
    // The first native button is 稍后. Space activates focus; Return still means install.
    app.typeKey(" ", modifierFlags: [])
    XCTAssertTrue(app.dialogs["cida-panel"].waitForNonExistence(timeout: 5))
    openGeneralSettings()
    app.buttons["settings-check-for-updates"].click()
    XCTAssertTrue(downloaded.waitForExistence(timeout: 5))
    app.typeKey(.return, modifierFlags: [])
    try waitForInstalledVersion()
  }

  private func launchUpdateFixture() throws {
    continueAfterFailure = false
    environment = try E2EEnvironment()
    let fixture = try control("setup")
    let path = try XCTUnwrap(fixture["appPath"] as? String)
    app = XCUIApplication(url: URL(fileURLWithPath: path))
    // No E2E arguments: Sparkle and launch policy follow their normal production path.
    app.launchArguments = ["-AppleKeyboardUIMode", "3"]
    app.launch()
    XCTAssertTrue(app.dialogs["cida-panel"].waitForExistence(timeout: 10))
    originalPIDs = try XCTUnwrap(control("state", get: true)["pids"] as? [Int])
    XCTAssertFalse(originalPIDs.isEmpty)
  }

  private func openGeneralSettings() {
    app.activate()
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(app.windows["settings-window"].waitForExistence(timeout: 5))
    app.buttons["settings-tab-general"].click()
  }

  private func showUpdate() {
    if app.buttons["message-choice-0"].exists { return }
    openGeneralSettings()
    app.buttons["settings-check-for-updates"].click()
    XCTAssertTrue(app.buttons["message-choice-0"].waitForExistence(timeout: 15))
  }

  private func control(_ action: String, get: Bool = false) throws -> [String: Any] {
    var arguments = ["--fail", "--silent", "--show-error", "--max-time", "120"]
    if !get { arguments += ["-X", "POST", "-H", "Content-Type: application/json", "-d", "{}"] }
    arguments.append("\(environment.controlBaseURL)/control/update/\(action)")
    let data = try ProcessRunner.run("/usr/bin/curl", arguments: arguments)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func waitForInstalledVersion() throws {
    XCTAssertTrue(waitUntil(timeout: 60) {
      guard let status = try? self.control("state", get: true),
        let pids = status["pids"] as? [Int] else { return false }
      return status["version"] as? String == "2" && !pids.isEmpty
        && Set(pids).isDisjoint(with: self.originalPIDs)
    }, "Sparkle must replace the bundle and relaunch a new process")
  }

  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return condition()
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.dialogs["cida-panel"].screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
