import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI

#if DEBUG
  struct PreviewTextProcessingService: TextProcessingService {
    /// Design states show the welcome exactly when the real service would.
    func isConfigured(by settings: CidaSettings) -> Bool {
      settings.isModelServiceComplete
    }

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
                translate(
                  request.text,
                  target: TextLanguageDetector.typography(of: request.text) == .chinese
                    ? .english : .chinese)
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
  /// Whether the Screen Recording permission lets the capture shortcut
  /// freeze the screen.
  private(set) var isCaptureAccessGranted: Bool
  /// Bumped when the result pane should scroll to the tail of the result.
  private(set) var resultFollowRevision = 0
  private(set) var copyFeedbackRevision = 0
  /// What Cida is saying in the panel in place of the translation panes
  /// (`Design/spec/lifecycle.md` §一); the source, action and result wait underneath.
  private(set) var panelMessage: PanelMessage?
  @ObservationIgnored private var panelMessageHandler: PanelMessageHandler?
  /// ⏎ was pressed before a model service was configured (`Design/spec/lifecycle.md` §三).
  private(set) var showsConfigurationReminder = false
  #if DEBUG
    /// The settings-language-editing design state shows 常用外语 focused.
    @ObservationIgnored var focusesForeignLanguageForDesign = false
  #endif

  private let service: any TextProcessingService
  private let streamPresentationPolicy: StreamPresentationPolicy
  private let saveSettings: @MainActor (CidaSettings) -> Void
  private let applyGlobalShortcut: @MainActor (GlobalShortcut, GlobalShortcutAction) -> Bool
  private let suspendGlobalShortcuts: @MainActor (Bool) -> Void
  /// The Settings chip waiting for the next key press. While one records,
  /// every global shortcut is suspended so any combination reaches it.
  var recordingShortcut: GlobalShortcutAction? {
    didSet {
      if (oldValue == nil) != (recordingShortcut == nil) {
        suspendGlobalShortcuts(recordingShortcut != nil)
      }
    }
  }
  private let selectionAccess: SystemPermission
  private let captureAccess: SystemPermission
  /// The latest check, from Settings or the command line; it applies only while its
  /// fingerprint matches the configuration (`modelServiceStatus`).
  private(set) var lastModelServiceCheck: ModelServiceCheckRecord?
  private(set) var isCheckingModelService = false
  /// Three seconds after the command line changed the model service or checked it.
  private(set) var isModelServiceRecentlyUpdated = false
  /// The onboarding card says the prompt was copied until a configuration arrives.
  private(set) var hasCopiedConfigurationPrompt = false
  /// ✓ 已复制 on the copy button, for `CidaMotion.copiedHoldMilliseconds`.
  private(set) var isShowingConfigurationPromptCopied = false
  private let checkService: @Sendable (CidaSettings) async -> ModelServiceCheckResult
  private let recordCheck: @MainActor (ModelServiceCheckRecord) -> Void
  /// Where copying writes; tests pass a private pasteboard so the user's clipboard survives.
  private let pasteboard: NSPasteboard
  @ObservationIgnored private var configurationPromptFeedbackTask: Task<Void, Never>?
  @ObservationIgnored private var recentUpdateTask: Task<Void, Never>?
  /// The selection the global shortcut brought in last; the same selection
  /// again leaves the panel as it is.
  @ObservationIgnored private var lastImportedSelection: String?
  private var processingTask: Task<Void, Never>?
  private var settingsSaveTask: Task<Void, Never>?
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
    service: any TextProcessingService = ModelServiceClient(),
    streamPresentationPolicy: StreamPresentationPolicy = .production,
    saveSettings: @escaping @MainActor (CidaSettings) -> Void = { settings in
      SettingsStore.saveApplicationSettings(settings)
    },
    applyGlobalShortcut: @escaping @MainActor (GlobalShortcut, GlobalShortcutAction) -> Bool = {
      _, _ in true
    },
    suspendGlobalShortcuts: @escaping @MainActor (Bool) -> Void = { _ in },
    selectionAccess: SystemPermission = .accessibility,
    captureAccess: SystemPermission = .screenRecording,
    lastModelServiceCheck: ModelServiceCheckRecord? = nil,
    checkModelService: @escaping @Sendable (CidaSettings) async -> ModelServiceCheckResult = {
      await ModelServiceCheck.run(settings: $0)
    },
    recordModelServiceCheck: @escaping @MainActor (ModelServiceCheckRecord) -> Void = {
      SettingsStore.saveLastCheck($0)
    },
    pasteboard: NSPasteboard = .general
  ) {
    self.mode = mode
    self.inputText = inputText
    self.result = result
    self.settings = settings
    self.service = service
    self.streamPresentationPolicy = streamPresentationPolicy
    self.saveSettings = saveSettings
    self.applyGlobalShortcut = applyGlobalShortcut
    self.suspendGlobalShortcuts = suspendGlobalShortcuts
    self.selectionAccess = selectionAccess
    self.captureAccess = captureAccess
    self.lastModelServiceCheck = lastModelServiceCheck
    checkService = checkModelService
    recordCheck = recordModelServiceCheck
    self.pasteboard = pasteboard
    isSelectionAccessGranted = selectionAccess.isGranted()
    isCaptureAccessGranted = captureAccess.isGranted()
  }

  /// No request can be sent until a model service is configured; the empty panel welcomes the
  /// user instead (`Design/spec/lifecycle.md` §三).
  var needsModelConfiguration: Bool {
    !service.isConfigured(by: settings)
  }

  // MARK: - Panel messages

  /// Shows `message` in the panel, replacing any earlier message and its handler.
  func present(_ message: PanelMessage, handler: PanelMessageHandler) {
    panelMessage = message
    panelMessageHandler = handler
  }

  /// Changes the message on screen, if it is still the one of `kind`.
  func updatePanelMessage(kind: String, _ change: (inout PanelMessage) -> Void) {
    guard var message = panelMessage, message.kind == kind else { return }
    change(&message)
    panelMessage = message
  }

  func clearConfigurationReminder() {
    showsConfigurationReminder = false
  }

  /// Takes the message away without telling its owner, which already knows.
  func clearPanelMessage() {
    panelMessage = nil
    panelMessageHandler = nil
  }

  func selectPanelMessageChoice(_ index: Int) {
    guard var message = panelMessage, !message.isWorking, message.choices.indices.contains(index)
    else { return }
    message.selectedChoice = index
    panelMessage = message
  }

  /// Tab: the next choice, wrapping around.
  func selectNextPanelMessageChoice() {
    guard let message = panelMessage, message.choices.count > 1 else { return }
    selectPanelMessageChoice((message.selectedChoice + 1) % message.choices.count)
  }

  /// ⏎: performs the selected choice.
  func performPanelMessageChoice() {
    guard let message = panelMessage, !message.isWorking, let handler = panelMessageHandler
    else { return }
    handler.choose(message.selectedChoice)
  }

  /// ⌘.: stops the work the message shows.
  func stopPanelMessage() {
    guard panelMessage?.slot == .stop else { return }
    panelMessageHandler?.stop()
  }

  /// The panel went away while showing a message: the owner hears it as the last choice.
  func dismissPanelMessage() {
    guard let handler = panelMessageHandler else { return }
    clearPanelMessage()
    handler.dismiss()
  }

  func setMode(_ newMode: ProcessingMode) {
    guard mode != newMode else { return }
    mode = newMode
  }

  /// Tab: the other action. While a request runs the action choice is dimmed and
  /// cannot change (`Design/spec/panel.md` §三), so Tab does nothing.
  func toggleMode() {
    guard !isProcessing else { return }
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

  /// The global shortcut's selection (`Design/spec/panel.md` §一 带入选区).
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
    replaceSource(with: selection)
    startGeneration()
    return true
  }

  /// The whole source becomes `text`, with the default action; the editor
  /// drops whatever it held.
  private func replaceSource(with text: String) {
    inputText = text
    stageInputDocument(nil)
    inputReplacementRevision &+= 1
    setMode(.translate)
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

  func refreshCaptureAccess() {
    let isGranted = captureAccess.isGranted()
    if isCaptureAccessGranted != isGranted {
      isCaptureAccessGranted = isGranted
    }
  }

  func requestCaptureAccess() {
    captureAccess.request()
    refreshCaptureAccess()
  }

  /// Runs the current action on the current source, cancelling any request
  /// still running; its record is no longer the result, so it finishes
  /// without touching the panel.
  private func startGeneration() {
    guard !needsModelConfiguration else {
      processingTask?.cancel()
      showsConfigurationReminder = true
      return
    }
    showsConfigurationReminder = false
    let requestText = currentInputDocument
    let requestCharacterCount = inputDocumentUTF16Count
    processingTask?.cancel()
    let request = makeRequest(text: requestText)
    let record = beginGeneration(
      request: request,
      reportedSourceCharacterCount: requestCharacterCount
    )
    processingTask = Task { [weak self] in
      await self?.runGeneration(request: request, record: record)
    }
  }

  /// ⌘. and 停止: stops a message's work while one is shown, the request otherwise.
  func cancelProcessing() {
    if panelMessage != nil {
      stopPanelMessage()
      return
    }
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
    saveSettings(settings)
  }

  func scheduleSettingsPersistence() {
    settingsSaveTask?.cancel()
    let settings = settings
    let saveSettings = saveSettings
    settingsSaveTask = Task {
      do {
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
        saveSettings(settings)
      } catch {
        return
      }
    }
  }

  func restorePersistedAPIKey(_ apiKey: String) {
    guard settings.apiKey.isEmpty, !apiKey.isEmpty else { return }
    settings.apiKey = apiKey
  }

  // MARK: Model service (`Design/spec/configuration.md` §四)

  /// Whether requests can be sent. Settings shows the onboarding card and the panel its
  /// welcome until this is true.
  var isModelServiceConfigured: Bool {
    settings.isModelServiceComplete
  }

  /// The service row's status: a running check, then the latest check of this exact
  /// configuration, and 已就绪 for a complete configuration nobody has checked yet.
  var modelServiceStatus: ModelServiceStatus {
    if isCheckingModelService { return .checking }
    if let lastModelServiceCheck, !lastModelServiceCheck.passed,
      lastModelServiceCheck.fingerprint == settings.modelServiceFingerprint
    {
      return .failed(lastModelServiceCheck.failureSummary ?? "检查失败")
    }
    return .ready
  }

  /// The prompt 复制配置提示词 copies, with this executable's path and the current service.
  var configurationPrompt: String {
    ConfigurationPrompt.text(settings: settings)
  }

  func copyConfigurationPrompt() {
    copyToPasteboard(configurationPrompt)
    hasCopiedConfigurationPrompt = true
    isShowingConfigurationPromptCopied = true
    configurationPromptFeedbackTask?.cancel()
    configurationPromptFeedbackTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(CidaMotion.copiedHoldMilliseconds))
      guard !Task.isCancelled else { return }
      self?.isShowingConfigurationPromptCopied = false
    }
  }

  /// Runs the same request as `Cida check` and records the outcome where the command line
  /// reads it.
  func checkModelService() async {
    guard !isCheckingModelService, isModelServiceConfigured else { return }
    isCheckingModelService = true
    let result = await checkService(settings)
    recordCheck(result.record)
    lastModelServiceCheck = result.record
    isCheckingModelService = false
  }

  /// Takes what the command line wrote while Cida runs: the configuration, the key and the
  /// latest check, plus the preferences Settings shows. The status says 刚刚更新 for three
  /// seconds when the model service or its check changed.
  func applyExternalSettings(
    _ newSettings: CidaSettings, lastCheck: ModelServiceCheckRecord?
  ) {
    settingsSaveTask?.cancel()
    let serviceChanged =
      newSettings.modelService != settings.modelService || newSettings.apiKey != settings.apiKey
      || lastCheck != lastModelServiceCheck
    var everythingButShortcuts = newSettings
    everythingButShortcuts.shortcut = settings.shortcut
    everythingButShortcuts.captureShortcut = settings.captureShortcut
    settings = everythingButShortcuts
    // New combinations are registered like ones recorded in Settings.
    for action in GlobalShortcutAction.allCases {
      setShortcut(newSettings.shortcut(for: action), for: action)
    }
    lastModelServiceCheck = lastCheck
    if settings != newSettings {
      // A combination the system refused stays as it was, and so does the stored one.
      saveSettings(settings)
    }
    if isModelServiceConfigured { hasCopiedConfigurationPrompt = false }
    if serviceChanged { markModelServiceUpdated() }
  }

  private func markModelServiceUpdated() {
    isModelServiceRecentlyUpdated = true
    recentUpdateTask?.cancel()
    recentUpdateTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      self?.isModelServiceRecentlyUpdated = false
    }
  }

  #if DEBUG
    /// Freezes the model group in one of the board's states (`--design-state settings-config-*`).
    func setModelServiceStateForDesign(
      copied: Bool = false, recentlyUpdated: Bool = false, checking: Bool = false,
      lastCheck: ModelServiceCheckRecord? = nil
    ) {
      hasCopiedConfigurationPrompt = copied
      isShowingConfigurationPromptCopied = copied
      isModelServiceRecentlyUpdated = recentlyUpdated
      isCheckingModelService = checking
      lastModelServiceCheck = lastCheck
    }
  #endif

  /// The combination is registered system-wide before it becomes the
  /// setting, so a combination the system, another application or the other
  /// global shortcut holds is refused and the current one keeps working.
  @discardableResult
  func setShortcut(
    _ shortcut: GlobalShortcut,
    for action: GlobalShortcutAction = .showPanel
  ) -> Bool {
    guard shortcut != settings.shortcut(for: action) else { return true }
    let isHeldByAnotherAction = GlobalShortcutAction.allCases.contains {
      $0 != action && settings.shortcut(for: $0) == shortcut
    }
    guard !isHeldByAnotherAction, applyGlobalShortcut(shortcut, action) else { return false }
    settings.setShortcut(shortcut, for: action)
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
    let request = makeRequest(text: text)
    let record = beginGeneration(
      request: request,
      reportedSourceCharacterCount: reportedSourceCharacterCount
    )
    await runGeneration(request: request, record: record)
  }

  private func makeRequest(text: String) -> ProcessingRequest {
    let languages = settings.requestLanguages
    return ProcessingRequest(
      text: text, mode: mode, myLanguage: languages.my, foreignLanguage: languages.foreign)
  }

  /// The result typography before any text arrives. An improvement keeps the source's script. A
  /// translation goes to the foreign language when the source looks like the user's own
  /// language and to their own otherwise; the first characters of the result settle it.
  static func expectedTypography(for request: ProcessingRequest) -> Language {
    let source = TextLanguageDetector.typography(of: request.text) ?? .chinese
    guard request.mode == .translate else { return source }
    let mine = TextLanguageDetector.typography(of: request.myLanguage) ?? .chinese
    let foreign = TextLanguageDetector.typography(of: request.foreignLanguage) ?? .english
    return source == mine ? foreign : mine
  }

  private func beginGeneration(
    request: ProcessingRequest,
    reportedSourceCharacterCount: Int?
  ) -> ResultRecord {
    let record = ResultRecord(
      mode: request.mode,
      source: request.text,
      sourceCharacterCount: reportedSourceCharacterCount ?? request.text.utf16.count,
      outputLanguage: Self.expectedTypography(for: request),
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
          throw ModelServiceError.emptyResult
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
    settleTypography(of: record)
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
    settleTypography(of: record)
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

  /// Once a few characters of the result exist, its own script decides the typography; a switch
  /// this early costs one relayout of a line or two.
  private func settleTypography(of record: ResultRecord) {
    guard !record.outputLanguageSettled, record.resultUTF16Length >= 12 || record.phase != .streaming
    else { return }
    record.outputLanguageSettled = true
    if let typography = TextLanguageDetector.typography(of: record.result),
      typography != record.outputLanguage
    {
      record.outputLanguage = typography
    }
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
