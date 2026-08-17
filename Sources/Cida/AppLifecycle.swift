import AppKit
import QuartzCore
import SwiftUI

@main
struct CidaApplication: App {
  @NSApplicationDelegateAdaptor(CidaAppDelegate.self) private var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("设置…") {
          appDelegate.showSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
      }

      CommandGroup(after: .newItem) {
        Button("打开输入窗口") {
          appDelegate.showMainWindow()
        }
        .keyboardShortcut(.space, modifiers: .option)
      }
    }
  }
}

@MainActor
final class CidaAppDelegate: NSObject, NSApplicationDelegate {
  private let launchOptions = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
  private let launchDiagnostics = LaunchPerformanceDiagnostics()
  private lazy var historyStore: HistoryStore? = {
    if let databaseURL = launchOptions.automationHistoryDatabaseURL {
      do {
        return try HistoryStore(databaseURL: databaseURL)
      } catch {
        fputs("Failed to open isolated automation history database: \(error)\n", stderr)
        return nil
      }
    }
    guard !launchOptions.isAutomation else { return nil }
    do {
      return try HistoryStore.openProduction()
    } catch {
      fputs("Failed to open history database: \(error)\n", stderr)
      return nil
    }
  }()
  private lazy var model: AppModel = {
    let persistedEntries: [HistoryEntry]
    var historyPage: HistoryPage?
    if let historyStore {
      let startedAt = CACurrentMediaTime()
      do {
        let loadedPage = try historyStore.loadRecent(limit: launchOptions.initialHistoryPageSize)
        historyPage = loadedPage
        persistedEntries = loadedPage.entries
      } catch {
        fputs("Failed to load history database: \(error)\n", stderr)
        persistedEntries = []
      }
      launchDiagnostics.recordHistoryLoad(
        durationMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
        databaseURL: launchOptions.automationHistoryDatabaseURL
      )
    } else if launchOptions.isAutomation {
      persistedEntries = launchOptions.designEntries
    } else {
      persistedEntries = []
    }
    return AppModel(
      mode: launchOptions.initialMode,
      inputText: launchOptions.initialInput,
      entries: persistedEntries,
      settings: launchOptions.initialSettings,
      service: launchOptions.textProcessingService,
      historyPersistence: historyStore,
      historyPageLoader: historyStore,
      historyTotalCount: historyPage?.totalCount,
      historyOldestSortOrder: historyPage?.oldestSortOrder,
      historyHasMoreBefore: historyPage?.hasMoreBefore ?? false,
      historyPageSize: launchOptions.initialHistoryPageSize
    )
  }()

  private var mainWindowController: NSWindowController?
  private var settingsWindowController: NSWindowController?
  private var eventMonitor: Any?
  private var globalHotKey: GlobalHotKey?
  private var performanceProbeView: FramePacingProbeNSView?
  private var millionCharacterPasteWorkload: MillionCharacterPasteWorkload?
  private var largeHistoryScrollWorkload: LargeHistoryScrollWorkload?
  private var extremeWorkflowWorkload: ExtremeWorkflowWorkload?
  private var inputInteractionProbe: InputInteractionProbe?
  private var didAttemptInteractiveAPIKeyRecovery = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    FontRegistrar.registerBundledFonts()
    HistoryResultTextContainerPool.shared.prewarm()
    NSApp.setActivationPolicy(
      launchOptions.isAutomation && !launchOptions.displaysInteractiveAutomationUI
        ? .accessory : .regular
    )

    let mainView = MainWindowView(
      model: model,
      automaticallyFocusInput:
        !launchOptions.isAutomation || launchOptions.displaysInteractiveAutomationUI,
      openSettings: { [weak self] in self?.showSettings() }
    )
    mainWindowController = makeWindowController(
      rootView: AnyView(mainView),
      size: CGSize(width: 860, height: 640),
      minimumSize: CGSize(width: 640, height: 480),
      title: "辞达"
    )
    if let contentView = mainWindowController?.window?.contentView {
      model.attachDisplayLink(to: contentView)
    }
    installPerformanceProbeIfNeeded()

    installKeyboardMonitor()
    if !launchOptions.isAutomation {
      globalHotKey = GlobalHotKey { [weak self] in
        self?.showMainWindow()
      }
    }

    if launchOptions.displaysInteractiveAutomationUI {
      showMainWindow()
    } else if launchOptions.isAutomation {
      prepareAutomationWindow()
      if let outputURL = launchOptions.inputInteractionOutputURL,
        let window = mainWindowController?.window
      {
        inputInteractionProbe = InputInteractionProbe(
          outputURL: outputURL,
          window: window,
          model: model
        )
        inputInteractionProbe?.run()
      } else if launchOptions.designState == .streaming {
        model.submit()
      }
    } else if launchOptions.designState.isSettings {
      showSettings()
    } else {
      showMainWindow()
    }

    if let outputURL = launchOptions.snapshotOutputURL {
      let targetWindow =
        launchOptions.designState.isSettings
        ? settingsWindowController?.window
        : mainWindowController?.window
      scheduleSnapshot(of: targetWindow, to: outputURL)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
    }
    if launchOptions.persistsSettings {
      model.persistSettings()
    }
    model.flushHistoryPersistence()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    guard
      !launchOptions.isAutomation,
      !didAttemptInteractiveAPIKeyRecovery,
      model.settings.apiKey.isEmpty
    else {
      return
    }
    didAttemptInteractiveAPIKeyRecovery = true
    if let apiKey = SettingsStore.loadAPIKeyAllowingInteraction() {
      model.restorePersistedAPIKey(apiKey)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      showMainWindow()
    }
    return true
  }

  @objc
  func showMainWindow() {
    guard let window = mainWindowController?.window else { return }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    model.requestInputFocus()
  }

  @objc
  func showSettings() {
    ensureSettingsWindowController()

    guard let window = settingsWindowController?.window else { return }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func prepareAutomationWindow() {
    if launchOptions.designState.isSettings {
      ensureSettingsWindowController()
    }

    if launchOptions.inputInteractionOutputURL != nil {
      guard let window = mainWindowController?.window else { return }
      window.alphaValue = 0
      window.hasShadow = false
      window.orderBack(nil)
      window.displayIfNeeded()
    } else if launchOptions.performanceProbe != nil {
      guard let window = mainWindowController?.window else { return }
      window.alphaValue = 1
      window.isOpaque = false
      window.backgroundColor = .clear
      window.hasShadow = false
      window.contentView?.alphaValue = 0.004
      window.ignoresMouseEvents = true
      window.collectionBehavior = [.ignoresCycle, .stationary]
      for buttonType in [
        NSWindow.ButtonType.closeButton,
        .miniaturizeButton,
        .zoomButton,
      ] {
        window.standardWindowButton(buttonType)?.isHidden = true
      }
      window.orderBack(nil)
      window.displayIfNeeded()
      launchDiagnostics.recordInitialRenderIfNeeded()
    }
  }

  private func ensureSettingsWindowController() {
    guard settingsWindowController == nil else { return }
    settingsWindowController = makeWindowController(
      rootView: AnyView(
        SettingsWindowView(
          model: model
        )
      ),
      size: CGSize(width: 560, height: 660),
      minimumSize: CGSize(width: 500, height: 500),
      title: "设置"
    )
  }

  private func installPerformanceProbeIfNeeded() {
    guard
      let configuration = launchOptions.performanceProbe,
      let contentView = mainWindowController?.window?.contentView
    else {
      return
    }

    let exerciseInteraction: @MainActor (Int) -> Bool
    let workloadMetrics: @MainActor () -> FramePacingWorkloadMetrics

    switch configuration.workload {
    case .streaming:
      let frameInterval = 1 / Double(configuration.requiredFramesPerSecond ?? 120)
      exerciseInteraction = { [weak self] frameTick in
        self?.model.exercisePerformanceWorkload(
          frameTick: frameTick,
          elapsedSeconds: frameInterval
        ) == true
      }
      workloadMetrics = { [weak self] in
        guard let self else {
          return FramePacingWorkloadMetrics(completed: false)
        }
        return FramePacingWorkloadMetrics(
          completed: self.model.streamPresentationUpdateCount >= 12,
          streamPresentationUpdateCount: self.model.streamPresentationUpdateCount,
          maximumStreamPresentationBatchCharacterCount:
            self.model.maximumStreamPresentationCharacterCount,
          outputCharacterCount: self.model.entries.last?.resultUTF16Length
        )
      }
    case .millionCharacterPaste:
      let pasteWorkload = MillionCharacterPasteWorkload(model: model, rootView: contentView)
      millionCharacterPasteWorkload = pasteWorkload
      exerciseInteraction = { displayLinkTick in
        if displayLinkTick < -20 {
          pasteWorkload.warmUpNativePaste()
          return false
        }
        if displayLinkTick == -20 {
          pasteWorkload.resetAfterWarmup()
          return false
        }
        guard displayLinkTick == 1 else { return false }
        return pasteWorkload.performPaste()
      }
      workloadMetrics = { pasteWorkload.metrics() }
    case .largeHistoryScroll:
      let historyWorkload = LargeHistoryScrollWorkload(model: model, rootView: contentView)
      largeHistoryScrollWorkload = historyWorkload
      exerciseInteraction = { displayLinkTick in
        if displayLinkTick < -20 {
          historyWorkload.warmUpUpwardScroll()
          return false
        }
        if displayLinkTick == -20 {
          historyWorkload.resetAfterWarmup()
          return false
        }
        guard displayLinkTick > 0 else {
          return false
        }
        return historyWorkload.performUpwardScroll()
      }
      workloadMetrics = { historyWorkload.metrics() }
    case .extremeWorkflow:
      guard let extremeConfiguration = launchOptions.extremeWorkflowConfiguration else {
        fputs("Extreme workflow performance configuration is missing\n", stderr)
        return
      }
      let extremeWorkload = ExtremeWorkflowWorkload(
        model: model,
        rootView: contentView,
        configuration: extremeConfiguration,
        diagnostics: launchDiagnostics
      )
      extremeWorkflowWorkload = extremeWorkload
      exerciseInteraction = { displayLinkTick in
        guard displayLinkTick > 0 else { return false }
        return extremeWorkload.exercise()
      }
      workloadMetrics = { extremeWorkload.metrics() }
    }

    let probeView = FramePacingProbeNSView(
      configuration: configuration,
      exerciseInteraction: exerciseInteraction,
      workloadMetrics: workloadMetrics
    )
    probeView.frame = NSRect(x: 0, y: 0, width: 96, height: 4)
    probeView.autoresizingMask = [.maxXMargin, .maxYMargin]
    probeView.setAccessibilityElement(false)
    contentView.addSubview(probeView, positioned: .above, relativeTo: nil)
    performanceProbeView = probeView
  }

  private func makeWindowController(
    rootView: AnyView,
    size: CGSize,
    minimumSize: CGSize,
    title: String
  ) -> NSWindowController {
    let window = CidaWindowFactory.makeWindow(
      size: size,
      minimumSize: minimumSize,
      title: title
    )

    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.autoresizingMask = [.width, .height]
    hostingView.setAccessibilityLabel("\(title)窗口内容")
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    window.contentView = hostingView
    window.setContentSize(size)
    window.center()

    return NSWindowController(window: window)
  }

  private func installKeyboardMonitor() {
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard
        let self,
        NSApp.keyWindow === self.mainWindowController?.window
      else {
        return event
      }

      if CopyShortcutRouting.isLatestResultShortcut(event) {
        if CopyShortcutRouting.nativeTextResponderOwnsCopy(
          window: self.mainWindowController?.window)
        {
          return event
        }
        return self.model.copyLatestResult() ? nil : event
      }

      switch event.keyCode {
      case 48 where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
        self.model.toggleMode()
        return nil
      case 53:
        self.mainWindowController?.window?.performClose(nil)
        return nil
      default:
        return event
      }
    }
  }

  private func scheduleSnapshot(of window: NSWindow?, to outputURL: URL) {
    guard let window else { return }

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(launchOptions.snapshotDelayMilliseconds))
      do {
        try SnapshotWriter.write(window: window, to: outputURL)
      } catch {
        fputs("Failed to capture snapshot: \(error)\n", stderr)
      }
      NSApp.terminate(nil)
    }
  }
}

final class CidaWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

@MainActor
enum CopyShortcutRouting {
  static func isLatestResultShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)
    guard modifiers == .command else { return false }
    return event.keyCode == 8 || event.charactersIgnoringModifiers?.lowercased() == "c"
  }

  static func nativeTextResponderOwnsCopy(window: NSWindow?) -> Bool {
    guard let textView = window?.firstResponder as? NSTextView else { return false }
    return textView.isEditable || textView.selectedRange().length > 0
  }
}

private enum DesignState: String {
  case translate
  case improve
  case largeInput = "large-input"
  case streaming
  case settings
  case settingsOpenAI = "settings-openai"

  var isSettings: Bool {
    self == .settings || self == .settingsOpenAI
  }
}

private struct LaunchOptions {
  let designState: DesignState
  let snapshotOutputURL: URL?
  let inputInteractionOutputURL: URL?
  let performanceProbe: PerformanceProbeConfiguration?
  let snapshotDelayMilliseconds: Int
  let explicitlyIsolatedAutomation: Bool
  let isE2ETesting: Bool
  let automationHistoryDatabaseURL: URL?
  let automationOpenAIEndpoint: String?
  let extremeWorkflowConfiguration: ExtremeWorkflowConfiguration?
  let initialHistoryPageSize: Int

  var isAutomation: Bool {
    explicitlyIsolatedAutomation || snapshotOutputURL != nil
      || inputInteractionOutputURL != nil || performanceProbe != nil
  }

  var displaysInteractiveAutomationUI: Bool {
    isE2ETesting
  }

  var persistsSettings: Bool {
    !isAutomation || isE2ETesting
  }

  private var usesDesignFixtures: Bool {
    isAutomation && !isE2ETesting
  }

  var initialSettings: CidaSettings {
    var settings = isE2ETesting ? SettingsStore.load() : CidaSettings()
    #if DEBUG
      if usesDesignFixtures {
        settings = CidaSettings.designPreview
      }
      if usesDesignFixtures, designState == .settingsOpenAI {
        settings.provider = .openAI
        settings.model = "local-model"
        settings.openAIEndpoint = "http://127.0.0.1:8080/v1/chat/completions"
        settings.apiKey = ""
      }
    #endif
    if let automationOpenAIEndpoint {
      settings.provider = .openAI
      settings.model = "cida-extreme-local-model"
      settings.openAIEndpoint = automationOpenAIEndpoint
      settings.apiKey = ""
    }
    return settings
  }

  var textProcessingService: any TextProcessingService {
    #if DEBUG
      if usesDesignFixtures, automationOpenAIEndpoint == nil {
        return PreviewTextProcessingService()
      }
    #endif
    return OpenAICompatibleTextProcessingService()
  }

  var initialMode: ProcessingMode {
    designState == .improve ? .improve : .translate
  }

  var designEntries: [HistoryEntry] {
    guard isAutomation else { return [] }
    #if DEBUG
      switch designState {
      case .streaming:
        return [HistoryEntry.designSamples[1]]
      case .largeInput:
        return HistoryEntry.longDesignSamples
      case .translate, .improve, .settings, .settingsOpenAI:
        return HistoryEntry.designSamples
      }
    #else
      return []
    #endif
  }

  var initialInput: String {
    #if DEBUG
      return switch designState {
      case .improve:
        "这个功能通过复用已有的缓存结果,使得整体的处理流程在大多数的情况下都能够得到比较明显的加速。"
      case .largeInput:
        HistoryEntry.designLongInput
      case .streaming:
        "我们的系统采用了全新的存储引擎,在保证数据一致性的前提下,显著提升了读写性能。"
      case .translate, .settings, .settingsOpenAI:
        ""
      }
    #else
      ""
    #endif
  }

  init(arguments: [String]) {
    explicitlyIsolatedAutomation =
      ProcessInfo.processInfo.environment["CIDA_ISOLATED_AUTOMATION"] == "1"
    isE2ETesting =
      explicitlyIsolatedAutomation && arguments.contains("--e2e-testing")
    automationHistoryDatabaseURL =
      explicitlyIsolatedAutomation
      ? arguments.value(after: "--automation-history-database")
        .map { URL(fileURLWithPath: $0) }
      : nil
    automationOpenAIEndpoint =
      explicitlyIsolatedAutomation
      ? arguments.value(after: "--automation-openai-endpoint")
      : nil
    initialHistoryPageSize = min(
      5_000,
      max(
        64,
        arguments.value(after: "--history-page-size").flatMap(Int.init)
          ?? 128
      )
    )
    designState =
      arguments.value(after: "--design-state")
      .flatMap(DesignState.init(rawValue:)) ?? .translate

    snapshotOutputURL = arguments.value(after: "--snapshot-output")
      .map { URL(fileURLWithPath: $0) }
    inputInteractionOutputURL = arguments.value(after: "--input-interaction-output")
      .map { URL(fileURLWithPath: $0) }
    snapshotDelayMilliseconds = max(
      0,
      arguments.value(after: "--snapshot-delay-ms")
        .flatMap(Int.init) ?? 700
    )

    if let output = arguments.value(after: "--performance-output") {
      let sampleCount =
        arguments.value(after: "--performance-samples")
        .flatMap(Int.init) ?? 720
      let workload =
        arguments.value(after: "--performance-workload")
        .flatMap(FramePacingWorkload.init(rawValue:)) ?? .streaming
      let requiredFramesPerSecond =
        arguments.value(after: "--performance-required-fps")
        .flatMap(Int.init)
        ?? (workload == .millionCharacterPaste || workload == .largeHistoryScroll
          || workload == .extremeWorkflow ? 120 : nil)
      performanceProbe = PerformanceProbeConfiguration(
        outputURL: URL(fileURLWithPath: output),
        sampleCount: max(120, sampleCount),
        warmupFrameCount: 120,
        workload: workload,
        requiredFramesPerSecond: requiredFramesPerSecond,
        requiresZeroMissedFrameBudgets: workload == .millionCharacterPaste
          || workload == .largeHistoryScroll
          || workload == .extremeWorkflow
          || arguments.contains("--performance-zero-missed-frame-budgets")
      )
      if workload == .extremeWorkflow {
        extremeWorkflowConfiguration = ExtremeWorkflowConfiguration(
          expectedInitialHistoryEntryCount: arguments.value(
            after: "--extreme-history-count"
          ).flatMap(Int.init) ?? 0,
          inputCharacterCount: arguments.value(after: "--extreme-input-characters")
            .flatMap(Int.init) ?? 1_000_000,
          outputCharacterCount: arguments.value(after: "--extreme-output-characters")
            .flatMap(Int.init) ?? 1_024,
          minimumNormalScrollDistancePoints: CGFloat(
            arguments.value(after: "--extreme-normal-scroll-points")
              .flatMap(Double.init) ?? 6_000
          ),
          minimumHyperScrollDistancePoints: CGFloat(
            arguments.value(after: "--extreme-hyper-scroll-points")
              .flatMap(Double.init) ?? 120_000
          )
        )
      } else {
        extremeWorkflowConfiguration = nil
      }
    } else {
      performanceProbe = nil
      extremeWorkflowConfiguration = nil
    }
  }
}

extension Array where Element == String {
  fileprivate func value(after flag: String) -> String? {
    guard
      let index = firstIndex(of: flag),
      indices.contains(index + 1)
    else {
      return nil
    }
    return self[index + 1]
  }
}
