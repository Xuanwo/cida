import AppKit
import SwiftUI

/// The panel's content: source pane, control bar, result pane (`Design/spec/panel.md`
/// §二 and `Design/boards/panel-states.html`). The panes take their own heights and
/// the view reports the height they add up to, so the panel can grow from its top
/// edge instead of the content adapting to a fixed window. While Cida has something
/// to say (`Design/spec/lifecycle.md`), the same three panes carry that message
/// instead.
///
/// The content always sits at the top at its final height; only the panel's frame
/// animates. Whatever the panel shows below the content while its frame catches up
/// is the bottom pane's own surface.
struct PanelView: View {
  let model: AppModel
  let heightBudget: PanelHeightBudget
  /// The height the panes add up to, and whether the panel should animate to it:
  /// every change does except the first layout, which the panel appears with.
  var onContentHeightChange: @MainActor (CGFloat, Bool) -> Void = { _, _ in }
  var openSettings: @MainActor () -> Void = {}
  @State private var composerMetrics: ComposerTextMetrics
  @State private var hasReportedHeight = false
  @State private var copiedFeedbackTask: Task<Void, Never>?
  @State private var shownCopyFeedback: CopyFeedback?

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
    VStack(spacing: 0) {
      if let message = model.panelMessage {
        PanelMessageView(model: model, message: message, heightBudget: heightBudget)
      } else if model.showsSetupWelcome || model.showsFirstTranslation {
        WelcomePane(model: model, openSettings: openSettings)
          .frame(width: CidaDesign.Panel.width)
      } else {
        translationPanes
      }
    }
    .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
      onContentHeightChange(height, hasReportedHeight)
      hasReportedHeight = true
    }
    // Both bounds: a content taller than the host (before the panel has grown)
    // stays at the top instead of being centred around it.
    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    .background(surfaceBelowContent)
    .onChange(of: model.copyFeedbackRevision) { showCopiedFeedback() }
    .onChange(of: model.result?.id) { shownCopyFeedback = nil }
    // No identifier on this stack: SwiftUI would push it down onto the pane
    // containers and hide their own `source-pane` / `control-bar` /
    // `result-pane` identifiers from XCUI.
  }

  private var translationPanes: some View {
    VStack(spacing: 0) {
      SourcePane(
        model: model,
        metrics: $composerMetrics,
        editorHeight: sourceEditorHeight,
        editorMaxHeight: heightBudget.sourceEditorMaxHeight
      )
      ControlBar(
        model: model,
        presentation: barActionPresentation,
        closesWithHairline: model.result != nil
      )
      if model.result != nil {
        ResultPane(
          model: model,
          maxTextHeight: resultTextMaxHeight,
          showsText: showsResultText
        )
      }
    }
    .frame(width: CidaDesign.Panel.width)
    .background(CidaDesign.surface)
    .overlay(alignment: .topTrailing) {
      if model.isCopyMenuOpen, barActionPresentation == .copy {
        copyMenuLayer
      }
    }
  }

  /// The copy menu hangs from the copy button over the result pane; a click
  /// above or below the control bar only closes it (`Design/spec/panel.md` §八).
  /// The control bar stays uncovered: a layer that appears over ⌄ under a
  /// resting pointer leaves ⌄ deaf to the next click once it goes, so ⌄ closes
  /// the menu itself and the bar's other controls close it through the model.
  private var copyMenuLayer: some View {
    ZStack(alignment: .topTrailing) {
      VStack(spacing: 0) {
        closesCopyMenu.frame(height: sourcePaneHeight)
        Color.clear
          .frame(height: CidaDesign.Panel.controlBarHeight)
          .allowsHitTesting(false)
        closesCopyMenu
      }
      CopyMenu(model: model)
        // 6 below the button, which sits in the middle of the control bar.
        .padding(.top, sourcePaneHeight + CopyMenu.topInControlBar)
        .padding(.trailing, CidaDesign.Spacing.windowHorizontal)
    }
  }

  private var closesCopyMenu: some View {
    Button {
      model.isCopyMenuOpen = false
    } label: {
      Color.clear.contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHidden(true)
  }

  /// The bottom pane's surface, which the panel shows below the content while
  /// its frame shrinks to the content's height.
  private var surfaceBelowContent: Color {
    let endsOnPaper =
      if let message = model.panelMessage {
        message.hasPaper
      } else {
        model.result != nil || model.showsSetupWelcome || model.showsFirstTranslation
      }
    return endsOnPaper ? CidaDesign.surfacePaper : CidaDesign.surface
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

  /// The result text area at the pane's cap, with the note row's allowance, in
  /// whole lines of the result's typography, so the pane never cuts a line
  /// through its glyphs.
  private var resultTextMaxHeight: CGFloat {
    let noteAllowance: CGFloat = model.resultNote == nil ? 0 : ResultNoteRow.height + 10
    let lineHeight = ResultTextStyle.lineHeight(for: model.result?.outputLanguage ?? .english)
    let available =
      resultPaneMaxHeight - CidaDesign.Spacing.resultVertical * 2 - noteAllowance
    return max(1, floor(available / lineHeight)) * lineHeight
  }

  private var showsResultText: Bool {
    guard let result = model.result else { return false }
    return result.phase == .streaming || result.resultUTF16Length > 0
  }

  // MARK: - Bar action

  private var barActionPresentation: BarActionPresentation {
    .resolve(
      isProcessing: model.isProcessing,
      canCopyResult: model.canCopyResult,
      hasResult: model.result != nil,
      copyFeedback: shownCopyFeedback
    )
  }

  private func showCopiedFeedback() {
    copiedFeedbackTask?.cancel()
    let feedback = model.copyFeedback
    shownCopyFeedback = feedback
    copiedFeedbackTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(feedback.holdMilliseconds))
      guard !Task.isCancelled else { return }
      shownCopyFeedback = nil
    }
  }
}

// MARK: - Source pane

private struct SourcePane: View {
  @Bindable var model: AppModel
  @Binding var metrics: ComposerTextMetrics
  let editorHeight: CGFloat
  let editorMaxHeight: CGFloat

  var body: some View {
    ZStack(alignment: .topLeading) {
      if !metrics.hasText {
        // The typed text's line box: glyphs centred in one composer line, where the
        // editor sets its first line.
        Text("输入内容，回车\(model.mode == .translate ? "翻译" : "改进")…")
          .font(CidaDesign.body(CidaDesign.Typography.bodySize))
          .foregroundStyle(CidaDesign.textTertiary)
          .frame(height: CidaDesign.Panel.composerLineHeight)
          .padding(.leading, CidaDesign.Spacing.windowHorizontal)
          .allowsHitTesting(false)
      }

      // The editor takes its new height at once; the panel's frame is what
      // animates (`Design/spec/panel.md` §二).
      ComposerTextEditor(
        text: $model.inputText,
        metrics: $metrics,
        horizontalInset: CidaDesign.Spacing.windowHorizontal,
        maxVisibleHeight: editorMaxHeight,
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

  var body: some View {
    HStack(spacing: 8) {
      ModeSegmentedControl(model: model, isEnabled: !model.isProcessing)
      if !model.isEditingForeignLanguage { TabHint(isDimmed: model.isProcessing) }
      Spacer(minLength: 12)
      if model.isEditingForeignLanguage {
        Text(model.foreignLanguageConfirmationHint)
          .font(CidaDesign.mainUI(11))
          .foregroundStyle(CidaDesign.textTertiary)
          .fixedSize()
          .accessibilityIdentifier("foreign-language-confirmation-hint")
      } else {
        BarActionButton(model: model, presentation: presentation)
          .fixedSize()
      }
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
      .modifier(DimmedWhileWorking(isDimmed: isDimmed))
      .accessibilityHidden(true)
  }
}

struct ModeSegmentedControl: View {
  @Bindable var model: AppModel
  var isEnabled = true

  var body: some View {
    ViewThatFits(in: .horizontal) {
      segments.fixedSize()
      ScrollViewReader { proxy in
        ScrollView(.horizontal) { segments }
          .scrollIndicators(.hidden)
          .onChange(of: model.mode) { proxy.scrollTo(model.mode.rawValue, anchor: .center) }
      }
    }
  }

  private var segments: some View {
    PanelSegmentedControl(
      titles: model.settings.actions.map(\.name),
      selected: model.settings.actions.firstIndex(where: { $0.id == model.mode }) ?? 0,
      identifiers: model.settings.actions.map { "action-\($0.id.rawValue)" },
      isEnabled: isEnabled,
      onSelect: { model.setMode(model.settings.actions[$0].id) },
      accessory: { index in
        // Only 翻译 has an object: the language a source in my language goes into.
        if model.settings.actions[index].id == .translate {
          PanelForeignLanguage(model: model)
        }
      }
    )
    .accessibilityLabel("动作")
    .accessibilityIdentifier("action-segment")
  }
}

enum PanelSegmentedControlMetrics {
  /// From an item's title to its edges.
  static let titlePadding: CGFloat = 12
}

/// The control bar's segmented control: the panel's two actions, or a message's choices.
/// An item can carry an accessory after its title, inside the same selected background.
struct PanelSegmentedControl<Accessory: View>: View {
  let titles: [String]
  let selected: Int
  let identifiers: [String]
  var isEnabled = true
  let onSelect: @MainActor (Int) -> Void
  @ViewBuilder let accessory: (Int) -> Accessory

  var body: some View {
    HStack(spacing: 2) {
      ForEach(titles.indices, id: \.self) { index in
        let isSelected = index == selected
        HStack(spacing: 0) {
          Button {
            onSelect(index)
          } label: {
            // The board's item: a 14 pt line in 4/11 padding inside a 1 pt border that
            // is transparent unless selected, so 5/12 from the text to the item's edge.
            Text(titles[index])
              .font(CidaDesign.mainUI(11.5, weight: isSelected ? .semibold : .medium))
              .foregroundStyle(isSelected ? CidaDesign.accent : CidaDesign.textSecondary)
              .frame(height: 14)
              .padding(.horizontal, PanelSegmentedControlMetrics.titlePadding)
              .padding(.vertical, 5)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(isSelected ? .isSelected : [])
          .accessibilityIdentifier(identifiers[index])
          .id(identifiers[index].replacingOccurrences(of: "action-", with: ""))
          accessory(index)
        }
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
    }
    .padding(2)
    .background(CidaDesign.surfaceDim)
    .clipShape(.rect(cornerRadius: CidaDesign.Radius.segment, style: .continuous))
    .modifier(DimmedWhileWorking(isDimmed: !isEnabled))
    .disabled(!isEnabled)
    .accessibilityElement(children: .contain)
  }
}

extension PanelSegmentedControl where Accessory == EmptyView {
  init(
    titles: [String],
    selected: Int,
    identifiers: [String],
    isEnabled: Bool = true,
    onSelect: @escaping @MainActor (Int) -> Void
  ) {
    self.init(
      titles: titles, selected: selected, identifiers: identifiers, isEnabled: isEnabled,
      onSelect: onSelect, accessory: { _ in EmptyView() })
  }
}

/// The action choice and its Tab hint dim to 45% while work runs. Only the opacity
/// animates: an animation attached to the whole control would also carry any move
/// of the control made in the same update.
private struct DimmedWhileWorking: ViewModifier {
  let isDimmed: Bool

  func body(content: Content) -> some View {
    content.animation(.easeOut(duration: CidaMotion.iconInSeconds)) {
      $0.opacity(isDimmed ? 0.45 : 1)
    }
  }
}

/// One slot, one button: execute while typing, 停止 while a
/// request runs, 复制结果 once a result exists (`Design/spec/panel.md` §二),
/// with the segment that opens the copy menu (§八).
private struct BarActionButton: View {
  let model: AppModel
  let presentation: BarActionPresentation

  var body: some View {
    ZStack {
      switch presentation {
      case .none:
        EmptyView()
      case .execute:
        pill(
          identifier: "bar-action-execute",
          label: model.settings.actions.first(where: { $0.id == model.mode })?.name ?? model.mode.title,
          key: "⏎", accent: false, minimumWidth: 92
        ) { EmptyView() } action: {
          model.submit()
        }
        .disabled(!model.hasSubmittableInput)
        .opacity(model.hasSubmittableInput ? 1 : 0.45)
      case .stop:
        pill(identifier: "bar-action-stop", label: "停止", key: "⌘.", accent: false, minimumWidth: 92) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(CidaDesign.textControl)
            .frame(width: 10, height: 10)
        } action: {
          model.cancelProcessing()
        }
      case .copy:
        CopyButton(model: model)
          .transition(.opacity.animation(.easeOut(duration: CidaMotion.iconSwapSeconds)))
      case .copied(.text):
        pill(identifier: "bar-action-copied", label: "已复制", key: nil, accent: true) {
          LucideIcon(.check, size: 12).foregroundStyle(CidaDesign.accent)
        } action: {}
      case .copied(.image):
        pill(identifier: "bar-action-image-copied", label: "已复制图片", key: nil, accent: true) {
          LucideIcon(.check, size: 12).foregroundStyle(CidaDesign.accent)
        } action: {}
      case .copied(.imageTooLong):
        pill(identifier: "bar-action-image-too-long", label: "太长，复制不了图片", key: nil, accent: false) {
          EmptyView()
        } action: {}
      }
    }
  }

  @ViewBuilder
  private func pill<Icon: View>(
    identifier: String,
    label: String,
    key: String?,
    accent: Bool,
    minimumWidth: CGFloat = 0,
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
      .frame(minWidth: minimumWidth)
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
    // The pills cross-fade (`motion-icon-swap-ms`) and appear where the bar puts
    // them: the animation belongs to the transition, not to the slot's layout.
    .transition(.opacity.animation(.easeOut(duration: CidaMotion.iconSwapSeconds)))
  }
}

// MARK: - Copy button and menu

/// 复制结果 and the segment that opens the copy menu: one pill, a short inset
/// hairline between the two, a quiet chevron (`Design/spec/panel.md` §二, §八).
private struct CopyButton: View {
  @Bindable var model: AppModel

  var body: some View {
    let isOpen = model.isCopyMenuOpen
    HStack(spacing: 0) {
      Button {
        _ = model.copyResult()
      } label: {
        HStack(spacing: 8) {
          LucideIcon(.copy, size: 12).foregroundStyle(CidaDesign.textControl)
          Text("复制结果")
            .font(CidaDesign.mainUI(11.5, weight: .semibold))
            .foregroundStyle(CidaDesign.textControl)
          Text("⌘C")
            .font(CidaDesign.mainUI(11))
            .foregroundStyle(CidaDesign.textTertiary)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(maxHeight: .infinity)
      }
      .buttonStyle(HoverFadeButtonStyle())
      .accessibilityLabel("复制结果")
      .accessibilityIdentifier("bar-action-copy")

      Rectangle()
        .fill(CidaDesign.border)
        .frame(width: 1, height: 14)
        .opacity(isOpen ? 0 : 1)

      Button {
        model.isCopyMenuOpen.toggle()
      } label: {
        LucideIcon(.chevronDown, size: 10)
          .foregroundStyle(isOpen ? CidaDesign.textControl : CidaDesign.textTertiary)
          .frame(width: 26)
          .frame(maxHeight: .infinity)
          .background(isOpen ? CidaDesign.surfaceDim : .clear)
      }
      .buttonStyle(HoverFadeButtonStyle())
      .accessibilityLabel("更多复制方式")
      .accessibilityIdentifier("bar-action-copy-menu")
    }
    .frame(height: 30)
    .background(CidaDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: CidaDesign.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: CidaDesign.Radius.card, style: .continuous)
        .strokeBorder(CidaDesign.border, lineWidth: 1)
    }
  }
}

/// The copy menu: both ways to copy with their keys, drawn on the hint pill's
/// surface. Radius 14 around 6 of padding keeps the rows' radius 8 concentric
/// with it (`Design/spec/panel.md` §八).
private struct CopyMenu: View {
  /// From the control bar's top edge: the button's 10 of inset and 30 of
  /// height, then 6 of gap.
  static let topInControlBar: CGFloat = 46

  let model: AppModel
  @State private var hovered: Item?
  /// The menu fades in (`motion-icon-in-ms`) and goes at once.
  @State private var isShown = false

  private enum Item {
    case result
    case image
  }

  var body: some View {
    VStack(spacing: 2) {
      row(.result, icon: .copy, title: "复制结果", key: "⌘C", identifier: "copy-menu-result") {
        model.copyResult()
      }
      row(.image, icon: .image, title: "复制图片", key: "⇧⌘C", identifier: "copy-menu-image") {
        model.copyResultImage()
      }
    }
    .padding(6)
    .frame(width: 184)
    .background {
      RoundedRectangle(cornerRadius: CidaDesign.Radius.panel, style: .continuous)
        .fill(CidaDesign.surface)
        .shadow(color: CidaDesign.Palette.contactShadow.swiftUI, radius: 3, y: 2)
        .shadow(color: CidaDesign.Palette.ambientShadow.swiftUI, radius: 36, y: 28)
    }
    .overlay {
      RoundedRectangle(cornerRadius: CidaDesign.Radius.panel, style: .continuous)
        .strokeBorder(CidaDesign.Palette.panelEdge.swiftUI, lineWidth: 1)
    }
    .opacity(isShown ? 1 : 0)
    .onAppear {
      withAnimation(CidaMotion.reducesMotion ? nil : .easeOut(duration: CidaMotion.iconInSeconds)) {
        isShown = true
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("copy-menu")
  }

  private func row(
    _ item: Item,
    icon: LucideIconName,
    title: String,
    key: String,
    identifier: String,
    action: @escaping () -> Bool
  ) -> some View {
    let isHovered = hovered == item || (item == .image && isImageHighlightedForDesign)
    return Button {
      _ = action()
    } label: {
      HStack(spacing: 10) {
        LucideIcon(icon, size: 12).foregroundStyle(CidaDesign.textControl)
        Text(title)
          .font(CidaDesign.mainUI(12, weight: .medium))
          .foregroundStyle(CidaDesign.textPrimary)
        Spacer(minLength: 8)
        Text(key)
          .font(CidaDesign.mainUI(11, weight: .medium))
          .tracking(0.4)
          .foregroundStyle(CidaDesign.textSecondary)
          .padding(.horizontal, 6)
          .frame(height: 18)
          .background {
            RoundedRectangle(cornerRadius: CidaDesign.Radius.segmentItem, style: .continuous)
              .fill(isHovered ? CidaDesign.surface : CidaDesign.surfaceDim)
              .overlay {
                if isHovered {
                  RoundedRectangle(cornerRadius: CidaDesign.Radius.segmentItem, style: .continuous)
                    .strokeBorder(CidaDesign.border, lineWidth: 1)
                }
              }
          }
      }
      .padding(.leading, 10)
      .padding(.trailing, 6)
      .frame(height: 30)
      .background {
        RoundedRectangle(cornerRadius: CidaDesign.Radius.card, style: .continuous)
          .fill(isHovered ? CidaDesign.surfaceDim : .clear)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
    .accessibilityLabel(title)
    .accessibilityIdentifier(identifier)
  }

  private var isImageHighlightedForDesign: Bool {
    #if DEBUG
      model.highlightsCopyImageForDesign
    #else
      false
    #endif
  }
}

// MARK: - Result pane

/// The paper pane: the result text at its own height up to `maxTextHeight`, then
/// the note. The text view reports its height as it lays out, so the pane has its
/// final height in the same pass as the record it shows.
private struct ResultPane: View {
  let model: AppModel
  let maxTextHeight: CGFloat
  let showsText: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if showsText {
        ResultTextView(
          record: model.result,
          generationState: model.generationState,
          isStale: model.isResultStale,
          maxVisibleHeight: maxTextHeight
        )
        .frame(maxWidth: .infinity)
      }
      if let note = model.resultNote {
        ResultNoteRow(note: note)
          .padding(.horizontal, CidaDesign.Spacing.windowHorizontal)
      }
    }
    .padding(.vertical, CidaDesign.Spacing.resultVertical)
    .frame(maxWidth: .infinity, alignment: .leading)
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
    case .unrecognized, .replacement: .info
    }
  }

  private var identifier: String {
    switch note.kind {
    case .stale: "stale"
    case .stopped: "stopped"
    case .failed: "failed"
    case .unrecognized: "unrecognized"
    case .replacement: "replacement"
    }
  }
}

// MARK: - Welcome

/// Setup and its optional first request occupy the whole panel (`Design/spec/lifecycle.md` §三).
private struct WelcomePane: View {
  let model: AppModel
  var openSettings: @MainActor () -> Void

  private var isReady: Bool { model.showsFirstTranslation }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(isReady ? "配置已收到，试译一句" : "先连接你的模型服务")
        .font(CidaDesign.mainUI(18, weight: .medium))
        .foregroundStyle(CidaDesign.textPrimary)
        .padding(.horizontal, CidaDesign.Spacing.windowHorizontal)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CidaDesign.surface)
      VStack(alignment: .leading, spacing: 18) {
        PaperText([isReady
          ? "Good tools leave room for thought."
          : "在设置里复制配置提示词，交给你的 AI 助手。配好后，辞达会自动接收配置。"])
        HStack(spacing: 14) {
          Button(isReady ? "试译这句话 ⏎" : "连接模型服务 ⏎") {
            if isReady { model.tryFirstTranslation() } else { openSettings() }
          }
          .buttonStyle(SettingsBorderedButtonStyle(isHighlighted: true))
          .settingsKeyboardFocus()
          .accessibilityIdentifier(isReady ? "welcome-try-translation" : "welcome-connect")
          if isReady {
            Button("直接开始") { model.dismissFirstTranslation() }
              .buttonStyle(SettingsBorderedButtonStyle())
              .settingsKeyboardFocus()
              .accessibilityIdentifier("welcome-skip-trial")
          }
        }
        Text(isReady
          ? "点击后会将这句话发送给已配置的模型。也可以直接输入自己的内容。"
          : model.hasSubmittableInput
            ? "已保留选中文字，连接后可继续翻译。"
            : "辞达住在菜单栏，随时可以回来继续。")
          .font(CidaDesign.mainUI(12))
          .foregroundStyle(CidaDesign.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("welcome-caption")
      }
      .padding(.horizontal, CidaDesign.Spacing.windowHorizontal)
      .padding(.vertical, CidaDesign.Spacing.resultVertical)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(CidaDesign.surfacePaper)
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("welcome-pane")
  }
}

// MARK: - Messages

/// A message in the panel's own shape (`Design/spec/lifecycle.md` §一): the statement in the
/// source pane, the choices in the control bar, the reason or the notes on paper. Notes taller
/// than the panel allows scroll.
private struct PanelMessageView: View {
  let model: AppModel
  let message: PanelMessage
  let heightBudget: PanelHeightBudget

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

  /// The paper at its own height when that fits the cap, a scroll view at the cap otherwise.
  /// The choice is made against the cap itself, so it does not depend on how tall the panel
  /// happens to be while its frame catches up, and nothing is measured and fed back.
  private var paper: some View {
    CapProposal(height: paperMaxHeight) {
      ViewThatFits(in: .vertical) {
        paperContent
        ScrollView { paperContent }
          .scrollBounceBehavior(.basedOnSize)
          .scrollIndicators(.automatic)
          .frame(height: paperMaxHeight)
      }
    }
    .background(CidaDesign.surfacePaper)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message-paper")
  }

  private var paperContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 6) {
        if let caption = message.bodyCaption {
          Text(caption)
            .font(CidaDesign.mainUI(11))
            .foregroundStyle(CidaDesign.textTertiary)
            .frame(height: 16.5)
            .accessibilityIdentifier("message-body-caption")
        }
        paperBody
      }
      if let note = message.note {
        ResultNoteRow(note: ResultNote(kind: .failed, text: note))
      }
    }
    .padding(.horizontal, CidaDesign.Spacing.windowHorizontal)
    .padding(.vertical, CidaDesign.Spacing.resultVertical)
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
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

/// Offers its content a fixed height to fit in, whatever height the parent offers, and takes the
/// size the content picks.
private struct CapProposal: Layout {
  let height: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: height)) ?? .zero
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    subviews.first?.place(
      at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: height))
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
      composed = composed + Text(Image(nsImage: PaperCaret.image(opacity: caretOpacity)))
        .baselineOffset(-Self.caretDescent)
    }
    return composed
      .font(Font(Self.font))
      .lineSpacing(Self.lineSpacing)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }

  private static let caretDescent = ResultTextStyle.caretDescent
}

/// Shared by the panel paper and its Settings preview.
@MainActor
enum PaperCaret {
  /// The caret with room before it, as the board's `margin-left: 2px`.
  static func image(opacity: Double) -> NSImage {
    let gap = ResultTextStyle.caretGap
    let size = NSSize(width: gap + CidaMotion.cursorWidth, height: CidaMotion.cursorHeight)
    return NSImage(size: size, flipped: false) { rect in
      CidaDesign.Palette.accent.appKit.withAlphaComponent(opacity).setFill()
      NSRect(x: gap, y: 0, width: CidaMotion.cursorWidth, height: rect.height).fill()
      return true
    }
  }
}
