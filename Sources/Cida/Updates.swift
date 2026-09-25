import AppKit
import Sparkle

/// What Settings and the menu bar show about updates (`Design/spec/updates.md`).
@MainActor
@Observable
final class UpdateState {
  /// Whether Cida checks the feed once a day on its own.
  private(set) var automaticallyChecks: Bool
  /// A newer version a scheduled check found while the user was elsewhere; the menu bar item and
  /// Settings offer to install it instead of interrupting with the panel.
  var availableVersion: String?

  @ObservationIgnored var performCheck: @MainActor () -> Void = {}
  @ObservationIgnored var applyAutomaticChecks: @MainActor (Bool) -> Void = { _ in }

  init(automaticallyChecks: Bool = true, availableVersion: String? = nil) {
    self.automaticallyChecks = automaticallyChecks
    self.availableVersion = availableVersion
  }

  /// Checks now, or shows the update a scheduled check found, in the panel.
  func checkForUpdates() {
    performCheck()
  }

  func setAutomaticallyChecks(_ enabled: Bool) {
    automaticallyChecks = enabled
    applyAutomaticChecks(enabled)
  }

  /// A scheduled check found `version` while the user was elsewhere.
  func remindLater(of version: String) {
    availableVersion = version
  }

  /// The update session ended: installed, skipped, or dismissed.
  func clearReminder() {
    availableVersion = nil
  }
}

/// Where the update driver speaks: the panel, through the app delegate.
@MainActor
protocol UpdatePresenter: AnyObject {
  /// Shows `message` in the panel, bringing the panel up.
  func presentUpdate(_ message: PanelMessage, handler: PanelMessageHandler)
  /// Changes the update message on screen, if it is still the one of `kind`.
  func updateUpdateMessage(kind: String, _ change: (inout PanelMessage) -> Void)
  /// Takes an update message off the panel and hides the panel it brought up.
  func finishUpdateMessage()
  /// Whether a scheduled check may bring the panel up: only right after the user opened Cida
  /// (`Design/spec/lifecycle.md` §四).
  var mayPresentScheduledUpdate: Bool { get }
}

/// Runs Sparkle against the feed and public key in Info.plist. A release candidate
/// (`CidaUpdateChannel` = beta) also receives later candidates; any other build receives only
/// releases. Every step of an update is shown in the panel (`CidaUpdateDriver`), never in
/// Sparkle's own windows.
@MainActor
final class CidaUpdater: NSObject, SPUUpdaterDelegate {
  /// Set right before Sparkle relaunches Cida after installing; the next launch reads and clears
  /// it and stays in the menu bar (`Design/spec/lifecycle.md` §四).
  static let relaunchedAfterUpdateKey = "CidaRelaunchedAfterUpdate"

  let state: UpdateState
  private let channel: String?
  private var updater: SPUUpdater?
  private var driver: CidaUpdateDriver?

  init(bundle: Bundle = .main) {
    channel = bundle.object(forInfoDictionaryKey: "CidaUpdateChannel") as? String
    state = UpdateState()
    super.init()
  }

  /// Whether this build can update itself: an app bundle with a feed and a public key. `swift
  /// run` and automation builds without them never talk to the feed.
  static func isConfigured(in bundle: Bundle = .main) -> Bool {
    bundle.bundleURL.pathExtension == "app"
      && bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil
      && !((bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? "").isEmpty
  }

  /// Starts Sparkle; `state` then follows the preference Sparkle keeps.
  func start(presenter: UpdatePresenter) {
    let driver = CidaUpdateDriver(state: state, presenter: presenter)
    let updater = SPUUpdater(
      hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    driver.checkForUpdates = { [weak updater] in updater?.checkForUpdates() }
    self.driver = driver
    self.updater = updater
    do {
      try updater.start()
    } catch {
      NSLog("Cida could not start updates: %@", error.localizedDescription)
      return
    }
    state.setAutomaticallyChecks(updater.automaticallyChecksForUpdates)
    state.performCheck = { [weak updater] in updater?.checkForUpdates() }
    state.applyAutomaticChecks = { [weak updater] enabled in
      updater?.automaticallyChecksForUpdates = enabled
    }
  }

  /// Sparkle channels beyond the default one that this build accepts.
  var allowedChannels: Set<String> {
    channel == "beta" ? ["beta"] : []
  }

  // MARK: SPUUpdaterDelegate

  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    allowedChannels
  }

  func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
    UserDefaults.standard.set(true, forKey: Self.relaunchedAfterUpdateKey)
  }
}

/// Sparkle's user driver, drawn as panel messages (`Design/spec/lifecycle.md` §五). The session
/// the user is watching follows every step in the panel; hiding the panel answers 稍后 and the
/// session carries on quietly, reachable again from the menu bar item.
@MainActor
final class CidaUpdateDriver: NSObject, SPUUserDriver {
  private enum Phase {
    case checking, found, downloading, extracting, ready, installing
  }

  private let state: UpdateState
  private weak var presenter: UpdatePresenter?
  private let currentVersion: String
  private let currentBuild: String
  private let isRunningFromReadOnlyLocation: Bool
  /// Starts a user-initiated check; set once the updater exists.
  var checkForUpdates: @MainActor () -> Void = {}

  private var phase = Phase.checking
  /// The new version as the statements name it.
  private var version = ""
  /// This copy's version as the statements name it next to `version`.
  private var currentLabel = ""
  private var notes: [String] = []
  private var expectedLength: UInt64 = 0
  private var receivedLength: UInt64 = 0
  /// The panel is showing this session; later steps replace the message on screen.
  private var isWatched = false
  /// The latest step, shown again when the user asks for the update from the menu bar.
  private var latest: (message: PanelMessage, handler: PanelMessageHandler)?
  private var cancelWork: (() -> Void)?

  init(
    state: UpdateState,
    presenter: UpdatePresenter,
    bundle: Bundle = .main
  ) {
    self.state = state
    self.presenter = presenter
    currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    currentBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    isRunningFromReadOnlyLocation = Self.isReadOnlyLocation(bundle.bundleURL)
    super.init()
  }

  // MARK: Messages

  static let installChoices = ["安装并重启", "稍后", "跳过这个版本"]
  static let readyChoices = ["立即重启", "退出时安装"]

  static func foundMessage(version: String, currentVersion: String, notes: [String]) -> PanelMessage {
    PanelMessage(
      kind: "update-found",
      statement: "辞达 \(version) 可以安装",
      statementDetail: currentVersion.isEmpty ? nil : " · 当前 \(currentVersion)",
      choices: installChoices,
      body: notes.isEmpty ? .none : .lines(notes),
      bodyCaption: notes.isEmpty ? nil : notesCaption
    )
  }

  static let notesCaption = "更新内容"

  /// The version the statements name: the build joins it while both versions read the same
  /// (between release candidates), so 1.1.0 (146) never reads as 1.1.0 over 1.1.0.
  static func versionLabels(
    new: String, newBuild: String, current: String, currentBuild: String
  ) -> (new: String, current: String) {
    guard new == current, !newBuild.isEmpty, !currentBuild.isEmpty else { return (new, current) }
    return ("\(new)（\(newBuild)）", "\(current)（\(currentBuild)）")
  }

  static func checkingMessage() -> PanelMessage {
    PanelMessage(
      kind: "update-checking", statement: "正在检查更新…", choices: installChoices,
      isWorking: true, slot: .stop)
  }

  static func downloadingMessage(version: String, percent: Int?, notes: [String]) -> PanelMessage {
    PanelMessage(
      kind: "update-downloading",
      statement: percent.map { "正在下载辞达 \(version) · \($0)%" } ?? "正在校验…",
      choices: installChoices,
      body: notes.isEmpty ? .none : .lines(notes),
      bodyCaption: notes.isEmpty ? nil : notesCaption,
      isWorking: true,
      slot: .stop
    )
  }

  static func readyMessage(version: String) -> PanelMessage {
    PanelMessage(
      kind: "update-ready",
      statement: "辞达 \(version) 已准备好",
      choices: readyChoices,
      body: .text("重启只需几秒，正在进行的翻译会停止。选「退出时安装」，下次退出辞达时换成新版本。")
    )
  }

  /// The step that failed, with 重试 / 稍后 and the reason under its paper.
  static func failedMessage(from message: PanelMessage, note: String) -> PanelMessage {
    var failed = message
    failed.kind = "update-failed"
    failed.choices = ["重试", "稍后"]
    failed.selectedChoice = 0
    failed.isWorking = false
    failed.slot = .none
    failed.note = note
    return failed
  }

  static func currentMessage(version: String) -> PanelMessage {
    PanelMessage(kind: "update-current", statement: "辞达 \(version) 已是最新版本", choices: ["好"])
  }

  static func readOnlyMessage(version: String, currentVersion: String, notes: [String]) -> PanelMessage {
    var message = foundMessage(version: version, currentVersion: currentVersion, notes: notes)
    message.kind = "update-read-only"
    message.choices = ["稍后"]
    message.note = "辞达正从磁盘映像运行，没法更新。把它拖进「应用程序」后再打开"
    return message
  }

  // MARK: Showing

  /// Records `message` as the session's latest step and shows it when the user is watching, or
  /// when `bringsUp` (the user asked, or Cida was just opened).
  private func show(
    _ message: PanelMessage,
    bringsUp: Bool = false,
    handler: PanelMessageHandler
  ) {
    latest = (message, handler)
    guard isWatched || bringsUp, let presenter else { return }
    isWatched = true
    presenter.presentUpdate(message, handler: handler)
  }

  /// A step without an answer to wait for (progress): changes the message on screen in place.
  private func progress(_ message: PanelMessage) {
    guard let latest else { return }
    let handler = latest.handler
    if isWatched, let presenter, latest.message.kind == message.kind {
      self.latest = (message, handler)
      presenter.updateUpdateMessage(kind: message.kind) { $0 = message }
    } else {
      show(message, handler: handler)
    }
  }

  /// The user answered: the panel goes back to what it was.
  private func finish() {
    isWatched = false
    latest = nil
    presenter?.finishUpdateMessage()
  }

  /// Hiding the panel mid-session keeps the session; the menu bar item brings it back.
  private func stopWatching() {
    isWatched = false
    if !version.isEmpty, phase == .found || phase == .ready {
      state.remindLater(of: version)
    }
  }

  // MARK: SPUUserDriver

  func show(
    _ request: SPUUpdatePermissionRequest,
    reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    // Info.plist turns automatic checks on without asking (`Design/spec/updates.md` §一).
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    phase = .checking
    cancelWork = cancellation
    show(
      Self.checkingMessage(),
      bringsUp: true,
      handler: PanelMessageHandler(
        choose: { _ in },
        stop: { [weak self] in
          self?.cancelWork?()
          self?.finish()
        },
        dismiss: { [weak self] in
          self?.cancelWork?()
          self?.isWatched = false
        }))
  }

  func showUpdateFound(
    with appcastItem: SUAppcastItem,
    state updateState: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    phase = .found
    (version, currentLabel) = Self.versionLabels(
      new: appcastItem.displayVersionString, newBuild: appcastItem.versionString,
      current: currentVersion, currentBuild: currentBuild)
    notes = ReleaseNotes.lines(from: appcastItem.itemDescription)
    let bringsUp = updateState.userInitiated || presenter?.mayPresentScheduledUpdate == true

    if isRunningFromReadOnlyLocation {
      show(
        Self.readOnlyMessage(version: version, currentVersion: currentLabel, notes: notes),
        bringsUp: bringsUp,
        handler: PanelMessageHandler(
          choose: { [weak self] _ in
            reply(.dismiss)
            self?.finish()
          },
          dismiss: { reply(.dismiss) }))
      if !bringsUp { state.remindLater(of: version) }
      return
    }

    show(
      Self.foundMessage(version: version, currentVersion: currentLabel, notes: notes),
      bringsUp: bringsUp,
      handler: PanelMessageHandler(
        choose: { [weak self] index in
          guard let self else { return }
          switch index {
          case 0:
            self.state.clearReminder()
            // Answer at once; Sparkle's first download step replaces this message.
            self.presenter?.updateUpdateMessage(kind: "update-found") { message in
              message.statement = "正在下载辞达 \(self.version) · 0%"
              message.statementDetail = nil
              message.isWorking = true
            }
            reply(.install)
          case 1:
            reply(.dismiss)
            self.finish()
          default:
            reply(.skip)
            self.finish()
          }
        },
        dismiss: { [weak self] in
          // 稍后: the session stays open so the menu bar can offer the update again.
          self?.stopWatching()
        }))
    if !bringsUp { state.remindLater(of: version) }
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

  func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    show(
      Self.currentMessage(version: currentVersion),
      bringsUp: true,
      handler: PanelMessageHandler(
        choose: { [weak self] _ in
          acknowledgement()
          self?.finish()
        },
        dismiss: { acknowledgement() }))
  }

  func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    let error = error as NSError
    if error.domain == SUSparkleErrorDomain,
      error.code == Int(SUError.runningFromDiskImageError.rawValue)
        || error.code == Int(SUError.runningTranslocated.rawValue)
    {
      show(
        Self.readOnlyMessage(version: version, currentVersion: currentLabel, notes: notes),
        handler: PanelMessageHandler(
          choose: { [weak self] _ in
            acknowledgement()
            self?.finish()
          },
          dismiss: { acknowledgement() }))
      return
    }

    let message = Self.failedMessage(
      from: latest?.message
        ?? Self.foundMessage(version: version, currentVersion: currentLabel, notes: notes),
      note: "\(failureTitle)：\(Self.reason(for: error)) · ⏎ 重试")
    show(
      message,
      handler: PanelMessageHandler(
        choose: { [weak self] index in
          acknowledgement()
          guard let self else { return }
          if index == 0 {
            // A new user-initiated session; its first step replaces this message.
            self.checkForUpdates()
          } else {
            self.finish()
          }
        },
        dismiss: { acknowledgement() }))
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    phase = .downloading
    expectedLength = 0
    receivedLength = 0
    cancelWork = cancellation
    show(
      Self.downloadingMessage(version: version, percent: 0, notes: notes),
      handler: PanelMessageHandler(
        choose: { _ in },
        stop: { [weak self] in
          self?.cancelWork?()
          self?.finish()
        },
        dismiss: { [weak self] in self?.isWatched = false }))
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    expectedLength = expectedContentLength
    receivedLength = 0
    progress(Self.downloadingMessage(version: version, percent: percent, notes: notes))
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    let before = percent
    receivedLength += length
    guard percent != before else { return }
    progress(Self.downloadingMessage(version: version, percent: percent, notes: notes))
  }

  func showDownloadDidStartExtractingUpdate() {
    phase = .extracting
    progress(Self.downloadingMessage(version: version, percent: nil, notes: notes))
  }

  func showExtractionReceivedProgress(_ progress: Double) {}

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    phase = .ready
    show(
      Self.readyMessage(version: version),
      handler: PanelMessageHandler(
        choose: { [weak self] index in
          guard let self else { return }
          if index == 0 {
            self.phase = .installing
            self.progress(
              PanelMessage(
                kind: "update-ready", statement: "正在安装…", choices: Self.readyChoices,
                isWorking: true))
            reply(.install)
          } else {
            // Sparkle installs it when Cida quits.
            reply(.dismiss)
            self.finish()
          }
        },
        dismiss: { [weak self] in
          reply(.dismiss)
          self?.isWatched = false
        }))
    if !isWatched { state.remindLater(of: version) }
  }

  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {
    phase = .installing
    progress(
      PanelMessage(
        kind: latest?.message.kind ?? "update-ready", statement: "正在安装…",
        choices: Self.readyChoices, isWorking: true))
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func showUpdateInFocus() {
    guard let latest, let presenter else { return }
    isWatched = true
    presenter.presentUpdate(latest.message, handler: latest.handler)
  }

  /// The session ended; a message still on screen goes with it.
  func dismissUpdateInstallation() {
    state.clearReminder()
    cancelWork = nil
    if isWatched {
      finish()
    } else {
      latest = nil
    }
  }

  // MARK: Helpers

  private var percent: Int {
    guard expectedLength > 0 else { return 0 }
    return Int(min(100, receivedLength * 100 / expectedLength))
  }

  private var failureTitle: String {
    switch phase {
    case .checking: "检查更新失败"
    case .found, .downloading, .extracting: "下载失败"
    case .ready, .installing: "安装失败"
    }
  }

  /// A short Chinese reason for the failure note; Sparkle's own description otherwise.
  static func reason(for error: NSError) -> String {
    if error.domain == NSURLErrorDomain { return "网络连接失败" }
    if error.domain == SUSparkleErrorDomain {
      switch error.code {
      case Int(SUError.signatureError.rawValue): return "安装包的签名不对"
      case Int(SUError.downloadError.rawValue): return "下载中断"
      case Int(SUError.unarchivingError.rawValue): return "安装包无法解压"
      default: break
      }
    }
    return error.localizedDescription
  }

  /// Running inside a disk image, on another read-only volume, or from the random read-only
  /// path macOS moves a downloaded app to (App Translocation): Sparkle cannot replace it.
  static func isReadOnlyLocation(_ url: URL) -> Bool {
    if url.path.contains("/AppTranslocation/") { return true }
    let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
    return values?.volumeIsReadOnly == true
  }
}

/// Release notes as the feed carries them: plain lines (one item each, an optional leading
/// "- "), or the HTML list older feeds used.
enum ReleaseNotes {
  static func lines(from description: String?) -> [String] {
    guard let description, !description.isEmpty else { return [] }
    if description.contains("<li") {
      return listItems(in: description)
    }
    return description
      .split(whereSeparator: \.isNewline)
      .map { line in
        var item = line.trimmingCharacters(in: .whitespaces)
        if item.hasPrefix("- ") { item.removeFirst(2) }
        return item
      }
      .filter { !$0.isEmpty }
  }

  private static func listItems(in html: String) -> [String] {
    var items: [String] = []
    var remainder = html[...]
    while let open = remainder.range(of: "<li") {
      guard let tagEnd = remainder[open.upperBound...].firstIndex(of: ">") else { break }
      let contentStart = remainder.index(after: tagEnd)
      let close = remainder[contentStart...].range(of: "</li>")?.lowerBound ?? remainder.endIndex
      let item = unescaped(stripTags(String(remainder[contentStart..<close])))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !item.isEmpty { items.append(item) }
      remainder = remainder[close...]
      if remainder.hasPrefix("</li>") { remainder = remainder.dropFirst(5) }
    }
    return items
  }

  private static func stripTags(_ text: String) -> String {
    text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
  }

  private static func unescaped(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&amp;", with: "&")
  }
}
