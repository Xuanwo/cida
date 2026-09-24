import AppKit
import Carbon.HIToolbox
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
      // The panel is summoned by the system hot key (`GlobalHotKey`) and the
      // menu bar item, both of which follow the recorded shortcut; a fixed
      // main-menu key equivalent would keep answering the old one while
      // Cida is active.
    }
  }
}

/// Cida is a menu-bar application: no Dock icon, one floating panel shown by
/// Option-Space, and a standard Settings window (Pencil `Spec — 面板模型`).
@MainActor
final class CidaAppDelegate: NSObject, NSApplicationDelegate {
  private let launchOptions = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
  private lazy var model: AppModel = {
    let settingsStorageNamespace = launchOptions.settingsStorageNamespace
    return AppModel(
      mode: launchOptions.initialMode,
      inputText: launchOptions.initialInput,
      result: launchOptions.initialResult,
      settings: launchOptions.initialSettings,
      service: launchOptions.textProcessingService,
      saveSettings: { settings in
        SettingsStore.save(settings, namespace: settingsStorageNamespace)
      },
      clearPersistedAPIKey: {
        SettingsStore.clearAPIKey(namespace: settingsStorageNamespace)
      },
      applyGlobalShortcut: { [weak self] shortcut in
        self?.applyGlobalShortcut(shortcut) ?? true
      }
    )
  }()

  private var panelController: PanelController?
  private var settingsWindowController: NSWindowController?
  private var statusItem: NSStatusItem?
  private var showPanelMenuItem: NSMenuItem?
  private var globalHotKey: GlobalHotKey?
  private var performanceProbeView: FramePacingProbeNSView?
  private var millionCharacterPasteWorkload: MillionCharacterPasteWorkload?
  private var inputInteractionProbe: InputInteractionProbe?
  private var lifecycleLog: AutomationLifecycleLog?
  private var didAttemptInteractiveAPIKeyRecovery = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    FontRegistrar.registerBundledFonts()
    NSApp.setActivationPolicy(.accessory)

    let panelController = PanelController(
      model: model,
      hidesOnResignKey: !launchOptions.isAutomation || launchOptions.displaysInteractiveAutomationUI,
      openSettings: { [weak self] in self?.showSettings() }
    )
    self.panelController = panelController
    if let logURL = launchOptions.lifecycleLogURL {
      lifecycleLog = AutomationLifecycleLog(url: logURL)
      lifecycleLog?.observe(panel: panelController.panel)
      lifecycleLog?.record("did-finish-launching", panel: panelController.panel)
    }
    if let contentView = panelController.contentView {
      model.attachDisplayLink(to: contentView)
    }
    installPerformanceProbeIfNeeded()

    if !launchOptions.isAutomation || launchOptions.displaysInteractiveAutomationUI {
      installStatusItem()
      globalHotKey = GlobalHotKey(shortcut: model.settings.shortcut) { [weak self] in
        self?.togglePanel()
      }
    }

    if launchOptions.displaysInteractiveAutomationUI {
      showPanel()
    } else if launchOptions.isAutomation {
      prepareAutomationPanel()
      if let outputURL = launchOptions.inputInteractionOutputURL {
        inputInteractionProbe = InputInteractionProbe(
          outputURL: outputURL,
          window: panelController.panel,
          model: model
        )
        inputInteractionProbe?.run()
      } else if launchOptions.designState == .streaming {
        model.submit()
      }
    } else if launchOptions.designState.isSettings {
      showSettings()
    } else {
      showPanel()
    }

    if let outputURL = launchOptions.snapshotOutputURL {
      let targetWindow: NSWindow? =
        launchOptions.designState.isSettings
        ? settingsWindowController?.window
        : panelController.panel
      scheduleSnapshot(of: targetWindow, to: outputURL)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    if launchOptions.persistsSettings {
      model.persistSettings()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    showPanel()
    return true
  }

  /// Swaps the system hot key; without one (automation) the setting is
  /// accepted as is. The menu bar item shows the combination that works.
  private func applyGlobalShortcut(_ shortcut: GlobalShortcut) -> Bool {
    if let globalHotKey, !globalHotKey.update(to: shortcut) {
      return false
    }
    updateShowPanelMenuItem(for: shortcut)
    return true
  }

  private func updateShowPanelMenuItem(for shortcut: GlobalShortcut) {
    showPanelMenuItem?.keyEquivalent = shortcut.menuKeyEquivalent
    showPanelMenuItem?.keyEquivalentModifierMask = shortcut.menuModifierMask
  }

  @objc
  func togglePanel() {
    guard let panelController else { return }
    if panelController.isVisible {
      panelController.hide()
    } else {
      showPanel()
    }
  }

  @objc
  func showPanel() {
    recoverAPIKeyIfNeeded()
    lifecycleLog?.record("show-panel-requested", panel: panelController?.panel)
    panelController?.show()
    lifecycleLog?.record("show-panel-finished", panel: panelController?.panel)
  }

  @objc
  func showSettings() {
    ensureSettingsWindowController()

    guard let window = settingsWindowController?.window else { return }
    panelController?.hide()
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  @objc
  private func quit() {
    NSApp.terminate(nil)
  }

  /// The Keychain may ask the user to allow access; do it the first time the
  /// panel is shown, when someone is at the keyboard.
  private func recoverAPIKeyIfNeeded() {
    guard
      !launchOptions.isAutomation,
      !didAttemptInteractiveAPIKeyRecovery,
      model.settings.apiKey.isEmpty
    else {
      return
    }
    didAttemptInteractiveAPIKeyRecovery = true
    if let apiKey = SettingsStore.loadAPIKeyAllowingInteraction(
      namespace: launchOptions.settingsStorageNamespace
    ) {
      model.restorePersistedAPIKey(apiKey)
    }
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      if let image = NSImage(systemSymbolName: "translate", accessibilityDescription: "辞达") {
        button.image = image
      } else {
        button.title = "辞"
      }
      button.setAccessibilityIdentifier("cida-status-item")
    }
    let menu = NSMenu()
    let show = NSMenuItem(title: "显示辞达", action: #selector(showPanel), keyEquivalent: "")
    show.target = self
    menu.addItem(show)
    showPanelMenuItem = show
    updateShowPanelMenuItem(for: model.settings.shortcut)
    let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "退出辞达", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    item.menu = menu
    statusItem = item
  }

  /// Non-interactive automation keeps the panel off the user's screen: probes
  /// order it behind everything at near-zero alpha, snapshots render it
  /// without ordering it in at all.
  private func prepareAutomationPanel() {
    guard let panel = panelController?.panel else { return }
    if launchOptions.designState.isSettings {
      ensureSettingsWindowController()
    }

    if launchOptions.inputInteractionOutputURL != nil {
      panel.alphaValue = 0
      panel.hasShadow = false
      panel.orderBack(nil)
      panel.displayIfNeeded()
    } else if launchOptions.performanceProbe != nil {
      panel.alphaValue = 1
      panel.hasShadow = false
      panel.contentView?.alphaValue = 0.004
      panel.ignoresMouseEvents = true
      panel.collectionBehavior = [.ignoresCycle, .stationary]
      panel.orderBack(nil)
      panel.displayIfNeeded()
    }
  }

  private func ensureSettingsWindowController() {
    guard settingsWindowController == nil else { return }
    #if DEBUG
      if launchOptions.designState == .settingsCustom {
        model.editingPrompt = .improve
      }
      if launchOptions.designState == .settingsRecording {
        model.isRecordingShortcut = true
      }
    #endif
    settingsWindowController = SettingsWindowFactory.makeWindowController(model: model)
  }

  private func installPerformanceProbeIfNeeded() {
    guard
      let configuration = launchOptions.performanceProbe,
      let contentView = panelController?.contentView
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
          outputCharacterCount: self.model.result?.resultUTF16Length
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

/// The panel states of `States — 面板交互` that automation can start in.
private enum DesignState: String {
  case empty
  case translate
  case improve
  case streaming
  case stale
  case stopped
  case failed
  case long
  case settings
  case settingsMissingKey = "settings-missing-key"
  case settingsCustom = "settings-custom"
  case settingsRecording = "settings-recording"

  var isSettings: Bool {
    switch self {
    case .settings, .settingsMissingKey, .settingsCustom, .settingsRecording: true
    default: false
    }
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
  let automationOpenAIEndpoint: String?
  let automationSettingsNamespace: String?
  let lifecycleLogURL: URL?

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

  var settingsStorageNamespace: String {
    automationSettingsNamespace ?? SettingsStore.storageNamespace
  }

  private var usesDesignFixtures: Bool {
    isAutomation && !isE2ETesting
  }

  /// A launch that saves settings starts from them; otherwise quitting would
  /// write the defaults over what the user chose.
  var initialSettings: CidaSettings {
    var settings =
      persistsSettings
      ? SettingsStore.load(namespace: settingsStorageNamespace)
      : CidaSettings()
    #if DEBUG
      if usesDesignFixtures {
        settings = CidaSettings.designPreview
      }
      if usesDesignFixtures, designState == .settingsMissingKey {
        settings.apiKey = ""
      }
      if usesDesignFixtures, designState == .settingsCustom {
        settings.provider = .custom
        settings.model = "qwen3-32b"
        settings.customEndpoint = "http://127.0.0.1:8080/v1/chat/completions"
        settings.apiKey = ""
        settings.launchAtLogin = true
        settings.shortcut = GlobalShortcut(
          keyCode: UInt16(kVK_ANSI_T), modifiers: [.control, .option])
      }
    #endif
    if let automationOpenAIEndpoint {
      settings.provider = .custom
      settings.model = "cida-local-model"
      settings.customEndpoint = automationOpenAIEndpoint
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

  var initialResult: ResultRecord? {
    guard usesDesignFixtures else { return nil }
    #if DEBUG
      switch designState {
      case .translate:
        return ResultRecord.designCompleted(mode: .translate)
      case .improve:
        return ResultRecord.designCompleted(mode: .improve)
      case .stale:
        return ResultRecord.designCompleted(mode: .translate)
      case .stopped:
        let record = ResultRecord(
          mode: .translate,
          source: ResultRecord.designTranslateSource,
          outputLanguage: .english,
          result: "Our system adopts a brand-new storage engine that significantly improves read and write",
          phase: .stopped
        )
        return record
      case .failed:
        return ResultRecord(
          mode: .translate,
          source: ResultRecord.designTranslateSource,
          outputLanguage: .english,
          phase: .failed(message: "401 Unauthorized（deepseek-chat）。检查 API Key 后")
        )
      case .long:
        return ResultRecord.designLong()
      case .empty, .streaming, .settings, .settingsMissingKey, .settingsCustom, .settingsRecording:
        return nil
      }
    #else
      return nil
    #endif
  }

  var initialInput: String {
    guard usesDesignFixtures else { return "" }
    #if DEBUG
      return switch designState {
      case .translate, .streaming, .stopped, .failed:
        ResultRecord.designTranslateSource
      case .improve:
        ResultRecord.designImproveSource
      case .stale:
        "我们的系统采用了全新的存储引擎,在保证数据一致性的前提下,读写性能提升了三倍。"
      case .long:
        ResultRecord.designLongInput
      case .empty, .settings, .settingsMissingKey, .settingsCustom, .settingsRecording:
        ""
      }
    #else
      return ""
    #endif
  }

  init(arguments: [String]) {
    explicitlyIsolatedAutomation =
      ProcessInfo.processInfo.environment["CIDA_ISOLATED_AUTOMATION"] == "1"
    isE2ETesting =
      explicitlyIsolatedAutomation && arguments.contains("--e2e-testing")
    automationOpenAIEndpoint =
      explicitlyIsolatedAutomation
      ? arguments.value(after: "--automation-openai-endpoint")
      : nil
    let requestedAutomationSettingsNamespace =
      explicitlyIsolatedAutomation
      ? arguments.value(after: "--automation-settings-namespace")
      : nil
    lifecycleLogURL =
      explicitlyIsolatedAutomation
      ? arguments.value(after: "--automation-lifecycle-log").map { URL(fileURLWithPath: $0) }
      : nil
    if isE2ETesting {
      guard
        let requestedAutomationSettingsNamespace,
        requestedAutomationSettingsNamespace.hasPrefix("com.xuanwo.Cida.Automation.")
      else {
        fatalError("E2E testing requires an isolated automation settings namespace")
      }
      automationSettingsNamespace = requestedAutomationSettingsNamespace
    } else {
      automationSettingsNamespace = nil
    }
    designState =
      arguments.value(after: "--design-state")
      .flatMap(DesignState.init(rawValue:)) ?? .empty

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
        ?? (workload == .millionCharacterPaste ? 120 : nil)
      performanceProbe = PerformanceProbeConfiguration(
        outputURL: URL(fileURLWithPath: output),
        sampleCount: max(120, sampleCount),
        warmupFrameCount: 120,
        workload: workload,
        requiredFramesPerSecond: requiredFramesPerSecond,
        requiresZeroMissedFrameBudgets: workload == .millionCharacterPaste
          || arguments.contains("--performance-zero-missed-frame-budgets")
      )
    } else {
      performanceProbe = nil
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
