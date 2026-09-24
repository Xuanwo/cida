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
    guard let endpoint = settings.resolvedEndpoint else {
      throw TextProcessingError.invalidEndpoint
    }
    guard !settings.apiKey.isEmpty || settings.usesLocalEndpoint else {
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
  /// The action the next ⏎ runs. It resets to `.translate` every time the
  /// panel is shown (see `PanelController`).
  var mode: ProcessingMode
  var inputText: String
  /// The one result the panel shows. A new submission replaces it; hiding the
  /// panel keeps it.
  private(set) var result: ResultRecord?
  var settings = CidaSettings()
  private(set) var generationState = GenerationPresentationState.idle
  var isProcessing: Bool {
    generationState.isActive
  }
  /// Errors from Settings actions (launch at login); request failures live
  /// on the result record instead.
  var errorMessage: String?
  /// The prompt whose sheet is open in Settings; at most one at a time.
  var editingPrompt: ProcessingMode?
  var inputFocusRequestID = 0
  /// Bumped when the whole source should be selected, e.g. when the panel is
  /// shown again with the previous text still in it.
  var inputSelectAllRequestID = 0
  /// Bumped when the model replaces the whole source (a selection brought in
  /// by the global shortcut); the editor then drops whatever it holds,
  /// including a large virtual document.
  private(set) var inputReplacementRevision = 0
  /// Whether the Accessibility permission lets the global shortcut read the
  /// frontmost application's selection.
  private(set) var isSelectionAccessGranted: Bool
  /// Bumped when the result pane should scroll to the tail of the result.
  private(set) var resultFollowRevision = 0
  private(set) var copyFeedbackRevision = 0

  private let service: any TextProcessingService
  private let streamPresentationPolicy: StreamPresentationPolicy
  private let saveSettings: @MainActor (CidaSettings) -> Void
  private let applyGlobalShortcut: @MainActor (GlobalShortcut) -> Bool
  /// The Settings chip is waiting for the next key press.
  var isRecordingShortcut = false
  private let clearPersistedAPIKey: @MainActor () -> Void
  private let selectionAccess: SelectionAccess
  /// The selection the global shortcut brought in last; the same selection
  /// again leaves the panel as it is.
  @ObservationIgnored private var lastImportedSelection: String?
  private var processingTask: Task<Void, Never>?
  private var settingsSaveTask: Task<Void, Never>?
  private var lastPersistedAPIKey: String
  @ObservationIgnored private var stagedInputDocument: String?
  @ObservationIgnored private var stagedInputDocumentUTF16Count: Int?
  @ObservationIgnored private var stagedInputDocumentHasNonWhitespace: Bool?
  @ObservationIgnored private weak var displayLinkView: NSView?
  private var performanceProbeStep = 0
  private var performancePresenter: SmoothStreamPresenter?
  private var lastResultFollowTimestamp = 0.0
  private(set) var streamPresentationUpdateCount = 0
  private(set) var maximumStreamPresentationCharacterCount = 0

  init(
    mode: ProcessingMode = .translate,
    inputText: String = "",
    result: ResultRecord? = nil,
    settings: CidaSettings = CidaSettings(),
    service: any TextProcessingService = OpenAICompatibleTextProcessingService(),
    streamPresentationPolicy: StreamPresentationPolicy = .production,
    saveSettings: @escaping @MainActor (CidaSettings) -> Void = { settings in
      SettingsStore.save(settings)
    },
    clearPersistedAPIKey: @escaping @MainActor () -> Void = {
      SettingsStore.clearAPIKey()
    },
    applyGlobalShortcut: @escaping @MainActor (GlobalShortcut) -> Bool = { _ in true },
    selectionAccess: SelectionAccess = .system
  ) {
    self.mode = mode
    self.inputText = inputText
    self.result = result
    self.settings = settings
    self.service = service
    self.streamPresentationPolicy = streamPresentationPolicy
    self.saveSettings = saveSettings
    self.clearPersistedAPIKey = clearPersistedAPIKey
    self.applyGlobalShortcut = applyGlobalShortcut
    self.selectionAccess = selectionAccess
    isSelectionAccessGranted = selectionAccess.isGranted()
    lastPersistedAPIKey = settings.apiKey
  }

  var modelStatus: String {
    settings.model
  }

  /// The source language of the current input, detected from the text; the
  /// target is the other language of the supported pair.
  var detectedSourceLanguage: Language {
    TextLanguageDetector.detect(in: stagedInputDocument ?? inputText) ?? .chinese
  }

  static func targetLanguage(for source: Language) -> Language {
    source == .chinese ? .english : .chinese
  }

  func setMode(_ newMode: ProcessingMode) {
    guard mode != newMode else { return }
    mode = newMode
  }

  func toggleMode() {
    setMode(mode == .translate ? .improve : .translate)
  }

  /// Every appearance of the panel starts from the default action.
  func resetModeToDefault() {
    setMode(.translate)
  }

  func requestInputFocus() {
    inputFocusRequestID &+= 1
  }

  func requestInputSelectAll() {
    inputSelectAllRequestID &+= 1
  }

  func attachDisplayLink(to view: NSView) {
    displayLinkView = view
  }

  #if DEBUG
    func setGenerationStateForTesting(_ state: GenerationPresentationState) {
      generationState = state
    }

    func setResultForTesting(_ result: ResultRecord?) {
      self.result = result
    }
  #endif

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

  var currentInputDocument: String {
    stagedInputDocument ?? inputText
  }

  var hasSubmittableInput: Bool {
    stagedInputDocumentHasNonWhitespace
      ?? ((inputText as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
        .location != NSNotFound)
  }

  /// The result no longer matches what the panel would generate now: the
  /// source or the action changed after the result was produced.
  var isResultStale: Bool {
    guard let result, result.phase.isTerminal else { return false }
    if result.mode != mode { return true }
    if result.source.utf16.count != inputDocumentUTF16Count { return true }
    return result.source != currentInputDocument
  }

  /// The note under the result: a stale marker wins over the terminal notes
  /// because it describes what ⏎ will do next.
  var resultNote: ResultNote? {
    guard let result else { return nil }
    if isResultStale, result.phase == .completed { return .stale }
    return result.note
  }

  var canCopyResult: Bool {
    result?.isCopyable == true
  }

  /// ⏎: runs the current action on the current source. The source stays in
  /// the editor; the previous result is replaced immediately.
  @discardableResult
  func submit() -> Bool {
    guard hasSubmittableInput, !isProcessing else { return false }
    startGeneration()
    return true
  }

  /// The global shortcut's selection (Pencil `Spec — 面板模型` §一 带入选区).
  /// A new selection replaces the source and is translated at once,
  /// superseding a running request. The selection brought in last time
  /// leaves everything as it is, so the source edited since survives
  /// summoning the panel again. No selection forgets the last one, so
  /// selecting the same text again later brings it in again.
  /// Returns whether the selection was brought in.
  @discardableResult
  func importSelection(_ selection: String?) -> Bool {
    guard let selection else {
      lastImportedSelection = nil
      return false
    }
    guard selection != lastImportedSelection else { return false }
    lastImportedSelection = selection
    inputText = selection
    stageInputDocument(nil)
    inputReplacementRevision &+= 1
    setMode(.translate)
    startGeneration()
    return true
  }

  func refreshSelectionAccess() {
    let isGranted = selectionAccess.isGranted()
    if isSelectionAccessGranted != isGranted {
      isSelectionAccessGranted = isGranted
    }
  }

  func requestSelectionAccess() {
    selectionAccess.request()
    refreshSelectionAccess()
  }

  /// Runs the current action on the current source, cancelling any request
  /// still running; its record is no longer the result, so it finishes
  /// without touching the panel.
  private func startGeneration() {
    let requestText = currentInputDocument
    let requestCharacterCount = inputDocumentUTF16Count
    processingTask?.cancel()
    let sourceLanguage = TextLanguageDetector.detect(in: requestText) ?? .chinese
    let request = ProcessingRequest(
      text: requestText,
      mode: mode,
      sourceLanguage: sourceLanguage,
      targetLanguage: Self.targetLanguage(for: sourceLanguage)
    )
    let record = beginGeneration(
      request: request,
      reportedSourceCharacterCount: requestCharacterCount
    )
    processingTask = Task { [weak self] in
      await self?.runGeneration(request: request, record: record)
    }
  }

  func cancelProcessing() {
    processingTask?.cancel()
  }

  @discardableResult
  func copyResult() -> Bool {
    guard let result, result.isCopyable else { return false }
    copyToPasteboard(result.result)
    copyFeedbackRevision &+= 1
    return true
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

  /// Switching the provider starts from its first suggested model; a custom
  /// endpoint has no suggestions, so its model is typed in.
  func selectProvider(_ provider: ModelProvider) {
    settings.provider = provider
    settings.model = provider.suggestedModels.first ?? ""
  }

  func restorePersistedAPIKey(_ apiKey: String) {
    guard settings.apiKey.isEmpty, !apiKey.isEmpty else { return }
    settings.apiKey = apiKey
    lastPersistedAPIKey = apiKey
  }

  /// The combination is registered system-wide before it becomes the
  /// setting, so a combination the system or another application holds is
  /// refused and the current one keeps working.
  @discardableResult
  func setShortcut(_ shortcut: GlobalShortcut) -> Bool {
    guard shortcut != settings.shortcut else { return true }
    guard applyGlobalShortcut(shortcut) else { return false }
    settings.shortcut = shortcut
    return true
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

  /// Runs one request to completion; used by tests and probes that drive the
  /// model without the editor.
  func process(
    text: String,
    reportedSourceCharacterCount: Int? = nil
  ) async {
    inputText = text
    let sourceLanguage = TextLanguageDetector.detect(in: text) ?? .chinese
    let request = ProcessingRequest(
      text: text,
      mode: mode,
      sourceLanguage: sourceLanguage,
      targetLanguage: Self.targetLanguage(for: sourceLanguage)
    )
    let record = beginGeneration(
      request: request,
      reportedSourceCharacterCount: reportedSourceCharacterCount
    )
    await runGeneration(request: request, record: record)
  }

  private func beginGeneration(
    request: ProcessingRequest,
    reportedSourceCharacterCount: Int?
  ) -> ResultRecord {
    let record = ResultRecord(
      mode: request.mode,
      source: request.text,
      sourceCharacterCount: reportedSourceCharacterCount ?? request.text.utf16.count,
      outputLanguage: request.mode == .translate
        ? request.targetLanguage : request.sourceLanguage,
      phase: .streaming
    )
    generationState = .waiting(entryID: record.id)
    result = record
    requestResultFollow()
    return record
  }

  private func runGeneration(
    request: ProcessingRequest,
    record: ResultRecord
  ) async {
    let latencyActivity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .latencyCritical],
      reason: "Presenting a streamed response"
    )
    defer {
      ProcessInfo.processInfo.endActivity(latencyActivity)
    }
    let presenter = makeStreamPresenter(for: record)
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
      finish(record, phase: .completed)
    } catch is CancellationError {
      presentationTask.cancel()
      finish(record, phase: .stopped)
    } catch {
      presentationTask.cancel()
      finish(record, phase: .failed(message: error.localizedDescription))
    }

    // A superseded request must not clear the state or the task of the one
    // that replaced it.
    if generationState.entryID == record.id {
      generationState = .idle
      processingTask = nil
    }
  }

  private func finish(_ record: ResultRecord, phase: ResultPhase) {
    guard result === record else { return }
    record.phase = phase
    requestResultFollow(force: false, allowsThrottling: false)
  }

  private func makeStreamPresenter(for record: ResultRecord) -> SmoothStreamPresenter {
    SmoothStreamPresenter(
      policy: streamPresentationPolicy,
      displayLinkView: displayLinkView
    ) { [weak self] delta in
      self?.publish(delta, to: record)
    }
  }

  private func publish(_ delta: String, to record: ResultRecord) {
    guard result === record else { return }
    record.appendPresentationDelta(delta)
    if generationState == .waiting(entryID: record.id) {
      generationState = .revealing(entryID: record.id)
    }
    streamPresentationUpdateCount &+= 1
    maximumStreamPresentationCharacterCount = max(
      maximumStreamPresentationCharacterCount,
      delta.count
    )
    requestResultFollow(force: false)
  }

  /// Asks the result pane to keep the tail visible. Streaming updates are
  /// throttled; submissions force the pane back to the tail even after the
  /// user scrolled away.
  func requestResultFollow(force: Bool = true, allowsThrottling: Bool = true) {
    let now = ProcessInfo.processInfo.systemUptime
    guard force || !allowsThrottling || now - lastResultFollowTimestamp >= 0.05 else { return }
    lastResultFollowTimestamp = now
    resultFollowRevision &+= 1
  }

  @discardableResult
  func exercisePerformanceWorkload(
    frameTick: Int,
    elapsedSeconds: Double
  ) -> Bool {
    if performancePresenter == nil {
      let record = ResultRecord(
        mode: mode,
        source: String(repeating: "Large streaming source paragraph. ", count: 120),
        outputLanguage: .english,
        phase: .streaming
      )
      result = record
      generationState = .revealing(entryID: record.id)
      performancePresenter = makeStreamPresenter(for: record)
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
}
