import AppKit
import SwiftUI

private enum ComposerLayout {
  static func editorHeight(
    for metrics: ComposerTextMetrics,
    availableHeight: CGFloat
  ) -> CGFloat {
    switch metrics.presentationState {
    case .compact:
      return 27
    case .document:
      return min(220, max(150, availableHeight * 0.275))
    case .multiline(let visibleLineCount):
      return CGFloat(min(5, max(2, visibleLineCount)) * 26 + 16)
    }
  }
}

struct MainWindowView: View {
  let model: AppModel
  let automaticallyFocusInput: Bool
  let animatesHistoryTransitions: Bool
  let openSettings: @MainActor () -> Void
  @State private var composerMetrics: ComposerTextMetrics

  init(
    model: AppModel,
    automaticallyFocusInput: Bool = true,
    animatesHistoryTransitions: Bool = true,
    openSettings: @escaping @MainActor () -> Void = {}
  ) {
    self.model = model
    self.automaticallyFocusInput = automaticallyFocusInput
    self.animatesHistoryTransitions = animatesHistoryTransitions
    self.openSettings = openSettings
    _composerMetrics = State(initialValue: ComposerTextMetrics(text: model.inputText))
  }

  var body: some View {
    WindowSurface {
      GeometryReader { geometry in
        VStack(spacing: 0) {
          MainTitlebar(
            model: model,
            openSettings: openSettings
          )
          ZStack(alignment: .bottom) {
            HistoryStream(
              model: model,
              animatesTransitions: animatesHistoryTransitions
            )
            .padding(
              .bottom,
              Self.compactComposerHeight
                + composerHeightDelta(
                  for: composerMetrics,
                  availableHeight: geometry.size.height
                )
            )
            .animation(
              .easeOut(duration: CidaMotion.heightSeconds),
              value: composerMetrics.presentationState
            )

            Composer(
              model: model,
              automaticallyFocusInput: automaticallyFocusInput,
              availableHeight: geometry.size.height,
              inputMetrics: $composerMetrics
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
          }
          .frame(maxHeight: .infinity)
          .background(CidaDesign.background)
        }
        .background(CidaDesign.background)
      }
    }
    .alert(
      "处理失败",
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

  private static let compactComposerHeight: CGFloat = 101

  private func composerHeightDelta(
    for metrics: ComposerTextMetrics,
    availableHeight: CGFloat
  ) -> CGFloat {
    let editorHeight = ComposerLayout.editorHeight(
      for: metrics,
      availableHeight: availableHeight
    )
    return max(0, editorHeight + 74 - Self.compactComposerHeight)
  }
}

private struct MainTitlebar: View {
  let model: AppModel
  let openSettings: @MainActor () -> Void

  var body: some View {
    ZStack {
      HStack {
        Color.clear.frame(width: 66, height: 16)
        Spacer(minLength: 20)
        ModelStatusChip(model: model, openSettings: openSettings)
      }
      .padding(.horizontal, 16)

      Text("辞达")
        .font(CidaDesign.brand(15, weight: .semibold))
        .tracking(3)
        .foregroundStyle(CidaDesign.accent)
        .accessibilityAddTraits(.isHeader)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 46)
  }
}

private struct ModelStatusChip: View {
  @Bindable var model: AppModel
  let openSettings: @MainActor () -> Void

  var body: some View {
    Button(action: openSettings) {
      HStack(spacing: 6) {
        Circle()
          .fill(CidaDesign.accent)
          .frame(width: 6, height: 6)
        Text(model.modelStatus)
          .font(CidaDesign.mainUI(11.5, weight: .medium))
          .lineLimit(1)
      }
      .foregroundStyle(CidaDesign.accent)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(CidaDesign.accentSoft)
      .clipShape(Capsule())
    }
    .buttonStyle(HoverFadeButtonStyle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("当前模型 \(model.modelStatus)")
    .accessibilityHint("打开设置")
    .accessibilityIdentifier("model-settings-button")
  }
}

private struct Composer: View {
  @Bindable var model: AppModel
  let automaticallyFocusInput: Bool
  let availableHeight: CGFloat
  @FocusState private var isInputFocused: Bool
  @Binding var inputMetrics: ComposerTextMetrics

  init(
    model: AppModel,
    automaticallyFocusInput: Bool,
    availableHeight: CGFloat,
    inputMetrics: Binding<ComposerTextMetrics>
  ) {
    self.model = model
    self.automaticallyFocusInput = automaticallyFocusInput
    self.availableHeight = availableHeight
    _inputMetrics = inputMetrics
  }

  var body: some View {
    VStack(spacing: 12) {
      ZStack(alignment: .topLeading) {
        if !inputMetrics.hasText {
          Text("输入内容,回车\(model.mode == .translate ? "翻译" : "改进")…")
            .font(CidaDesign.body(16))
            .foregroundStyle(CidaDesign.textTertiary)
            .padding(.leading, 28)
            .padding(.top, 3)
            .allowsHitTesting(false)
        }

        ComposerTextEditor(
          text: $model.inputText,
          metrics: $inputMetrics,
          isFocused: $isInputFocused,
          resetRevision: model.inputResetRevision,
          currentResetRevision: { model.inputResetRevision },
          onSubmit: submit,
          onVirtualDocumentChange: { document, utf16Count, hasNonWhitespace in
            model.stageInputDocument(
              document,
              utf16Count: utf16Count,
              hasNonWhitespace: hasNonWhitespace
            )
          }
        )
      }
      .frame(maxWidth: .infinity)
      .frame(height: editorHeight(for: inputMetrics))
      .animation(
        .easeOut(duration: CidaMotion.heightSeconds),
        value: inputMetrics.presentationState
      )

      HStack(spacing: 12) {
        HStack(spacing: 8) {
          ModeSegmentedControl(model: model)
          OutputHint(model: model)
        }

        Spacer(minLength: 8)

        HStack(spacing: 12) {
          if inputMetrics.presentationState.showsDocumentChrome {
            Text("\(inputMetrics.formattedCharacterCount) 字")
              .font(CidaDesign.mainUI(11.5))
              .foregroundStyle(CidaDesign.textTertiary)
              .accessibilityLabel("输入了 \(inputMetrics.formattedCharacterCount) 个字符")
          }

          if inputMetrics.isImportingLargeDocument {
            HStack(spacing: 6) {
              ProgressView().controlSize(.mini)
              Text("正在载入长文本…")
            }
            .font(CidaDesign.mainUI(11, weight: .medium))
            .foregroundStyle(CidaDesign.accent)
          }

          Button {
            if model.isProcessing {
              model.cancelProcessing()
            } else {
              _ = submit()
            }
          } label: {
            ZStack {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CidaDesign.accent)
              RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(CidaDesign.accentForeground)
                .frame(width: 10, height: 10)
                .opacity(model.isProcessing ? 1 : 0)
              LucideIcon(.arrowUp, size: 15)
                .foregroundStyle(.white)
                .opacity(model.isProcessing ? 0 : 1)
            }
            .frame(width: 30, height: 30)
            .animation(.easeOut(duration: CidaMotion.iconSwapSeconds), value: model.isProcessing)
          }
          .buttonStyle(HoverFadeButtonStyle())
          .disabled(
            !model.isProcessing
              && (!inputMetrics.hasNonWhitespace || inputMetrics.isImportingLargeDocument)
          )
          .accessibilityLabel(
            model.isProcessing ? "停止生成" : (model.mode == .translate ? "翻译" : "改进")
          )
          .accessibilityIdentifier("composer-submit-button")
        }
      }
      .padding(.horizontal, 28)
      .frame(height: 30)
    }
    .padding(.vertical, 16)
    .background(CidaDesign.surface)
    .overlay(alignment: .top) { Hairline() }
    .onAppear {
      guard automaticallyFocusInput else { return }
      Task { @MainActor in
        await Task.yield()
        isInputFocused = true
      }
    }
    .onChange(of: model.inputFocusRequestID) {
      isInputFocused = true
    }
    .onChange(of: model.inputResetRevision) {
      guard model.inputText.isEmpty else { return }
      inputMetrics = ComposerTextMetrics(text: "")
    }
  }

  private func editorHeight(for metrics: ComposerTextMetrics) -> CGFloat {
    ComposerLayout.editorHeight(for: metrics, availableHeight: availableHeight)
  }

  private func submit() -> Bool {
    let didSubmit = model.submit()
    if didSubmit {
      inputMetrics = ComposerTextMetrics(text: "")
    }
    return didSubmit
  }
}

private struct ModeSegmentedControl: View {
  @Bindable var model: AppModel

  var body: some View {
    HStack(spacing: 2) {
      ForEach(ProcessingMode.allCases, id: \.self) { mode in
        Button {
          model.setMode(mode)
        } label: {
          Text(mode.title)
            .font(CidaDesign.mainUI(11.5, weight: model.mode == mode ? .semibold : .medium))
            .foregroundStyle(model.mode == mode ? CidaDesign.textPrimary : CidaDesign.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background {
              if model.mode == mode {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                  .fill(CidaDesign.surface)
                  .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                      .strokeBorder(CidaDesign.border, lineWidth: 1)
                  }
              }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
      }
    }
    .padding(2)
    .background(CidaDesign.surfaceDim)
    .clipShape(.rect(cornerRadius: 7, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("处理模式")
  }
}

private struct OutputHint: View {
  @Bindable var model: AppModel

  @ViewBuilder
  var body: some View {
    if model.mode == .translate {
      Button {
        model.swapLanguages()
      } label: {
        HStack(spacing: 6) {
          Text(model.sourceLanguage.title)
          LucideIcon(.arrowLeftRight, size: 11)
          Text(model.targetLanguage.title)
        }
        .modifier(OutputHintStyle())
      }
      .buttonStyle(HoverFadeButtonStyle())
      .accessibilityLabel("交换源语言与目标语言")
    } else {
      HStack(spacing: 6) {
        LucideIcon(.scanText, size: 11)
        Text(model.outputHint)
      }
      .modifier(OutputHintStyle())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(model.outputHint)
      .accessibilityIdentifier("improvement-output-hint")
    }
  }
}

private struct OutputHintStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(CidaDesign.mainUI(11.5, weight: .medium))
      .foregroundStyle(CidaDesign.textTertiary)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
  }
}
