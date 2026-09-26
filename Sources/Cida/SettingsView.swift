import AppKit
import SwiftUI

/// The Settings tabs (`Design/spec/settings.md` §一), in the order a new user needs them:
/// which model, what and how to translate, how to summon Cida and what it may read, and the
/// app itself.
enum SettingsTab: String, CaseIterable {
  case model
  case translation
  case shortcuts
  case general

  var title: String {
    switch self {
    case .model: "模型"
    case .translation: "翻译"
    case .shortcuts: "快捷键"
    case .general: "通用"
    }
  }

  var icon: LucideIconName {
    switch self {
    case .model: .sparkles
    case .translation: .languages
    case .shortcuts: .keyboard
    case .general: .slidersHorizontal
    }
  }
}

/// The Settings window (`Design/spec/settings.md`, `Design/boards/settings-states.html`): four
/// tabs under the titlebar, each as tall as its content. Everything saves itself.
struct SettingsWindowView: View {
  @Bindable var model: AppModel
  let updates: UpdateState
  /// The tallest the window's content may be; below the tabs the groups scroll past it.
  @State private var maxContentHeight: CGFloat
  /// The tab's natural height, measured on every layout.
  @State private var bodyHeight: CGFloat?

  init(
    model: AppModel, updates: UpdateState,
    maxContentHeight: CGFloat = SettingsWindowFactory.screenContentHeight()
  ) {
    self.model = model
    self.updates = updates
    _maxContentHeight = State(initialValue: maxContentHeight)
  }

  var body: some View {
    WindowSurface {
      VStack(spacing: 0) {
        SettingsTitlebar(title: model.settingsTab.title)
        SettingsTabBar(selection: $model.settingsTab)
        Hairline()
        ScrollView(.vertical) {
          SettingsBody(model: model, updates: updates)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(
          height: bodyHeight.map {
            min($0, maxContentHeight - SettingsWindowFactory.chromeHeight)
          })
      }
    }
    .frame(width: SettingsWindowFactory.width)
    .fixedSize(horizontal: false, vertical: true)
    // While the window animates to a new height the content stays put at the top; the window
    // reveals or covers its bottom.
    .frame(maxHeight: .infinity, alignment: .top)
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
    ) { _ in
      maxContentHeight = SettingsWindowFactory.screenContentHeight()
    }
  }
}

/// Builds the Settings window around a hosting controller whose preferred content size drives
/// the window height, so switching tabs or expanding a prompt resizes the window instead of
/// scrolling it, up to the screen's visible height (minus the menu bar and the Dock); a smaller
/// screen scrolls the tab instead. The window follows over `motion-height-ms` with its top edge
/// fixed (`CidaWindow.animatesHeightChanges`, `Design/spec/settings.md` §一).
@MainActor
enum SettingsWindowFactory {
  static let width: CGFloat = 560
  /// The compact title bar the window's empty toolbar gives on macOS 26 (`CidaWindowFactory`).
  static let titlebarHeight: CGFloat = 40
  /// The tabs under the title bar and the space below them, above the hairline.
  static let tabBarHeight: CGFloat = 56
  /// Everything above the tab's content: title bar, tabs and hairline.
  static var chromeHeight: CGFloat { titlebarHeight + tabBarHeight + 1 }

  /// The visible height of the screen Settings opens on, where the Dock and the menu bar leave
  /// room for windows.
  static func screenContentHeight() -> CGFloat {
    NSScreen.main?.visibleFrame.height ?? .greatestFiniteMagnitude
  }

  static func makeWindowController(
    model: AppModel, updates: UpdateState,
    maxContentHeight: CGFloat = screenContentHeight()
  ) -> NSWindowController {
    let hostingController = NSHostingController(
      rootView: SettingsWindowView(
        model: model, updates: updates, maxContentHeight: maxContentHeight))
    hostingController.sizingOptions = [.preferredContentSize]
    // The titlebar is drawn by `SettingsTitlebar` inside the content; without
    // this SwiftUI would add the system titlebar's safe area to the height.
    hostingController.safeAreaRegions = []
    // The first pass measures the tab; the second sizes the window from it.
    hostingController.view.layoutSubtreeIfNeeded()
    hostingController.view.layoutSubtreeIfNeeded()
    let initialHeight = hostingController.view.fittingSize.height
    let window = CidaWindowFactory.makeWindow(
      size: CGSize(width: width, height: initialHeight),
      minimumSize: CGSize(width: width, height: 200),
      title: model.settingsTab.title
    )
    window.styleMask.remove(.resizable)
    window.contentViewController = hostingController
    // The title names the tab, so the window is found by this instead.
    window.setAccessibilityIdentifier("settings-window")
    hostingController.view.setAccessibilityLabel("设置窗口内容")
    window.setContentSize(CGSize(width: width, height: initialHeight))
    window.center()
    window.animatesHeightChanges = true
    followTabTitle(of: model, in: window)
    return NSWindowController(window: window)
  }

  /// Keeps the window's own title (the Window menu, VoiceOver, Mission Control) on the tab.
  private static func followTabTitle(of model: AppModel, in window: NSWindow) {
    withObservationTracking {
      window.title = model.settingsTab.title
    } onChange: { [weak window] in
      Task { @MainActor in
        guard let window else { return }
        followTabTitle(of: model, in: window)
      }
    }
  }
}

private struct SettingsTitlebar: View {
  let title: String

  var body: some View {
    ZStack {
      Text(title)
        .font(CidaDesign.ui(13, weight: .semibold))
        .foregroundStyle(CidaDesign.textPrimary)
        .accessibilityAddTraits(.isHeader)
    }
    .frame(maxWidth: .infinity)
    .frame(height: SettingsWindowFactory.titlebarHeight)
  }
}

/// Four tabs centred under the title: a Lucide icon over its name. The chosen one sits on
/// `surface-dim` with the icon in `accent`.
private struct SettingsTabBar: View {
  @Binding var selection: SettingsTab

  var body: some View {
    HStack(spacing: 4) {
      ForEach(SettingsTab.allCases, id: \.self) { tab in
        let isSelected = tab == selection
        Button {
          selection = tab
        } label: {
          VStack(spacing: 3) {
            LucideIcon(tab.icon, size: 18)
              .foregroundStyle(isSelected ? CidaDesign.accent : CidaDesign.textSecondary)
            Text(tab.title)
              .font(CidaDesign.ui(11.5, weight: .medium))
              .foregroundStyle(isSelected ? CidaDesign.textPrimary : CidaDesign.textSecondary)
          }
          .frame(width: 76, height: 46)
          .background(isSelected ? CidaDesign.surfaceDim : .clear)
          .clipShape(.rect(cornerRadius: CidaDesign.Radius.card, style: .continuous))
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: SettingsWindowFactory.tabBarHeight, alignment: .top)
  }
}

private struct SettingsBody: View {
  @Bindable var model: AppModel
  let updates: UpdateState

  var body: some View {
    VStack(spacing: 0) {
      switch model.settingsTab {
      case .model:
        // One group a tab needs no heading: the title already names it.
        SettingsGroup(isFirst: true) {
          ModelServiceGroup(model: model)
        }
      case .translation:
        SettingsGroup(title: "语言", isFirst: true) {
          LanguagesRow(model: model)
        }
        Hairline()
        SettingsGroup(title: "提示词") {
          PromptRow(model: model, mode: .translate)
          PromptRow(model: model, mode: .improve)
        }
      case .shortcuts:
        SettingsGroup(title: "快捷键", isFirst: true) {
          GlobalShortcutRow(model: model, action: .showPanel)
          GlobalShortcutRow(model: model, action: .captureText)
          GlobalShortcutRow(model: model, action: .translationLayer)
        }
        Hairline()
        SettingsGroup(title: "权限") {
          AccessibilityPermissionRow(model: model)
          ScreenRecordingPermissionRow(model: model)
        }
      case .general:
        SettingsGroup(isFirst: true) {
          LaunchAtLoginRow(model: model)
          AutomaticUpdatesRow(updates: updates)
        }
        AboutFooter()
      }
    }
    .padding(.top, 6)
    .padding(.horizontal, CidaDesign.Spacing.windowHorizontal)
    .padding(.bottom, 24)
    .onChange(of: model.settings) {
      model.scheduleSettingsPersistence()
    }
    .alert(
      "设置错误",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { presented in
          if !presented { model.errorMessage = nil }
        }
      )
    ) {
      Button("好") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }
}

// MARK: - Languages

/// The user's two languages in one row (`Design/spec/settings.md` §三): mine on the left, the
/// foreign one on the right. Both are free text the model reads, so a dialect, a regional variant
/// or a register works as well as a language. An emptied field takes its default back when it
/// loses focus. One row keeps the window whole on a 14-inch screen.
private struct LanguagesRow: View {
  @Bindable var model: AppModel
  @FocusState private var focused: Side?

  enum Side {
    case mine, foreign
  }

  var body: some View {
    SettingsRow(title: "互译", caption: "其他语言都译成左边") {
      HStack(spacing: 10) {
        SettingsTextField(
          text: $model.settings.myLanguage,
          placeholder: defaults.my,
          accessibilityLabel: "我的语言",
          accessibilityIdentifier: "settings-my-language-editor",
          isFocused: focused == .mine
        )
        .focused($focused, equals: .mine)
        Text("⇄")
          .font(CidaDesign.ui(13))
          .foregroundStyle(CidaDesign.textTertiary)
          .accessibilityHidden(true)
        SettingsTextField(
          text: $model.settings.foreignLanguage,
          placeholder: defaults.foreign,
          accessibilityLabel: "常用外语",
          accessibilityIdentifier: "settings-foreign-language-editor",
          isFocused: focused == .foreign
        )
        .focused($focused, equals: .foreign)
      }
    }
    .onChange(of: focused) { previous, _ in
      if let previous { restoreDefaultIfEmpty(previous) }
    }
    .onAppear {
      #if DEBUG
        if model.focusesForeignLanguageForDesign { focused = .foreign }
      #endif
    }
  }

  private var defaults: (my: String, foreign: String) {
    CidaSettings.defaultLanguages()
  }

  private func restoreDefaultIfEmpty(_ side: Side) {
    let isEmpty = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    switch side {
    case .mine where isEmpty(model.settings.myLanguage):
      model.settings.myLanguage = defaults.my
    case .foreign where isEmpty(model.settings.foreignLanguage):
      model.settings.foreignLanguage = defaults.foreign
    default:
      break
    }
  }
}

/// A single-line field: Inter 12.5 on `surface`, a 1.5 pt accent rule while focused. The owner
/// attaches the focus binding.
private struct SettingsTextField: View {
  @Binding var text: String
  let placeholder: String
  let accessibilityLabel: String
  let accessibilityIdentifier: String
  let isFocused: Bool

  var body: some View {
    TextField(placeholder, text: $text)
      .textFieldStyle(.plain)
      .font(CidaDesign.ui(12.5))
      .foregroundStyle(CidaDesign.textPrimary)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity)
      .frame(height: 30)
      .background(CidaDesign.surface)
      .clipShape(.rect(cornerRadius: CidaDesign.Radius.segment, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: CidaDesign.Radius.segment, style: .continuous)
          .strokeBorder(
            isFocused ? CidaDesign.accent : CidaDesign.border, lineWidth: isFocused ? 1.5 : 1)
      }
      .accessibilityLabel(accessibilityLabel)
      .accessibilityIdentifier(accessibilityIdentifier)
  }
}

// MARK: - Layout pieces

/// A group of rows; the first in a tab sits 12 pt under the tab bar, the next 20 pt under
/// its hairline.
private struct SettingsGroup<Content: View>: View {
  var title: String? = nil
  var isFirst = false
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let title {
        Text(title)
          .font(CidaDesign.ui(12, weight: .semibold))
          .foregroundStyle(CidaDesign.textControl)
          .frame(height: 17)
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, isFirst ? 12 : 20)
  }
}

/// Label column (120 pt) beside a control column that fills the row.
private struct SettingsRow<Control: View>: View {
  let title: String
  var caption: String? = nil
  var verticalPadding: CGFloat = 9
  var alignment: Alignment = .leading
  @ViewBuilder let control: Control

  var body: some View {
    HStack(alignment: .center, spacing: 24) {
      SettingsLabel(title, caption: caption)
        .frame(width: 120, alignment: .leading)
      control
        .frame(maxWidth: .infinity, alignment: alignment)
    }
    .padding(.vertical, verticalPadding)
  }
}

private struct SettingsLabel: View {
  let title: String
  let caption: String?

  init(_ title: String, caption: String? = nil) {
    self.title = title
    self.caption = caption
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(CidaDesign.ui(13.5))
        .foregroundStyle(CidaDesign.textPrimary)
        .frame(height: 20)
      if let caption {
        Text(caption)
          .font(CidaDesign.ui(11.5))
          .foregroundStyle(CidaDesign.textTertiary)
          .lineLimit(1)
      }
    }
  }
}

/// The bordered button of every row; highlighted, it is the copied feedback on `accent-soft`.
private struct SettingsBorderedButtonStyle: ButtonStyle {
  var isHighlighted = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(CidaDesign.ui(12.5, weight: .medium))
      .foregroundStyle(isHighlighted ? CidaDesign.accent : CidaDesign.textControl)
      .padding(.horizontal, 12)
      .frame(height: 30)
      .background(
        (isHighlighted ? CidaDesign.accentSoft : CidaDesign.surface)
          .opacity(configuration.isPressed ? 0.7 : 1)
      )
      .clipShape(.rect(cornerRadius: CidaDesign.Radius.card, style: .continuous))
      .overlay {
        if !isHighlighted {
          RoundedRectangle(cornerRadius: CidaDesign.Radius.card, style: .continuous)
            .strokeBorder(CidaDesign.border, lineWidth: 1)
        }
      }
  }
}

// MARK: - 模型

/// The model service is configured by an AI assistant through the command line; this group
/// shows where it stands and copies the prompt (`Design/spec/configuration.md` §四).
private struct ModelServiceGroup: View {
  @Bindable var model: AppModel

  var body: some View {
    if model.isModelServiceConfigured {
      ModelServiceRow(model: model)
      if let note = model.modelServiceStatus.failureNote {
        ModelServiceFailureNote(text: note)
      }
      SettingsRow(title: "调整配置", caption: "交给 AI 助手", alignment: .trailing) {
        CopyConfigurationPromptButton(model: model)
      }
    } else {
      ModelServiceOnboardingCard(model: model)
    }
  }
}

/// No service yet: one sheet of paper that says what to do next.
private struct ModelServiceOnboardingCard: View {
  @Bindable var model: AppModel

  private var caption: String {
    model.hasCopiedConfigurationPrompt
      ? "已复制。粘贴给你的 AI 助手，配好后这里会自动更新。"
      // One sentence a line, as the board sets it at this width.
      : "复制配置提示词，交给 Claude Code、Codex 等 AI 助手。\n它会问你用哪家服务，配好后自己检查。"
  }

  var body: some View {
    HStack(alignment: .center, spacing: 24) {
      VStack(alignment: .leading, spacing: 4) {
        Text("还没有模型服务")
          .font(CidaDesign.ui(13.5, weight: .medium))
          .foregroundStyle(CidaDesign.textPrimary)
          .frame(height: 20)
        Text(caption)
          .font(CidaDesign.ui(11.5))
          .foregroundStyle(CidaDesign.textTertiary)
          // The board's 17 pt lines: 3 pt between lines and half of it above and below.
          .lineSpacing(3)
          .padding(.vertical, 1.5)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("settings-model-onboarding-caption")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      CopyConfigurationPromptButton(model: model)
    }
    .padding(.vertical, 16)
    .padding(.horizontal, 18)
    .background(CidaDesign.surfacePaper)
    .clipShape(.rect(cornerRadius: CidaDesign.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: CidaDesign.Radius.card, style: .continuous)
        .strokeBorder(CidaDesign.border, lineWidth: 1)
    }
    .padding(.top, 10)
    .padding(.bottom, 12)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-model-onboarding")
  }
}

/// 模型服务: the status under the label, the model and where it runs, and 检查.
private struct ModelServiceRow: View {
  @Bindable var model: AppModel

  private var status: ModelServiceStatus { model.modelServiceStatus }

  private var statusText: String {
    model.isModelServiceRecentlyUpdated ? "\(status.caption) · 刚刚更新" : status.caption
  }

  var body: some View {
    HStack(alignment: .center, spacing: 24) {
      VStack(alignment: .leading, spacing: 3) {
        Text("模型服务")
          .font(CidaDesign.ui(13.5))
          .foregroundStyle(CidaDesign.textPrimary)
          .frame(height: 20)
        HStack(spacing: 6) {
          Circle()
            .fill(status.isReady ? CidaDesign.accent : CidaDesign.textTertiary)
            .frame(width: 6, height: 6)
          Text(statusText)
            .font(CidaDesign.ui(11.5))
            .foregroundStyle(CidaDesign.textTertiary)
            .lineLimit(1)
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-model-status")
      }
      .frame(width: 120, alignment: .leading)

      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text(model.settings.modelService.model)
            .font(CidaDesign.ui(13.5))
            .foregroundStyle(CidaDesign.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(height: 20)
          Text(model.settings.modelService.hostAndFormat)
            .font(CidaDesign.ui(11.5))
            .foregroundStyle(CidaDesign.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-model-summary")
        Spacer(minLength: 8)
        Button(status == .checking ? "检查中…" : "检查") {
          Task { await model.checkModelService() }
        }
        .buttonStyle(SettingsBorderedButtonStyle())
        .disabled(status == .checking)
        .accessibilityIdentifier("settings-model-check")
      }
      .frame(maxWidth: .infinity)
    }
    .padding(.vertical, 9)
  }
}

/// Under a failed check, starting at the control column: what failed and how to fix it.
private struct ModelServiceFailureNote: View {
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      LucideIcon(.circleAlert, size: 13)
        .foregroundStyle(CidaDesign.textTertiary)
        .padding(.top, 2)
      Text(text)
        .font(CidaDesign.ui(11.5))
        .foregroundStyle(CidaDesign.textSecondary)
        .lineSpacing(3)
        .padding(.vertical, 1.5)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.leading, 144)
    .padding(.top, -2)
    .padding(.bottom, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("settings-model-failure")
  }
}

/// Copies the configuration prompt; for 800 ms it says ✓ 已复制 on `accent-soft`, like the
/// panel's copied feedback.
private struct CopyConfigurationPromptButton: View {
  @Bindable var model: AppModel

  var body: some View {
    let isCopied = model.isShowingConfigurationPromptCopied
    Button(action: model.copyConfigurationPrompt) {
      HStack(spacing: 6) {
        LucideIcon(isCopied ? .check : .copy, size: 12)
          .foregroundStyle(isCopied ? CidaDesign.accent : CidaDesign.textSecondary)
        Text(isCopied ? "已复制" : "复制配置提示词")
      }
    }
    .buttonStyle(SettingsBorderedButtonStyle(isHighlighted: isCopied))
    // The panel's 已复制 cross-fades over `motion-icon-swap-ms`; this one does too.
    .animation(.easeOut(duration: CidaMotion.iconSwapSeconds), value: isCopied)
    .accessibilityLabel(isCopied ? "已复制" : "复制配置提示词")
    .accessibilityIdentifier("settings-copy-configuration-prompt")
  }
}

// MARK: - 提示词

private struct PromptRow: View {
  @Bindable var model: AppModel
  let mode: ProcessingMode

  private var prompt: Binding<String> {
    mode == .translate ? $model.settings.translationPrompt : $model.settings.improvementPrompt
  }

  var body: some View {
    if model.editingPrompt == mode {
      ExpandedPromptRow(
        mode: mode,
        prompt: prompt,
        reset: mode == .translate ? model.resetTranslationPrompt : model.resetImprovementPrompt
      )
    } else {
      CollapsedPromptRow(mode: mode, preview: prompt.wrappedValue) {
        model.editingPrompt = mode
      }
    }
  }
}

private struct CollapsedPromptRow: View {
  let mode: ProcessingMode
  let preview: String
  let edit: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 24) {
      SettingsLabel(mode.title, caption: preview)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("编辑", action: edit)
        .buttonStyle(SettingsBorderedButtonStyle())
        .accessibilityIdentifier("settings-prompt-edit-\(mode.rawValue)")
    }
    .padding(.vertical, 10)
  }
}

/// The prompt sheet: paper under the text the model will read.
private struct ExpandedPromptRow: View {
  let mode: ProcessingMode
  @Binding var prompt: String
  let reset: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(mode.title)
          .font(CidaDesign.ui(13.5))
          .foregroundStyle(CidaDesign.textPrimary)
        Spacer()
        Button("恢复默认", action: reset)
          .buttonStyle(.plain)
          .font(CidaDesign.ui(12, weight: .medium))
          .foregroundStyle(CidaDesign.textSecondary)
          .accessibilityIdentifier("settings-prompt-reset-\(mode.rawValue)")
      }
      .frame(height: 20)

      PromptTextEditor(
        text: $prompt,
        accessibilityLabel: "\(mode.title)提示词",
        accessibilityIdentifier: "settings-prompt-editor-\(mode.rawValue)"
      )
      .frame(height: 92)
      .background(CidaDesign.surfacePaper)
      .clipShape(.rect(cornerRadius: CidaDesign.Radius.card, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: CidaDesign.Radius.card, style: .continuous)
          .strokeBorder(CidaDesign.accent, lineWidth: 1.5)
      }

      Text("自动保存 · 目标语言与任务由应用传入，不必写占位符")
        .font(CidaDesign.ui(11.5))
        .foregroundStyle(CidaDesign.textTertiary)
        .frame(height: 17)
    }
    .padding(.vertical, 10)
  }
}

// MARK: - 快捷键

/// The key chip is the recorder: a click waits for the next combination,
/// which is registered before it is kept (`Design/spec/settings.md` §四).
private struct GlobalShortcutRow: View {
  @Bindable var model: AppModel
  let action: GlobalShortcutAction
  @State private var feedback: Feedback?

  /// What the caption says instead of the row's purpose: the recording hint,
  /// or why the last press changed nothing.
  private enum Feedback {
    case missingModifier
    case rejected
  }

  private var isRecording: Bool {
    model.recordingShortcut == action
  }

  private var shortcut: GlobalShortcut {
    model.settings.shortcut(for: action)
  }

  private var title: String {
    switch action {
    case .showPanel: "显示辞达"
    case .captureText: "截图翻译"
    case .translationLayer: "翻译图层"
    }
  }

  private var caption: String {
    if isRecording {
      return feedback == .missingModifier ? "要带 ⌘、⌥ 或 ⌃" : "Esc 取消"
    }
    if feedback == .rejected { return "这个组合已被占用，换一个" }
    switch action {
    case .showPanel: return "在任何应用里唤起"
    case .captureText: return "框选屏幕文字并翻译"
    case .translationLayer: return "在原处翻译外文"
    }
  }

  private var identifierPrefix: String {
    switch action {
    case .showPanel: "settings-shortcut"
    case .captureText: "settings-capture-shortcut"
    case .translationLayer: "settings-layer-shortcut"
    }
  }

  private var accessibilityName: String {
    switch action {
    case .showPanel: "显示辞达快捷键"
    case .captureText: "截图翻译快捷键"
    case .translationLayer: "翻译图层快捷键"
    }
  }

  var body: some View {
    SettingsRow(title: title, caption: caption, alignment: .trailing) {
      HStack(spacing: 12) {
        if shortcut != action.defaultShortcut, !isRecording {
          Button("恢复默认") {
            feedback = model.setShortcut(action.defaultShortcut, for: action) ? nil : .rejected
          }
          .buttonStyle(.plain)
          .font(CidaDesign.ui(12, weight: .medium))
          .foregroundStyle(CidaDesign.textSecondary)
          .accessibilityIdentifier("\(identifierPrefix)-reset")
        }
        Button {
          feedback = nil
          model.recordingShortcut = action
        } label: {
          ShortcutChip(
            text: isRecording ? "按下新组合…" : shortcut.displayText,
            isRecording: isRecording)
        }
        .buttonStyle(.plain)
        .background {
          ShortcutCaptureView(
            isRecording: Binding(
              get: { model.recordingShortcut == action },
              set: { recording in
                if recording {
                  model.recordingShortcut = action
                } else if model.recordingShortcut == action {
                  model.recordingShortcut = nil
                }
              }),
            onCapture: { newShortcut in
              feedback = model.setShortcut(newShortcut, for: action) ? nil : .rejected
            },
            onInvalidPress: { feedback = .missingModifier })
        }
        .accessibilityLabel(
          isRecording ? "按下新的\(accessibilityName)" : "\(accessibilityName) \(shortcut.displayText)")
        .accessibilityIdentifier(identifierPrefix)
      }
    }
  }
}

private struct ShortcutChip: View {
  let text: String
  let isRecording: Bool

  var body: some View {
    Text(text)
      .font(CidaDesign.ui(12, weight: .medium))
      .foregroundStyle(isRecording ? CidaDesign.textTertiary : CidaDesign.textSecondary)
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(isRecording ? CidaDesign.surface : CidaDesign.surfaceDim)
      .clipShape(.rect(cornerRadius: CidaDesign.Radius.chip, style: .continuous))
      .overlay {
        if isRecording {
          RoundedRectangle(cornerRadius: CidaDesign.Radius.chip, style: .continuous)
            .strokeBorder(CidaDesign.accent, lineWidth: 1.5)
        }
      }
  }
}

// MARK: - 权限

/// Accessibility lets Option-Space bring in the frontmost application's selection and lets the
/// translation layer read other applications' text (`Design/spec/settings.md` §五). There is no
/// switch: granting turns both on, revoking in System Settings turns them off.
private struct AccessibilityPermissionRow: View {
  @Bindable var model: AppModel

  var body: some View {
    PermissionRow(
      title: "辅助功能", caption: "选中文字与原处翻译", isGranted: model.isSelectionAccessGranted,
      request: model.requestSelectionAccess, identifier: "settings-selection-access"
    )
    // The system does not say when the permission changes for this process;
    // re-read it when the user comes back to the window and when the list of
    // allowed applications changes.
    .onAppear(perform: model.refreshSelectionAccess)
    .onReceive(
      NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
    ) { _ in
      model.refreshSelectionAccess()
    }
    .onReceive(
      DistributedNotificationCenter.default()
        .publisher(for: SystemPermission.accessibilityDidChangeNotification)
        .receive(on: DispatchQueue.main)
    ) { _ in
      Task { @MainActor in
        // The new state is readable shortly after the notification.
        try? await Task.sleep(for: .milliseconds(300))
        model.refreshSelectionAccess()
      }
    }
  }
}

/// Screen Recording lets the capture shortcut freeze the screen and lets the translation
/// layer match the page's colours and follow it while it scrolls.
private struct ScreenRecordingPermissionRow: View {
  @Bindable var model: AppModel

  var body: some View {
    PermissionRow(
      title: "屏幕录制", caption: "截图与图层跟随", isGranted: model.isCaptureAccessGranted,
      request: model.requestCaptureAccess, identifier: "settings-capture-access"
    )
    .onAppear(perform: model.refreshCaptureAccess)
    .onReceive(
      NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
    ) { _ in
      model.refreshCaptureAccess()
    }
  }
}

/// 已开启 once granted, otherwise 去授权, which asks the system.
private struct PermissionRow: View {
  let title: String
  let caption: String
  let isGranted: Bool
  let request: () -> Void
  let identifier: String

  var body: some View {
    SettingsRow(title: title, caption: caption, alignment: .trailing) {
      if isGranted {
        Text("已开启")
          .font(CidaDesign.ui(12, weight: .medium))
          .foregroundStyle(CidaDesign.textSecondary)
          .frame(height: 30)
          .accessibilityIdentifier("\(identifier)-granted")
      } else {
        Button("去授权", action: request)
          .buttonStyle(SettingsBorderedButtonStyle())
          .accessibilityIdentifier("\(identifier)-request")
      }
    }
  }
}

// MARK: - 通用

private struct LaunchAtLoginRow: View {
  @Bindable var model: AppModel

  var body: some View {
    SettingsRow(title: "开机启动", alignment: .trailing) {
      Toggle(
        "",
        isOn: Binding(
          get: { model.settings.launchAtLogin },
          set: { enabled in
            model.setLaunchAtLogin(enabled)
          }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .tint(CidaDesign.accent)
      .controlSize(.small)
      .accessibilityIdentifier("settings-launch-at-login-toggle")
    }
    .onAppear(perform: model.refreshLaunchAtLoginStatus)
  }
}

/// One row (`Design/spec/settings.md` §六): checking daily is a switch, checking now or
/// installing what a scheduled check found is the button beside it.
private struct AutomaticUpdatesRow: View {
  let updates: UpdateState

  var body: some View {
    SettingsRow(
      title: "自动检查更新",
      caption: updates.availableVersion.map { "新版本 \($0) 可以安装" } ?? "每天检查一次",
      alignment: .trailing
    ) {
      HStack(spacing: 12) {
        Button(updates.availableVersion == nil ? "检查更新" : "安装…", action: updates.checkForUpdates)
          .buttonStyle(SettingsBorderedButtonStyle())
          .accessibilityIdentifier("settings-check-for-updates")
        Toggle(
          "",
          isOn: Binding(
            get: { updates.automaticallyChecks },
            set: { updates.setAutomaticallyChecks($0) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .tint(CidaDesign.accent)
        .controlSize(.small)
        .accessibilityIdentifier("settings-automatic-updates-toggle")
      }
    }
  }
}

private struct AboutFooter: View {
  /// The bundle's CFBundleShortVersionString; a release build sets it from its tag. Unbundled
  /// runs (`swift run`) have none and show only the motto.
  private let version =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

  var body: some View {
    HStack(spacing: 8) {
      CidaWordmark()
      Text(version.map { "\($0) · 辞达而已矣" } ?? "辞达而已矣")
        .font(CidaDesign.ui(11))
        .foregroundStyle(CidaDesign.textTertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 26)
  }
}
