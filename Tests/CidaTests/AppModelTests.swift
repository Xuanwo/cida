import Carbon.HIToolbox
import XCTest

@testable import Cida

@MainActor
final class AppModelTests: XCTestCase {
  func testNewModelStartsWithoutAResult() {
    let model = AppModel()
    XCTAssertNil(model.result)
    XCTAssertNil(model.resultNote)
    XCTAssertFalse(model.canCopyResult)
    XCTAssertEqual(model.mode, .translate)
  }

  func testEveryDesignLucideIconIsBundledForOfflineRendering() {
    for name in LucideIconName.allCases {
      XCTAssertNotNil(LucideIconAsset.image(for: name), "Missing Lucide icon: \(name.rawValue)")
    }
  }

  func testModeTogglePreservesInput() {
    let model = AppModel(inputText: "Keep this text")

    model.toggleMode()

    XCTAssertEqual(model.mode, .improve)
    XCTAssertEqual(model.inputText, "Keep this text")
  }

  func testImprovementDetectsTheSourceLanguageWithoutChangingTheModelPolicy() {
    let model = AppModel(mode: .improve, inputText: "这句话需要改进。")

    XCTAssertEqual(model.detectedSourceLanguage, .chinese)
    model.inputText = "This sentence needs improvement."
    XCTAssertEqual(model.detectedSourceLanguage, .english)

    let request = ProcessingRequest(
      text: model.inputText,
      mode: .improve,
      sourceLanguage: .chinese,
      targetLanguage: .chinese
    )
    XCTAssertEqual(ModelTaskParameters(request: request).languageBehavior, .preserveSource)
    XCTAssertNil(ModelTaskParameters(request: request).sourceLanguage)
    XCTAssertNil(ModelTaskParameters(request: request).targetLanguage)
  }

  func testCopyResultRequiresATerminalResultWithText() {
    let model = AppModel(inputText: "Source")
    XCTAssertFalse(model.copyResult())

    let streaming = ResultRecord(
      mode: .translate, source: "Source", outputLanguage: .english,
      result: "Partial", phase: .streaming)
    model.setResultForTesting(streaming)
    XCTAssertFalse(model.canCopyResult)
    XCTAssertFalse(model.copyResult())

    streaming.phase = .stopped
    XCTAssertTrue(model.canCopyResult, "A stopped result keeps its partial text copyable")

    let failed = ResultRecord(
      mode: .translate, source: "Source", outputLanguage: .english,
      phase: .failed(message: "boom"))
    model.setResultForTesting(failed)
    XCTAssertFalse(model.canCopyResult)
    XCTAssertEqual(model.resultNote?.kind, .failed)
  }

  func testTargetLanguageIsTheOtherHalfOfTheSupportedPair() {
    XCTAssertEqual(AppModel.targetLanguage(for: .chinese), .english)
    XCTAssertEqual(AppModel.targetLanguage(for: .english), .chinese)
    let model = AppModel(inputText: "Cache invalidation is hard.")
    XCTAssertEqual(model.detectedSourceLanguage, .english)
  }

  func testStagedVirtualDocumentKeepsItsPreparedUTF16Count() {
    let model = AppModel(inputText: "Visible tail")

    model.stageInputDocument("Virtual backing document", utf16Count: 1_000_000)

    XCTAssertEqual(model.inputDocumentUTF16Count, 1_000_000)
    model.stageInputDocument(nil)
    XCTAssertEqual(model.inputDocumentUTF16Count, "Visible tail".utf16.count)
  }

  func testStreamingPublishesPartialResultsAndCompletionFollowRequests() async throws {
    let model = AppModel(
      mode: .improve,
      inputText: "Draft",
      service: DelayedStreamingService(chunks: ["Clear", " and", " concise."])
    )

    let processing = Task { await model.process(text: "Draft") }

    try await waitUntil { model.generationState.phase == .waiting }
    try await waitUntil { model.result?.result.hasPrefix("Clear") == true }
    let partialFollowRevision = model.resultFollowRevision
    XCTAssertTrue(model.isProcessing)
    XCTAssertEqual(model.generationState.phase, .revealing)
    XCTAssertEqual(model.result?.phase, .streaming)
    XCTAssertEqual(model.inputText, "Draft", "The source stays in the editor")

    await processing.value

    let result = try XCTUnwrap(model.result)
    XCTAssertEqual(result.result, "Clear and concise.")
    XCTAssertEqual(result.phase, .completed)
    XCTAssertEqual(result.outputLanguage, .english, "Improvement keeps the source language")
    XCTAssertFalse(model.isProcessing)
    XCTAssertEqual(model.generationState, .idle)
    XCTAssertGreaterThan(model.resultFollowRevision, partialFollowRevision)
  }

  func testTerminalResultFollowBypassesTheStreamingThrottle() {
    let model = AppModel()

    model.requestResultFollow(force: false)
    let throttledRevision = model.resultFollowRevision
    model.requestResultFollow(force: false)

    XCTAssertEqual(model.resultFollowRevision, throttledRevision)

    model.requestResultFollow(force: false, allowsThrottling: false)

    XCTAssertEqual(model.resultFollowRevision, throttledRevision + 1)
  }

  func testCancellingStreamingKeepsTheVisiblePartialResult() async throws {
    let model = AppModel(
      inputText: "Draft",
      service: DelayedStreamingService(
        chunks: ["First", " second", " third"],
        delay: .milliseconds(100)
      )
    )

    model.submit()
    try await waitUntil { model.result?.result.isEmpty == false }
    let visibleResult = model.result?.result
    model.cancelProcessing()
    try await waitUntil { !model.isProcessing }

    XCTAssertEqual(model.result?.result, visibleResult)
    XCTAssertEqual(model.result?.phase, .stopped)
    XCTAssertEqual(model.resultNote?.kind, .stopped)
    XCTAssertTrue(model.canCopyResult)
  }

  func testSubmitReplacesThePreviousResultAndKeepsTheSource() async throws {
    let model = AppModel(
      inputText: "Next source",
      service: DelayedStreamingService(chunks: ["Next result"], delay: .milliseconds(250))
    )
    model.setResultForTesting(
      ResultRecord(
        mode: .translate, source: "Previous source", outputLanguage: .english,
        result: "Previous result", phase: .completed))
    XCTAssertTrue(model.isResultStale)

    XCTAssertTrue(model.submit())

    let submitted = try XCTUnwrap(model.result)
    XCTAssertEqual(model.inputText, "Next source")
    XCTAssertEqual(submitted.source, "Next source")
    XCTAssertEqual(submitted.result, "")
    XCTAssertEqual(submitted.phase, .streaming)
    XCTAssertEqual(model.generationState, .waiting(entryID: submitted.id))
    XCTAssertFalse(model.isResultStale, "A running request is never stale")

    model.cancelProcessing()
    try await waitUntil { !model.isProcessing }
    XCTAssertEqual(submitted.phase, .stopped)
  }

  func testFailedRequestKeepsThePartialTextAndExplainsInline() async throws {
    let model = AppModel(
      inputText: "Draft",
      service: FailingStreamingService(chunks: ["Partial"], message: "boom"),
      streamPresentationPolicy: .fastTests
    )

    await model.process(text: "Draft")

    let result = try XCTUnwrap(model.result)
    XCTAssertEqual(result.result, "Partial")
    XCTAssertEqual(result.phase, .failed(message: "boom"))
    XCTAssertEqual(model.resultNote?.kind, .failed)
    XCTAssertTrue(model.resultNote?.text.contains("boom") == true)
    XCTAssertNil(model.errorMessage, "Request failures never raise a Settings alert")
  }

  func testBurstyResponseIsReleasedInBoundedPresentationUpdates() async {
    let response = String(repeating: "Smooth burst rendering. ", count: 24)
    let model = AppModel(
      service: DelayedStreamingService(chunks: [response], delay: .zero),
      streamPresentationPolicy: .fastTests
    )

    await model.process(text: "Draft")

    XCTAssertEqual(model.result?.result, response)
    XCTAssertEqual(model.result?.phase, .completed)
    XCTAssertGreaterThan(model.streamPresentationUpdateCount, 1)
    XCTAssertLessThan(model.maximumStreamPresentationCharacterCount, response.count)
    XCTAssertLessThanOrEqual(model.maximumStreamPresentationCharacterCount, 16)
  }

  func testCharacterAtATimeResponseIsCoalescedBeforeRendering() async {
    let response = "A backend can arrive one character at a time."
    let model = AppModel(
      service: DelayedStreamingService(
        chunks: response.map(String.init),
        delay: .zero
      ),
      streamPresentationPolicy: .fastTests
    )

    await model.process(text: "Draft")

    XCTAssertEqual(model.result?.result, response)
    XCTAssertGreaterThan(model.streamPresentationUpdateCount, 1)
    XCTAssertLessThan(model.streamPresentationUpdateCount, response.count)
  }

  func testVisibleResultRemainsStableDuringABackendPause() async throws {
    let service = GatedStreamingService(firstChunk: "Steady", secondChunk: " finish")
    let model = AppModel(
      service: service,
      streamPresentationPolicy: .fastTests
    )

    let processing = Task { await model.process(text: "Draft") }
    try await waitUntil { model.result?.result == "Steady" }
    let revisionDuringPause = model.streamPresentationUpdateCount
    try await Task.sleep(for: .milliseconds(70))

    XCTAssertEqual(model.result?.result, "Steady")
    XCTAssertEqual(model.streamPresentationUpdateCount, revisionDuringPause)
    XCTAssertEqual(model.result?.phase, .streaming)

    service.releaseSecondChunk()
    await processing.value
    XCTAssertEqual(model.result?.result, "Steady finish")
    XCTAssertEqual(model.result?.phase, .completed)
  }

  func testPresentationBufferPreservesASplitUnicodeGraphemeCluster() {
    var buffer = StreamPresentationBuffer()
    buffer.append("👩")
    buffer.append("🏽")
    buffer.append("\u{200D}")
    buffer.append("💻")

    XCTAssertEqual(buffer.pendingUTF8ByteCount, 0)

    buffer.finish()
    let result = buffer.take(maximumGraphemeClusterCount: 1)

    XCTAssertEqual(result, "👩🏽‍💻")
    XCTAssertEqual(result.count, 1)
    XCTAssertTrue(buffer.isDrained)
  }

  func testProductionStreamVelocityMatchesTheDesignMotionContract() {
    let policy = StreamPresentationPolicy.production

    XCTAssertEqual(policy.targetCharactersPerSecond(forPendingCount: 1), 30)
    XCTAssertEqual(policy.targetCharactersPerSecond(forPendingCount: 40), 100)
    XCTAssertEqual(policy.targetCharactersPerSecond(forPendingCount: 160), 400)
    XCTAssertEqual(policy.targetCharactersPerSecond(forPendingCount: 10_000), 400)

    var controller = StreamVelocityController(policy: policy)
    _ = controller.releaseLimit(
      pendingGraphemeClusterCount: 40,
      elapsedSeconds: 1 / 120
    )
    XCTAssertEqual(controller.smoothedCharactersPerSecond, 100, accuracy: 0.001)
    _ = controller.releaseLimit(
      pendingGraphemeClusterCount: 160,
      elapsedSeconds: 1 / 120
    )
    XCTAssertEqual(controller.smoothedCharactersPerSecond, 145, accuracy: 0.001)
  }

  func testProductionStreamNeverDumpsMoreThanOneBoundedFrameBatch() {
    var controller = StreamVelocityController(policy: .production)

    for _ in 0..<240 {
      let releaseCount = controller.releaseLimit(
        pendingGraphemeClusterCount: 10_000,
        elapsedSeconds: 1 / 120
      )
      XCTAssertLessThanOrEqual(
        releaseCount,
        StreamPresentationPolicy.production.maximumGraphemeClustersPerUpdate
      )
    }
  }

  func testProductionPresenterConsumesTheBufferOnEvery120HertzDisplayFrame() async {
    var publishedDeltas: [String] = []
    let presenter = SmoothStreamPresenter(policy: .production) { delta in
      publishedDeltas.append(delta)
    }
    presenter.append(String(repeating: "A", count: 10_000))

    for _ in 0..<120 {
      presenter.presentForExternalDisplayPulse(elapsedSeconds: 1 / 120)
      await Task.yield()
    }
    try? await Task.sleep(for: .milliseconds(1))

    XCTAssertEqual(publishedDeltas.count, 120)
    XCTAssertTrue(
      publishedDeltas.allSatisfy {
        $0.count <= StreamPresentationPolicy.production.maximumGraphemeClustersPerUpdate
      }
    )
    XCTAssertGreaterThan(publishedDeltas.joined().count, 200)
  }

  func testDesignMotionTokensDriveTheProductionStreamPolicy() {
    let policy = StreamPresentationPolicy.production

    XCTAssertEqual(policy.targetCatchUpDurationSeconds, 0.4)
    XCTAssertEqual(policy.minimumCharactersPerSecond, CidaMotion.minimumCharactersPerSecond)
    XCTAssertEqual(policy.maximumCharactersPerSecond, CidaMotion.maximumCharactersPerSecond)
    XCTAssertEqual(
      policy.smoothingAlphaPer120HzFrame,
      CidaMotion.smoothingAlphaPer120HzFrame
    )
    XCTAssertEqual(policy.minimumPresentationIntervalSeconds, 1 / 120)
    XCTAssertEqual(StreamGlyphFadeAnimation.duration, CidaMotion.characterInSeconds)
  }

  func testComposerPresentationStateDoesNotReplaceTheTrueDocumentMetrics() {
    let metrics = ComposerTextMetrics(
      characterCount: 1_000_000,
      hasLineBreak: true,
      lineCount: 8_000,
      hasNonWhitespace: true,
      isImportingLargeDocument: false
    )

    let compactPresentation = metrics.presented(as: .compact)
    let multilinePresentation = metrics.presented(as: .multiline(visibleLineCount: 5))

    XCTAssertEqual(compactPresentation.characterCount, 1_000_000)
    XCTAssertEqual(compactPresentation.presentationState, .compact)
    XCTAssertEqual(multilinePresentation.characterCount, 1_000_000)
    XCTAssertEqual(
      multilinePresentation.presentationState,
      .multiline(visibleLineCount: 5)
    )
  }

  func testResultStorageKeepsIdentityAcrossIncrementalUpdates() {
    let record = ResultRecord(mode: .translate, source: "Source", outputLanguage: .english)
    let storage = record.storage

    for _ in 0..<1_000 {
      record.appendPresentationDelta("bounded delta ")
    }

    XCTAssertTrue(storage === record.storage)
    XCTAssertEqual(record.presentationRevision, 1_000)
    XCTAssertEqual(record.result, String(repeating: "bounded delta ", count: 1_000))
  }

  func testStrictSmoothStreamingReportCarriesPresentationMetrics() {
    let timestamps = (0..<1_440).map { Double($0) / 120 }

    let report = FramePacingProbeNSView.makeReport(
      timestamps: timestamps,
      maximumFramesPerSecond: 120,
      requiredSampleCount: 1_440,
      workload: FramePacingWorkload.streaming.description,
      requiredFramesPerSecond: 120,
      requiresZeroMissedFrameBudgets: true,
      workloadCompleted: true,
      streamPresentationUpdateCount: 240,
      maximumStreamPresentationBatchCharacterCount: 246
    )

    XCTAssertTrue(report.passed)
    XCTAssertEqual(report.streamPresentationUpdateCount, 240)
    XCTAssertEqual(report.maximumStreamPresentationBatchCharacterCount, 246)
    XCTAssertEqual(report.missedFrameBudgetCount, 0)
  }

  func testHighFrequencyStreamUpdatesAreBatchedForRendering() async {
    let chunks = Array(repeating: "token ", count: 1_000)
    let model = AppModel(
      service: DelayedStreamingService(chunks: chunks, delay: .zero),
      streamPresentationPolicy: .fastTests
    )

    await model.process(text: "Draft")

    XCTAssertEqual(model.result?.result, chunks.joined())
    XCTAssertLessThan(model.streamPresentationUpdateCount, chunks.count)
    XCTAssertLessThan(model.resultFollowRevision, model.streamPresentationUpdateCount)
  }

  func testLegacySettingsDecodeWithTheOfficialOpenAIEndpoint() throws {
    let data = Data(
      #"{"provider":"OpenAI","apiKey":"","model":"gpt-5","translationPrompt":"translate","improvementPrompt":"improve","launchAtLogin":false}"#
        .utf8
    )

    let settings = try JSONDecoder().decode(CidaSettings.self, from: data)

    XCTAssertEqual(settings.provider, .openAI)
    XCTAssertEqual(settings.customEndpoint, "")
    XCTAssertEqual(settings.resolvedEndpoint?.absoluteString, CidaSettings.officialOpenAIEndpoint)
  }

  func testLegacyOpenAIWithAnotherEndpointBecomesACustomProvider() throws {
    let data = Data(
      #"{"provider":"OpenAI","apiKey":"","model":"local-model","openAIEndpoint":"http://127.0.0.1:8080/v1/chat/completions","translationPrompt":"translate","improvementPrompt":"improve","launchAtLogin":false}"#
        .utf8
    )

    let settings = try JSONDecoder().decode(CidaSettings.self, from: data)

    XCTAssertEqual(settings.provider, .custom)
    XCTAssertEqual(settings.customEndpoint, "http://127.0.0.1:8080/v1/chat/completions")
    XCTAssertTrue(settings.usesLocalEndpoint)
    let encoded = try JSONEncoder().encode(settings)
    XCTAssertEqual(try JSONDecoder().decode(CidaSettings.self, from: encoded), settings)
  }

  func testReadinessIsDerivedWithoutANetworkRequest() {
    var settings = CidaSettings()
    XCTAssertEqual(settings.readiness, .missingAPIKey)
    settings.apiKey = "sk-test"
    XCTAssertEqual(settings.readiness, .ready)

    settings.provider = .custom
    settings.model = "local-model"
    settings.customEndpoint = ""
    XCTAssertEqual(settings.readiness, .invalidEndpoint)
    settings.customEndpoint = "http://localhost:8080/v1/chat/completions"
    settings.apiKey = ""
    XCTAssertEqual(settings.readiness, .localEndpoint)
    XCTAssertTrue(settings.readiness.isReady)
    settings.customEndpoint = "https://example.com/v1/chat/completions"
    XCTAssertEqual(settings.readiness, .missingAPIKey)
    settings.model = " "
    settings.apiKey = "sk-test"
    XCTAssertEqual(settings.readiness, .missingModel)

    for provider in ModelProvider.allCases where !provider.isCustom {
      XCTAssertNotNil(provider.presetEndpoint, provider.rawValue)
      XCTAssertFalse(provider.suggestedModels.isEmpty, provider.rawValue)
      XCTAssertNotNil(provider.endpointCaption, provider.rawValue)
    }
  }

  func testLegacyPromptPlaceholdersMigrateToPlainPoliciesOnlyOnce() throws {
    let data = Data(
      #"{"provider":"DeepSeek","apiKey":"","model":"deepseek-chat","translationPrompt":"Translate {text} into {target_lang}.","improvementPrompt":"Improve {text} without changing {target_lang}.","launchAtLogin":false}"#
        .utf8
    )

    let migrated = try JSONDecoder().decode(CidaSettings.self, from: data)

    XCTAssertFalse(migrated.translationPrompt.contains("{text}"))
    XCTAssertFalse(migrated.translationPrompt.contains("{target_lang}"))
    XCTAssertFalse(migrated.improvementPrompt.contains("{text}"))
    XCTAssertFalse(migrated.improvementPrompt.contains("{target_lang}"))

    let encoded = try JSONEncoder().encode(migrated)
    let decodedAgain = try JSONDecoder().decode(CidaSettings.self, from: encoded)
    XCTAssertEqual(decodedAgain, migrated)
  }

  func testVersionedPromptTreatsLegacyPlaceholderSyntaxAsLiteralText() throws {
    var settings = CidaSettings()
    settings.translationPrompt = "Preserve the literal markers {text} and {target_lang}."

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(CidaSettings.self, from: encoded)

    XCTAssertEqual(decoded.translationPrompt, settings.translationPrompt)
  }

  func testPromptBuilderSeparatesTypedParametersFromTheUserDocument() throws {
    let source = "SOURCE_ONLY_8472 with literal {text} and {target_lang} markers."
    let request = ProcessingRequest(
      text: source,
      mode: .translate,
      sourceLanguage: .chinese,
      targetLanguage: .english
    )
    var settings = CidaSettings()
    settings.translationPrompt = "Policy keeps {text} and {target_lang} as ordinary text."

    let prompt = try ModelPromptBuilder.build(request: request, settings: settings)

    XCTAssertEqual(prompt.userMessage, source)
    XCTAssertFalse(prompt.systemMessage.contains("SOURCE_ONLY_8472"))
    XCTAssertTrue(prompt.systemMessage.contains(settings.translationPrompt))
    XCTAssertEqual(prompt.parameters.operation, .translate)
    XCTAssertEqual(prompt.parameters.languageBehavior, .translateToTarget)
    XCTAssertEqual(prompt.parameters.sourceLanguage, .chinese)
    XCTAssertEqual(prompt.parameters.targetLanguage, .english)
    XCTAssertTrue(prompt.systemMessage.contains(#""operation":"translate""#))
    XCTAssertTrue(prompt.systemMessage.contains(#""target_language":"english""#))

    let improvePrompt = try ModelPromptBuilder.build(
      request: ProcessingRequest(
        text: source,
        mode: .improve,
        sourceLanguage: .english,
        targetLanguage: .chinese
      ),
      settings: settings
    )
    XCTAssertEqual(improvePrompt.parameters.languageBehavior, .preserveSource)
    XCTAssertNil(improvePrompt.parameters.sourceLanguage)
    XCTAssertNil(improvePrompt.parameters.targetLanguage)
    XCTAssertFalse(improvePrompt.systemMessage.contains(#""source_language""#))
    XCTAssertFalse(improvePrompt.systemMessage.contains(#""target_language""#))
    XCTAssertTrue(
      improvePrompt.systemMessage.contains(#""language_behavior":"preserve_source""#)
    )
  }

  func testSelectingProviderKeepsModelValid() {
    let model = AppModel()

    model.selectProvider(.openAI)

    XCTAssertEqual(model.settings.provider, .openAI)
    XCTAssertEqual(model.settings.model, "gpt-5")

    model.selectProvider(.custom)
    XCTAssertEqual(model.settings.provider, .custom)
    XCTAssertEqual(model.settings.model, "", "A custom endpoint takes a typed model")
  }

  func testGlobalShortcutRequiresACommandOptionOrControlModifier() throws {
    XCTAssertNil(GlobalShortcut(keyCode: UInt16(kVK_ANSI_T), modifierFlags: []))
    XCTAssertNil(GlobalShortcut(keyCode: UInt16(kVK_ANSI_T), modifierFlags: [.shift]))
    XCTAssertNil(
      GlobalShortcut(keyCode: UInt16(kVK_Command), modifierFlags: [.command]),
      "A bare modifier is not a key")

    let shortcut = try XCTUnwrap(
      GlobalShortcut(keyCode: UInt16(kVK_ANSI_T), modifierFlags: [.control, .option, .capsLock]))
    XCTAssertEqual(shortcut.modifiers, [.control, .option])
    XCTAssertEqual(shortcut.displayText, "⌃ ⌥ T")
    XCTAssertEqual(shortcut.menuKeyEquivalent, "t")
    XCTAssertEqual(shortcut.menuModifierMask, [.control, .option])
    XCTAssertEqual(GlobalShortcut.optionSpace.displayText, "⌥ Space")
    XCTAssertEqual(GlobalShortcut.optionSpace.menuKeyEquivalent, " ")
    XCTAssertEqual(
      GlobalShortcut(keyCode: UInt16(kVK_Return), modifiers: [.shift, .command]).displayText,
      "⇧ ⌘ ↩")
  }

  func testSettingsWithoutAShortcutDecodeToOptionSpaceAndACustomOneRoundTrips() throws {
    let legacy = Data(
      #"{"apiKey":"","model":"deepseek-chat","translationPrompt":"translate","improvementPrompt":"improve","launchAtLogin":false}"#
        .utf8)
    XCTAssertEqual(try JSONDecoder().decode(CidaSettings.self, from: legacy).shortcut, .optionSpace)

    var settings = CidaSettings()
    settings.shortcut = GlobalShortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: [.control, .option])
    let encoded = try JSONEncoder().encode(settings)
    XCTAssertEqual(try JSONDecoder().decode(CidaSettings.self, from: encoded), settings)
  }

  func testSettingsKeepTheCurrentShortcutWhenTheSystemRefusesTheNewOne() {
    let refused = GlobalShortcut(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command])
    let model = AppModel(saveSettings: { _ in }, applyGlobalShortcut: { shortcut, _ in shortcut != refused })

    XCTAssertFalse(model.setShortcut(refused))
    XCTAssertEqual(model.settings.shortcut, .optionSpace)

    let accepted = GlobalShortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: [.control, .option])
    XCTAssertTrue(model.setShortcut(accepted))
    XCTAssertEqual(model.settings.shortcut, accepted)
    XCTAssertTrue(model.setShortcut(accepted), "Re-applying the current combination is a no-op")
  }

  func testAutomationBundleUsesAnIndependentSettingsNamespace() {
    XCTAssertEqual(
      SettingsStore.storageNamespace(for: "com.xuanwo.Cida"),
      "com.xuanwo.Cida"
    )
    XCTAssertEqual(
      SettingsStore.storageNamespace(for: "com.xuanwo.Cida.Automation.run42"),
      "com.xuanwo.Cida.Automation.run42"
    )
    XCTAssertNotEqual(
      SettingsStore.storageNamespace(for: "com.xuanwo.Cida.Automation.run42"),
      SettingsStore.storageNamespace(for: "com.xuanwo.Cida")
    )
  }

  func testSettingsPersistWithinOneNamespaceWithoutLeakingIntoAnother() {
    let firstNamespace = "com.xuanwo.Cida.Automation.Unit.First.\(UUID().uuidString)"
    let secondNamespace = "com.xuanwo.Cida.Automation.Unit.Second.\(UUID().uuidString)"
    defer {
      SettingsStore.reset(namespace: firstNamespace)
      SettingsStore.reset(namespace: secondNamespace)
    }

    var firstSettings = CidaSettings()
    firstSettings.provider = .openAI
    firstSettings.model = "isolated-model"
    SettingsStore.save(firstSettings, namespace: firstNamespace)

    XCTAssertEqual(SettingsStore.load(namespace: firstNamespace).provider, .openAI)
    XCTAssertEqual(SettingsStore.load(namespace: firstNamespace).model, "isolated-model")
    XCTAssertEqual(SettingsStore.load(namespace: secondNamespace).provider, .deepSeek)
    XCTAssertEqual(SettingsStore.load(namespace: secondNamespace).model, "deepseek-chat")
  }

  func testSavingUnrelatedSettingsDoesNotClearAnUnavailableAPIKey() {
    var clearCount = 0
    var persistedSettings: CidaSettings?
    let model = AppModel(
      settings: CidaSettings(),
      saveSettings: { persistedSettings = $0 },
      clearPersistedAPIKey: { clearCount += 1 }
    )

    model.settings.model = "new-model"
    model.persistSettings()

    XCTAssertEqual(clearCount, 0)
    XCTAssertEqual(persistedSettings?.model, "new-model")
  }

  func testExplicitlyClearingALoadedAPIKeyDeletesIt() {
    var settings = CidaSettings()
    settings.apiKey = "sk-existing-test-key"
    var clearCount = 0
    let model = AppModel(
      settings: settings,
      saveSettings: { _ in },
      clearPersistedAPIKey: { clearCount += 1 }
    )

    model.settings.apiKey = ""
    model.persistSettings()

    XCTAssertEqual(clearCount, 1)
  }

  func testRecoveredAPIKeyIsRestoredWithoutReenteringIt() {
    var clearCount = 0
    let model = AppModel(
      settings: CidaSettings(),
      saveSettings: { _ in },
      clearPersistedAPIKey: { clearCount += 1 }
    )

    model.restorePersistedAPIKey("sk-recovered-test-key")
    model.persistSettings()

    XCTAssertEqual(model.settings.apiKey, "sk-recovered-test-key")
    XCTAssertEqual(clearCount, 0)
  }

  func testFramePacingReportPassesForStable120HzSamples() {
    let timestamps = (0..<720).map { Double($0) / 120 }

    let report = FramePacingProbeNSView.makeReport(
      timestamps: timestamps,
      maximumFramesPerSecond: 120
    )

    XCTAssertTrue(report.passed)
    XCTAssertEqual(report.measuredFramesPerSecond, 120, accuracy: 0.01)
    XCTAssertEqual(report.missedFrameBudgetCount, 0)
  }

  func testPhysicalFrameReportUsesMainActorLatencyForMissedBudgets() {
    let timestamps = (0..<720).map { Double($0) / 120 }
    var latencies = Array(repeating: 0.001, count: timestamps.count)
    latencies[100] = 0.014
    let eventLabels = (0..<timestamps.count).map { "event-\($0)" }

    let report = FramePacingProbeNSView.makeReport(
      timestamps: timestamps,
      mainActorLatencies: latencies,
      maximumFramesPerSecond: 120,
      requiredFramesPerSecond: 120,
      requiresZeroMissedFrameBudgets: true,
      phaseLabels: Array(repeating: "translating", count: timestamps.count),
      eventLabels: eventLabels
    )

    XCTAssertFalse(report.passed)
    XCTAssertEqual(report.measuredFramesPerSecond, 120, accuracy: 0.01)
    XCTAssertEqual(report.missedFrameSampleIndices, [101])
    XCTAssertEqual(report.missedFrameEvents, ["event-100"])
    XCTAssertEqual(report.maximumFrameSampleIndex, 101)
    XCTAssertEqual(report.maximumMainActorLatencyMilliseconds, 14, accuracy: 0.001)
    XCTAssertEqual(report.phaseFramePacing["translating"]?.missedFrameBudgetCount, 1)
  }

  func testPhysicalFrameReportAcceptsInBudgetCallbackHandlingJitter() {
    let timestamps = (0..<720).map { Double($0) / 120 }
    var latencies = Array(repeating: 0.001, count: timestamps.count)
    latencies[100] = 0.007

    let report = FramePacingProbeNSView.makeReport(
      timestamps: timestamps,
      mainActorLatencies: latencies,
      maximumFramesPerSecond: 120,
      requiredFramesPerSecond: 120,
      requiresZeroMissedFrameBudgets: true
    )

    XCTAssertTrue(report.passed)
    XCTAssertEqual(report.missedFrameBudgetCount, 0)
    XCTAssertEqual(report.maximumMainActorLatencyMilliseconds, 7, accuracy: 0.001)
  }

  func testFramePacingReportCarriesArtifactHardwareAndDisplayProvenance() {
    let report = FramePacingProbeNSView.makeReport(
      timestamps: (0..<120).map { Double($0) / 120 },
      maximumFramesPerSecond: 120,
      artifactAppTreeSHA256: "app-digest",
      artifactSourceCommit: "source-commit",
      hardwareModel: "Mac-test",
      operatingSystemVersion: "macOS test",
      thermalState: "nominal",
      lowPowerModeEnabled: false,
      powerSource: "AC Power",
      displayName: "Test Display",
      displayBackingScaleFactor: 2,
      displayPixelWidth: 3_456,
      displayPixelHeight: 2_234
    )

    XCTAssertEqual(report.frameClock, "display-link")
    XCTAssertEqual(report.artifactAppTreeSHA256, "app-digest")
    XCTAssertEqual(report.artifactSourceCommit, "source-commit")
    XCTAssertEqual(report.hardwareModel, "Mac-test")
    XCTAssertEqual(report.powerSource, "AC Power")
    XCTAssertEqual(report.displayMaximumFramesPerSecond, 120)
    XCTAssertEqual(report.displayPixelWidth, 3_456)
  }

  func testFramePacingReportRejects60HzRenderingOn120HzDisplay() {
    let timestamps = (0..<360).map { Double($0) / 60 }

    let report = FramePacingProbeNSView.makeReport(
      timestamps: timestamps,
      maximumFramesPerSecond: 120
    )

    XCTAssertFalse(report.passed)
    XCTAssertEqual(report.measuredFramesPerSecond, 60, accuracy: 0.01)
  }

  func testFramePacingReportRejectsAnIncompleteSampleTarget() {
    let timestamps = (0..<400).map { Double($0) / 120 }

    let report = FramePacingProbeNSView.makeReport(
      timestamps: timestamps,
      maximumFramesPerSecond: 120,
      requiredSampleCount: 720
    )

    XCTAssertFalse(report.passed)
    XCTAssertEqual(report.sampleCount, 400)
  }

  func testMillionCharacterPasteReportPassesOnlyAtStable120HzWithoutMisses() {
    let timestamps = (0..<1_440).map { Double($0) / 120 }

    let report = FramePacingProbeNSView.makeReport(
      timestamps: timestamps,
      maximumFramesPerSecond: 120,
      requiredSampleCount: 1_440,
      workload: FramePacingWorkload.millionCharacterPaste.description,
      requiredFramesPerSecond: 120,
      requiresZeroMissedFrameBudgets: true,
      workloadCompleted: true,
      inputCharacterCount: 1_000_000
    )

    XCTAssertTrue(report.passed)
    XCTAssertTrue(report.displayRequirementSatisfied)
    XCTAssertEqual(report.inputCharacterCount, 1_000_000)
    XCTAssertEqual(report.minimumMeasuredFramesPerSecond, 118.8, accuracy: 0.001)
    XCTAssertEqual(report.missedFrameBudgetCount, 0)
  }

  func testMillionCharacterPasteReportRejectsASingleDroppedFrame() {
    var timestamps = [0.0]
    for sample in 1..<1_440 {
      let interval = sample == 100 ? 2 / 120.0 : 1 / 120.0
      timestamps.append(timestamps[timestamps.count - 1] + interval)
    }

    let report = FramePacingProbeNSView.makeReport(
      timestamps: timestamps,
      maximumFramesPerSecond: 120,
      requiredSampleCount: 1_440,
      workload: FramePacingWorkload.millionCharacterPaste.description,
      requiredFramesPerSecond: 120,
      requiresZeroMissedFrameBudgets: true,
      workloadCompleted: true,
      inputCharacterCount: 1_000_000
    )

    XCTAssertFalse(report.passed)
    XCTAssertEqual(report.missedFrameBudgetCount, 1)
    XCTAssertEqual(report.missedFrameSampleIndices, [100])
    XCTAssertEqual(report.maximumFrameSampleIndex, 100)
  }

  func testMillionCharacterPasteReportRejectsA60HzDisplay() {
    let timestamps = (0..<720).map { Double($0) / 60 }

    let report = FramePacingProbeNSView.makeReport(
      timestamps: timestamps,
      maximumFramesPerSecond: 60,
      requiredSampleCount: 720,
      workload: FramePacingWorkload.millionCharacterPaste.description,
      requiredFramesPerSecond: 120,
      requiresZeroMissedFrameBudgets: true,
      workloadCompleted: true,
      inputCharacterCount: 1_000_000
    )

    XCTAssertFalse(report.passed)
    XCTAssertFalse(report.displayRequirementSatisfied)
  }

  func testMillionCharacterPasteReportRejectsIncompleteInsertion() {
    let timestamps = (0..<1_440).map { Double($0) / 120 }

    let report = FramePacingProbeNSView.makeReport(
      timestamps: timestamps,
      maximumFramesPerSecond: 120,
      requiredSampleCount: 1_440,
      workload: FramePacingWorkload.millionCharacterPaste.description,
      requiredFramesPerSecond: 120,
      requiresZeroMissedFrameBudgets: true,
      workloadCompleted: false,
      inputCharacterCount: 850_000
    )

    XCTAssertFalse(report.passed)
    XCTAssertFalse(report.workloadCompleted)
    XCTAssertEqual(report.inputCharacterCount, 850_000)
  }

  func testFramePacingReportWithoutSamplesCanBeEncodedAsAFailure() throws {
    let report = FramePacingProbeNSView.makeReport(
      timestamps: [],
      maximumFramesPerSecond: 120,
      requiredSampleCount: 720
    )

    XCTAssertFalse(report.passed)
    XCTAssertEqual(report.sampleCount, 0)
    XCTAssertNoThrow(try JSONEncoder().encode(report))
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      if clock.now >= deadline {
        XCTFail("Timed out waiting for condition")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private final class GatedStreamingService: TextProcessingService, @unchecked Sendable {
  private let firstChunk: String
  private let secondChunk: String
  private let releaseStream: AsyncStream<Void>
  private let releaseContinuation: AsyncStream<Void>.Continuation

  init(firstChunk: String, secondChunk: String) {
    self.firstChunk = firstChunk
    self.secondChunk = secondChunk
    var continuation: AsyncStream<Void>.Continuation?
    releaseStream = AsyncStream { continuation = $0 }
    releaseContinuation = continuation!
  }

  func releaseSecondChunk() {
    releaseContinuation.yield(())
    releaseContinuation.finish()
  }

  func stream(
    _ request: ProcessingRequest,
    settings: CidaSettings
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        continuation.yield(firstChunk)
        for await _ in releaseStream {
          break
        }
        try Task.checkCancellation()
        continuation.yield(secondChunk)
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

struct DelayedStreamingService: TextProcessingService {
  let chunks: [String]
  var delay: Duration = .milliseconds(45)

  func stream(
    _ request: ProcessingRequest,
    settings: CidaSettings
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for chunk in chunks {
            continuation.yield(chunk)
            try await Task.sleep(for: delay)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

private struct FailingStreamingService: TextProcessingService {
  let chunks: [String]
  let message: String

  func stream(
    _ request: ProcessingRequest,
    settings: CidaSettings
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        for chunk in chunks {
          continuation.yield(chunk)
        }
        // Let the presenter show what arrived before the backend fails.
        try? await Task.sleep(for: .milliseconds(150))
        continuation.finish(
          throwing: TextProcessingError.apiError(statusCode: 500, message: message))
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
