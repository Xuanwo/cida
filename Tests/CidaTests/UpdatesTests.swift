import Foundation
import Sparkle
import XCTest

@testable import Cida

/// Cida's own update contracts (`Design/spec/updates.md`); Sparkle's checking and installing
/// are Sparkle's to test. Only release candidates look for candidates, and builds without a feed
/// and a public key (`swift run`, tests, automation) never contact the feed.
@MainActor
final class UpdatesTests: XCTestCase {
  func testOnlyReleaseCandidatesReceiveTheBetaChannel() throws {
    let candidate = CidaUpdater(bundle: try makeApp(info: ["CidaUpdateChannel": "beta"]))
    let release = CidaUpdater(bundle: try makeApp(info: [:]))

    XCTAssertEqual(candidate.allowedChannels, ["beta"])
    XCTAssertEqual(release.allowedChannels, [])
  }

  func testOnlyAnAppWithAFeedAndAPublicKeyTalksToTheFeed() throws {
    let feed = ["SUFeedURL": "https://cida-releases.xuanwo.io/appcast.xml"]
    XCTAssertTrue(
      CidaUpdater.isConfigured(in: try makeApp(info: feed.merging(["SUPublicEDKey": "key"]) { $1 })))
    XCTAssertFalse(CidaUpdater.isConfigured(in: try makeApp(info: feed)), "No public key")
    XCTAssertFalse(
      CidaUpdater.isConfigured(in: try makeApp(info: feed.merging(["SUPublicEDKey": ""]) { $1 })))
    XCTAssertFalse(CidaUpdater.isConfigured(in: .main), "The test runner is not Cida.app")
  }

  /// A development build (`CIDA_VARIANT=dev`) has no feed, so it offers no update controls, and
  /// it names itself with its version, build and commit wherever Cida names itself.
  func testADevelopmentBuildNamesItselfAndDoesNotUpdate() throws {
    let info: [String: Any] = [
      "CidaBuildVariant": "dev", "CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "170",
      "CidaSourceRevision": "c243eb7+", "SUPublicEDKey": "key",
    ]
    XCTAssertFalse(CidaUpdater(bundle: try makeApp(info: info)).state.isAvailable)
    XCTAssertEqual(CidaBuild(info: info).developmentLabel, "开发版 1.2.0 (170) · c243eb7+")

    let release: [String: Any] = [
      "CFBundleShortVersionString": "1.2.0", "SUFeedURL": "https://cida-releases.xuanwo.io/appcast.xml",
      "SUPublicEDKey": "key",
    ]
    XCTAssertTrue(CidaUpdater(bundle: try makeApp(info: release)).state.isAvailable)
    XCTAssertNil(CidaBuild(info: release).developmentLabel)
  }

  func testAcceptedUpdateInstallsWithoutASecondQuestion() throws {
    let presenter = RecordingUpdatePresenter()
    let state = UpdateState()
    let driver = CidaUpdateDriver(state: state, presenter: presenter, bundle: try makeApp(info: [:]))
    var answers: [SPUUserUpdateChoice] = []
    driver.showUpdateFound(version: "2.0", currentVersion: "1.0", notes: ["Change"], bringsUp: true) {
      answers.append($0)
    }
    presenter.handler?.choose(0)
    XCTAssertEqual(answers, [.install])
    XCTAssertTrue(presenter.message?.isWorking == true, "Ignore a repeated click while Sparkle responds")
    driver.showDownloadInitiated(cancellation: {})
    driver.showDownloadDidStartExtractingUpdate()
    driver.showReady { answers.append($0) }
    XCTAssertEqual(answers, [.install, .install])
    XCTAssertEqual(presenter.message?.kind, "update-installing")
    XCTAssertFalse(presenter.message?.hasBar ?? true)
    XCTAssertNil(state.availableVersion)
  }

  func testLeavingDownloadRevokesRestartEvenAfterRefocusing() throws {
    let presenter = RecordingUpdatePresenter()
    let state = UpdateState()
    let driver = CidaUpdateDriver(state: state, presenter: presenter, bundle: try makeApp(info: [:]))
    var answers: [SPUUserUpdateChoice] = []
    driver.showUpdateFound(version: "2.0", currentVersion: "1.0", notes: ["Change"], bringsUp: true) {
      answers.append($0)
    }
    presenter.handler?.choose(0)
    driver.showDownloadInitiated(cancellation: {})
    presenter.handler?.dismiss()
    XCTAssertEqual(state.availableVersion, "2.0")
    driver.showUpdateInFocus()
    driver.showReady { answers.append($0) }
    XCTAssertEqual(answers, [.install], "Returning to progress is not permission to restart")
    XCTAssertEqual(presenter.message?.statement, "辞达 2.0 已下载")
    XCTAssertEqual(presenter.message?.body, .lines(["Change"]))
    presenter.handler?.choose(1)
    XCTAssertEqual(state.availableVersion, "2.0", "Later stays reachable in Settings")
    XCTAssertNil(presenter.message)
    driver.showUpdateInFocus()
    presenter.handler?.choose(0)
    XCTAssertEqual(answers, [.install, .install])
    XCTAssertNil(state.availableVersion)
  }

  func testHiddenDownloadStaysQuietAndFoundLaterIsNotSkip() throws {
    let presenter = RecordingUpdatePresenter()
    let state = UpdateState()
    let driver = CidaUpdateDriver(state: state, presenter: presenter, bundle: try makeApp(info: [:]))
    var answers: [SPUUserUpdateChoice] = []
    driver.showUpdateFound(version: "2.0", currentVersion: "1.0", notes: [], bringsUp: true) {
      answers.append($0)
    }
    presenter.handler?.choose(1)
    XCTAssertTrue(answers.isEmpty)
    XCTAssertEqual(state.availableVersion, "2.0")
    driver.showUpdateInFocus()
    presenter.handler?.choose(0)
    driver.showDownloadInitiated(cancellation: {})
    presenter.handler?.dismiss()
    let presentations = presenter.presentations
    driver.showReady { answers.append($0) }
    XCTAssertEqual(presenter.presentations, presentations, "No background presentation")
    XCTAssertEqual(answers, [.install])
    driver.showUpdateInFocus()
    XCTAssertEqual(presenter.message?.kind, "update-ready")
    presenter.handler?.dismiss()
    driver.showUpdateInFocus()
    presenter.handler?.choose(0)
    XCTAssertEqual(answers, [.install, .install])
  }

  func testUpdateFailureRetriesCheckingAndStopCancelsWork() throws {
    let presenter = RecordingUpdatePresenter()
    let driver = CidaUpdateDriver(state: UpdateState(), presenter: presenter, bundle: try makeApp(info: [:]))
    var cancelled = 0
    var acknowledged = 0
    var checks = 0
    driver.checkForUpdates = { checks += 1 }
    driver.showUpdateFound(version: "2.0", currentVersion: "1.0", notes: [], bringsUp: true) { _ in }
    presenter.handler?.choose(0)
    driver.showDownloadInitiated { cancelled += 1 }
    driver.showUpdaterError(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)) {
      acknowledged += 1
    }
    XCTAssertEqual(presenter.message?.statement, "辞达 2.0 可以安装")
    presenter.handler?.choose(0)
    XCTAssertEqual(acknowledged, 1)
    XCTAssertEqual(checks, 1)
    driver.showUserInitiatedUpdateCheck { cancelled += 1 }
    driver.showUpdaterError(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)) {}
    XCTAssertEqual(presenter.message?.statement, "检查更新失败")
    XCTAssertNil(presenter.message?.statementDetail, "A failed check must not offer the previous version")
    driver.showUserInitiatedUpdateCheck { cancelled += 1 }
    presenter.handler?.stop()
    XCTAssertEqual(cancelled, 1)
    XCTAssertNil(presenter.message)
  }

  /// An empty `.app` bundle whose Info.plist holds `info`, removed after the test.
  private func makeApp(info: [String: Any]) throws -> Bundle {
    let app = FileManager.default.temporaryDirectory
      .appendingPathComponent("cida-updates-\(UUID().uuidString).app")
    addTeardownBlock { try? FileManager.default.removeItem(at: app) }
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var plist = info
    plist["CFBundleIdentifier"] = "com.xuanwo.Cida.Automation.Updates"
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return try XCTUnwrap(Bundle(url: app))
  }
}

@MainActor
private final class RecordingUpdatePresenter: UpdatePresenter {
  var message: PanelMessage?
  var handler: PanelMessageHandler?
  var presentations = 0
  var mayPresentScheduledUpdate = false

  func presentUpdate(_ message: PanelMessage, handler: PanelMessageHandler) {
    self.message = message
    self.handler = handler
    presentations += 1
  }

  func updateUpdateMessage(kind: String, _ change: (inout PanelMessage) -> Void) {
    guard var message, message.kind == kind else { return }
    change(&message)
    self.message = message
  }

  func finishUpdateMessage() { message = nil; handler = nil }
}
