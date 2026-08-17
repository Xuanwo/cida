import XCTest

@testable import Cida

@MainActor
final class AppModelTests: XCTestCase {
  func testNewModelStartsWithoutDesignHistory() {
    XCTAssertTrue(AppModel().entries.isEmpty)
  }

  func testEveryPencilLucideIconIsBundledForOfflineRendering() {
    for name in LucideIconName.allCases {
      XCTAssertNotNil(LucideIconAsset.image(for: name), "Missing Lucide icon: \(name.rawValue)")
    }
  }

  func testModeTogglePreservesInput() {
    let model = AppModel(inputText: "Keep this text")

    model.toggleMode()

    XCTAssertEqual(model.mode, .improve)
    XCTAssertEqual(model.inputText, "Keep this text")
    XCTAssertEqual(model.outputHint, "English · 输出跟随原文")
  }

  func testImprovementHistoryShowsTheDetectedSourceLanguageAndProfile() {
    let legacyEntry = HistoryEntry(
      mode: .improve,
      source: "This sentence needs improvement.",
      result: "This sentence is clearer.",
      detail: "中文",
      timestamp: "18:00"
    )

    XCTAssertTrue(legacyEntry.metadata.hasPrefix("English · 语气与语法 · "))
    XCTAssertFalse(legacyEntry.metadata.contains("中文"))
  }

  func testImprovementComposerHintTracksChineseAndEnglishWithoutChangingTheModelPolicy() {
    let model = AppModel(mode: .improve, inputText: "这句话需要改进。")

    XCTAssertEqual(model.outputHint, "中文 · 输出跟随原文")
    model.inputText = "This sentence needs improvement."
    XCTAssertEqual(model.outputHint, "English · 输出跟随原文")

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

  func testLatestCopyableResultSkipsTheActiveStreamingEntry() {
    let model = AppModel(
      entries: [
        HistoryEntry(
          mode: .translate,
          source: "Older",
          result: "Older result",
          detail: "中文 → English",
          timestamp: "16:01"
        ),
        HistoryEntry(
          mode: .translate,
          source: "Latest completed",
          result: "Latest completed result",
          detail: "中文 → English",
          timestamp: "16:02"
        ),
        HistoryEntry(
          mode: .translate,
          source: "Streaming",
          result: "Partial stream",
          detail: "中文 → English",
          timestamp: "16:03",
          state: .streaming
        ),
      ]
    )

    XCTAssertEqual(model.latestCopyableResult, "Latest completed result")
  }

  func testHistoryFocusKeepsOnlyTheLatestEntryAutomaticallyExpanded() {
    let firstID = UUID()
    let secondID = UUID()
    let thirdID = UUID()
    let fourthID = UUID()
    let model = AppModel(
      entries: [
        historyEntry(id: firstID, source: "First"),
        historyEntry(id: secondID, source: "Second"),
        historyEntry(id: thirdID, source: "Third"),
      ]
    )

    XCTAssertFalse(model.isHistoryEntryExpanded(firstID))
    XCTAssertFalse(model.isHistoryEntryExpanded(secondID))
    XCTAssertTrue(model.isHistoryEntryExpanded(thirdID))

    model.expandHistoryEntry(firstID)
    XCTAssertTrue(model.isHistoryEntryExpanded(firstID))

    model.entries.append(historyEntry(id: fourthID, source: "Fourth"))

    XCTAssertTrue(
      model.isHistoryEntryExpanded(firstID),
      "A manually expanded comparison must survive a new submission"
    )
    XCTAssertFalse(
      model.isHistoryEntryExpanded(thirdID),
      "The former automatic focus must fold when a newer entry arrives"
    )
    XCTAssertTrue(model.isHistoryEntryExpanded(fourthID))

    model.collapseHistoryEntry(firstID)
    XCTAssertFalse(model.isHistoryEntryExpanded(firstID))

    model.collapseHistoryEntry(fourthID)
    XCTAssertTrue(
      model.isHistoryEntryExpanded(fourthID),
      "The newest automatic focus cannot be collapsed"
    )
  }

  func testStagedVirtualDocumentKeepsItsPreparedUTF16Count() {
    let model = AppModel(inputText: "Visible tail")

    model.stageInputDocument("Virtual backing document", utf16Count: 1_000_000)

    XCTAssertEqual(model.inputDocumentUTF16Count, 1_000_000)
    model.stageInputDocument(nil)
    XCTAssertEqual(model.inputDocumentUTF16Count, "Visible tail".utf16.count)
  }

  private func historyEntry(id: UUID, source: String) -> HistoryEntry {
    HistoryEntry(
      id: id,
      mode: .translate,
      source: source,
      result: "\(source) result",
      detail: "中文 → English",
      timestamp: "18:00"
    )
  }

  func testSwappingLanguagesUpdatesBothSides() {
    let model = AppModel()

    model.swapLanguages()

    XCTAssertEqual(model.sourceLanguage, .english)
    XCTAssertEqual(model.targetLanguage, .chinese)
  }

  func testStreamingPublishesPartialResultsAndCompletionScrollRequests() async throws {
    let model = AppModel(
      mode: .improve,
      inputText: "Draft",
      entries: [],
      service: DelayedStreamingService(chunks: ["Clear", " and", " concise."])
    )

    let processing = Task { await model.process(text: "Draft") }

    try await waitUntil { model.generationState.phase == .waiting }
    try await waitUntil { model.entries.last?.result.hasPrefix("Clear") == true }
    let partialScrollRevision = model.historyScrollRevision
    XCTAssertTrue(model.isProcessing)
    XCTAssertEqual(model.generationState.phase, .revealing)
    XCTAssertEqual(model.entries.last?.state, .streaming)
    XCTAssertEqual(model.inputText, "")

    await processing.value

    XCTAssertEqual(model.entries.count, 1)
    XCTAssertEqual(model.entries[0].result, "Clear and concise.")
    XCTAssertEqual(model.entries[0].state, .completed)
    XCTAssertFalse(model.isProcessing)
    XCTAssertEqual(model.generationState, .idle)
    XCTAssertGreaterThan(model.historyScrollRevision, partialScrollRevision)
  }

  func testTerminalHistoryFollowBypassesStreamingThrottleWithoutForcingPin() {
    let model = AppModel()

    model.requestHistoryFollow(force: false)
    let throttledRevision = model.historyScrollRevision
    let forcePinRevision = model.historyForcePinRevision
    model.requestHistoryFollow(force: false)

    XCTAssertEqual(model.historyScrollRevision, throttledRevision)

    model.requestHistoryFollow(force: false, allowsThrottling: false)

    XCTAssertEqual(model.historyScrollRevision, throttledRevision + 1)
    XCTAssertEqual(model.historyForcePinRevision, forcePinRevision)
  }

  func testCancellingStreamingKeepsTheVisiblePartialResult() async throws {
    let model = AppModel(
      inputText: "Draft",
      entries: [],
      service: DelayedStreamingService(
        chunks: ["First", " second", " third"],
        delay: .milliseconds(100)
      )
    )

    model.submit()
    try await waitUntil { model.entries.last?.result.isEmpty == false }
    let visibleResult = model.entries.last?.result
    model.cancelProcessing()
    try await waitUntil { !model.isProcessing }

    XCTAssertEqual(model.entries.last?.result, visibleResult)
    XCTAssertEqual(model.entries.last?.state, .cancelled)
  }

  func testSubmitAtomicallyClearsTheComposerFoldsThePreviousEntryAndInsertsWaitingOutput()
    async throws
  {
    let previous = HistoryEntry(
      mode: .translate,
      source: "Previous source",
      result: "Previous result",
      detail: "中文 → English",
      timestamp: "18:00"
    )
    let model = AppModel(
      inputText: "Next source",
      entries: [previous],
      service: DelayedStreamingService(
        chunks: ["Next result"],
        delay: .milliseconds(250)
      )
    )
    XCTAssertTrue(model.submit())

    let submitted = try XCTUnwrap(model.entries.last)
    XCTAssertEqual(model.inputText, "")
    XCTAssertEqual(model.entries.count, 2)
    XCTAssertFalse(previous.isLatestInHistory)
    XCTAssertTrue(submitted.isLatestInHistory)
    XCTAssertEqual(submitted.source, "Next source")
    XCTAssertEqual(submitted.result, "")
    XCTAssertEqual(submitted.state, .streaming)
    XCTAssertEqual(model.generationState, .waiting(entryID: submitted.id))

    model.cancelProcessing()
    try await waitUntil { !model.isProcessing }

    XCTAssertEqual(model.entries.count, 2)
    XCTAssertEqual(submitted.state, .cancelled)
    XCTAssertFalse(model.isHistoryEntryExpanded(previous))
    XCTAssertTrue(model.isHistoryEntryExpanded(submitted))
  }

  func testBurstyResponseIsReleasedInBoundedPresentationUpdates() async {
    let response = String(repeating: "Smooth burst rendering. ", count: 24)
    let model = AppModel(
      entries: [],
      service: DelayedStreamingService(chunks: [response], delay: .zero),
      streamPresentationPolicy: .fastTests
    )

    await model.process(text: "Draft")

    XCTAssertEqual(model.entries.last?.result, response)
    XCTAssertEqual(model.entries.last?.state, .completed)
    XCTAssertGreaterThan(model.streamPresentationUpdateCount, 1)
    XCTAssertLessThan(model.maximumStreamPresentationCharacterCount, response.count)
    XCTAssertLessThanOrEqual(model.maximumStreamPresentationCharacterCount, 16)
  }

  func testCharacterAtATimeResponseIsCoalescedBeforeRendering() async {
    let response = "A backend can arrive one character at a time."
    let model = AppModel(
      entries: [],
      service: DelayedStreamingService(
        chunks: response.map(String.init),
        delay: .zero
      ),
      streamPresentationPolicy: .fastTests
    )

    await model.process(text: "Draft")

    XCTAssertEqual(model.entries.last?.result, response)
    XCTAssertGreaterThan(model.streamPresentationUpdateCount, 1)
    XCTAssertLessThan(model.streamPresentationUpdateCount, response.count)
  }

  func testVisibleResultRemainsStableDuringABackendPause() async throws {
    let service = GatedStreamingService(firstChunk: "Steady", secondChunk: " finish")
    let model = AppModel(
      entries: [],
      service: service,
      streamPresentationPolicy: .fastTests
    )

    let processing = Task { await model.process(text: "Draft") }
    try await waitUntil { model.entries.last?.result == "Steady" }
    let revisionDuringPause = model.streamPresentationUpdateCount
    try await Task.sleep(for: .milliseconds(70))

    XCTAssertEqual(model.entries.last?.result, "Steady")
    XCTAssertEqual(model.streamPresentationUpdateCount, revisionDuringPause)
    XCTAssertEqual(model.entries.last?.state, .streaming)

    service.releaseSecondChunk()
    await processing.value
    XCTAssertEqual(model.entries.last?.result, "Steady finish")
    XCTAssertEqual(model.entries.last?.state, .completed)
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

  func testProductionStreamVelocityMatchesThePencilMotionContract() {
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

  func testPencilMotionTokensDriveTheProductionStreamPolicy() {
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
      formattedCharacterCount: "1,000,000",
      hasLineBreak: true,
      lineCount: 8_000,
      hasNonWhitespace: true,
      isImportingLargeDocument: false
    )

    let compactPresentation = metrics.presented(as: .compact)
    let multilinePresentation = metrics.presented(as: .multiline(visibleLineCount: 5))

    XCTAssertEqual(compactPresentation.characterCount, 1_000_000)
    XCTAssertEqual(compactPresentation.formattedCharacterCount, "1,000,000")
    XCTAssertEqual(compactPresentation.presentationState, .compact)
    XCTAssertEqual(multilinePresentation.characterCount, 1_000_000)
    XCTAssertEqual(
      multilinePresentation.presentationState,
      .multiline(visibleLineCount: 5)
    )
  }

  func testHistoryMetadataTransitionsFromGeneratingToCompletedCounts() {
    let entry = HistoryEntry(
      mode: .translate,
      source: "Source",
      result: "Result",
      detail: "中文 → English",
      timestamp: "18:00",
      reportedSourceCharacterCount: 1_846,
      reportedResultCharacterCount: 3_214,
      state: .streaming
    )

    XCTAssertEqual(entry.metadata, "中文 → English · 生成中")
    entry.state = .completed
    XCTAssertEqual(entry.metadata, "中文 → English · 18:00 · 1,846 → 3,214 字")
  }

  func testHistoryResultStorageKeepsIdentityAcrossIncrementalUpdates() {
    let entry = HistoryEntry(
      mode: .translate,
      source: "Source",
      result: "",
      detail: "中文 → English",
      timestamp: "18:00",
      state: .streaming
    )
    let storage = entry.resultStorage

    for _ in 0..<1_000 {
      entry.appendPresentationDelta("bounded delta ")
    }

    XCTAssertTrue(storage === entry.resultStorage)
    XCTAssertEqual(entry.presentationRevision, 1_000)
    XCTAssertEqual(entry.result, String(repeating: "bounded delta ", count: 1_000))
  }

  func testFoldedHistoryPreviewCacheStaysBoundedAndGraphemeSafe() {
    let family = "👨‍👩‍👧‍👦"
    let initial = String(repeating: "A", count: 419) + family + "trailing text"
    let storage = HistoryResultStorage(initial)

    XCTAssertEqual(storage.foldedPreview, String(initial.prefix(420)))
    XCTAssertTrue(storage.foldedPreview.hasSuffix(family))
    XCTAssertTrue(storage.foldedPreviewNeedsFade)

    storage.replace(with: String(repeating: "B", count: 120))
    XCTAssertEqual(storage.foldedPreview, String(repeating: "B", count: 120))
    XCTAssertFalse(storage.foldedPreviewNeedsFade)

    storage.append(family)
    XCTAssertEqual(storage.foldedPreview, String(repeating: "B", count: 120) + family)
    XCTAssertTrue(storage.foldedPreviewNeedsFade)

    storage.replace(with: "first\nsecond\nthird")
    XCTAssertEqual(storage.foldedPreview, "first\nsecond\nthird")
    XCTAssertTrue(storage.foldedPreviewNeedsFade)
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
      entries: [],
      service: DelayedStreamingService(chunks: chunks, delay: .zero),
      streamPresentationPolicy: .fastTests
    )

    await model.process(text: "Draft")

    XCTAssertEqual(model.entries.last?.result, chunks.joined())
    XCTAssertLessThan(model.streamPresentationUpdateCount, chunks.count)
    XCTAssertLessThan(model.historyScrollRevision, model.streamPresentationUpdateCount)
  }

  func testLegacySettingsDecodeWithTheOfficialOpenAIEndpoint() throws {
    let data = Data(
      #"{"provider":"OpenAI","apiKey":"","model":"gpt-5","translationPrompt":"translate","improvementPrompt":"improve","launchAtLogin":false}"#
        .utf8
    )

    let settings = try JSONDecoder().decode(CidaSettings.self, from: data)

    XCTAssertEqual(settings.openAIEndpoint, CidaSettings.officialOpenAIEndpoint)
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
      entries: [],
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
      entries: [],
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
      entries: [],
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

  func testLargeHistoryScrollReportCarriesTheSustainedUpwardWorkload() {
    let timestamps = (0..<1_440).map { Double($0) / 120 }

    let report = FramePacingProbeNSView.makeReport(
      timestamps: timestamps,
      maximumFramesPerSecond: 120,
      interactionCount: 1_200,
      requiredSampleCount: 1_440,
      workload: FramePacingWorkload.largeHistoryScroll.description,
      requiredFramesPerSecond: 120,
      requiresZeroMissedFrameBudgets: true,
      workloadCompleted: true,
      historyEntryCount: 1_000,
      scrollDistancePoints: 38_400
    )

    XCTAssertTrue(report.passed)
    XCTAssertEqual(report.historyEntryCount, 1_000)
    XCTAssertEqual(report.scrollDistancePoints, 38_400)
    XCTAssertEqual(report.interactionCount, 1_200)
    XCTAssertEqual(report.missedFrameBudgetCount, 0)
  }

  func testOlderHistoryPageApplicationWaitsUntilLiveScrollEnds() async throws {
    let initialEntry = HistoryEntry(
      mode: .translate,
      source: "Newest source",
      result: "Newest result",
      detail: "中文 → English",
      timestamp: "18:00"
    )
    let olderEntry = HistoryEntry(
      mode: .translate,
      source: "Older source",
      result: "Older result",
      detail: "中文 → English",
      timestamp: "17:59"
    )
    let loader = CountingHistoryPageLoader(
      page: HistoryPage(
        entries: [olderEntry],
        oldestSortOrder: 0,
        totalCount: 2,
        hasMoreBefore: false
      )
    )
    let model = AppModel(
      entries: [initialEntry],
      historyPageLoader: loader,
      historyTotalCount: 2,
      historyOldestSortOrder: 1,
      historyHasMoreBefore: true,
      historyPageSize: 128
    )

    model.historyDidLiveScroll()
    model.loadOlderHistoryIfNeeded()
    try await Task.sleep(for: .milliseconds(200))

    XCTAssertEqual(loader.loadCount, 0)
    XCTAssertEqual(model.entries.map(\.id), [initialEntry.id])

    model.historyDidEndLiveScroll()
    try await waitUntil {
      loader.loadCount == 1 && model.entries.map(\.id) == [olderEntry.id, initialEntry.id]
    }
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

private final class CountingHistoryPageLoader: HistoryPageLoading, @unchecked Sendable {
  private let lock = NSLock()
  private let page: HistoryPage
  private var count = 0

  init(page: HistoryPage) {
    self.page = page
  }

  var loadCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func loadBefore(sortOrder: Int64, limit: Int) throws -> HistoryPage {
    lock.lock()
    count += 1
    lock.unlock()
    return page
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

private struct DelayedStreamingService: TextProcessingService {
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
