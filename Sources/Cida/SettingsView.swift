import AppKit
import SwiftUI

struct SettingsWindowView: View {
  @Bindable var model: AppModel

  init(model: AppModel) {
    self.model = model
  }

  var body: some View {
    WindowSurface {
      VStack(spacing: 0) {
        SettingsTitlebar()
        ScrollView(.vertical) {
          SettingsBody(model: model)
            .background {
              CidaScrollIndicatorInstaller(configuration: .settings)
                .frame(width: 0, height: 0)
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

private struct SettingsTitlebar: View {
  var body: some View {
    ZStack {
      HStack {
        Color.clear.frame(width: 66, height: 16)
        Spacer()
        Color.clear.frame(width: 66, height: 16)
      }
      .padding(.horizontal, 16)

      Text("设置")
        .font(CidaDesign.ui(13, weight: .semibold))
        .foregroundStyle(CidaDesign.textPrimary)
        .accessibilityAddTraits(.isHeader)
    }
    .frame(height: 46)
  }
}

private struct SettingsBody: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      SettingsSectionTitle("模型服务")
      ProviderRow(model: model)
      if model.settings.provider == .openAI {
        OpenAIEndpointRow(model: model)
      }
      APIKeyRow(model: model)
      ModelRow(model: model)

      Hairline()

      SettingsSectionTitle("提示词")
      TranslationPromptRow(model: model)
      ImprovementPromptRow(model: model)

      Hairline()

      SettingsSectionTitle("通用")
      GlobalShortcutRow()
      LaunchAtLoginRow(model: model)

      HStack(spacing: 8) {
        Text("辞达")
          .font(CidaDesign.brand(12, weight: .semibold))
          .tracking(2)
          .foregroundStyle(CidaDesign.textSecondary)
        Text("1.0 · 辞达而已矣")
          .font(CidaDesign.ui(11))
          .foregroundStyle(CidaDesign.textTertiary)
      }
      .frame(height: 39, alignment: .bottom)
    }
    .padding(.leading, 24)
    .padding(.trailing, 24)
    .padding(.bottom, 20)
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

private struct SettingsSectionTitle: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title)
      .font(CidaDesign.ui(11, weight: .semibold))
      .tracking(0.8)
      .foregroundStyle(CidaDesign.textTertiary)
      .frame(height: 16)
      .padding(.bottom, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: 34, alignment: .bottom)
  }
}

private struct SettingsLabel: View {
  let title: String
  let subtitle: String?

  init(_ title: String, subtitle: String? = nil) {
    self.title = title
    self.subtitle = subtitle
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(CidaDesign.ui(13.5))
        .foregroundStyle(CidaDesign.textPrimary)
        .frame(height: 20)
      if let subtitle {
        Text(subtitle)
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
  let width: CGFloat
  let title: (Value) -> String
  let onSelect: (Value) -> Void

  var body: some View {
    Menu {
      ForEach(values, id: \.self) { value in
        Button(title(value)) { onSelect(value) }
      }
    } label: {
      ZStack {
        Text(valueLabel)
          .font(CidaDesign.ui(12.5, weight: .medium))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.trailing, 12)
        HStack {
          Spacer()
          Image(systemName: "chevron.down")
            .font(.system(size: 7.5, weight: .semibold))
            .frame(width: 12, height: 12)
            .foregroundStyle(CidaDesign.textTertiary)
        }
      }
      .foregroundStyle(CidaDesign.textPrimary)
      .padding(.horizontal, 10)
      .frame(width: width, height: 25, alignment: .leading)
      .background(CidaDesign.surface)
      .clipShape(.rect(cornerRadius: 7, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(CidaDesign.border, lineWidth: 1)
      }
    }
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .fixedSize()
  }
}

private struct ProviderRow: View {
  @Bindable var model: AppModel

  var body: some View {
    HStack {
      SettingsLabel("服务商")
      Spacer()
      SettingsMenu(
        valueLabel: model.settings.provider.rawValue,
        values: ModelProvider.allCases,
        width: 100,
        title: \.rawValue,
        onSelect: model.selectProvider
      )
      .accessibilityIdentifier("settings-provider-menu")
    }
    .frame(height: 43)
  }
}

private struct APIKeyRow: View {
  @Bindable var model: AppModel

  var body: some View {
    HStack {
      SettingsLabel(
        "API Key",
        subtitle: model.settings.usesLocalOpenAIEndpoint
          ? "本地端点可留空"
          : "仅保存在本机"
      )
      Spacer(minLength: 24)
      MaskedAPIKeyField(apiKey: $model.settings.apiKey)
        .frame(width: 159, height: 27)
    }
    .frame(minHeight: 58)
  }
}

private struct OpenAIEndpointRow: View {
  @Bindable var model: AppModel

  var body: some View {
    HStack(alignment: .center, spacing: 24) {
      SettingsLabel(
        "Endpoint",
        subtitle: model.settings.usesLocalOpenAIEndpoint
          ? "本地 OpenAI-compatible 服务"
          : "Chat Completions API 地址"
      )
      .frame(minWidth: 130, alignment: .leading)

      Spacer(minLength: 0)

      VStack(alignment: .trailing, spacing: 5) {
        SettingsTextField(
          text: $model.settings.openAIEndpoint,
          placeholder: CidaSettings.officialOpenAIEndpoint,
          accessibilityIdentifier: "settings-openai-endpoint",
          usesMonospacedFont: true
        )
        .frame(minWidth: 250, idealWidth: 300, maxWidth: 340, minHeight: 30, maxHeight: 30)

        if model.settings.openAIEndpoint != CidaSettings.officialOpenAIEndpoint {
          Button("恢复 OpenAI 官方地址") {
            model.settings.openAIEndpoint = CidaSettings.officialOpenAIEndpoint
          }
          .buttonStyle(.plain)
          .font(CidaDesign.ui(10.5, weight: .medium))
          .foregroundStyle(CidaDesign.accent)
        }
      }
    }
    .frame(minHeight: 66)
  }
}

private struct ModelRow: View {
  @Bindable var model: AppModel

  var body: some View {
    HStack {
      SettingsLabel("模型")
      Spacer()
      if model.settings.provider == .openAI {
        SettingsTextField(
          text: $model.settings.model,
          placeholder: "Model ID",
          accessibilityIdentifier: "settings-model",
          usesMonospacedFont: true
        )
        .frame(width: 220, height: 30)
      } else {
        SettingsMenu(
          valueLabel: model.settings.model,
          values: model.settings.provider.models,
          width: 128,
          title: { $0 },
          onSelect: { model.settings.model = $0 }
        )
      }
    }
    .frame(minHeight: 46)
  }
}

private struct TranslationPromptRow: View {
  @Bindable var model: AppModel

  var body: some View {
    Group {
      if model.editingPrompt == .translate {
        ExpandedPromptRow(
          mode: .translate,
          prompt: $model.settings.translationPrompt,
          reset: model.resetTranslationPrompt
        )
      } else {
        CollapsedPromptRow(
          mode: .translate,
          summary: "Translate using application-provided language parameters…"
        ) {
          model.editingPrompt = .translate
        }
      }
    }
  }
}

private struct ImprovementPromptRow: View {
  @Bindable var model: AppModel

  var body: some View {
    Group {
      if model.editingPrompt == .improve {
        ExpandedPromptRow(
          mode: .improve,
          prompt: $model.settings.improvementPrompt,
          reset: model.resetImprovementPrompt
        )
      } else {
        CollapsedPromptRow(
          mode: .improve,
          summary: "Improve clarity, grammar, and natural tone while preserving meaning…"
        ) {
          model.editingPrompt = .improve
        }
      }
    }
  }
}

private struct CollapsedPromptRow: View {
  let mode: ProcessingMode
  let summary: String
  let edit: () -> Void

  var body: some View {
    HStack(spacing: 24) {
      SettingsLabel(mode.title, subtitle: summary)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button("编辑", action: edit)
        .font(CidaDesign.ui(12.5, weight: .medium))
        .foregroundStyle(CidaDesign.textPrimary)
        .buttonStyle(SettingsBorderedButtonStyle())
        .frame(width: 50, height: 28)
    }
    .frame(height: 55)
  }
}

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
      }
      .frame(height: 20)

      PromptTextEditor(text: $prompt, accessibilityLabel: "\(mode.title)提示词")
        .frame(height: 84)
        .background(CidaDesign.surface)
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(CidaDesign.accent, lineWidth: 1.5)
        }

      Text("自动保存 · 任务参数由应用安全传入,无需占位符")
        .font(CidaDesign.ui(11.5))
        .foregroundStyle(CidaDesign.textTertiary)
        .frame(height: 17)
    }
    .padding(.vertical, 9)
    .frame(height: 155, alignment: .top)
  }
}

private struct GlobalShortcutRow: View {
  var body: some View {
    HStack {
      SettingsLabel("全局唤起", subtitle: "在任意应用中打开输入窗口")
      Spacer()
      Text("⌥ Space")
        .font(CidaDesign.ui(12, weight: .medium))
        .foregroundStyle(CidaDesign.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(CidaDesign.surfaceDim)
        .clipShape(.rect(cornerRadius: 6, style: .continuous))
    }
    .frame(height: 58)
  }
}

private struct LaunchAtLoginRow: View {
  @Bindable var model: AppModel

  var body: some View {
    HStack {
      Text("开机启动")
        .font(CidaDesign.ui(13.5))
        .foregroundStyle(CidaDesign.textPrimary)
      Spacer()
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
    }
    .frame(height: 38)
    .onAppear(perform: model.refreshLaunchAtLoginStatus)
  }
}

private struct SettingsTextField: View {
  @Binding var text: String
  let placeholder: String
  let accessibilityIdentifier: String
  let usesMonospacedFont: Bool
  @FocusState private var isFocused: Bool

  var body: some View {
    TextField(placeholder, text: $text)
      .textFieldStyle(.plain)
      .font(usesMonospacedFont ? CidaDesign.mono(11.5) : CidaDesign.ui(12.5))
      .foregroundStyle(CidaDesign.textPrimary)
      .focused($isFocused)
      .padding(.horizontal, 10)
      .background(CidaDesign.surface)
      .clipShape(.rect(cornerRadius: 7, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(isFocused ? CidaDesign.accent : CidaDesign.border, lineWidth: 1)
      }
      .accessibilityIdentifier(accessibilityIdentifier)
  }
}

struct MaskedAPIKeyField: View {
  @Binding var apiKey: String
  @FocusState private var isFocused: Bool

  var body: some View {
    ZStack(alignment: .leading) {
      SecureField("API Key", text: $apiKey)
        .textFieldStyle(.plain)
        .font(CidaDesign.mono(11.5))
        .foregroundStyle(isFocused ? CidaDesign.textSecondary : Color.clear)
        .focused($isFocused)
        .accessibilityIdentifier("settings-api-key-editor")

      if !isFocused {
        Text(maskedValue)
          .font(CidaDesign.mono(11.5))
          .foregroundStyle(CidaDesign.textSecondary)
          .lineLimit(1)
          .allowsHitTesting(false)
      }
    }
    .padding(.leading, 10)
    .padding(.trailing, 27)
    .background(CidaDesign.surface)
    .clipShape(.rect(cornerRadius: 7, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .strokeBorder(isFocused ? CidaDesign.accent : CidaDesign.border, lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("API Key")
    .overlay(alignment: .trailing) {
      ConfiguredAPIKeyIcon(isVisible: !apiKey.isEmpty)
        .padding(.trailing, 10)
    }
  }

  private var maskedValue: String {
    guard !apiKey.isEmpty else { return "" }
    let prefix = apiKey.hasPrefix("sk-") ? "sk-" : ""
    let suffix = String(apiKey.suffix(min(4, apiKey.count)))
    return "\(prefix)••••••••••\(suffix)"
  }
}

private struct ConfiguredAPIKeyIcon: View {
  let isVisible: Bool

  var body: some View {
    Image(systemName: "checkmark.circle")
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(CidaDesign.accent)
      .opacity(isVisible ? 1 : 0)
      .fixedSize()
      .accessibilityLabel("API Key 已配置")
      .accessibilityHidden(!isVisible)
  }
}

private struct SettingsBorderedButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(CidaDesign.surface.opacity(configuration.isPressed ? 0.7 : 1))
      .clipShape(.rect(cornerRadius: 7, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(CidaDesign.border, lineWidth: 1)
      }
  }
}
