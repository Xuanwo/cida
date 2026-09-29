import Foundation

/// The feedback issue form on GitHub (`.github/ISSUE_TEMPLATE/feedback.yml`) that Settings'
/// 反馈 row opens (`Design/spec/settings.md` §六). Cida sends nothing itself: the link only
/// prefills the form's environment fields, which the user sees and can edit before submitting.
/// The query names are the form's field ids.
enum FeedbackForm {
  static let newIssueURL = URL(string: "https://github.com/Xuanwo/cida/issues/new")!

  static func url(
    build: CidaBuild = .current,
    systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
    systemBuild: String? = currentSystemBuild(),
    architecture: String = currentArchitecture
  ) -> URL {
    var items = [URLQueryItem(name: "template", value: "feedback.yml")]
    if let version = versionText(build) {
      items.append(URLQueryItem(name: "version", value: version))
    }
    var macOS = "\(systemVersion.majorVersion).\(systemVersion.minorVersion)"
    if systemVersion.patchVersion > 0 { macOS += ".\(systemVersion.patchVersion)" }
    if let systemBuild { macOS += " (\(systemBuild))" }
    items.append(URLQueryItem(name: "macos", value: macOS))
    items.append(URLQueryItem(name: "arch", value: architecture))
    var components = URLComponents(url: newIssueURL, resolvingAgainstBaseURL: false)!
    components.queryItems = items
    return components.url!
  }

  /// 1.2.1 (171) for a release, the development label for a development build, nothing for an
  /// unbundled run.
  private static func versionText(_ build: CidaBuild) -> String? {
    if let label = build.developmentLabel { return label }
    guard let version = build.version else { return nil }
    return build.buildNumber.map { "\(version) (\($0))" } ?? version
  }

  static let currentArchitecture: String = {
    #if arch(arm64)
      "arm64"
    #else
      "x86_64"
    #endif
  }()

  /// The system build, 25E246, from `kern.osversion`.
  static func currentSystemBuild() -> String? {
    var size = 0
    guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
  }
}
