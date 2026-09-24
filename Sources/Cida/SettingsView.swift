import AppKit
import SwiftUI

/// The Settings window (Pencil `Spec — 设置`, `States — 设置`): three groups
/// that answer, in order, which model, how to translate or improve, and how
/// to summon the panel. Everything saves itself; the window is as tall as
/// its content.
struct SettingsWindowView: View {
  @Bindable var model: AppModel

  init(model: AppModel) {
    self.model = model
  }

  var body: some View {
    WindowSurface {
      VStack(spacing: 0) {
        SettingsTitlebar()
        SettingsBody(model: model)
      }
    }
    .frame(width: SettingsWindowFactory.width)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// Builds the Settings window around a hosting controller whose preferred
/// content size drives the window height, so expanding a prompt grows the
/// window instead of scrolling it.
@MainActor
enum SettingsWindowFactory {
  static let width: CGFloat = 560
  static let titlebarHeight: CGFloat = 46

  static func makeWindowController(model: AppModel) -> NSWindowController {
    let hostingController = NSHostingController(rootView: SettingsWindowView(model: model))
    hostingController.sizingOptions = [.preferredContentSize]
    // The titlebar is drawn by `SettingsTitlebar` inside the content; without
    // this SwiftUI would add the system titlebar's safe area to the height.
    hostingController.safeAreaRegions = []
    let initialSize = hostingController.view.fittingSize
    let window = CidaWindowFactory.makeWindow(
      size: CGSize(width: width, height: initialSize.height),
      minimumSize: CGSize(width: width, height: 200),
      title: "设置"
    )
    window.styleMask.remove(.resizable)
    window.contentViewController = hostingController
    hostingController.view.setAccessibilityLabel("设置窗口内容")
    window.setContentSize(CGSize(width: width, height: initialSize.height))
    window.center()
    return NSWindowController(window: window)
  }
}

private struct SettingsTitlebar: View {
  var body: some View {
    ZStack {
      Text("设置")
        .font(CidaDesign.ui(13, weight: .semibold))
        .foregroundStyle(CidaDesign.textPrimary)
        .accessibilityAddTraits(.isHeader)
    }
    .frame(maxWidth: .infinity)
    .frame(height: SettingsWindowFactory.titlebarHeight)
  }
}

private struct SettingsBody: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      SettingsGroup(title: "模型", isFirst: true) {
        ProviderRow(model: model)
        if model.settings.provider.isCustom {
          EndpointRow(model: model)
        }
        if model.settings.provider.isCustom {
          ModelRow(model: model)
          APIKeyRow(model: model)
        } else {
          APIKeyRow(model: model)
          ModelRow(model: model)
        }
        ReadinessRow(readiness: model.settings.readiness)
      }
      Hairline()
      SettingsGroup(title: "提示词") {
        PromptRow(model: model, mode: .translate)
        PromptRow(model: model, mode: .improve)
      }
      Hairline()
      SettingsGroup(title: "唤起") {
        GlobalShortcutRow(model: model)
        LaunchAtLoginRow(model: model)
      }
      AboutFooter()
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

// MARK: - Layout pieces

private struct SettingsGroup<Content: View>: View {
  let title: String
  var isFirst = false
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title)
        .font(CidaDesign.ui(12, weight: .semibold))
        .foregroundStyle(CidaDesign.textControl)
        .frame(height: 17)
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

private struct SettingsMenu<Value: Hashable>: View {
  let valueLabel: String
  let values: [Value]
  let title: (Value) -> String
  let onSelect: (Value) -> Void

  var body: some View {
    Menu {
      ForEach(values, id: \.self) { value in
        Button(title(value)) { onSelect(value) }
      }
    } label: {
      HStack(spacing: 6) {
        Text(valueLabel)
          .font(CidaDesign.ui(12.5, weight: .medium))
          .foregroundStyle(CidaDesign.textPrimary)
        Image(systemName: "chevron.down")
          .font(.system(size: 7.5, weight: .semibold))
          .frame(width: 12, height: 12)
          .foregroundStyle(CidaDesign.textTertiary)
      }
      .padding(.horizontal, 10)
      .frame(height: 25)
      .background(CidaDesign.surface)
      .clipShape(.rect(cornerRadius: CidaDesign.Radius.segment, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: CidaDesign.Radius.segment, style: .continuous)
          .strokeBorder(CidaDesign.border, lineWidth: 1)
      }
    }
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .fixedSize()
  }
}

/// A bordered text field that fills its column; the border turns accent while
/// it has focus.
private struct SettingsTextField: View {
  @Binding var text: String
  let placeholder: String
  let accessibilityIdentifier: String
  var usesMonospacedFont = true
  @FocusState private var isFocused: Bool

  var body: some View {
    TextField(placeholder, text: $text)
      .textFieldStyle(.plain)
      .font(usesMonospacedFont ? CidaDesign.mono(11.5) : CidaDesign.ui(12.5))
      .foregroundStyle(CidaDesign.textPrimary)
      .focused($isFocused)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity)
      .frame(height: 30)
      .background(CidaDesign.surface)
      .clipShape(.rect(cornerRadius: CidaDesign.Radius.segment, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: CidaDesign.Radius.segment, style: .continuous)
          .strokeBorder(isFocused ? CidaDesign.accent : CidaDesign.border, lineWidth: isFocused ? 1.5 : 1)
      }
      .accessibilityIdentifier(accessibilityIdentifier)
  }
}

private struct SettingsBorderedButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(CidaDesign.ui(12.5, weight: .medium))
      .foregroundStyle(CidaDesign.textControl)
      .padding(.horizontal, 12)
      .frame(height: 30)
      .background(CidaDesign.surface.opacity(configuration.isPressed ? 0.7 : 1))
      .clipShape(.rect(cornerRadius: CidaDesign.Radius.card, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: CidaDesign.Radius.card, style: .continuous)
          .strokeBorder(CidaDesign.border, lineWidth: 1)
      }
  }
}

// MARK: - 模型

private struct ProviderRow: View {
  @Bindable var model: AppModel

  var body: some View {
    SettingsRow(title: "服务商") {
      VStack(alignment: .leading, spacing: 5) {
        SettingsMenu(
          valueLabel: model.settings.provider.displayName,
          values: ModelProvider.allCases,
          title: \.displayName,
          onSelect: model.selectProvider
        )
        .accessibilityIdentifier("settings-provider-menu")
        if let caption = model.settings.provider.endpointCaption {
          Text(caption)
            .font(CidaDesign.ui(11.5))
            .foregroundStyle(CidaDesign.textTertiary)
            .accessibilityIdentifier("settings-provider-endpoint-caption")
        }
      }
    }
  }
}

private struct EndpointRow: View {
  @Bindable var model: AppModel

  var body: some View {
    SettingsRow(title: "端点", caption: "OpenAI 格式的接口") {
      SettingsTextField(
        text: $model.settings.customEndpoint,
        placeholder: "http://127.0.0.1:8080/v1/chat/completions",
        accessibilityIdentifier: "settings-endpoint"
      )
    }
  }
}

/// Presets offer their models in a menu whose last item switches to a typed
/// model; a custom endpoint always takes a typed model.
private struct ModelRow: View {
  @Bindable var model: AppModel

  private var suggestions: [String] {
    model.settings.provider.suggestedModels
  }

  private var showsField: Bool {
    model.settings.provider.isCustom || !suggestions.contains(model.settings.model)
  }

  var body: some View {
    SettingsRow(title: "模型") {
      if showsField {
        SettingsTextField(
          text: $model.settings.model,
          placeholder: "模型 ID",
          accessibilityIdentifier: "settings-model"
        )
      } else {
        SettingsMenu(
          valueLabel: model.settings.model,
          values: suggestions + [""],
          title: { $0.isEmpty ? "其他…" : $0 },
          onSelect: { model.settings.model = $0 }
        )
        .accessibilityIdentifier("settings-model-menu")
      }
    }
  }
}

private struct APIKeyRow: View {
  @Bindable var model: AppModel

  var body: some View {
    SettingsRow(title: "API Key", caption: "只存本机钥匙串") {
      MaskedAPIKeyField(
        apiKey: $model.settings.apiKey,
        placeholder: model.settings.usesLocalEndpoint ? "本地端点可留空" : "粘贴 API Key"
      )
    }
  }
}

/// What the model group can tell without a request: a 6 pt dot and one line.
private struct ReadinessRow: View {
  let readiness: SettingsReadiness

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(readiness.isReady ? CidaDesign.accent : CidaDesign.textTertiary)
        .frame(width: 6, height: 6)
      Text(readiness.text)
        .font(CidaDesign.ui(12))
        .foregroundStyle(CidaDesign.textSecondary)
    }
    .padding(.top, 6)
    .padding(.bottom, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("settings-readiness")
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

// MARK: - 唤起

/// The key chip is the recorder: a click waits for the next combination,
/// which is registered before it is kept (Pencil `Spec — 设置` §四).
private struct GlobalShortcutRow: View {
  @Bindable var model: AppModel
  @State private var feedback: Feedback?

  /// What the caption says instead of the row's purpose: the recording hint,
  /// or why the last press changed nothing.
  private enum Feedback {
    case missingModifier
    case rejected
  }

  private var caption: String {
    if model.isRecordingShortcut {
      return feedback == .missingModifier ? "要带 ⌘、⌥ 或 ⌃" : "Esc 取消"
    }
    return feedback == .rejected ? "这个组合已被占用，换一个" : "在任何应用里显示辞达"
  }

  var body: some View {
    SettingsRow(title: "全局快捷键", caption: caption, alignment: .trailing) {
      HStack(spacing: 12) {
        if model.settings.shortcut != .optionSpace, !model.isRecordingShortcut {
          Button("恢复默认") {
            feedback = nil
            model.setShortcut(.optionSpace)
          }
          .buttonStyle(.plain)
          .font(CidaDesign.ui(12, weight: .medium))
          .foregroundStyle(CidaDesign.textSecondary)
          .accessibilityIdentifier("settings-shortcut-reset")
        }
        Button {
          feedback = nil
          model.isRecordingShortcut = true
        } label: {
          ShortcutChip(
            text: model.isRecordingShortcut ? "按下新组合…" : model.settings.shortcut.displayText,
            isRecording: model.isRecordingShortcut)
        }
        .buttonStyle(.plain)
        .background {
          ShortcutCaptureView(
            isRecording: $model.isRecordingShortcut,
            onCapture: { shortcut in
              feedback = model.setShortcut(shortcut) ? nil : .rejected
            },
            onInvalidPress: { feedback = .missingModifier })
        }
        .accessibilityLabel(
          model.isRecordingShortcut ? "按下新的全局快捷键" : "全局快捷键 \(model.settings.shortcut.displayText)")
        .accessibilityIdentifier("settings-shortcut")
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
      .controlSize(.mini)
      .accessibilityIdentifier("settings-launch-at-login-toggle")
    }
    .onAppear(perform: model.refreshLaunchAtLoginStatus)
  }
}

private struct AboutFooter: View {
  var body: some View {
    HStack(spacing: 8) {
      Text("辞达")
        .font(CidaDesign.brand(12, weight: .semibold))
        .tracking(2)
        .foregroundStyle(CidaDesign.textSecondary)
      Text("1.0 · 辞达而已矣")
        .font(CidaDesign.ui(11))
        .foregroundStyle(CidaDesign.textTertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 26)
  }
}

// MARK: - API key field

struct MaskedAPIKeyField: View {
  @Binding var apiKey: String
  var placeholder = "粘贴 API Key"
  @FocusState private var isFocused: Bool

  var body: some View {
    ZStack(alignment: .leading) {
      SecureField(placeholder, text: $apiKey)
        .textFieldStyle(.plain)
        .font(CidaDesign.mono(11.5))
        .foregroundStyle(isFocused || apiKey.isEmpty ? CidaDesign.textPrimary : Color.clear)
        .focused($isFocused)
        .accessibilityIdentifier("settings-api-key-editor")

      if !isFocused, !apiKey.isEmpty {
        Text(maskedValue)
          .font(CidaDesign.mono(11.5))
          .foregroundStyle(CidaDesign.textPrimary)
          .lineLimit(1)
          .allowsHitTesting(false)
      }
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity)
    .frame(height: 30)
    .background(CidaDesign.surface)
    .clipShape(.rect(cornerRadius: CidaDesign.Radius.segment, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: CidaDesign.Radius.segment, style: .continuous)
        .strokeBorder(isFocused ? CidaDesign.accent : CidaDesign.border, lineWidth: isFocused ? 1.5 : 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("API Key")
  }

  private var maskedValue: String {
    guard !apiKey.isEmpty else { return "" }
    let prefix = apiKey.hasPrefix("sk-") ? "sk-" : ""
    let suffix = String(apiKey.suffix(min(4, apiKey.count)))
    return "\(prefix)••••••••••••••••\(suffix)"
  }
}
