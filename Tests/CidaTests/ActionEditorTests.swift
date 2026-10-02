import XCTest

@testable import Cida

@MainActor
final class ActionEditorTests: XCTestCase {
  func testLegacyPromptsMigrateAndOrderedActionsRoundTrip() throws {
    let legacy = Data(
      #"{"translationPrompt":"Translate {text} to {target_lang}","improvementPrompt":"Make it clear"}"#
        .utf8)
    var settings = try JSONDecoder().decode(CidaSettings.self, from: legacy)
    XCTAssertEqual(settings.actions.map(\.id), [.translate, .improve])
    XCTAssertFalse(settings.translationPrompt.contains("{text}"))
    XCTAssertEqual(settings.improvementPrompt, "Make it clear")
    let custom = TextAction(
      id: .init(rawValue: "summary"), name: "摘要", prompt: "Summarize in French.")
    settings.actions.insert(custom, at: 0)
    settings.actions.removeAll { $0.id == .improve }
    let decoded = try JSONDecoder().decode(CidaSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(decoded.actions, settings.actions)
    XCTAssertFalse(decoded.actions.contains { $0.id == .improve })
    let request = ProcessingRequest(
      text: "Original", mode: custom.id, myLanguage: "中文", foreignLanguage: "English")
    let prompt = try ModelPromptBuilder.build(request: request, settings: decoded)
    XCTAssertTrue(prompt.systemMessage.hasPrefix(custom.prompt))
    XCTAssertEqual(prompt.parameters.languageBehavior, .followPolicy)
    XCTAssertTrue(prompt.systemMessage.contains("Return the output requested by the policy"))
    XCTAssertFalse(prompt.systemMessage.contains("without commentary or wrappers"))
    XCTAssertNil(prompt.parameters.myLanguage)
    XCTAssertEqual(prompt.userMessage, "Original")
  }

  func testDraftValidationDiscardUndoAndProtectedTranslation() {
    var settings = CidaSettings()
    let editor = ActionEditor(service: ControlledActionService())
    editor.create(settings)
    let id = editor.selected
    editor.draft?.action.name = "翻译"
    editor.draft?.action.prompt = "Summarize"
    XCTAssertFalse(editor.apply(to: &settings))
    editor.select(.translate)
    XCTAssertEqual(editor.selected, id, "A dirty draft keeps its selection")
    editor.draft?.action.name = "摘要"
    editor.discard(settings: settings)
    XCTAssertNil(editor.draft)
    XCTAssertEqual(settings.actions.count, 2)
    editor.undoChange(settings: &settings)
    XCTAssertEqual(editor.draft?.action.name, "摘要")
    XCTAssertTrue(editor.apply(to: &settings))
    XCTAssertEqual(settings.actions.last?.id, id)
    editor.move(id, to: 0, settings: &settings)
    editor.delete(id, from: &settings)
    editor.undoChange(settings: &settings)
    XCTAssertEqual(settings.actions.first?.id, id)
    editor.delete(.translate, from: &settings)
    XCTAssertTrue(settings.actions.contains { $0.id == .translate })
    XCTAssertNotNil(editor.error)
    editor.stopPreview()
  }

  func testPreviewOnlyRunsOnApplyAndSupersededRequestsCannotReplaceIt() async throws {
    let service = ControlledActionService()
    var settings = CidaSettings()
    let editor = ActionEditor(service: service)
    editor.select(.improve)
    editor.begin(settings)
    XCTAssertEqual(service.count, 0)
    XCTAssertTrue(editor.apply(to: &settings))
    await wait { service.count == 1 }
    XCTAssertEqual(service.requests[0].text, ActionEditor.sample)
    service.finish(0, text: "First result")
    await wait { editor.running == nil }
    XCTAssertEqual(editor.previews[.improve]?.text, "First result")
    editor.begin(settings)
    editor.draft?.action.name = "润色"
    XCTAssertTrue(editor.apply(to: &settings))
    XCTAssertEqual(service.count, 1, "Renaming a previewed action sends no request")
    editor.begin(settings)
    editor.draft?.action.prompt = "Shorter"
    XCTAssertTrue(editor.apply(to: &settings))
    await wait { service.count == 2 }
    XCTAssertEqual(editor.previews[.improve]?.text, "First result")
    editor.begin(settings)
    editor.draft?.action.prompt = "Shortest"
    XCTAssertTrue(editor.apply(to: &settings))
    await wait { service.count == 3 }
    service.finish(2, text: "Latest")
    await wait { editor.running == nil }
    service.finish(1, text: "Obsolete")
    await Task.yield()
    XCTAssertEqual(editor.previews[.improve]?.text, "Latest")
    editor.begin(settings)
    editor.draft?.action.prompt = "Stop me"
    XCTAssertTrue(editor.apply(to: &settings))
    await wait { service.count == 4 }
    editor.stopPreview()
    service.finish(3, text: "Stopped")
    await Task.yield()
    XCTAssertEqual(editor.previews[.improve]?.text, "Latest")
    XCTAssertNil(editor.running)
  }

  func testDefaultActionIsUsedByPanelAndSelectionButCaptureStillTranslates() async {
    var settings = CidaSettings()
    let custom = TextAction(id: .init(rawValue: "shorten"), name: "精简", prompt: "Shorten")
    settings.actions.insert(custom, at: 0)
    let service = ControlledActionService()
    let model = AppModel(settings: settings, service: service, saveSettings: { _ in })
    model.resetModeToDefault()
    XCTAssertEqual(model.mode, custom.id)
    model.toggleMode()
    XCTAssertEqual(model.mode, .translate)
    model.toggleMode()
    XCTAssertEqual(model.mode, .improve)
    model.toggleMode()
    XCTAssertEqual(model.mode, custom.id)
    _ = model.importSelection("Selected")
    await wait { service.count == 1 }
    XCTAssertEqual(service.requests[0].mode, custom.id)
    model.importCapturedText("Captured")
    await wait { service.count == 2 }
    XCTAssertEqual(service.requests[1].mode, .translate)
    model.cancelProcessing()
  }

  func testSampleUsesRealProviderRequestAndKeepsPanelResult() async throws {
    let server = try LocalModelServiceServer(
      plan: .init(chunks: ["A real", " sample result"], delay: 0.01))
    defer { server.stop() }
    var settings = CidaSettings()
    settings.modelService.endpoint = server.endpoint(for: .chatCompletions).absoluteString
    settings.modelService.model = "local-model"
    let result = ResultRecord(
      mode: .translate, source: "Panel input", outputLanguage: .english,
      result: "Panel result", phase: .completed)
    let model = AppModel(result: result, settings: settings, saveSettings: { _ in })
    model.actionEditor.create(settings)
    model.actionEditor.draft?.action.prompt = "Return a short summary"
    let id = model.actionEditor.selected
    XCTAssertTrue(model.actionEditor.apply(to: &model.settings))
    await wait { model.actionEditor.running == nil }
    XCTAssertEqual(model.actionEditor.previews[id]?.text, "A real sample result")
    XCTAssertTrue(model.result === result)
    let request = try server.recordedRequest()
    let messages = try XCTUnwrap(request.body["messages"]?.arrayValue)
    XCTAssertEqual(messages.last?["content"]?.stringValue, ActionEditor.sample)
    XCTAssertTrue(messages[0]["content"]?.stringValue?.hasPrefix("Return a short summary") == true)
  }

  func testFailedPreviewKeepsThePreviousOutputAndCanBeRetried() async {
    let service = ControlledActionService()
    var settings = CidaSettings()
    let editor = ActionEditor(service: service)
    editor.begin(settings)
    editor.apply(to: &settings)
    await wait { service.count == 1 }
    service.finish(0, text: "Previous")
    await wait { editor.running == nil }
    editor.begin(settings)
    editor.draft?.action.prompt = "A changed policy"
    editor.apply(to: &settings)
    await wait { service.count == 2 }
    service.fail(1)
    await wait { editor.running == nil }
    XCTAssertEqual(editor.previews[.translate]?.text, "Previous")
    XCTAssertNotNil(editor.previewNotes[.translate])
    editor.begin(settings)
    editor.apply(to: &settings)
    await wait { service.count == 3 }
    service.finish(2, text: "Recovered")
    await wait { editor.running == nil }
    XCTAssertEqual(editor.previews[.translate]?.text, "Recovered")
    XCTAssertNil(editor.previewNotes[.translate])
  }

  func testApplicationSavingKeepsActionOrderAndDoesNotOverwriteCLIModelConfiguration() {
    let namespace = SettingsStore.automationNamespacePrefix + UUID().uuidString
    defer { UserDefaults(suiteName: namespace)?.removePersistentDomain(forName: namespace) }
    var stored = CidaSettings()
    stored.modelService.model = "new-model-from-cli"
    SettingsStore.save(stored, namespace: namespace)
    var editing = CidaSettings()
    editing.actions.reverse()
    editing.actions[0].name = "润色"
    SettingsStore.saveApplicationSettings(editing, namespace: namespace)
    let restored = SettingsStore.loadWithoutAPIKey(namespace: namespace)
    XCTAssertEqual(restored.actions, editing.actions)
    XCTAssertEqual(restored.modelService.model, "new-model-from-cli")
  }

  func testChangingAnAppliedPromptMarksThePanelResultStale() {
    let settings = CidaSettings()
    let result = ResultRecord(
      mode: .improve, source: "Source", outputLanguage: .english,
      result: "Result", phase: .completed, actionPrompt: settings.improvementPrompt)
    let model = AppModel(mode: .improve, inputText: "Source", result: result, settings: settings)
    XCTAssertFalse(model.isResultStale)
    model.settings.improvementPrompt = "A different policy"
    XCTAssertTrue(model.isResultStale)
    XCTAssertEqual(result.result, "Result")
  }

  func testBlankDraftsCannotSaveAndValidFieldsAreTrimmed() async {
    let service = ControlledActionService()
    let editor = ActionEditor(service: service)
    var settings = CidaSettings()
    let original = settings.actions
    editor.create(settings)
    for (name, prompt, error) in [
      (" \n", "Summarize", "给动作起一个名字"),
      ("Summary", " \n", "写下你希望这个动作做什么"),
      (" 翻译 ", "Summarize", "已经有同名的动作了"),
    ] {
      editor.draft?.action.name = name
      editor.draft?.action.prompt = prompt
      XCTAssertFalse(editor.apply(to: &settings))
      XCTAssertEqual(editor.error, error)
      XCTAssertEqual(settings.actions, original)
      XCTAssertEqual(service.count, 0)
    }
    editor.draft?.action.name = " Summary \n"
    editor.draft?.action.prompt = " Summarize \n"
    XCTAssertTrue(editor.apply(to: &settings))
    XCTAssertEqual(settings.actions.last?.name, "Summary")
    XCTAssertEqual(settings.actions.last?.prompt, "Summarize")
    await wait { service.count == 1 }
    editor.stopPreview()
  }

  func testModelAndLanguageChangesInvalidateCachedPreviewOnApply() async {
    let service = ControlledActionService()
    let editor = ActionEditor(service: service)
    var settings = CidaSettings()
    for index in 0..<3 {
      if index == 1 { settings.modelService.model = "another-model" }
      if index == 2 { settings.foreignLanguage = "French" }
      editor.begin(settings)
      XCTAssertTrue(editor.apply(to: &settings))
      await wait { service.count == index + 1 }
      service.finish(index, text: "Result \(index)")
      await wait { editor.running == nil }
      XCTAssertEqual(editor.previews[.translate]?.fingerprint, settings.modelServiceFingerprint)
      XCTAssertEqual(editor.previews[.translate]?.languages.foreign, settings.requestLanguages.foreign)
    }
    XCTAssertEqual(service.requests[2].foreignLanguage, "French")
    editor.begin(settings)
    XCTAssertTrue(editor.apply(to: &settings))
    XCTAssertEqual(service.count, 3, "Unchanged settings reuse the latest preview")
  }

  func testDeletingRunningActionRejectsLateOutputAndUndoCanRetry() async {
    let service = ControlledActionService()
    let editor = ActionEditor(service: service)
    var settings = CidaSettings()
    editor.select(.improve)
    editor.begin(settings)
    editor.apply(to: &settings)
    await wait { service.count == 1 }
    editor.delete(.improve, from: &settings)
    XCTAssertNil(editor.running)
    service.finish(0, text: "Deleted result")
    await Task.yield()
    XCTAssertNil(editor.previews[.improve])
    editor.undoChange(settings: &settings)
    editor.begin(settings)
    editor.apply(to: &settings)
    await wait { service.count == 2 }
    service.finish(1, text: "Restored result")
    await wait { editor.running == nil }
    XCTAssertEqual(editor.previews[.improve]?.text, "Restored result")
  }

  func testUnconfiguredServiceSavesActionAndDefaultRestorationRequiresApply() {
    let editor = ActionEditor(service: ModelServiceClient())
    var settings = CidaSettings()
    settings.translationPrompt = "Custom translation policy"
    editor.begin(settings)
    editor.restoreDefault()
    XCTAssertEqual(settings.translationPrompt, "Custom translation policy")
    XCTAssertEqual(editor.draft?.action.prompt, CidaSettings.defaultTranslationPrompt)
    XCTAssertTrue(editor.apply(to: &settings))
    XCTAssertEqual(settings.translationPrompt, CidaSettings.defaultTranslationPrompt)
    XCTAssertNil(editor.running)
    XCTAssertNotNil(editor.previewNotes[.translate])
    XCTAssertNil(editor.previews[.translate])
  }

  func testExplicitImprovementRetainsItsPolicyWhenReorderedOrRemoved() throws {
    var settings = CidaSettings()
    let custom = TextAction(id: .init(rawValue: "summary"), name: "Summary", prompt: "Summarize")
    settings.actions.insert(custom, at: 0)
    settings.improvementPrompt = "Improve while preserving tone"
    let request = ProcessingRequest(text: "Source", mode: .improve,
      myLanguage: "中文", foreignLanguage: "English")
    let configured = try ModelPromptBuilder.build(request: request, settings: settings)
    XCTAssertTrue(configured.systemMessage.hasPrefix("Improve while preserving tone"))
    XCTAssertEqual(configured.parameters.languageBehavior, .preserveSource)
    settings.actions.removeAll { $0.id == .improve }
    let fallback = try ModelPromptBuilder.build(request: request, settings: settings)
    XCTAssertTrue(fallback.systemMessage.hasPrefix(CidaSettings.defaultImprovementPrompt))
    XCTAssertEqual(fallback.parameters.languageBehavior, .preserveSource)
  }

  private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line)
    async
  {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(condition(), file: file, line: line)
  }
}

/// Tests control each stream explicitly; a cancelled producer may still try to yield late data.
private final class ControlledActionService: TextProcessingService, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [(ProcessingRequest, AsyncThrowingStream<String, Error>.Continuation)] = []
  var requests: [ProcessingRequest] { lock.withLock { values.map(\.0) } }
  var count: Int { lock.withLock { values.count } }
  func isConfigured(by settings: CidaSettings) -> Bool { true }
  func stream(_ request: ProcessingRequest, settings: CidaSettings) -> AsyncThrowingStream<
    String, Error
  > {
    AsyncThrowingStream { continuation in lock.withLock { values.append((request, continuation)) } }
  }
  func fail(_ index: Int) {
    let continuation = lock.withLock { values[index].1 }
    continuation.finish(throwing: ModelServiceError.emptyResult)
  }
  func finish(_ index: Int, text: String) {
    let continuation = lock.withLock { values[index].1 }
    continuation.yield(text)
    continuation.finish()
  }
}
