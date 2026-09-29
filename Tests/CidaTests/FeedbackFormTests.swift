import Foundation
import XCTest

@testable import Cida

/// Settings' 反馈 opens the GitHub issue form with the environment prefilled and nothing else
/// (`Design/spec/settings.md` §六).
final class FeedbackFormTests: XCTestCase {
  private let macOS = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)

  func testAReleasePrefillsItsVersionTheSystemAndTheArchitectureOnly() throws {
    let build = CidaBuild(info: ["CFBundleShortVersionString": "1.2.1", "CFBundleVersion": "171"])
    let url = FeedbackForm.url(
      build: build, systemVersion: macOS, systemBuild: "25E246", architecture: "arm64")

    XCTAssertEqual(url.host(), "github.com")
    XCTAssertEqual(url.path(), "/Xuanwo/cida/issues/new")
    XCTAssertEqual(
      try queryItems(url),
      [
        "template": "feedback.yml", "version": "1.2.1 (171)", "macos": "26.4 (25E246)",
        "arch": "arm64",
      ])
  }

  func testADevelopmentBuildNamesItselfAndAnUnbundledRunHasNoVersion() throws {
    let development = CidaBuild(info: [
      "CidaBuildVariant": "dev", "CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "170",
      "CidaSourceRevision": "c243eb7+",
    ])
    let patched = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 1)
    let developmentItems = try queryItems(
      FeedbackForm.url(
        build: development, systemVersion: patched, systemBuild: nil, architecture: "arm64"))
    XCTAssertEqual(developmentItems["version"], "开发版 1.2.0 (170) · c243eb7+")
    XCTAssertEqual(developmentItems["macos"], "26.4.1")

    let unbundled = try queryItems(
      FeedbackForm.url(
        build: CidaBuild(info: [:]), systemVersion: macOS, systemBuild: nil, architecture: "arm64"))
    XCTAssertNil(unbundled["version"])
  }

  /// The query names are the form's field ids; a renamed field would silently stop prefilling.
  func testEveryPrefilledFieldExistsInTheIssueForm() throws {
    let form = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: ".github/ISSUE_TEMPLATE/feedback.yml")
    let text = try String(contentsOf: form, encoding: .utf8)
    let build = CidaBuild(info: ["CFBundleShortVersionString": "1.2.1"])
    let items = try queryItems(
      FeedbackForm.url(build: build, systemVersion: macOS, systemBuild: nil, architecture: "arm64"))
    for field in items.keys where field != "template" {
      XCTAssertTrue(text.contains("id: \(field)\n"), "feedback.yml has no field \(field)")
    }
  }

  private func queryItems(_ url: URL) throws -> [String: String] {
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    var items: [String: String] = [:]
    for item in components.queryItems ?? [] { items[item.name] = item.value }
    return items
  }
}
