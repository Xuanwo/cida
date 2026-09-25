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
