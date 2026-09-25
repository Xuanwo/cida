import AppKit
import XCTest

@testable import Cida

/// What Cida says between download and update (`Design/spec/lifecycle.md`): panel messages and
/// their keys, the welcome before a model service exists, the update steps' wording, and which
/// launches bring the panel up.
@MainActor
final class LifecycleTests: XCTestCase {
  // MARK: Panel messages

  func testMessageChoicesFollowTabAndReturnAndHidingAnswersLater() {
    let model = AppModel(service: ImmediateStreamingService())
    var chosen: [Int] = []
    var dismissed = 0
    model.present(
      PanelMessage(kind: "test", statement: "辞达 1.1.0 可以安装", choices: ["安装并重启", "稍后", "跳过这个版本"]),
      handler: PanelMessageHandler(
        choose: { chosen.append($0) },
        dismiss: { dismissed += 1 }))

    model.selectNextPanelMessageChoice()
    model.selectNextPanelMessageChoice()
    model.selectNextPanelMessageChoice()
    XCTAssertEqual(model.panelMessage?.selectedChoice, 0, "Tab wraps around")
    model.selectNextPanelMessageChoice()
    model.performPanelMessageChoice()
    XCTAssertEqual(chosen, [1])

    model.dismissPanelMessage()
    XCTAssertEqual(dismissed, 1)
    XCTAssertNil(model.panelMessage, "The translation panes come back")
    model.dismissPanelMessage()
    XCTAssertEqual(dismissed, 1, "An answered message is not answered twice")
  }

  func testWorkingMessageTakesNoChoiceAndStopReachesItsOwner() {
    let model = AppModel(service: ImmediateStreamingService())
    var chosen: [Int] = []
    var stopped = 0
    model.present(
      PanelMessage(
        kind: "test", statement: "正在下载辞达 1.1.0 · 38%", choices: ["安装并重启", "稍后"],
        isWorking: true, slot: .stop),
      handler: PanelMessageHandler(
        choose: { chosen.append($0) }, stop: { stopped += 1 }, dismiss: {}))

    model.performPanelMessageChoice()
    model.selectPanelMessageChoice(1)
    XCTAssertEqual(chosen, [])
    XCTAssertEqual(model.panelMessage?.selectedChoice, 0)

    model.cancelProcessing()
    XCTAssertEqual(stopped, 1, "⌘. stops the message's work, not a request")
  }

  func testTranslationStateWaitsUnderAMessage() {
    let model = AppModel(inputText: "原文", service: ImmediateStreamingService())
    model.present(
      PanelMessage(kind: "test", statement: "辞达 1.1.0 已是最新版本", choices: ["好"]),
      handler: PanelMessageHandler(choose: { _ in }, dismiss: {}))
    model.dismissPanelMessage()
    XCTAssertEqual(model.inputText, "原文")
  }

  // MARK: Welcome

  func testWithoutAModelServiceReturnRemindsInsteadOfSending() {
    var settings = CidaSettings()
    settings.apiKey = ""
    let model = AppModel(
      inputText: "Consistency", settings: settings, service: ModelServiceClient())
    XCTAssertTrue(model.needsModelConfiguration)

    XCTAssertTrue(model.submit())
    XCTAssertNil(model.result, "No request, no failed result")
    XCTAssertFalse(model.isProcessing)
    XCTAssertTrue(model.showsConfigurationReminder)

    XCTAssertTrue(model.importSelection("Selected"))
    XCTAssertNil(model.result, "A selection is brought in but not sent")
    XCTAssertEqual(model.inputText, "Selected")

    model.clearConfigurationReminder()
    XCTAssertFalse(model.showsConfigurationReminder)
  }

  func testAConfiguredServiceNeedsNoWelcome() {
    var settings = CidaSettings()
    settings.modelService.endpoint = "https://api.deepseek.com/chat/completions"
    settings.modelService.model = "deepseek-chat"
    settings.apiKey = "test-key"
    let model = AppModel(settings: settings, service: ModelServiceClient())
    XCTAssertFalse(model.needsModelConfiguration)
    XCTAssertFalse(
      AppModel(service: ImmediateStreamingService()).needsModelConfiguration,
      "A service that talks to no model service needs no configuration")
  }

  func testTheWelcomeOffersSettingsInTheActionSlot() {
    XCTAssertEqual(
      BarActionPresentation.resolve(
        isProcessing: false, canCopyResult: false, showsCopiedFeedback: false, showsWelcome: true),
      .openSettings)
    XCTAssertEqual(
      BarActionPresentation.resolve(
        isProcessing: true, canCopyResult: false, showsCopiedFeedback: false, showsWelcome: true),
      .stop)
  }

  // MARK: Languages

  func testChineseIsTheDefaultLanguageWhateverTheSystemSpeaks() {
    XCTAssertEqual(CidaSettings.defaultLanguages(preferredLanguages: ["en-US", "en"]).my, "简体中文")
    XCTAssertEqual(CidaSettings.defaultLanguages(preferredLanguages: ["zh-Hans-CN"]).my, "简体中文")
    XCTAssertEqual(CidaSettings.defaultLanguages(preferredLanguages: ["en-US", "zh-Hant-TW"]).my, "繁體中文")
    XCTAssertEqual(CidaSettings.defaultLanguages(preferredLanguages: ["zh-HK"]).my, "繁體中文")
    XCTAssertEqual(CidaSettings.defaultLanguages(preferredLanguages: ["ja-JP"]).foreign, "English")
  }

  func testEmptiedLanguagesFallBackAndOlderSettingsGainDefaults() throws {
    var settings = CidaSettings()
    settings.myLanguage = "  "
    settings.foreignLanguage = "英式英语"
    XCTAssertEqual(settings.requestLanguages.my, CidaSettings.defaultLanguages().my)
    XCTAssertEqual(settings.requestLanguages.foreign, "英式英语")

    let older = try JSONDecoder().decode(CidaSettings.self, from: Data(#"{"launchAtLogin": true}"#.utf8))
    XCTAssertEqual(older.myLanguage, CidaSettings.defaultLanguages().my)
    XCTAssertEqual(older.foreignLanguage, "English")
    let roundTrip = try JSONDecoder().decode(CidaSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(roundTrip.foreignLanguage, "英式英语")
  }

  func testResultTypographyFollowsTheScriptThatArrives() async throws {
    XCTAssertEqual(TextLanguageDetector.typography(of: "こんにちは"), .chinese, "Kana is CJK")
    XCTAssertEqual(TextLanguageDetector.typography(of: "안녕하세요"), .chinese, "Hangul is CJK")
    XCTAssertEqual(TextLanguageDetector.typography(of: "Bonjour"), .english)
    XCTAssertNil(TextLanguageDetector.typography(of: "123 !"))

    // English source with 简体中文 as my language: the guess is Chinese, the reply is not.
    let model = AppModel(inputText: "Hello there", service: ImmediateStreamingService())
    XCTAssertTrue(model.submit())
    let record = try XCTUnwrap(model.result)
    XCTAssertEqual(record.outputLanguage, .chinese)
    let deadline = Date().addingTimeInterval(5)
    while record.phase == .streaming, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(record.outputLanguage, .english, "The reply's own script settles it")
  }

  // MARK: Update steps

  func testUpdateMessagesSayWhatTheSpecSays() {
    let found = CidaUpdateDriver.foundMessage(
      version: "1.1.0", currentVersion: "1.0.0", notes: ["第一条", "第二条"])
    XCTAssertEqual(found.statement, "辞达 1.1.0 可以安装")
    XCTAssertEqual(found.statementDetail, " · 当前 1.0.0")
    XCTAssertEqual(found.choices, ["安装并重启", "稍后", "跳过这个版本"])
    XCTAssertEqual(found.body, .lines(["第一条", "第二条"]))

    let downloading = CidaUpdateDriver.downloadingMessage(version: "1.1.0", percent: 38, notes: [])
    XCTAssertEqual(downloading.statement, "正在下载辞达 1.1.0 · 38%")
    XCTAssertTrue(downloading.isWorking)
    XCTAssertEqual(downloading.slot, .stop)
    XCTAssertEqual(
      CidaUpdateDriver.downloadingMessage(version: "1.1.0", percent: nil, notes: []).statement,
      "正在校验…")

    XCTAssertEqual(CidaUpdateDriver.readyMessage(version: "1.1.0").choices, ["立即重启", "退出时安装"])
    XCTAssertEqual(CidaUpdateDriver.currentMessage(version: "1.1.0").statement, "辞达 1.1.0 已是最新版本")

    let failed = CidaUpdateDriver.failedMessage(from: downloading, note: "下载失败：网络连接失败 · ⏎ 重试")
    XCTAssertEqual(failed.choices, ["重试", "稍后"])
    XCTAssertFalse(failed.isWorking, "A failure can be answered")
    XCTAssertEqual(failed.slot, .none)
    XCTAssertEqual(failed.note, "下载失败：网络连接失败 · ⏎ 重试")

    let readOnly = CidaUpdateDriver.readOnlyMessage(
      version: "1.1.0", currentVersion: "1.0.0", notes: [])
    XCTAssertEqual(readOnly.choices, ["稍后"], "A copy that cannot be replaced offers no install")
    XCTAssertEqual(readOnly.note, "辞达正从磁盘映像运行，没法更新。把它拖进「应用程序」后再打开")
  }

  func testNotesReadAsAChangelogAndEqualVersionsShowTheirBuilds() {
    let found = CidaUpdateDriver.foundMessage(
      version: "1.1.0", currentVersion: "1.0.0", notes: ["第一条"])
    XCTAssertEqual(found.bodyCaption, "更新内容")
    XCTAssertNil(
      CidaUpdateDriver.foundMessage(version: "1.1.0", currentVersion: "1.0.0", notes: []).bodyCaption,
      "No notes, no caption")

    let candidates = CidaUpdateDriver.versionLabels(
      new: "1.1.0", newBuild: "146", current: "1.1.0", currentBuild: "145")
    XCTAssertEqual(candidates.new, "1.1.0（146）")
    XCTAssertEqual(candidates.current, "1.1.0（145）")
    let release = CidaUpdateDriver.versionLabels(
      new: "1.2.0", newBuild: "160", current: "1.1.0", currentBuild: "146")
    XCTAssertEqual(release.new, "1.2.0")
    XCTAssertEqual(release.current, "1.1.0")
  }

  func testFailureReasonsAreShortChinese() {
    XCTAssertEqual(
      CidaUpdateDriver.reason(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
      "网络连接失败")
    XCTAssertEqual(
      CidaUpdateDriver.reason(for: NSError(domain: "SUSparkleErrorDomain", code: 3001)),
      "安装包的签名不对")
  }

  func testTranslocatedAndReadOnlyCopiesCannotUpdate() throws {
    XCTAssertTrue(
      CidaUpdateDriver.isReadOnlyLocation(
        URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Cida.app")))
    XCTAssertFalse(CidaUpdateDriver.isReadOnlyLocation(FileManager.default.temporaryDirectory))
  }

  func testReleaseNotesReadPlainLinesAndTheOlderHTMLList() {
    XCTAssertEqual(
      ReleaseNotes.lines(from: "- 第一条\n\n第二条\n"),
      ["第一条", "第二条"])
    XCTAssertEqual(
      ReleaseNotes.lines(from: "<ul><li>feat: a &amp; b</li><li><b>fix</b>: c &lt;d&gt;</li></ul>"),
      ["feat: a & b", "fix: c <d>"])
    XCTAssertEqual(ReleaseNotes.lines(from: nil), [])
  }

  // MARK: Launch

  func testOnlyTheFirstLaunchAfterAnUpdateStaysInTheMenuBar() throws {
    let suite = "com.xuanwo.Cida.Tests.Lifecycle.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }

    defaults.set(true, forKey: CidaUpdater.relaunchedAfterUpdateKey)
    XCTAssertEqual(LaunchSource.current(defaults: defaults), .relaunchAfterUpdate)
    XCTAssertEqual(LaunchSource.current(defaults: defaults), .user, "The mark is read once")
  }
}
