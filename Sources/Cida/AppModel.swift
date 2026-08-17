import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI

protocol TextProcessingService: Sendable {
  func stream(
    _ request: ProcessingRequest,
    settings: CidaSettings
  ) -> AsyncThrowingStream<String, Error>
}

struct HistoryRenderPage: Identifiable, Sendable {
  let id: UUID
  let entries: [HistoryEntry]

  init(entries: [HistoryEntry]) {
    self.entries = entries
    id = entries.first?.id ?? UUID()
  }
}

#if DEBUG
  struct PreviewTextProcessingService: TextProcessingService {
    func stream(
      _ request: ProcessingRequest,
      settings: CidaSettings
    ) -> AsyncThrowingStream<String, Error> {
      AsyncThrowingStream { continuation in
        let task = Task {
          do {
            try await Task.sleep(for: .milliseconds(80))
            let result =
              switch request.mode {
              case .translate:
                translate(request.text, target: request.targetLanguage)
              case .improve:
                improve(request.text)
              }

            for chunk in result.chunked(maxLength: 14) {
              try Task.checkCancellation()
              continuation.yield(chunk)
              try await Task.sleep(for: .milliseconds(22))
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }

    private func translate(_ text: String, target: Language) -> String {
      let knownTranslations: [String: String] = [
        "缓存失效是计算机科学中的两大难题之一。":
          "Cache invalidation is one of the two hard problems in computer science.",
        "我们的系统采用了全新的存储引擎,在保证数据一致性的前提下,显著提升了读写性能。":
          "Our system adopts a brand-new storage engine that significantly improves\nread and write performance while preserving data consistency.",
      ]

      if let translation = knownTranslations[text] {
        return translation
      }

      switch target {
      case .english:
        return "English translation preview: \(text)"
      case .chinese:
        return "中文翻译预览：\(text)"
      }
    }

    private func improve(_ text: String) -> String {
      let knownImprovements: [String: String] = [
        "This feature are very useful for user, it can makes the process more faster and easy to use.":
          "This feature is very useful — it makes the whole process faster and easier to use.",
        "这个功能通过复用已有的缓存结果,使得整体的处理流程在大多数的情况下都能够得到比较明显的加速。": "通过复用已有缓存结果，该功能可在大多数情况下显著加速整体处理流程。",
      ]

      return knownImprovements[text] ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
#endif

struct OpenAICompatibleTextProcessingService: TextProcessingService {
  func stream(
    _ request: ProcessingRequest,
    settings: CidaSettings
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .utility) {
        do {
          let urlRequest = try makeRequest(for: request, settings: settings)
          let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
          guard let response = response as? HTTPURLResponse else {
            throw TextProcessingError.invalidResponse
          }

          guard (200..<300).contains(response.statusCode) else {
            let data = try await bytes.collectData()
            let apiError = try? JSONDecoder().decode(ChatCompletionErrorResponse.self, from: data)
            throw TextProcessingError.apiError(
              statusCode: response.statusCode,
              message: apiError?.error.message
            )
          }

          if response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains("text/event-stream") == true
          {
            try await forwardServerSentEvents(bytes, to: continuation)
          } else {
            let data = try await bytes.collectData()
            let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let content = completion.choices.first?.message.content, !content.isEmpty else {
              throw TextProcessingError.emptyResult
            }
            continuation.yield(content)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func makeRequest(
    for request: ProcessingRequest,
    settings: CidaSettings
  ) throws -> URLRequest {
    let endpoint: URL
    switch settings.provider {
    case .deepSeek:
      endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    case .openAI:
      let value = settings.openAIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        let candidate = URL(string: value),
        let scheme = candidate.scheme?.lowercased(),
        ["http", "https"].contains(scheme),
        candidate.host != nil
      else {
        throw TextProcessingError.invalidEndpoint
      }
      endpoint = candidate
    }

    guard !settings.apiKey.isEmpty || settings.usesLocalOpenAIEndpoint else {
      throw TextProcessingError.missingAPIKey
    }

    let prompt = try ModelPromptBuilder.build(request: request, settings: settings)
    let body = ChatCompletionRequest(
      model: settings.model,
      messages: [
        ChatMessage(role: "system", content: prompt.systemMessage),
        ChatMessage(role: "user", content: prompt.userMessage),
      ],
      stream: true
    )

    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = 300
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    if !settings.apiKey.isEmpty {
      urlRequest.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
    }
    urlRequest.httpBody = try JSONEncoder().encode(body)
    return urlRequest
  }

  private func forwardServerSentEvents(
    _ bytes: URLSession.AsyncBytes,
    to continuation: AsyncThrowingStream<String, Error>.Continuation
  ) async throws {
    for try await line in bytes.lines {
      try Task.checkCancellation()
      guard line.hasPrefix("data:") else { continue }
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
      guard payload != "[DONE]" else { return }
      guard let data = payload.data(using: .utf8) else { continue }
      let event = try JSONDecoder().decode(ChatCompletionStreamResponse.self, from: data)
      if let content = event.choices.first?.delta.content, !content.isEmpty {
        continuation.yield(content)
      }
    }
  }
}

enum TextProcessingError: LocalizedError {
  case missingAPIKey
  case invalidEndpoint
  case invalidRequest
  case invalidResponse
  case apiError(statusCode: Int, message: String?)
  case emptyResult

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      "请先在设置中填写 API Key。"
    case .invalidEndpoint:
      "OpenAI Endpoint 不是有效的 HTTP 或 HTTPS 地址。"
    case .invalidRequest:
      "无法构造模型请求。"
    case .invalidResponse:
      "模型服务返回了无效响应。"
    case .apiError(let statusCode, let message):
      message ?? "模型服务请求失败（HTTP \(statusCode)）。"
    case .emptyResult:
      "模型服务没有返回文本。"
    }
  }
}

private struct ChatCompletionRequest: Encodable {
  let model: String
  let messages: [ChatMessage]
  let stream: Bool
}

private struct ChatMessage: Codable {
  let role: String
  let content: String
}

private struct ChatCompletionResponse: Decodable {
  struct Choice: Decodable {
    let message: ChatMessage
  }

  let choices: [Choice]
}

private struct ChatCompletionStreamResponse: Decodable {
  struct Choice: Decodable {
    struct Delta: Decodable {
      let content: String?
    }

    let delta: Delta
  }

  let choices: [Choice]
}

private struct ChatCompletionErrorResponse: Decodable {
  struct APIError: Decodable {
    let message: String
  }

  let error: APIError
}

extension URLSession.AsyncBytes {
  fileprivate func collectData() async throws -> Data {
    var data = Data()
    for try await byte in self {
      data.append(byte)
    }
    return data
  }
}

extension String {
  fileprivate func chunked(maxLength: Int) -> [String] {
    guard !isEmpty else { return [] }
    var chunks: [String] = []
    var start = startIndex
    while start < endIndex {
      let end = index(start, offsetBy: maxLength, limitedBy: endIndex) ?? endIndex
      chunks.append(String(self[start..<end]))
      start = end
    }
    return chunks
  }
}

@MainActor
@Observable
final class AppModel {
  var mode: ProcessingMode
  var sourceLanguage: Language = .chinese
  var targetLanguage: Language = .english
  var inputText: String
  var entries: [HistoryEntry] {
    didSet {
      synchronizeEntriesAfterMutation(previousEntries: oldValue)
    }
  }
  private(set) var persistedHistoryEntries: [HistoryEntry]
  private(set) var persistedHistoryPages: [HistoryRenderPage]
  private(set) var sessionHistoryEntries: [HistoryEntry] = []
  private(set) var hasLongHistoryDocument: Bool
  private(set) var totalHistoryEntryCount: Int
  private(set) var hasOlderHistory: Bool
  private(set) var isLoadingOlderHistory = false
  var settings = CidaSettings()
  private(set) var generationState = GenerationPresentationState.idle
  var isProcessing: Bool {
    get { generationState.isActive }
    set {
      generationState =
        newValue
        ? .waiting(entryID: entries.last?.id ?? UUID())
        : .idle
    }
  }
  var errorMessage: String?
  var editingPrompt: ProcessingMode? = .improve
  var inputFocusRequestID = 0
  var inputResetRevision = 0
  var historyScrollRevision = 0
  private(set) var historyForcePinRevision = 0
  private var manuallyExpandedHistoryEntryIDs: Set<UUID> = []
  private(set) var automaticallyFoldingHistoryEntryID: UUID?

  private let service: any TextProcessingService
  private let streamPresentationPolicy: StreamPresentationPolicy
  private let historyPersistence: (any HistoryPersisting)?
  private let historyPageLoader: (any HistoryPageLoading)?
  private let historyPageSize: Int
  private let saveSettings: @MainActor (CidaSettings) -> Void
  private let clearPersistedAPIKey: @MainActor () -> Void
  private var processingTask: Task<Void, Never>?
  @ObservationIgnored private var automaticFoldCleanupTask: Task<Void, Never>?
  private var settingsSaveTask: Task<Void, Never>?
  private var olderHistoryLoadTask: Task<Void, Never>?
  @ObservationIgnored private var olderHistoryLoadRequestTask: Task<Void, Never>?
  @ObservationIgnored private var olderHistoryLoadWasRequested = false
  @ObservationIgnored private var isHistoryLiveScrolling = false
  private var lastPersistedAPIKey: String
  @ObservationIgnored private var stagedInputDocument: String?
  @ObservationIgnored private var stagedInputDocumentUTF16Count: Int?
  @ObservationIgnored private var stagedInputDocumentHasNonWhitespace: Bool?
  @ObservationIgnored private weak var displayLinkView: NSView?
  private var oldestLoadedHistorySortOrder: Int64?
  @ObservationIgnored private var suppressesEntrySynchronization = false
  private var performanceProbeStep = 0
  private var performancePresenter: SmoothStreamPresenter?
  private var lastHistoryFollowTimestamp = 0.0
  private(set) var streamPresentationUpdateCount = 0
  private(set) var maximumStreamPresentationCharacterCount = 0

  var unloadedHistoryEntryCount: Int {
    max(0, totalHistoryEntryCount - entries.count)
  }

  init(
    mode: ProcessingMode = .translate,
    inputText: String = "",
    entries: [HistoryEntry] = [],
    settings: CidaSettings = CidaSettings(),
    service: any TextProcessingService = OpenAICompatibleTextProcessingService(),
    streamPresentationPolicy: StreamPresentationPolicy = .production,
    historyPersistence: (any HistoryPersisting)? = nil,
    historyPageLoader: (any HistoryPageLoading)? = nil,
    historyTotalCount: Int? = nil,
    historyOldestSortOrder: Int64? = nil,
    historyHasMoreBefore: Bool = false,
    historyPageSize: Int = 128,
    saveSettings: @escaping @MainActor (CidaSettings) -> Void = { settings in
      SettingsStore.save(settings)
    },
    clearPersistedAPIKey: @escaping @MainActor () -> Void = {
      SettingsStore.clearAPIKey()
    }
  ) {
    self.mode = mode
    self.inputText = inputText
    self.entries = entries
    persistedHistoryEntries = entries
    persistedHistoryPages = entries.isEmpty ? [] : [HistoryRenderPage(entries: entries)]
    for entry in entries {
      entry.isLatestInHistory = false
    }
    entries.last?.isLatestInHistory = true
    hasLongHistoryDocument = entries.contains(where: \.isLongDocument)
    totalHistoryEntryCount = max(entries.count, historyTotalCount ?? entries.count)
    hasOlderHistory = historyHasMoreBefore
    self.settings = settings
    self.service = service
    self.streamPresentationPolicy = streamPresentationPolicy
    self.historyPersistence = historyPersistence
    self.historyPageLoader = historyPageLoader
    oldestLoadedHistorySortOrder = historyOldestSortOrder
    self.historyPageSize = max(1, historyPageSize)
    self.saveSettings = saveSettings
    self.clearPersistedAPIKey = clearPersistedAPIKey
    lastPersistedAPIKey = settings.apiKey
    _ = Self.timeFormatter.string(from: Date())
  }

  var modelStatus: String {
    settings.model
  }

  var outputHint: String {
    switch mode {
    case .translate:
      "\(sourceLanguage.title) → \(targetLanguage.title)"
    case .improve:
      ImprovementPresentation.composerHint(
        for: stagedInputDocument ?? inputText
      )
    }
  }

  func setMode(_ newMode: ProcessingMode) {
    guard mode != newMode else { return }
    mode = newMode
  }

  func toggleMode() {
    setMode(mode == .translate ? .improve : .translate)
  }

  func swapLanguages() {
    (sourceLanguage, targetLanguage) = (targetLanguage, sourceLanguage)
  }

  func requestInputFocus() {
    inputFocusRequestID &+= 1
  }

  func attachDisplayLink(to view: NSView) {
    displayLinkView = view
  }

  func stageInputDocument(
    _ document: String?,
    utf16Count: Int? = nil,
    hasNonWhitespace: Bool? = nil
  ) {
    stagedInputDocument = document
    stagedInputDocumentUTF16Count = document.map { utf16Count ?? $0.utf16.count }
    stagedInputDocumentHasNonWhitespace = document.map {
      hasNonWhitespace
        ?? (($0 as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted).location
          != NSNotFound)
    }
  }

  var inputDocumentUTF16Count: Int {
    stagedInputDocumentUTF16Count ?? inputText.utf16.count
  }

  @discardableResult
  func submit() -> Bool {
    let requestText = stagedInputDocument ?? inputText
    let requestCharacterCount = stagedInputDocumentUTF16Count ?? requestText.utf16.count
    let hasNonWhitespace =
      stagedInputDocumentHasNonWhitespace
      ?? ((requestText as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
        .location
        != NSNotFound)
    guard
      hasNonWhitespace,
      !isProcessing
    else {
      return false
    }
    stageInputDocument(nil)
    inputResetRevision &+= 1
    inputText = ""
    processingTask?.cancel()
    let request = ProcessingRequest(
      text: requestText,
      mode: mode,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage
    )
    let entryID = beginGeneration(
      request: request,
      reportedSourceCharacterCount: requestCharacterCount
    )
    processingTask = Task { [weak self] in
      await self?.runGeneration(request: request, entryID: entryID)
    }
    return true
  }

  func cancelProcessing() {
    processingTask?.cancel()
  }

  func redo(_ entry: HistoryEntry) {
    guard !isProcessing else { return }
    setMode(entry.mode)
    processingTask?.cancel()
    let request = ProcessingRequest(
      text: entry.source,
      mode: entry.mode,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage
    )
    let entryID = beginGeneration(
      request: request,
      reportedSourceCharacterCount: entry.reportedSourceCharacterCount
    )
    processingTask = Task { [weak self] in
      await self?.runGeneration(request: request, entryID: entryID)
    }
  }

  func copyResult(_ entry: HistoryEntry) {
    copyToPasteboard(entry.result)
  }

  func copySource(_ entry: HistoryEntry) {
    copyToPasteboard(entry.source)
  }

  @discardableResult
  func copyLatestResult() -> Bool {
    guard let latestCopyableResult else { return false }
    copyToPasteboard(latestCopyableResult)
    return true
  }

  var latestCopyableResult: String? {
    entries.last(where: {
      $0.state != .streaming && $0.resultUTF16Length > 0
    })?.result
  }

  func isHistoryEntryExpanded(_ entryID: UUID) -> Bool {
    entryID == entries.last?.id || manuallyExpandedHistoryEntryIDs.contains(entryID)
  }

  func isHistoryEntryExpanded(_ entry: HistoryEntry) -> Bool {
    entry.isLatestInHistory || manuallyExpandedHistoryEntryIDs.contains(entry.id)
  }

  func isHistoryEntryManuallyExpanded(_ entryID: UUID) -> Bool {
    manuallyExpandedHistoryEntryIDs.contains(entryID)
  }

  func expandHistoryEntry(_ entryID: UUID) {
    guard entryID != entries.last?.id, entries.contains(where: { $0.id == entryID }) else {
      return
    }
    manuallyExpandedHistoryEntryIDs.insert(entryID)
  }

  func collapseHistoryEntry(_ entryID: UUID) {
    guard entryID != entries.last?.id else { return }
    manuallyExpandedHistoryEntryIDs.remove(entryID)
  }

  private func copyToPasteboard(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
  }

  func resetImprovementPrompt() {
    settings.improvementPrompt = CidaSettings().improvementPrompt
  }

  func resetTranslationPrompt() {
    settings.translationPrompt = CidaSettings().translationPrompt
  }

  func persistSettings() {
    settingsSaveTask?.cancel()
    persist(settings)
  }

  func flushHistoryPersistence() {
    historyPersistence?.flush()
  }

  func scheduleSettingsPersistence() {
    settingsSaveTask?.cancel()
    let settings = settings
    let saveSettings = saveSettings
    let clearPersistedAPIKey = clearPersistedAPIKey
    let shouldClearAPIKey = settings.apiKey.isEmpty && !lastPersistedAPIKey.isEmpty
    settingsSaveTask = Task {
      do {
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
        if shouldClearAPIKey {
          clearPersistedAPIKey()
        }
        saveSettings(settings)
        self.lastPersistedAPIKey = settings.apiKey
      } catch {
        return
      }
    }
  }

  private func persist(_ settings: CidaSettings) {
    if settings.apiKey.isEmpty, !lastPersistedAPIKey.isEmpty {
      clearPersistedAPIKey()
    }
    saveSettings(settings)
    lastPersistedAPIKey = settings.apiKey
  }

  func selectProvider(_ provider: ModelProvider) {
    settings.provider = provider
    settings.model = provider.models[0]
  }

  func restorePersistedAPIKey(_ apiKey: String) {
    guard settings.apiKey.isEmpty, !apiKey.isEmpty else { return }
    settings.apiKey = apiKey
    lastPersistedAPIKey = apiKey
  }

  func refreshLaunchAtLoginStatus() {
    guard Bundle.main.bundleURL.pathExtension == "app" else { return }
    settings.launchAtLogin = SMAppService.mainApp.status == .enabled
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
      settings.launchAtLogin = enabled
      return
    }

    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      settings.launchAtLogin = SMAppService.mainApp.status == .enabled
      errorMessage = nil
    } catch {
      settings.launchAtLogin = SMAppService.mainApp.status == .enabled
      errorMessage = "无法更新开机启动设置：\(error.localizedDescription)"
    }
  }

  func process(
    text: String,
    reportedSourceCharacterCount: Int? = nil,
    clearInput: Bool = true
  ) async {
    let request = ProcessingRequest(
      text: text,
      mode: mode,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage
    )
    let entryID = beginGeneration(
      request: request,
      reportedSourceCharacterCount: reportedSourceCharacterCount
    )
    if clearInput, stagedInputDocument != nil || !inputText.isEmpty {
      stageInputDocument(nil)
      inputResetRevision &+= 1
      inputText = ""
    }
    await runGeneration(request: request, entryID: entryID)
  }

  private func beginGeneration(
    request: ProcessingRequest,
    reportedSourceCharacterCount: Int?
  ) -> UUID {
    errorMessage = nil
    let entryID = UUID()
    generationState = .waiting(entryID: entryID)
    let entry = HistoryEntry(
      id: entryID,
      mode: request.mode,
      source: request.text,
      result: "",
      detail: request.mode == .translate
        ? "\(request.sourceLanguage.title) → \(request.targetLanguage.title)"
        : ImprovementPresentation.historyDetail(for: request.text),
      timestamp: Self.timeFormatter.string(from: Date()),
      reportedSourceCharacterCount: reportedSourceCharacterCount ?? request.text.utf16.count,
      state: .streaming
    )
    entries.append(entry)
    if entry.isLongDocument {
      hasLongHistoryDocument = true
    }
    historyPersistence?.insert(HistoryPersistenceRecord(entry))
    requestHistoryFollow()
    return entryID
  }

  private func runGeneration(
    request: ProcessingRequest,
    entryID: UUID
  ) async {
    let latencyActivity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .latencyCritical],
      reason: "Presenting a streamed response"
    )
    defer {
      ProcessInfo.processInfo.endActivity(latencyActivity)
    }
    let presenter = makeStreamPresenter(for: entryID)
    let presentationTask = Task { @MainActor in
      try await presenter.run()
    }

    do {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        for try await chunk in service.stream(request, settings: settings) {
          try Task.checkCancellation()
          presenter.append(chunk)
        }

        try Task.checkCancellation()
        guard presenter.receivedContent else {
          throw TextProcessingError.emptyResult
        }
        presenter.finishInput()
        try await presentationTask.value
        try Task.checkCancellation()
      } onCancel: {
        presentationTask.cancel()
      }

      persistState(.completed, for: entryID)
      requestHistoryFollow(force: false, allowsThrottling: false)
    } catch is CancellationError {
      presentationTask.cancel()
      persistState(.cancelled, for: entryID)
      requestHistoryFollow(force: false, allowsThrottling: false)
    } catch {
      presentationTask.cancel()
      persistState(.failed, for: entryID)
      errorMessage = error.localizedDescription
      requestHistoryFollow(force: false, allowsThrottling: false)
    }

    if generationState.entryID == entryID {
      generationState = .idle
    }
    processingTask = nil
  }

  private func makeStreamPresenter(for entryID: UUID) -> SmoothStreamPresenter {
    SmoothStreamPresenter(
      policy: streamPresentationPolicy,
      displayLinkView: displayLinkView
    ) { [weak self] delta in
      self?.publish(delta, to: entryID)
    }
  }

  private func publish(_ delta: String, to entryID: UUID) {
    guard
      updateEntry(
        entryID,
        update: {
          $0.appendPresentationDelta(delta)
        })
    else { return }
    if generationState == .waiting(entryID: entryID) {
      generationState = .revealing(entryID: entryID)
    }
    historyPersistence?.appendResult(entryID: entryID, delta: delta)
    streamPresentationUpdateCount &+= 1
    maximumStreamPresentationCharacterCount = max(
      maximumStreamPresentationCharacterCount,
      delta.count
    )
  }

  @discardableResult
  private func updateEntry(
    _ entryID: UUID,
    update: (HistoryEntry) -> Void
  ) -> Bool {
    let entry: HistoryEntry
    if let latest = entries.last, latest.id == entryID {
      entry = latest
    } else if let existing = entries.first(where: { $0.id == entryID }) {
      entry = existing
    } else {
      return false
    }
    update(entry)
    if !hasLongHistoryDocument, entry.isLongDocument {
      hasLongHistoryDocument = true
    }
    return true
  }

  func replaceHistoryEntries(_ entries: [HistoryEntry]) {
    olderHistoryLoadTask?.cancel()
    olderHistoryLoadRequestTask?.cancel()
    olderHistoryLoadWasRequested = false
    isHistoryLiveScrolling = false
    automaticFoldCleanupTask?.cancel()
    automaticallyFoldingHistoryEntryID = nil
    suppressesEntrySynchronization = true
    self.entries = entries
    suppressesEntrySynchronization = false
    persistedHistoryEntries = entries
    persistedHistoryPages = entries.isEmpty ? [] : [HistoryRenderPage(entries: entries)]
    sessionHistoryEntries = []
    for entry in entries {
      entry.isLatestInHistory = false
    }
    entries.last?.isLatestInHistory = true
    hasLongHistoryDocument = entries.contains(where: \.isLongDocument)
    totalHistoryEntryCount = entries.count
    hasOlderHistory = false
    isLoadingOlderHistory = false
    oldestLoadedHistorySortOrder = nil
  }

  func loadOlderHistoryIfNeeded() {
    guard
      hasOlderHistory,
      let historyPageLoader,
      let oldestLoadedHistorySortOrder
    else {
      return
    }

    olderHistoryLoadWasRequested = true
    scheduleOlderHistoryLoadAfterScrollingSettles(
      historyPageLoader: historyPageLoader,
      oldestLoadedHistorySortOrder: oldestLoadedHistorySortOrder
    )
  }

  func historyDidLiveScroll() {
    isHistoryLiveScrolling = true
    olderHistoryLoadRequestTask?.cancel()
    olderHistoryLoadRequestTask = nil
  }

  func historyDidEndLiveScroll() {
    isHistoryLiveScrolling = false
    guard
      let historyPageLoader,
      let oldestLoadedHistorySortOrder
    else {
      return
    }
    scheduleOlderHistoryLoadAfterScrollingSettles(
      historyPageLoader: historyPageLoader,
      oldestLoadedHistorySortOrder: oldestLoadedHistorySortOrder
    )
  }

  private func scheduleOlderHistoryLoadAfterScrollingSettles(
    historyPageLoader: any HistoryPageLoading,
    oldestLoadedHistorySortOrder: Int64
  ) {
    guard
      olderHistoryLoadWasRequested,
      !isHistoryLiveScrolling,
      !isLoadingOlderHistory
    else {
      return
    }

    olderHistoryLoadRequestTask?.cancel()
    olderHistoryLoadRequestTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(120))
      guard
        !Task.isCancelled,
        let self,
        self.olderHistoryLoadWasRequested,
        !self.isHistoryLiveScrolling,
        !self.isLoadingOlderHistory
      else {
        return
      }
      self.olderHistoryLoadRequestTask = nil
      self.startOlderHistoryLoad(
        historyPageLoader: historyPageLoader,
        oldestLoadedHistorySortOrder: oldestLoadedHistorySortOrder
      )
    }
  }

  private func startOlderHistoryLoad(
    historyPageLoader: any HistoryPageLoading,
    oldestLoadedHistorySortOrder: Int64
  ) {
    guard
      olderHistoryLoadWasRequested,
      !isHistoryLiveScrolling,
      !isLoadingOlderHistory,
      hasOlderHistory
    else {
      return
    }

    olderHistoryLoadWasRequested = false
    isLoadingOlderHistory = true
    let pageSize = historyPageSize
    olderHistoryLoadTask = Task { [weak self] in
      defer {
        self?.isLoadingOlderHistory = false
        self?.olderHistoryLoadTask = nil
      }
      do {
        let page = try await Task.detached(priority: .utility) {
          try historyPageLoader.loadBefore(
            sortOrder: oldestLoadedHistorySortOrder,
            limit: pageSize
          )
        }.value
        try Task.checkCancellation()
        guard let self else { return }
        self.suppressesEntrySynchronization = true
        self.entries.insert(contentsOf: page.entries, at: 0)
        self.suppressesEntrySynchronization = false
        self.persistedHistoryEntries.insert(contentsOf: page.entries, at: 0)
        if !page.entries.isEmpty {
          self.persistedHistoryPages.insert(HistoryRenderPage(entries: page.entries), at: 0)
        }
        self.oldestLoadedHistorySortOrder = page.oldestSortOrder
        self.totalHistoryEntryCount = max(self.totalHistoryEntryCount, page.totalCount)
        self.hasOlderHistory = page.hasMoreBefore
        if !self.hasLongHistoryDocument, page.entries.contains(where: \.isLongDocument) {
          self.hasLongHistoryDocument = true
        }
      } catch is CancellationError {
        return
      } catch {
        fputs("Failed to load an older history page: \(error)\n", stderr)
      }
    }
  }

  private func synchronizeEntriesAfterMutation(previousEntries: [HistoryEntry]) {
    guard !suppressesEntrySynchronization else { return }

    let preservesExistingPrefix =
      previousEntries.count <= entries.count
      && zip(previousEntries, entries).allSatisfy { previous, current in
        previous === current
      }
    guard preservesExistingPrefix else {
      automaticFoldCleanupTask?.cancel()
      automaticallyFoldingHistoryEntryID = nil
      persistedHistoryEntries = entries
      persistedHistoryPages = entries.isEmpty ? [] : [HistoryRenderPage(entries: entries)]
      sessionHistoryEntries = []
      totalHistoryEntryCount = entries.count
      hasOlderHistory = false
      oldestLoadedHistorySortOrder = nil
      for entry in entries {
        entry.isLatestInHistory = false
      }
      entries.last?.isLatestInHistory = true
      hasLongHistoryDocument = entries.contains(where: \.isLongDocument)
      return
    }

    let appendedEntries = entries.dropFirst(previousEntries.count)
    guard !appendedEntries.isEmpty else { return }
    if previousEntries.last?.isLatestInHistory == true {
      beginAutomaticFold(of: previousEntries.last)
    }
    for entry in appendedEntries {
      entry.isLatestInHistory = false
    }
    if entries.last?.isLatestInHistory == false {
      entries.last?.isLatestInHistory = true
    }
    sessionHistoryEntries.append(contentsOf: appendedEntries)
    totalHistoryEntryCount += appendedEntries.count
    if !hasLongHistoryDocument, appendedEntries.contains(where: \.isLongDocument) {
      hasLongHistoryDocument = true
    }
  }

  private func beginAutomaticFold(of entry: HistoryEntry?) {
    guard let entry, entry.isLatestInHistory else { return }
    // Preserve the standalone segment before clearing the latest marker. If
    // these mutations happen in the opposite order SwiftUI briefly replaces
    // the expanded entry with a virtualized row, only to rebuild it again in
    // the same submission preflight.
    automaticallyFoldingHistoryEntryID = entry.id
    entry.isLatestInHistory = false
    automaticFoldCleanupTask?.cancel()
    automaticFoldCleanupTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(CidaMotion.historyFoldMilliseconds))
      guard !Task.isCancelled, self?.automaticallyFoldingHistoryEntryID == entry.id else {
        return
      }
      self?.automaticallyFoldingHistoryEntryID = nil
      self?.automaticFoldCleanupTask = nil
    }
  }

  private func persistState(_ state: HistoryEntryState, for entryID: UUID) {
    guard updateEntry(entryID, update: { $0.state = state }) else { return }
    historyPersistence?.updateState(entryID: entryID, state: state)
  }

  func requestHistoryFollow(force: Bool = true, allowsThrottling: Bool = true) {
    let now = ProcessInfo.processInfo.systemUptime
    guard force || !allowsThrottling || now - lastHistoryFollowTimestamp >= 0.05 else { return }
    lastHistoryFollowTimestamp = now
    if force {
      historyForcePinRevision &+= 1
    }
    historyScrollRevision &+= 1
  }

  @discardableResult
  func exercisePerformanceWorkload(
    frameTick: Int,
    elapsedSeconds: Double
  ) -> Bool {
    if performancePresenter == nil {
      let entryID = UUID()
      isProcessing = true
      entries.append(
        HistoryEntry(
          id: entryID,
          mode: mode,
          source: String(repeating: "Large streaming source paragraph. ", count: 120),
          result: "",
          detail: "Performance probe",
          timestamp: "",
          state: .streaming
        )
      )
      let presenter = makeStreamPresenter(for: entryID)
      performancePresenter = presenter
    }

    guard let performancePresenter else { return false }
    guard frameTick.isMultiple(of: 4) else {
      performancePresenter.presentForExternalDisplayPulse(elapsedSeconds: elapsedSeconds)
      return false
    }
    performanceProbeStep &+= 1
    let chunk: String
    switch performanceProbeStep % 10 {
    case 1, 2:
      chunk = performanceProbeStep.isMultiple(of: 2) ? "字" : "A"
    case 5:
      chunk = String(repeating: " backend burst arrives unevenly;", count: 72)
    case 6:
      chunk = "."
    case 8:
      chunk = String(repeating: " smooth stream", count: 28)
    case 0:
      chunk = " response continues"
    default:
      performancePresenter.presentForExternalDisplayPulse(elapsedSeconds: elapsedSeconds)
      return false
    }
    performancePresenter.append(chunk)
    performancePresenter.presentForExternalDisplayPulse(elapsedSeconds: elapsedSeconds)
    return true
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    return formatter
  }()
}
