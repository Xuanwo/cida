import Foundation

/// What this copy of Cida is: a release, versioned from its tag, or a development build
/// (`CIDA_VARIANT=dev scripts/build-app.sh`) that installs beside the release under its own
/// bundle identifier and never updates itself (`Design/spec/updates.md` §三).
struct CidaBuild: Equatable {
  let isDevelopment: Bool
  let version: String?
  let buildNumber: String?
  /// The commit a development build came from, with a trailing + when the checkout had changes.
  let revision: String?

  init(info: [String: Any]) {
    isDevelopment = info["CidaBuildVariant"] as? String == "dev"
    version = info["CFBundleShortVersionString"] as? String
    buildNumber = info["CFBundleVersion"] as? String
    revision = info["CidaSourceRevision"] as? String
  }

  static let current = CidaBuild(info: Bundle.main.infoDictionary ?? [:])

  /// Names a development build where Cida names itself (the menu, the Settings footer), so it
  /// is never mistaken for the release: 开发版 1.2.0 (170) · c243eb7.
  var developmentLabel: String? {
    guard isDevelopment else { return nil }
    var label = "开发版"
    if let version { label += " \(version)" }
    if let buildNumber { label += " (\(buildNumber))" }
    if let revision { label += " · \(revision)" }
    return label
  }
}
