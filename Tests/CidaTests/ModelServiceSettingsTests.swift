import AppKit
import XCTest

@testable import Cida

/// Settings' 模型 group as the model drives it (`Design/spec/configuration.md` §四).
@MainActor
final class ModelServiceSettingsTests: XCTestCase {
  private func failedCheck(for settings: CidaSettings) -> ModelServiceCheckRecord {
    ModelServiceCheckRecord(
      passed: false, statusCode: 401, reason: "服务商拒绝了 API Key", checkedAt: Date(),
      fingerprint: settings.modelServiceFingerprint)
  }

  private func privatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("cida-tests-\(UUID().uuidString)"))
  }

  func testTheLatestCheckOfThisConfigurationDecidesTheStatus() {
    let settings = CidaSettings.designPreview
    let model = AppModel(settings: settings, saveSettings: { _ in })
    XCTAssertTrue(model.isModelServiceConfigured)
    XCTAssertEqual(model.modelServiceStatus, .ready, "Complete and never checked is 已就绪")

    model.applyExternalSettings(settings, lastCheck: failedCheck(for: settings))
    XCTAssertEqual(model.modelServiceStatus, .failed("401 · 服务商拒绝了 API Key"))
    XCTAssertEqual(
      model.modelServiceStatus.failureNote, "401 · 服务商拒绝了 API Key。复制配置提示词，让 AI 助手修好。")
    XCTAssertEqual(model.modelServiceStatus.caption, "检查失败")

    var fixed = settings
    fixed.apiKey = "sk-a-new-key"
    model.applyExternalSettings(fixed, lastCheck: failedCheck(for: settings))
    XCTAssertEqual(
      model.modelServiceStatus, .ready, "A check of another configuration no longer applies")
  }

  func testTheCheckButtonRunsTheCheckAndRecordsIt() async throws {
    let settings = CidaSettings.designPreview
    var recorded: [ModelServiceCheckRecord] = []
    let gate = AsyncGate()
    let model = AppModel(
      settings: settings,
      saveSettings: { _ in },
      checkModelService: { settings in
        await gate.wait()
        return ModelServiceCheckResult(
          model: settings.modelService.model, duration: 0.4, reply: "你好", failure: nil,
          request: nil, responseStatus: 200, responseBody: "",
          record: ModelServiceCheckRecord(
            passed: false, statusCode: 429, reason: "请求太频繁或额度不足", checkedAt: Date(),
            fingerprint: settings.modelServiceFingerprint))
      },
      recordModelServiceCheck: { recorded.append($0) }
    )

    let checking = Task { await model.checkModelService() }
    try await waitUntil { model.isCheckingModelService }
    XCTAssertEqual(model.modelServiceStatus, .checking)
    XCTAssertEqual(model.modelServiceStatus.caption, "正在检查…")
    await gate.open()
    await checking.value

    XCTAssertFalse(model.isCheckingModelService)
    XCTAssertEqual(recorded.count, 1)
    XCTAssertEqual(model.modelServiceStatus, .failed("429 · 请求太频繁或额度不足"))
  }

  func testCopyingThePromptShowsCopiedFor800MillisecondsAndTheCardUntilConfigured()
    async throws
  {
    let pasteboard = privatePasteboard()
    defer { pasteboard.releaseGlobally() }
    let model = AppModel(saveSettings: { _ in }, pasteboard: pasteboard)
    XCTAssertFalse(model.isModelServiceConfigured)

    model.copyConfigurationPrompt()

    XCTAssertEqual(pasteboard.string(forType: .string), model.configurationPrompt)
    XCTAssertTrue(model.configurationPrompt.contains("辞达的命令行：\(ConfigurationPrompt.executablePath)"))
    XCTAssertTrue(model.configurationPrompt.contains("当前配置：还没配置"))
    XCTAssertTrue(model.isShowingConfigurationPromptCopied)
    XCTAssertTrue(model.hasCopiedConfigurationPrompt)
    try await Task.sleep(for: .milliseconds(CidaMotion.copiedHoldMilliseconds + 150))
    XCTAssertFalse(model.isShowingConfigurationPromptCopied)
    XCTAssertTrue(model.hasCopiedConfigurationPrompt, "The card keeps saying what to do next")

    model.applyExternalSettings(.designPreview, lastCheck: nil)
    XCTAssertTrue(model.isModelServiceConfigured)
    XCTAssertFalse(model.hasCopiedConfigurationPrompt)
  }

  func testAnExternalChangeSaysRecentlyUpdatedForThreeSeconds() async throws {
    let model = AppModel(settings: .designPreview, saveSettings: { _ in })
    var changed = CidaSettings.designPreview
    changed.modelService.model = "deepseek-reasoner"

    model.applyExternalSettings(changed, lastCheck: nil)

    XCTAssertEqual(model.settings.modelService.model, "deepseek-reasoner")
    XCTAssertTrue(model.isModelServiceRecentlyUpdated)
    try await Task.sleep(for: .seconds(3.2))
    XCTAssertFalse(model.isModelServiceRecentlyUpdated)

    model.applyExternalSettings(changed, lastCheck: nil)
    XCTAssertFalse(model.isModelServiceRecentlyUpdated, "Nothing about the service changed")
  }

  func testExternalShortcutsAreRegisteredAndARefusedOneIsKept() {
    var saved: [CidaSettings] = []
    let refused = GlobalShortcut(configurationText: "command+q")!
    let accepted = GlobalShortcut(configurationText: "control+option+t")!
    let model = AppModel(
      settings: .designPreview,
      saveSettings: { saved.append($0) },
      applyGlobalShortcut: { shortcut, _ in shortcut != refused })

    var external = CidaSettings.designPreview
    external.shortcut = accepted
    external.captureShortcut = refused
    external.translationPrompt = "From the command line."
    model.applyExternalSettings(external, lastCheck: nil)

    XCTAssertEqual(model.settings.shortcut, accepted)
    XCTAssertEqual(model.settings.captureShortcut, .optionS)
    XCTAssertEqual(model.settings.translationPrompt, "From the command line.")
    XCTAssertEqual(saved.last?.captureShortcut, .optionS, "The stored setting follows what works")
  }

  /// The command line posts a distributed notification; an observer for the same namespace
  /// reloads what the command line wrote.
  func testTheChangeNotificationReloadsTheStoredConfiguration() async throws {
    let namespace = "com.xuanwo.Cida.Automation.Unit.Reload.\(UUID().uuidString)"
    let otherNamespace = "com.xuanwo.Cida.Automation.Unit.Other.\(UUID().uuidString)"
    defer {
      SettingsStore.reset(namespace: namespace)
      SettingsStore.reset(namespace: otherNamespace)
    }
    let model = AppModel(saveSettings: { _ in })
    var reloads = 0
    let observer = ConfigurationChangeNotification.observe(namespace: namespace) {
      reloads += 1
      model.applyExternalSettings(
        SettingsStore.load(namespace: namespace),
        lastCheck: SettingsStore.loadLastCheck(namespace: namespace))
    }
    defer { DistributedNotificationCenter.default().removeObserver(observer) }

    let store = ConfigurationStore.production(namespace: namespace)
    let context = CommandLineInterface.Context(
      store: store, environment: [:], readStandardInput: { Data() },
      readFile: { _ in Data() }, output: { _ in }, errorOutput: { _ in },
      check: { await ModelServiceCheck.run(settings: $0) })
    let status = await CommandLineInterface.run(
      ["config", "set", "endpoint=http://127.0.0.1:8080/v1/messages", "format=anthropic-messages",
       "model=local-claude"],
      context: context)
    XCTAssertEqual(status, 0)

    try await waitUntil { model.settings.modelService.model == "local-claude" }
    XCTAssertEqual(model.settings.modelService.format, .anthropicMessages)
    XCTAssertTrue(model.isModelServiceConfigured, "A local endpoint needs no key")
    XCTAssertTrue(model.isModelServiceRecentlyUpdated)

    ConfigurationChangeNotification.post(namespace: otherNamespace)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(reloads, 1, "Another namespace's change is not ours")
  }

  private func waitUntil(
    timeout: Duration = .seconds(3),
    condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      if clock.now >= deadline {
        XCTFail("Timed out waiting for condition", file: file, line: line)
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private actor AsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    waiters.forEach { $0.resume() }
    waiters = []
  }
}
