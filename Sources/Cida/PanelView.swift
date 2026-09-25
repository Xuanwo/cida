import AppKit
import SwiftUI

/// The panel's content: source pane, control bar, result pane (`Design/spec/panel.md`
/// §二 and `Design/boards/panel-states.html`). The view computes the height
/// it wants from the two panes and reports it, so the panel can grow from its
/// top edge instead of the content adapting to a fixed window. While Cida has
/// something to say (`Design/spec/lifecycle.md`), the same three panes carry
/// that message instead.
struct PanelView: View {
  let model: AppModel
  let heightBudget: PanelHeightBudget
  var onContentHeightChange: @MainActor (CGFloat, Bool) -> Void = { _, _ in }
  var openSettings: @MainActor () -> Void = {}
  @State private var composerMetrics: ComposerTextMetrics
  @State private var resultContentHeight: CGFloat = CidaDesign.Typography.resultLineHeight
  @State private var resultHeightAnimated = false
  @State private var copiedFeedbackTask: Task<Void, Never>?
  @State private var showsCopiedFeedback = false
  @State private var welcomeHeight: CGFloat = 0

  init(
    model: AppModel,
    heightBudget: PanelHeightBudget,
    onContentHeightChange: @escaping @MainActor (CGFloat, Bool) -> Void = { _, _ in },
    openSettings: @escaping @MainActor () -> Void = {}
  ) {
    self.model = model
    self.heightBudget = heightBudget
    self.onContentHeightChange = onContentHeightChange
    self.openSettings = openSettings
    _composerMetrics = State(initialValue: ComposerTextMetrics(text: model.inputText))
  }

  var body: some View {
    if let message = model.panelMessage {
      PanelMessageView(
        model: model,
        message: message,
        heightBudget: heightBudget,
        onContentHeightChange: onContentHeightChange
      )
    } else {
      translationPanes
    }
  }

  private var translationPanes: some View {
    VStack(spacing: 0) {
      SourcePane(
        model: model,
        metrics: $composerMetrics,
        editorHeight: sourceEditorHeight
      )
      ControlBar(
        model: model,
        presentation: barActionPresentation,
        closesWithHairline: model.result != nil || showsWelcome,
        openSettings: openSettings
      )
      if showsWelcome {
        WelcomePane(model: model)
          .onGeometryChange(for: CGFloat.self, of: \.size.height) { welcomeHeight = $0 }
      }
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
    .onChange(of: model.panelMessage == nil) { publishHeight(animated: false) }
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
      + (showsWelcome ? welcomeHeight : 0)
  }

  /// No model service yet and nothing to show: the paper pane welcomes the user.
  private var showsWelcome: Bool {
    model.result == nil && model.needsModelConfiguration
  }

  private func publishHeight(animated: Bool) {
    onContentHeightChange(idealHeight, animated)
  }

  // MARK: - Bar action

  private var barActionPresentation: BarActionPresentation {
    .resolve(
      isProcessing: model.isProcessing,
      canCopyResult: model.canCopyResult,
      showsCopiedFeedback: showsCopiedFeedback,
      showsWelcome: showsWelcome
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
  let closesWithHairline: Bool
  let openSettings: @MainActor () -> Void

  var body: some View {
    HStack(spacing: 8) {
      ModeSegmentedControl(model: model, isEnabled: !model.isProcessing)
      TabHint(isDimmed: model.isProcessing)
      Spacer(minLength: 12)
      BarActionButton(model: model, presentation: presentation, openSettings: openSettings)
    }
    .modifier(ControlBarChrome(closesWithHairline: closesWithHairline))
  }
}

/// The control bar's frame and rules, shared by the translation and message panels.
private struct ControlBarChrome: ViewModifier {
  let closesWithHairline: Bool

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, CidaDesign.Spacing.windowHorizontal)
      .frame(height: CidaDesign.Panel.controlBarHeight)
      .frame(maxWidth: .infinity)
      .background(CidaDesign.surface)
      .overlay(alignment: .top) { Hairline() }
      .overlay(alignment: .bottom) {
        if closesWithHairline { Hairline() }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("control-bar")
  }
}

private struct TabHint: View {
  let isDimmed: Bool

  var body: some View {
    Text("⇥ 切换")
      .font(CidaDesign.mainUI(11))
      .foregroundStyle(CidaDesign.hint)
      .opacity(isDimmed ? 0.45 : 1)
      .accessibilityHidden(true)
  }
}

struct ModeSegmentedControl: View {
  @Bindable var model: AppModel
  var isEnabled = true

  var body: some View {
    PanelSegmentedControl(
      titles: ProcessingMode.allCases.map(\.title),
      selected: ProcessingMode.allCases.firstIndex(of: model.mode) ?? 0,
      identifiers: ProcessingMode.allCases.map { "action-\($0.rawValue)" },
      isEnabled: isEnabled,
      onSelect: { model.setMode(ProcessingMode.allCases[$0]) }
    )
    .accessibilityLabel("动作")
    .accessibilityIdentifier("action-segment")
  }
}

/// The control bar's segmented control: the panel's two actions, or a message's choices.
struct PanelSegmentedControl: View {
  let titles: [String]
  let selected: Int
  let identifiers: [String]
  var isEnabled = true
  let onSelect: @MainActor (Int) -> Void

  var body: some View {
    HStack(spacing: 2) {
      ForEach(titles.indices, id: \.self) { index in
        let isSelected = index == selected
        Button {
          onSelect(index)
        } label: {
          Text(titles[index])
            .font(CidaDesign.mainUI(11.5, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? CidaDesign.accent : CidaDesign.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background {
              if isSelected {
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifiers[index])
      }
    }
    .padding(2)
    .background(CidaDesign.surfaceDim)
    .clipShape(.rect(cornerRadius: CidaDesign.Radius.segment, style: .continuous))
    .opacity(isEnabled ? 1 : 0.45)
    .disabled(!isEnabled)
    .animation(.easeOut(duration: CidaMotion.iconInSeconds), value: isEnabled)
    .accessibilityElement(children: .contain)
  }
}

/// One slot, one button, three phases: nothing while typing, 停止 while a
/// request runs, 复制结果 once a result exists (`Design/spec/panel.md` §二).
private struct BarActionButton: View {
  let model: AppModel
  let presentation: BarActionPresentation
  var openSettings: @MainActor () -> Void = {}

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
      case .openSettings:
        pill(identifier: "bar-action-open-settings", label: "打开设置", key: "⌘,", accent: false) {
          EmptyView()
        } action: {
          openSettings()
        }
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

// MARK: - Welcome

/// The paper pane of an empty panel before a model service is configured
/// (`Design/spec/lifecycle.md` §三).
private struct WelcomePane: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      PaperText(["辞达需要一个模型服务。打开设置，复制配置提示词交给你的 AI 助手，它会帮你配好。"])
      // ⏎ without a model service swaps the shortcuts for what is missing.
      if model.showsConfigurationReminder {
        ResultNoteRow(note: ResultNote(kind: .failed, text: "还没配置模型服务 · ⌘, 打开设置"))
      } else {
        Text(shortcutsLine)
          .font(CidaDesign.mainUI(11))
          .foregroundStyle(CidaDesign.textTertiary)
          // The caption's 1.5 line height.
          .frame(height: 16.5)
          .accessibilityIdentifier("welcome-shortcuts")
      }
    }
    .padding(.horizontal, CidaDesign.Spacing.windowHorizontal)
    .padding(.vertical, CidaDesign.Spacing.resultVertical)
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .background(CidaDesign.surfacePaper)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("welcome-pane")
  }

  private var shortcutsLine: String {
    func compact(_ shortcut: GlobalShortcut) -> String {
      (shortcut.modifiers.symbols + [shortcut.keyDisplayName]).joined()
    }
    return "\(compact(model.settings.shortcut)) 随时唤起 · \(compact(model.settings.captureShortcut)) 截图翻译 · 辞达住在菜单栏"
  }
}

// MARK: - Messages

/// A message in the panel's own shape (`Design/spec/lifecycle.md` §一): the statement in the
/// source pane, the choices in the control bar, the reason or the notes on paper. It reports the
/// height it needs like the translation panes do; notes taller than the panel allows scroll.
private struct PanelMessageView: View {
  let model: AppModel
  let message: PanelMessage
  let heightBudget: PanelHeightBudget
  let onContentHeightChange: @MainActor (CGFloat, Bool) -> Void
  @State private var paperContentHeight: CGFloat = 0

  var body: some View {
    VStack(spacing: 0) {
      statement
      bar
      if message.hasPaper {
        paper
      }
    }
    .frame(width: CidaDesign.Panel.width)
    .background(CidaDesign.surface)
    .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
      onContentHeightChange(height, true)
    }
  }

  private var statementHeight: CGFloat {
    CidaDesign.Panel.compactEditorHeight + CidaDesign.Spacing.paneVertical * 2
  }

  private var statement: some View {
    (Text(message.statement).foregroundStyle(CidaDesign.textPrimary)
      + Text(message.statementDetail ?? "").foregroundStyle(CidaDesign.textTertiary))
      .font(CidaDesign.body(CidaDesign.Typography.bodySize))
      .lineLimit(1)
      .frame(maxWidth: .infinity, minHeight: CidaDesign.Panel.compactEditorHeight, alignment: .leading)
      .padding(.horizontal, CidaDesign.Spacing.windowHorizontal)
      .padding(.vertical, CidaDesign.Spacing.paneVertical)
      .background(CidaDesign.surface)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("message-statement")
  }

  private var bar: some View {
    HStack(spacing: 8) {
      PanelSegmentedControl(
        titles: message.choices,
        selected: message.selectedChoice,
        identifiers: message.choices.indices.map { "message-choice-\($0)" },
        isEnabled: !message.isWorking,
        onSelect: { index in
          model.selectPanelMessageChoice(index)
          model.performPanelMessageChoice()
        }
      )
      .accessibilityLabel("选择")
      .accessibilityIdentifier("message-choices")
      if message.choices.count > 1 {
        TabHint(isDimmed: message.isWorking)
      }
      Spacer(minLength: 12)
      BarActionButton(
        model: model,
        presentation: message.slot == .stop ? .stop : .none
      )
    }
    .modifier(ControlBarChrome(closesWithHairline: message.hasPaper))
  }

  /// The paper pane's cap: whatever the panel's height budget leaves under the statement and bar.
  private var paperMaxHeight: CGFloat {
    max(
      CidaDesign.Typography.resultLineHeightCJK + CidaDesign.Spacing.resultVertical * 2,
      heightBudget.panelMaxHeight - statementHeight - CidaDesign.Panel.controlBarHeight
    )
  }

  private var paper: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        if let caption = message.bodyCaption {
          Text(caption)
            .font(CidaDesign.mainUI(11))
            .foregroundStyle(CidaDesign.textTertiary)
            .frame(height: 16.5)
            .accessibilityIdentifier("message-body-caption")
        }
        paperBody
        if let note = message.note {
          ResultNoteRow(note: ResultNote(kind: .failed, text: note))
        }
      }
      .padding(.horizontal, CidaDesign.Spacing.windowHorizontal)
      .padding(.vertical, CidaDesign.Spacing.resultVertical)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self, of: \.size.height) { paperContentHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollIndicators(.automatic)
    .frame(height: min(paperContentHeight, paperMaxHeight))
    .background(CidaDesign.surfacePaper)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message-paper")
  }

  @ViewBuilder
  private var paperBody: some View {
    switch message.body {
    case .none:
      if message.isWorking {
        PaperText([""], showsCaret: true)
      }
    case .text(let text):
      PaperText([text], showsCaret: message.isWorking)
    case .lines(let lines):
      PaperText(lines, bulleted: true, showsCaret: message.isWorking)
    }
  }
}

/// Serif paper text in the result pane's Chinese setting (Noto Serif SC 17 / 31): a paragraph, or
/// a list whose wrapped items hang under their own text rather than under the bullet, ending in
/// the streaming caret.
private struct PaperText: View {
  let lines: [String]
  var bulleted = false
  var showsCaret = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(_ lines: [String], bulleted: Bool = false, showsCaret: Bool = false) {
    self.lines = lines
    self.bulleted = bulleted
    self.showsCaret = showsCaret
  }

  private static let font = CidaDesign.appKitResult(for: .chinese)
  /// What TextKit adds between lines to reach the design's 31 pt line height.
  private static let lineSpacing = max(
    0,
    CidaDesign.Typography.resultLineHeightCJK - NSLayoutManager().defaultLineHeight(for: font)
  )
  /// The bullet column: one em of the result size.
  private static let bulletWidth = CidaDesign.Typography.resultSizeCJK

  var body: some View {
    if showsCaret && !reduceMotion {
      TimelineView(.animation) { context in
        content(
          caretOpacity: Double(
            StatusItemMark.caretOpacity(after: context.date.timeIntervalSinceReferenceDate)))
      }
    } else {
      content(caretOpacity: showsCaret ? 1 : nil)
    }
  }

  private func content(caretOpacity: Double?) -> some View {
    Group {
      if bulleted {
        VStack(alignment: .leading, spacing: Self.lineSpacing) {
          ForEach(lines.indices, id: \.self) { index in
            HStack(alignment: .firstTextBaseline, spacing: 0) {
              Text("·")
                .font(Font(Self.font))
                .foregroundStyle(CidaDesign.textTertiary)
                .frame(width: Self.bulletWidth, alignment: .leading)
              paragraph(lines[index], caretOpacity: index == lines.count - 1 ? caretOpacity : nil)
            }
          }
        }
      } else {
        paragraph(lines.joined(separator: "\n"), caretOpacity: caretOpacity)
      }
    }
    // CSS line-height puts half the leading above the first line and below the last. The
    // caret's descent would deepen the last line; the paper does not grow for it.
    .padding(.top, Self.lineSpacing / 2)
    .padding(.bottom, Self.lineSpacing / 2 - (caretOpacity == nil ? 0 : Self.caretDescent))
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  private func paragraph(_ text: String, caretOpacity: Double?) -> some View {
    var composed = Text(text).foregroundStyle(CidaDesign.textInk)
    if let caretOpacity {
      // Like the result pane's caret: 2 pt past the text, 4 pt below the baseline.
      composed = composed + Text(Image(nsImage: Self.caret(opacity: caretOpacity)))
        .baselineOffset(-Self.caretDescent)
    }
    return composed
      .font(Font(Self.font))
      .lineSpacing(Self.lineSpacing)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }

  private static let caretDescent: CGFloat = 4

  /// The caret with 2 pt of room before it, as the board's `margin-left: 2px`.
  private static func caret(opacity: Double) -> NSImage {
    let gap: CGFloat = 2
    let size = NSSize(width: gap + CidaMotion.cursorWidth, height: CidaMotion.cursorHeight)
    return NSImage(size: size, flipped: false) { rect in
      CidaDesign.Palette.accent.appKit.withAlphaComponent(opacity).setFill()
      NSRect(x: gap, y: 0, width: CidaMotion.cursorWidth, height: rect.height).fill()
      return true
    }
  }
}
