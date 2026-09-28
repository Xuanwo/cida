import Foundation
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
