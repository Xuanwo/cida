import AppKit
import SwiftUI

/// The panel's content: source pane, control bar, result pane (`Design/spec/panel.md`
/// §二 and `Design/boards/panel-states.html`). The view computes the height
/// it wants from the two panes and reports it, so the panel can grow from its
/// top edge instead of the content adapting to a fixed window.
struct PanelView: View {
  let model: AppModel
  let heightBudget: PanelHeightBudget
  var onContentHeightChange: @MainActor (CGFloat, Bool) -> Void = { _, _ in }
  @State private var composerMetrics: ComposerTextMetrics
  @State private var resultContentHeight: CGFloat = CidaDesign.Typography.resultLineHeight
  @State private var resultHeightAnimated = false
  @State private var copiedFeedbackTask: Task<Void, Never>?
  @State private var showsCopiedFeedback = false

  init(
    model: AppModel,
    heightBudget: PanelHeightBudget,
    onContentHeightChange: @escaping @MainActor (CGFloat, Bool) -> Void = { _, _ in }
  ) {
    self.model = model
    self.heightBudget = heightBudget
    self.onContentHeightChange = onContentHeightChange
    _composerMetrics = State(initialValue: ComposerTextMetrics(text: model.inputText))
  }

  var body: some View {
    VStack(spacing: 0) {
      SourcePane(
        model: model,
        metrics: $composerMetrics,
        editorHeight: sourceEditorHeight
      )
      ControlBar(
        model: model,
        presentation: barActionPresentation
      )
      if model.result != nil {
        ResultPane(
          model: model,
          paneHeight: resultPaneHeight,
          maxTextHeight: resultTextMaxHeight,
          showsText: showsResultText,
          onContentHeightChange: { height, animated in
            resultHeightAnimated = animated
            resultContentHeight = height
          }
        )
      }
    }
    .frame(width: CidaDesign.Panel.width)
    .background(CidaDesign.surface)
    .onAppear { publishHeight(animated: false) }
    .onChange(of: idealHeight) { publishHeight(animated: resultHeightAnimated) }
    .onChange(of: model.copyFeedbackRevision) { showCopiedFeedback() }
    .onChange(of: model.result?.id) { showsCopiedFeedback = false }
    // No identifier on this stack: SwiftUI would push it down onto the pane
    // containers and hide their own `source-pane` / `control-bar` /
    // `result-pane` identifiers from XCUI.
  }

  // MARK: - Heights

  /// The editor takes the height of its text up to the source cap. Documents
  /// too long to measure synchronously take the cap outright.
  private var sourceEditorHeight: CGFloat {
    guard let natural = composerMetrics.naturalHeight else {
      if composerMetrics.isDocument {
        return heightBudget.sourceEditorMaxHeight
      }
      let lines = CGFloat(max(1, composerMetrics.lineCount))
      let estimated = max(CidaDesign.Panel.compactEditorHeight, lines * CidaDesign.Panel.composerLineHeight)
      return min(heightBudget.sourceEditorMaxHeight, estimated)
    }
    let wanted = max(CidaDesign.Panel.compactEditorHeight, ceil(natural))
    return min(heightBudget.sourceEditorMaxHeight, wanted)
  }

  private var sourcePaneHeight: CGFloat {
    sourceEditorHeight + CidaDesign.Spacing.paneVertical * 2
  }

  private var resultPaneMaxHeight: CGFloat {
    max(
      CidaDesign.Typography.resultLineHeight + CidaDesign.Spacing.resultVertical * 2,
      heightBudget.panelMaxHeight - sourcePaneHeight - CidaDesign.Panel.controlBarHeight
    )
  }

  /// The result text area at the pane's cap, with the note row's allowance.
  private var resultTextMaxHeight: CGFloat {
    let noteAllowance: CGFloat = model.resultNote == nil ? 0 : ResultNoteRow.height + 10
    return max(
      CidaDesign.Typography.resultLineHeight,
      resultPaneMaxHeight - CidaDesign.Spacing.resultVertical * 2 - noteAllowance)
  }

  private var showsResultText: Bool {
    guard let result = model.result else { return false }
    return result.phase == .streaming || result.resultUTF16Length > 0
  }

  private var resultPaneHeight: CGFloat {
    let noteHeight: CGFloat = model.resultNote == nil ? 0 : ResultNoteRow.height
    let textHeight = showsResultText ? ceil(resultContentHeight) : 0
    let spacing: CGFloat = showsResultText && model.resultNote != nil ? 10 : 0
    let wanted = textHeight + spacing + noteHeight + CidaDesign.Spacing.resultVertical * 2
    return min(resultPaneMaxHeight, wanted)
  }

  private var idealHeight: CGFloat {
    sourcePaneHeight + CidaDesign.Panel.controlBarHeight
      + (model.result == nil ? 0 : resultPaneHeight)
  }

  private func publishHeight(animated: Bool) {
    onContentHeightChange(idealHeight, animated)
  }

  // MARK: - Bar action

  private var barActionPresentation: BarActionPresentation {
    .resolve(
      isProcessing: model.isProcessing,
      canCopyResult: model.canCopyResult,
      showsCopiedFeedback: showsCopiedFeedback
    )
  }

  private func showCopiedFeedback() {
    copiedFeedbackTask?.cancel()
    showsCopiedFeedback = true
    copiedFeedbackTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(CidaMotion.copiedHoldMilliseconds))
      guard !Task.isCancelled else { return }
      showsCopiedFeedback = false
    }
  }
}

// MARK: - Source pane

private struct SourcePane: View {
  @Bindable var model: AppModel
  @Binding var metrics: ComposerTextMetrics
  let editorHeight: CGFloat

  var body: some View {
    ZStack(alignment: .topLeading) {
      if !metrics.hasText {
        Text("输入内容，回车\(model.mode == .translate ? "翻译" : "改进")…")
          .font(CidaDesign.body(CidaDesign.Typography.bodySize))
          .foregroundStyle(CidaDesign.textTertiary)
          .padding(.leading, CidaDesign.Spacing.windowHorizontal)
          .padding(.top, 3)
          .allowsHitTesting(false)
      }

      ComposerTextEditor(
        text: $model.inputText,
        metrics: $metrics,
        horizontalInset: CidaDesign.Spacing.windowHorizontal,
        selectAllRevision: model.inputSelectAllRequestID,
        focusRevision: model.inputFocusRequestID,
        replacementRevision: model.inputReplacementRevision,
        onSubmit: { model.submit() },
        onVirtualDocumentChange: { document, utf16Count, hasNonWhitespace in
          model.stageInputDocument(
            document,
            utf16Count: utf16Count,
            hasNonWhitespace: hasNonWhitespace
          )
        }
      )
      .frame(height: editorHeight)
      .animation(
        CidaMotion.easeOutAnimation(duration: CidaMotion.heightSeconds),
        value: editorHeight
      )
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, CidaDesign.Spacing.paneVertical)
    .background(CidaDesign.surface)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("source-pane")
  }
}

// MARK: - Control bar

private struct ControlBar: View {
  let model: AppModel
  let presentation: BarActionPresentation

  var body: some View {
    HStack(spacing: 8) {
      ModeSegmentedControl(model: model, isEnabled: !model.isProcessing)
      Text("⇥ 切换")
        .font(CidaDesign.mainUI(11))
        .foregroundStyle(CidaDesign.hint)
        .opacity(model.isProcessing ? 0.45 : 1)
        .accessibilityHidden(true)
      Spacer(minLength: 12)
      BarActionButton(model: model, presentation: presentation)
    }
    .padding(.horizontal, CidaDesign.Spacing.windowHorizontal)
    .frame(height: CidaDesign.Panel.controlBarHeight)
    .frame(maxWidth: .infinity)
    .background(CidaDesign.surface)
    .overlay(alignment: .top) { Hairline() }
    .overlay(alignment: .bottom) {
      if model.result != nil { Hairline() }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("control-bar")
  }
}

struct ModeSegmentedControl: View {
  @Bindable var model: AppModel
  var isEnabled = true

  var body: some View {
    HStack(spacing: 2) {
      ForEach(ProcessingMode.allCases, id: \.self) { mode in
        Button {
          model.setMode(mode)
        } label: {
          Text(mode.title)
            .font(CidaDesign.mainUI(11.5, weight: model.mode == mode ? .semibold : .medium))
            .foregroundStyle(model.mode == mode ? CidaDesign.accent : CidaDesign.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background {
              if model.mode == mode {
                RoundedRectangle(cornerRadius: CidaDesign.Radius.segmentItem, style: .continuous)
                  .fill(CidaDesign.surface)
                  .overlay {
                    RoundedRectangle(cornerRadius: CidaDesign.Radius.segmentItem, style: .continuous)
                      .strokeBorder(CidaDesign.border, lineWidth: 1)
                  }
              }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
        .accessibilityIdentifier("action-\(mode.rawValue)")
      }
    }
    .padding(2)
    .background(CidaDesign.surfaceDim)
    .clipShape(.rect(cornerRadius: CidaDesign.Radius.segment, style: .continuous))
    .opacity(isEnabled ? 1 : 0.45)
    .disabled(!isEnabled)
    .animation(.easeOut(duration: CidaMotion.iconInSeconds), value: isEnabled)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("动作")
    .accessibilityIdentifier("action-segment")
  }
}

/// One slot, one button, three phases: nothing while typing, 停止 while a
/// request runs, 复制结果 once a result exists (`Design/spec/panel.md` §二).
private struct BarActionButton: View {
  let model: AppModel
  let presentation: BarActionPresentation

  var body: some View {
    ZStack {
      switch presentation {
      case .none:
        EmptyView()
      case .stop:
        pill(identifier: "bar-action-stop", label: "停止", key: "⌘.", accent: false) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(CidaDesign.textControl)
            .frame(width: 10, height: 10)
        } action: {
          model.cancelProcessing()
        }
      case .copy:
        pill(identifier: "bar-action-copy", label: "复制结果", key: "⌘C", accent: false) {
          LucideIcon(.copy, size: 12).foregroundStyle(CidaDesign.textControl)
        } action: {
          _ = model.copyResult()
        }
      case .copied:
        pill(identifier: "bar-action-copied", label: "已复制", key: nil, accent: true) {
          LucideIcon(.check, size: 12).foregroundStyle(CidaDesign.accent)
        } action: {}
      }
    }
    .animation(.easeOut(duration: CidaMotion.iconSwapSeconds), value: presentation)
  }

  @ViewBuilder
  private func pill<Icon: View>(
    identifier: String,
    label: String,
    key: String?,
    accent: Bool,
    @ViewBuilder icon: () -> Icon,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        icon()
        Text(label)
          .font(CidaDesign.mainUI(11.5, weight: .semibold))
          .foregroundStyle(accent ? CidaDesign.accent : CidaDesign.textControl)
        if let key {
          Text(key)
            .font(CidaDesign.mainUI(11))
            .foregroundStyle(CidaDesign.textTertiary)
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 30)
      .background {
        RoundedRectangle(cornerRadius: CidaDesign.Radius.card, style: .continuous)
          .fill(accent ? CidaDesign.accentSoft : CidaDesign.surface)
          .overlay {
            if !accent {
              RoundedRectangle(cornerRadius: CidaDesign.Radius.card, style: .continuous)
                .strokeBorder(CidaDesign.border, lineWidth: 1)
            }
          }
      }
    }
    .buttonStyle(HoverFadeButtonStyle())
    .accessibilityLabel(label)
    .accessibilityIdentifier(identifier)
    .transition(.opacity)
  }
}

// MARK: - Result pane

private struct ResultPane: View {
  let model: AppModel
  let paneHeight: CGFloat
  let maxTextHeight: CGFloat
  let showsText: Bool
  let onContentHeightChange: @MainActor (CGFloat, Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if showsText {
        ResultTextView(
          record: model.result,
          generationState: model.generationState,
          isStale: model.isResultStale,
          followRevision: model.resultFollowRevision,
          maxVisibleHeight: maxTextHeight,
          onContentHeightChange: onContentHeightChange
        )
        .frame(maxWidth: .infinity)
        .frame(
          height: max(
            CidaDesign.Typography.resultLineHeight,
            paneHeight - CidaDesign.Spacing.resultVertical * 2
              - (model.resultNote == nil ? 0 : ResultNoteRow.height + 10)
          )
        )
      }
      if let note = model.resultNote {
        ResultNoteRow(note: note)
          .padding(.horizontal, CidaDesign.Spacing.windowHorizontal)
      }
    }
    .padding(.vertical, CidaDesign.Spacing.resultVertical)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: paneHeight)
    .background(CidaDesign.surfacePaper)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("result-pane")
  }
}

struct ResultNoteRow: View {
  static let height: CGFloat = 20
  let note: ResultNote

  var body: some View {
    HStack(spacing: 8) {
      LucideIcon(icon, size: 13)
        .foregroundStyle(CidaDesign.textTertiary)
      Text(note.text)
        .font(CidaDesign.mainUI(13))
        .foregroundStyle(CidaDesign.textSecondary)
        .lineLimit(1)
    }
    .frame(height: Self.height)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("result-note-\(identifier)")
  }

  private var icon: LucideIconName {
    switch note.kind {
    case .stale: .info
    case .stopped: .circleStop
    case .failed: .circleAlert
    case .unrecognized: .info
    }
  }

  private var identifier: String {
    switch note.kind {
    case .stale: "stale"
    case .stopped: "stopped"
    case .failed: "failed"
    case .unrecognized: "unrecognized"
    }
  }
}
