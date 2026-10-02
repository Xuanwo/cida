import AppKit
import Carbon.HIToolbox
import QuartzCore
import SwiftUI
import os

/// One executable, two ways in: with a command (`Cida config …`, `Cida check`, `Cida --help`)
/// it runs the command line and exits before NSApplication starts
/// (`Design/spec/configuration.md` §二); otherwise it is the application.
@main
enum CidaEntryPoint {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if CommandLineInterface.handles(arguments: arguments) {
      CommandLineInterface.runAndExit(arguments: arguments)
    }
    CidaApplication.main()
  }
}

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
/// Option-A, and a standard Settings window (`Design/spec/panel.md`).
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
        SettingsStore.saveApplicationSettings(settings, namespace: settingsStorageNamespace)
      },
      applyGlobalShortcut: { [weak self] shortcut, action in
        self?.applyGlobalShortcut(shortcut, for: action) ?? true
      },
      suspendGlobalShortcuts: { [weak self] isSuspended in
        self?.globalHotKey?.setSuspended(isSuspended)
        self?.captureHotKey?.setSuspended(isSuspended)
        self?.layerHotKey?.setSuspended(isSuspended)
        self?.layerWindowHotKey?.setSuspended(isSuspended)
        self?.improvementHotKey?.setSuspended(isSuspended)
      },
      selectionAccess: launchOptions.selectionAccess,
      captureAccess: launchOptions.captureAccess,
      lastModelServiceCheck: launchOptions.persistsSettings
        ? SettingsStore.loadLastCheck(namespace: settingsStorageNamespace) : nil,
      recordModelServiceCheck: { record in
        SettingsStore.saveLastCheck(record, namespace: settingsStorageNamespace)
      }
    )
  }()
  private var configurationChangeObserver: NSObjectProtocol?
  private let selectedTextSource = AccessibilitySelectedTextSource()
  private let selectionCopier = PasteboardSelectionCopier()
  private let screenCaptureSource = SystemScreenCaptureSource()

  private var panelController: PanelController?
  private var settingsWindowController: NSWindowController?
  private var statusItem: NSStatusItem?
  private var statusItemMark: StatusItemMark?
  private let updater = CidaUpdater()
  private var showPanelMenuItem: NSMenuItem?
  private var captureMenuItem: NSMenuItem?
  private var globalHotKey: GlobalHotKey?
  private var captureHotKey: GlobalHotKey?
  private var layerHotKey: GlobalHotKey?
  private var improvementHotKey: GlobalHotKey?
  private var improvementScreen: NSScreen?
  private lazy var improvementHint = CidaHintPanel(identifier: "improvement-hint")
  private lazy var selectionImprovement: SelectionImprovement = {
    let operation = SelectionImprovement(service: launchOptions.textProcessingService)
    operation.recordEvent = { [weak self] event in self?.lifecycleLog?.record(event) }
    operation.onFeedback = { [weak self] feedback in
      guard let self else { return }
      guard let feedback else { improvementHint.hide(); return }
      improvementHint.show(feedback.text, for: feedback.dismissAfter, action: feedback.action, on: improvementScreen,
        onPress: feedback.action == nil ? nil : { [weak self] in
          self?.selectionImprovement.performFeedbackAction()
        })
    }
    operation.onResult = { [weak self] result in
      guard let self else { return }
      model.importImprovementResult(result)
      panelController?.show(preservingMode: true)
    }
    return operation
  }()

  /// The layer shortcut with ⇧: the whole window (`Design/spec/translation-layer.md` §三).
  private var layerWindowHotKey: GlobalHotKey?
  /// The translation layer (`Design/spec/translation-layer.md`); nil in automation that shows
  /// no interactive UI.
  private var translationLayer: TranslationLayerController?
  /// The layer's configuration is over the screen; the other shortcuts wait for it.
  private var performanceProbeView: FramePacingProbeNSView?
  private var millionCharacterPasteWorkload: MillionCharacterPasteWorkload?
  private var inputInteractionProbe: InputInteractionProbe?
  private var lifecycleLog: AutomationLifecycleLog?
  private var didAttemptInteractiveAPIKeyRecovery = false
  /// A shortcut press is reading the selection; further presses wait for it.
  private var isReadingSelection = false
  /// The capture shortcut is freezing the screen, waiting for a frame, or
  /// recognizing text; both shortcuts wait for it.
  private var isCapturing = false
  /// When the user opened Cida themselves; a scheduled check that finds an update soon after
  /// may bring the panel up (`Design/spec/lifecycle.md` §四).
  private var launchedByUserAt: Date?

  func applicationDidFinishLaunching(_ notification: Notification) {
    FontRegistrar.registerBundledFonts()
    NSApp.setActivationPolicy(.accessory)
    if launchOptions.isAutomation, let appearance = launchOptions.designAppearance {
      NSApp.appearance = appearance
    }

    let panelController = PanelController(
      model: model,
      hidesOnResignKey: !launchOptions.isAutomation || launchOptions.displaysInteractiveAutomationUI,
      // Without a model service, Settings opens where it is configured.
      openSettings: { [weak self] in
        guard let self else { return }
        openSettings(on: model.isModelServiceConfigured ? nil : .model)
      }
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
    if launchOptions.persistsSettings {
      observeConfigurationChanges()
    }

    if !launchOptions.isAutomation || launchOptions.displaysInteractiveAutomationUI {
      installStatusItem()
      globalHotKey = GlobalHotKey(shortcut: model.settings.shortcut) { [weak self] in
        self?.handleGlobalShortcut()
      }
      captureHotKey = GlobalHotKey(shortcut: model.settings.captureShortcut) { [weak self] in
        self?.handleCaptureShortcut()
      }
      layerHotKey = GlobalHotKey(shortcut: model.settings.layerShortcut) { [weak self] in
        self?.handleLayerShortcut(wholeWindow: false)
      }
      layerWindowHotKey = GlobalHotKey(shortcut: model.settings.layerShortcut?.addingShift) { [weak self] in
        self?.handleLayerShortcut(wholeWindow: true)
      }
      improvementHotKey = GlobalHotKey(shortcut: model.settings.improvementShortcut) { [weak self] in
        self?.handleImprovementShortcut()
      }
      updateTranslationLayer(for: model.settings.layerShortcut)
      warmUpTextRecognition()
    }
    // Only a user's own launch talks to the update feed; automation and E2E never do.
    if !launchOptions.isAutomation, CidaUpdater.isConfigured() {
      updater.start(presenter: self)
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
    } else if LaunchSource.current() == .user {
      // At login and after an update Cida stays in the menu bar.
      launchedByUserAt = Date()
      showPanel()
    }
    #if DEBUG
      if launchOptions.isAutomation {
        presentDesignStateMessage()
      }
    #endif

    #if DEBUG
      if launchOptions.designState == .copyMenu {
        model.isCopyMenuOpen = true
        model.highlightsCopyImageForDesign = true
      }
    #endif

    if let outputURL = launchOptions.snapshotOutputURL, launchOptions.designState.isShareCard {
      writeShareCardSnapshot(to: outputURL)
    } else if let outputURL = launchOptions.snapshotOutputURL {
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

  /// Swaps the action's system hot key; without one (automation) the
  /// setting is accepted as is. The menu bar items show the combinations
  /// that work.
  private func applyGlobalShortcut(
    _ shortcut: GlobalShortcut?,
    for action: GlobalShortcutAction
  ) -> Bool {
    let hotKey =
      switch action {
      case .showPanel: globalHotKey
      case .captureText: captureHotKey
      case .translationLayer: layerHotKey
      case .improveSelection: improvementHotKey
      }
    let previous = hotKey?.shortcut
    if let hotKey, !hotKey.update(to: shortcut) {
      return false
    }
    // The layer's ⇧ variant moves with it; both register or neither changes.
    if action == .translationLayer, let windowHotKey = layerWindowHotKey,
      !windowHotKey.update(to: shortcut?.addingShift)
    {
      if let previous { _ = hotKey?.update(to: previous) }
      return false
    }
    if action == .improveSelection, shortcut == nil { selectionImprovement.dismiss() }
    updateMenuItem(for: action, shortcut: shortcut)
    if action == .translationLayer { updateTranslationLayer(for: shortcut) }
    return true
  }

  /// An item whose action has no shortcut shows no key.
  private func updateMenuItem(for action: GlobalShortcutAction, shortcut: GlobalShortcut?) {
    // The layer acts on what is under the pointer, so it has no menu item.
    let item =
      switch action {
      case .showPanel: showPanelMenuItem
      case .captureText: captureMenuItem
      case .translationLayer, .improveSelection: nil as NSMenuItem?
      }
    item?.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
    item?.keyEquivalentModifierMask = shortcut?.menuModifierMask ?? []
  }

  /// The global shortcut hides a visible panel. Otherwise it first reads the
  /// frontmost application's selection, so a new one appears in the panel
  /// already being translated (`Design/spec/panel.md` §一 带入选区). The
  /// menu bar item shows the panel without reading anything.
  private func handleGlobalShortcut() {
    guard let panelController, !isCapturing else { return }
    if panelController.isVisible {
      panelController.hide()
      return
    }
    guard !isReadingSelection else {
      logShortcut("shortcut-ignored reading-selection")
      return
    }
    selectionImprovement.dismiss()
    isReadingSelection = true
    let pressedAt = ContinuousClock.now
    logShortcut(
      "shortcut-pressed app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
    Task { @MainActor [weak self] in
      guard let self else { return }
      let selection = await SelectedText.read(
        from: selectedTextSource, copyingWith: selectionCopier
      ) { [weak self] event in self?.logShortcut(event) }
      isReadingSelection = false
      guard !panelController.isVisible else { return }
      // The request may need the Keychain key, which the first show recovers.
      recoverAPIKeyIfNeeded()
      let imported = model.importSelection(selection)
      logShortcut(imported ? "selection-imported" : "selection-kept")
      await panelController.layOutHiddenContent()
      guard !panelController.isVisible else { return }
      showPanel()
      logShortcut("shortcut-panel-shown ms=\(pressedAt.duration(to: .now).milliseconds)")
    }
  }

  private static let shortcutLogger = Logger(subsystem: "com.xuanwo.Cida", category: "shortcut")

  /// Records how the global shortcut spent its time in the unified log and, under automation,
  /// the lifecycle log, so a slow ⌥A on someone's Mac shows which step was slow. Events carry
  /// timings and the frontmost application's bundle identifier, never its text.
  private func logShortcut(_ event: String) {
    Self.shortcutLogger.notice("\(event, privacy: .public)")
    lifecycleLog?.record(event)
  }

  private func handleImprovementShortcut() {
    guard !isCapturing, !isReadingSelection else { return }
    if selectionImprovement.isRunning { selectionImprovement.cancel(); return }
    model.refreshSelectionAccess()
    guard model.isSelectionAccessGranted else {
      model.requestSelectionAccess()
      return
    }
    recoverAPIKeyIfNeeded()
    guard !model.needsModelConfiguration else { showPanel(); return }
    guard panelController?.isVisible != true else { return }
    improvementScreen = PanelController.activeScreen()
    selectionImprovement.trigger(settings: model.settings)
  }

  /// The capture shortcut (`Design/spec/panel.md` §一 截图翻译): freezes
  /// the screen under the pointer, lets the user frame some text, and shows
  /// the panel translating what was recognized. Without the Screen Recording
  /// permission it asks for it instead.
  @objc
  func handleCaptureShortcut() {
    guard !isCapturing, !isReadingSelection else { return }
    selectionImprovement.dismiss()
    panelController?.hide()
    model.refreshCaptureAccess()
    guard model.isCaptureAccessGranted else {
      model.requestCaptureAccess()
      return
    }
    isCapturing = true
    Task { @MainActor [weak self] in
      await self?.captureAndTranslate()
      self?.isCapturing = false
    }
  }

  private func captureAndTranslate() async {
    guard let screen = PanelController.activeScreen() else { return }
    let frozenScreen: CGImage
    do {
      frozenScreen = try await screenCaptureSource.captureScreen(screen)
    } catch {
      lifecycleLog?.record("capture-failed")
      NSSound.beep()
      return
    }
    lifecycleLog?.record("capture-overlay-shown")
    guard let region = await CaptureOverlay.selectRegion(of: frozenScreen, on: screen) else {
      lifecycleLog?.record("capture-cancelled")
      return
    }
    let text = (try? await TextRecognizer.recognizeText(in: region)) ?? nil
    // The request may need the Keychain key, which the first show recovers.
    recoverAPIKeyIfNeeded()
    model.importCapturedText(text)
    lifecycleLog?.record(text == nil ? "capture-unrecognized" : "capture-imported")
    await panelController?.layOutHiddenContent()
    showPanel()
  }

  /// The layer runs only while it has a shortcut: without one nothing could turn off a
  /// window translated whole (`Design/spec/translation-layer.md` §二).
  private func updateTranslationLayer(for shortcut: GlobalShortcut?) {
    if shortcut == nil {
      translationLayer?.stop()
      translationLayer = nil
    } else if translationLayer == nil, statusItem != nil {
      // Automation without the menu bar item and hot keys has no layer either.
      startTranslationLayer()
    }
  }

  private func startTranslationLayer() {
    let controller = TranslationLayerController(
      settings: { [weak self] in self?.model.settings ?? CidaSettings() },
      service: launchOptions.textProcessingService,
      namespace: launchOptions.settingsStorageNamespace,
      persists: launchOptions.persistsSettings)
    controller.lifecycleLog = { [weak self] event in self?.lifecycleLog?.record(event) }
    controller.start()
    translationLayer = controller
  }

  /// The layer shortcut (`Design/spec/translation-layer.md` §二, §三): the paragraph under
  /// the pointer turns into its translation and back; with ⇧, the whole window. Without the
  /// Accessibility permission it asks for it instead, and without a model service it shows
  /// the panel's welcome.
  private func handleLayerShortcut(wholeWindow: Bool) {
    guard let translationLayer, !isCapturing, !isReadingSelection else { return }
    selectionImprovement.dismiss()
    model.refreshSelectionAccess()
    guard model.isSelectionAccessGranted else {
      model.requestSelectionAccess()
      return
    }
    // The request may need the Keychain key, which the first show recovers.
    recoverAPIKeyIfNeeded()
    // The welcome says what to do, as it does for ⌥A and ⌥S (`spec/lifecycle.md` §三).
    guard !model.needsModelConfiguration else {
      lifecycleLog?.record("layer-needs-configuration")
      showPanel()
      return
    }
    let point = LayerScreenGeometry.topLeftPoint(fromAppKit: NSEvent.mouseLocation)
    lifecycleLog?.record(wholeWindow ? "layer-window-shortcut" : "layer-paragraph-shortcut")
    if wholeWindow {
      translationLayer.toggleWindow(at: point)
    } else {
      translationLayer.toggleParagraph(at: point)
    }
  }

  /// The first recognition in a process loads the models, which takes
  /// seconds; do it in the background once the app is up.
  private func warmUpTextRecognition() {
    Task.detached(priority: .utility) {
      try? await Task.sleep(for: .seconds(2))
      await TextRecognizer.warmUp()
    }
  }

  @objc
  func showPanel() {
    selectionImprovement.dismiss()
    recoverAPIKeyIfNeeded()
    lifecycleLog?.record("show-panel-requested", panel: panelController?.panel)
    panelController?.show()
    lifecycleLog?.record("show-panel-finished", panel: panelController?.panel)
  }

  @objc
  func showSettings() {
    openSettings(on: nil)
  }

  /// Opens Settings on `tab`, or on the tab it showed last.
  func openSettings(on tab: SettingsTab?) {
    selectionImprovement.dismiss()
    if let tab { model.settingsTab = tab }
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

  /// The command line changed the settings or checked the service; Settings and the next
  /// request follow at once (`Design/spec/configuration.md` §四).
  private func observeConfigurationChanges() {
    let namespace = launchOptions.settingsStorageNamespace
    configurationChangeObserver = ConfigurationChangeNotification.observe(namespace: namespace) {
      [weak self] in
      guard let self else { return }
      SettingsStore.synchronize(namespace: namespace)
      var settings = launchOptions.applyingEndpointOverride(
        to: SettingsStore.load(namespace: namespace))
      // A key this launch recovered interactively cannot be read again without asking.
      if settings.apiKey.isEmpty, SettingsStore.hasAPIKey(namespace: namespace) {
        settings.apiKey = model.settings.apiKey
      }
      model.applyExternalSettings(
        settings, lastCheck: SettingsStore.loadLastCheck(namespace: namespace))
      model.refreshLaunchAtLoginStatus()
      lifecycleLog?.record(
        "configuration-reloaded model=\(model.settings.modelService.model)"
          + " host=\(model.settings.modelService.host ?? "none")"
          + " configured=\(model.isModelServiceConfigured)")
    }
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
      statusItemMark = StatusItemMark(button: button)
      if statusItemMark == nil {
        button.title = "辞"
      }
      button.setAccessibilityIdentifier("cida-status-item")
    }
    panelController?.onVisibilityChange = { [weak self] _ in
      self?.updateStatusItemBreathing()
    }
    observeGenerationForStatusItem()
    let menu = NSMenu()
    if let label = CidaBuild.current.developmentLabel {
      // A development build says so first; it runs beside the released Cida's settings.
      let development = NSMenuItem(title: label, action: nil, keyEquivalent: "")
      development.isEnabled = false
      menu.addItem(development)
      menu.addItem(.separator())
    }
    let show = NSMenuItem(title: "显示辞达", action: #selector(showPanel), keyEquivalent: "")
    show.target = self
    menu.addItem(show)
    showPanelMenuItem = show
    updateMenuItem(for: .showPanel, shortcut: model.settings.shortcut)
    let capture = NSMenuItem(
      title: "截图翻译", action: #selector(handleCaptureShortcut), keyEquivalent: "")
    capture.target = self
    menu.addItem(capture)
    captureMenuItem = capture
    updateMenuItem(for: .captureText, shortcut: model.settings.captureShortcut)
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

  /// The menu bar caret breathes while a request runs behind a hidden panel
  /// (`Design/spec/brand.md` §三).
  private func updateStatusItemBreathing() {
    guard let statusItemMark else { return }
    let isBreathing = model.isProcessing && !(panelController?.isVisible ?? false)
    guard statusItemMark.isBreathing != isBreathing else { return }
    statusItemMark.isBreathing = isBreathing
    lifecycleLog?.record(isBreathing ? "status-item-breathing" : "status-item-resting")
  }

  private func observeGenerationForStatusItem() {
    withObservationTracking {
      _ = model.isProcessing
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.updateStatusItemBreathing()
        self?.observeGenerationForStatusItem()
      }
    }
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
      if let tab = launchOptions.designState.settingsTab {
        model.settingsTab = tab
      }
      if launchOptions.designState == .settingsPromptEditing {
        model.editingPrompt = .improve
      }
      if launchOptions.designState == .settingsRecording {
        model.recordingShortcut = .showPanel
      }
      if launchOptions.designState == .settingsUpdateAvailable {
        updater.state.availableVersion = "1.1.0"
      }
      if launchOptions.designState == .settingsLanguageEditing {
        model.settings.myLanguage = "繁體中文（台灣）"
        model.focusesMyLanguageForDesign = true
      }
      switch launchOptions.designState {
      case .settingsConfigCopied:
        model.setModelServiceStateForDesign(copied: true)
      case .settingsConfigUpdated:
        model.setModelServiceStateForDesign(recentlyUpdated: true)
      case .settingsConfigChecking:
        model.setModelServiceStateForDesign(checking: true)
      case .settingsConfigFailed:
        model.setModelServiceStateForDesign(
          lastCheck: ModelServiceCheckRecord(
            passed: false, statusCode: 401, reason: "服务商拒绝了 API Key", checkedAt: Date(),
            fingerprint: model.settings.modelServiceFingerprint))
      default:
        break
      }
    #endif
    settingsWindowController = SettingsWindowFactory.makeWindowController(
      model: model, updates: updater.state)
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

  /// The card the model's result would copy, at the 2x the other state
  /// captures use, so it compares with the board's render.
  private func writeShareCardSnapshot(to outputURL: URL) {
    Task { @MainActor in
      if let result = model.result,
        case .success(let card) = ShareCard.render(
          source: result.source, result: result.result, language: result.outputLanguage, scale: 2)
      {
        do {
          try card.png.write(to: outputURL, options: .atomic)
        } catch {
          fputs("Failed to write the share card: \(error)\n", stderr)
        }
      } else {
        fputs("The design state has no share card to write.\n", stderr)
      }
      NSApp.terminate(nil)
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


// MARK: - Updates in the panel

extension CidaAppDelegate: UpdatePresenter {
  func presentUpdate(_ message: PanelMessage, handler: PanelMessageHandler) {
    model.present(message, handler: handler)
    if panelController?.isVisible != true {
      showPanel()
    }
  }

  func updateUpdateMessage(kind: String, _ change: (inout PanelMessage) -> Void) {
    model.updatePanelMessage(kind: kind, change)
  }

  func finishUpdateMessage() {
    guard model.panelMessage?.kind.hasPrefix("update-") == true else { return }
    model.clearPanelMessage()
    panelController?.hide()
  }

  var mayPresentScheduledUpdate: Bool {
    guard let launchedByUserAt else { return false }
    return Date().timeIntervalSince(launchedByUserAt) < 60
  }

  #if DEBUG
    /// The lifecycle states of `States — 生命周期` (`Design/boards/lifecycle.html`).
    fileprivate func presentDesignStateMessage() {
      let notes = [
        "模型服务改由 AI 助手配置：在设置里复制提示词，交给 Claude Code、Codex 等助手，它会帮你配好。",
        "开机启动时不再弹出面板。",
        "现在也能直接使用 Anthropic Claude 的模型。",
      ]
      let found = CidaUpdateDriver.foundMessage(
        version: "1.1.0", currentVersion: "1.0.0", notes: notes)
      let message: PanelMessage? =
        switch launchOptions.designState {
        case .lifecycleUpdateChecking: CidaUpdateDriver.checkingMessage()
        case .lifecycleUpdateFound: found
        case .lifecycleUpdateDownloading:
          CidaUpdateDriver.downloadingMessage(version: "1.1.0", percent: 38, notes: notes)
        case .lifecycleUpdateReady: CidaUpdateDriver.readyMessage(version: "1.1.0")
        case .lifecycleUpdateCurrent: CidaUpdateDriver.currentMessage(version: "1.1.0")
        case .lifecycleUpdateFailed:
          CidaUpdateDriver.failedMessage(
            from: CidaUpdateDriver.foundMessage(
              version: "1.1.0", currentVersion: "1.0.0", notes: [notes[0]]),
            note: "下载失败：网络连接失败 · ⏎ 重试")
        case .lifecycleUpdateReadOnly:
          CidaUpdateDriver.readOnlyMessage(
            version: "1.1.0", currentVersion: "1.0.0", notes: [notes[0]])
        default: nil
        }
      if let message {
        model.present(message, handler: PanelMessageHandler(choose: { _ in }, dismiss: {}))
      }
      if launchOptions.designState == .lifecycleWelcomeSubmitted {
        model.submit()
      }
      if launchOptions.designState == .targetEditing {
        model.beginEditingForeignLanguage()
      }
    }
  #endif
}

/// Why Cida is starting (`Design/spec/lifecycle.md` §四): only a launch the user asked for
/// brings the panel up.
enum LaunchSource: Equatable {
  case user
  case login
  case relaunchAfterUpdate

  @MainActor
  static func current(defaults: UserDefaults = .standard) -> LaunchSource {
    if defaults.bool(forKey: CidaUpdater.relaunchedAfterUpdateKey) {
      defaults.removeObject(forKey: CidaUpdater.relaunchedAfterUpdateKey)
      return .relaunchAfterUpdate
    }
    // Login items open with this property on the launch event, SMAppService's included.
    if let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventID == kAEOpenApplication,
      event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    {
      return .login
    }
    return .user
  }
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
  case translateIntoMine = "translate-into-mine"
  case targetEditing = "target-editing"
  case settings
  case settingsTranslation = "settings-translation"
  case settingsLanguageEditing = "settings-language-editing"
  case settingsPromptEditing = "settings-prompt-editing"
  case settingsShortcuts = "settings-shortcuts"
  case settingsShortcutsCustom = "settings-shortcuts-custom"
  case settingsShortcutsUnset = "settings-shortcuts-unset"
  case settingsRecording = "settings-recording"
  case settingsGeneral = "settings-general"
  case settingsUpdateAvailable = "settings-update-available"
  case settingsConfigUnset = "settings-config-unset"
  case settingsConfigCopied = "settings-config-copied"
  case settingsConfigReady = "settings-config-ready"
  case settingsConfigUpdated = "settings-config-updated"
  case settingsConfigChecking = "settings-config-checking"
  case settingsConfigFailed = "settings-config-failed"
  case lifecycleWelcome = "lifecycle-welcome"
  case lifecycleWelcomeSubmitted = "lifecycle-welcome-submitted"
  case lifecycleUpdateChecking = "lifecycle-update-checking"
  case lifecycleUpdateFound = "lifecycle-update-found"
  case lifecycleUpdateDownloading = "lifecycle-update-downloading"
  case lifecycleUpdateReady = "lifecycle-update-ready"
  case lifecycleUpdateCurrent = "lifecycle-update-current"
  case lifecycleUpdateFailed = "lifecycle-update-failed"
  case lifecycleUpdateReadOnly = "lifecycle-update-read-only"
  case copyMenu = "copy-menu"
  case shareTranslate = "share-translate"
  case shareRead = "share-read"
  case shareImprove = "share-improve"

  /// The share card ⇧⌘C copies (`Design/boards/share-card.html`); the snapshot
  /// is the card itself rather than a window.
  var isShareCard: Bool {
    self == .shareTranslate || self == .shareRead || self == .shareImprove
  }

  /// The empty panel before a model service is configured.
  var isWelcome: Bool {
    self == .lifecycleWelcome || self == .lifecycleWelcomeSubmitted
  }

  var isSettings: Bool { settingsTab != nil }

  /// The Settings tab the state shows, or nil for a panel state.
  var settingsTab: SettingsTab? {
    switch self {
    case .settings, .settingsConfigUnset, .settingsConfigCopied, .settingsConfigReady,
      .settingsConfigUpdated, .settingsConfigChecking, .settingsConfigFailed:
      .model
    case .settingsTranslation, .settingsLanguageEditing, .settingsPromptEditing: .translation
    case .settingsShortcuts, .settingsShortcutsCustom, .settingsShortcutsUnset, .settingsRecording:
      .shortcuts
    case .settingsGeneral, .settingsUpdateAvailable: .general
    default: nil
    }
  }
}

private struct LaunchOptions {
  let designState: DesignState
  /// The appearance a design snapshot is drawn in; nil follows the system.
  let designAppearance: NSAppearance?
  let snapshotOutputURL: URL?
  let inputInteractionOutputURL: URL?
  let performanceProbe: PerformanceProbeConfiguration?
  let snapshotDelayMilliseconds: Int
  let explicitlyIsolatedAutomation: Bool
  let isE2ETesting: Bool
  let automationOpenAIEndpoint: String?
  let automationSettingsNamespace: String?
  let lifecycleLogURL: URL?
  /// UI automation pins both permissions to "not granted" for a Settings
  /// pixel baseline, whatever the guest has granted.
  let automationDeniesPermissions: Bool

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
      if usesDesignFixtures,
        designState == .settingsConfigUnset || designState == .settingsConfigCopied
          || designState.isWelcome
      {
        settings.modelService = ModelConfiguration()
        settings.apiKey = ""
      }
      if usesDesignFixtures, designState == .settingsConfigUpdated {
        // The assistant has just moved to a model whose reasoning cannot be turned off and set
        // it to the lowest level, which the row shows beside the name.
        settings.modelService = ModelConfiguration(
          endpoint: "https://api.openai.com/v1/responses", format: .responses, model: "gpt-5",
          body: ["reasoning": .object(["effort": .string("minimal")])])
      }
      if usesDesignFixtures, designState == .settingsShortcutsCustom {
        settings.shortcut = GlobalShortcut(
          keyCode: UInt16(kVK_ANSI_T), modifiers: [.control, .option])
      }
      if usesDesignFixtures, designState == .settingsShortcutsUnset {
        // Someone who only captures text.
        settings.shortcut = nil
        settings.layerShortcut = nil
        settings.improvementShortcut = nil
      }
    #endif
    return applyingEndpointOverride(to: settings)
  }

  /// UI automation points the instance at the loopback scenario server, which needs no key.
  func applyingEndpointOverride(to settings: CidaSettings) -> CidaSettings {
    guard let automationOpenAIEndpoint else { return settings }
    var settings = settings
    settings.modelService = ModelConfiguration(
      endpoint: automationOpenAIEndpoint, format: .chatCompletions, model: "cida-local-model")
    settings.apiKey = ""
    return settings
  }

  var textProcessingService: any TextProcessingService {
    #if DEBUG
      if usesDesignFixtures, automationOpenAIEndpoint == nil {
        return PreviewTextProcessingService()
      }
    #endif
    return ModelServiceClient()
  }

  var selectionAccess: SystemPermission {
    if usesDesignFixtures { return .fixed(granted: designState == .settingsShortcutsCustom) }
    return automationDeniesPermissions ? .fixed(granted: false) : .accessibility
  }

  var captureAccess: SystemPermission {
    if usesDesignFixtures { return .fixed(granted: designState == .settingsShortcutsCustom) }
    return automationDeniesPermissions ? .fixed(granted: false) : .screenRecording
  }

  var initialMode: ProcessingMode {
    designState == .improve || designState == .shareImprove ? .improve : .translate
  }

  var initialResult: ResultRecord? {
    guard usesDesignFixtures else { return nil }
    #if DEBUG
      switch designState {
      case .translate, .copyMenu, .shareTranslate:
        return ResultRecord.designCompleted(mode: .translate)
      case .improve, .shareImprove:
        return ResultRecord.designCompleted(mode: .improve)
      case .shareRead:
        return ResultRecord.designRead()
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
      case .translateIntoMine:
        return ResultRecord.designIntoMine()
      case .targetEditing:
        return ResultRecord.designCompleted(mode: .translate)
      case .empty, .streaming, .settings, .settingsTranslation, .settingsLanguageEditing,
        .settingsPromptEditing, .settingsShortcuts, .settingsShortcutsCustom,
        .settingsShortcutsUnset, .settingsRecording, .settingsGeneral, .settingsUpdateAvailable,
        .settingsConfigUnset, .settingsConfigCopied,
        .settingsConfigReady, .settingsConfigUpdated, .settingsConfigChecking,
        .settingsConfigFailed, .lifecycleWelcome, .lifecycleWelcomeSubmitted,
        .lifecycleUpdateChecking, .lifecycleUpdateFound, .lifecycleUpdateDownloading,
        .lifecycleUpdateReady, .lifecycleUpdateCurrent, .lifecycleUpdateFailed,
        .lifecycleUpdateReadOnly:
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
      case .translate, .streaming, .stopped, .failed, .copyMenu, .shareTranslate, .targetEditing:
        ResultRecord.designTranslateSource
      case .translateIntoMine:
        ResultRecord.designIntoMineSource
      case .improve, .shareImprove:
        ResultRecord.designImproveSource
      case .shareRead:
        ResultRecord.designReadSource
      case .stale:
        "我们的系统采用了全新的存储引擎,在保证数据一致性的前提下,读写性能提升了三倍。"
      case .long:
        ResultRecord.designLongInput
      case .lifecycleWelcomeSubmitted:
        "Consistency is the last refuge of the unimaginative."
      case .empty, .settings, .settingsTranslation, .settingsLanguageEditing,
        .settingsPromptEditing, .settingsShortcuts, .settingsShortcutsCustom,
        .settingsShortcutsUnset, .settingsRecording, .settingsGeneral, .settingsUpdateAvailable,
        .settingsConfigUnset, .settingsConfigCopied,
        .settingsConfigReady, .settingsConfigUpdated, .settingsConfigChecking,
        .settingsConfigFailed, .lifecycleWelcome, .lifecycleUpdateChecking, .lifecycleUpdateFound,
        .lifecycleUpdateDownloading, .lifecycleUpdateReady, .lifecycleUpdateCurrent,
        .lifecycleUpdateFailed, .lifecycleUpdateReadOnly:
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
    automationDeniesPermissions =
      explicitlyIsolatedAutomation
      && arguments.value(after: "--automation-permissions") == "denied"
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
    // `dark-<state>` is the state in the dark appearance (`Design/boards/appearance.html`).
    let requestedState = arguments.value(after: "--design-state")
    designAppearance = requestedState?.hasPrefix("dark-") == true ? NSAppearance(named: .darkAqua) : nil
    designState =
      requestedState.map { $0.hasPrefix("dark-") ? String($0.dropFirst("dark-".count)) : $0 }
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
