import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ActionsSettingsView: View {
  private static let sampleFont = CidaDesign.appKitBody(13)
  private static var sampleLineSpacing: CGFloat {
    21 - NSLayoutManager().defaultLineHeight(for: sampleFont)
  }

  @Bindable var model: AppModel
  @Bindable var editor: ActionEditor
  @FocusState private var nameFocused: Bool
  @FocusState private var focusedAction: ProcessingMode?
  @State private var dragging: ProcessingMode?
  @State private var dropTarget: ActionInsertion?
  @State private var segmentWidths: [ProcessingMode: CGFloat] = [:]
  @State private var promptFocus = 0

  private var actions: [TextAction] {
    var actions = model.settings.actions
    if let draft = editor.draft, draft.original == nil { actions.append(draft.action) }
    return actions
  }
  private var preview: ActionEditor.Preview? { editor.previews[editor.selected] }
  private var isRunning: Bool { editor.running == editor.selected }
  private var stale: Bool {
    editor.isDirty || isRunning || editor.previewNotes[editor.selected] != nil
      || preview.map {
        $0.prompt != model.settings.prompt(for: editor.selected)
          || $0.fingerprint != model.settings.modelServiceFingerprint
          || $0.languages != model.settings.requestLanguages
      } == true
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("动作").font(CidaDesign.ui(12, weight: .semibold)).foregroundStyle(
          CidaDesign.textControl)
        Spacer()
        Text("拖动排序 · 首项默认").font(CidaDesign.ui(11)).foregroundStyle(CidaDesign.textTertiary)
      }
      .padding(.bottom, 12)
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("样例")
            Spacer()
            Text("使用当前模型")
          }
          .font(CidaDesign.ui(11))
          .foregroundStyle(CidaDesign.textTertiary)
          Text(ActionEditor.sample)
            .font(Font(Self.sampleFont))
            .lineSpacing(Self.sampleLineSpacing)
            .foregroundStyle(CidaDesign.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings-action-sample")
        }
        .padding(18)
        Hairline()
        actionBar.padding(.horizontal, 12).frame(height: 44)
        Hairline()
        if dragging != nil {
          Text(dragging == .translate ? "「翻译」用于截图翻译与原处翻译，不能删除" : "拖到这里删除")
            .font(CidaDesign.ui(11))
            .foregroundStyle(CidaDesign.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(10)
            .overlay(
              RoundedRectangle(cornerRadius: 6).strokeBorder(
                CidaDesign.border, style: StrokeStyle(dash: [4]))
            )
            .onDrop(of: [.text], isTargeted: nil) { _ in
              guard let dragging else { return false }
              editor.delete(dragging, from: &model.settings)
              self.dragging = nil
              return true
            }
            .padding(.bottom, 8)
        }
        paper
      }
      .background(CidaDesign.surface)
      .clipShape(.rect(cornerRadius: CidaDesign.Radius.card))
      .overlay(
        RoundedRectangle(cornerRadius: CidaDesign.Radius.card).strokeBorder(
          CidaDesign.border, lineWidth: 1))
      if let notice = editor.notice {
        HStack(spacing: 8) {
          Text(notice).foregroundStyle(CidaDesign.textTertiary)
          Button("撤销") { editor.undoChange(settings: &model.settings) }
            .buttonStyle(.plain)
            .foregroundStyle(CidaDesign.accent)
            .keyboardShortcut("z", modifiers: .command)
            .disabled(editor.isDirty)
            .accessibilityIdentifier("settings-action-undo")
        }
        .font(CidaDesign.ui(11))
        .padding(.top, 10)
      }
    }
    // SettingsContentController owns height motion. Animating this subtree would move the
    // sample and controls while repeatedly giving the window intermediate layout heights.
    .onAppear {
      if editor.draft == nil { editor.select(model.mode) }
    }
    .onExitCommand { editor.discard(settings: model.settings) }
    .onKeyPress(keys: [.leftArrow, .rightArrow, .delete, .init("\u{F705}")]) { key in
      guard let focusedAction, editor.draft == nil else { return .ignored }
      if key.modifiers.contains(.option), key.key == .leftArrow || key.key == .rightArrow {
        move(focusedAction, key.key == .leftArrow ? -1 : 1)
        return .handled
      }
      if key.modifiers.contains(.command), key.key == .delete {
        editor.delete(focusedAction, from: &model.settings)
        return .handled
      }
      if key.key == .init("\u{F705}") {
        editor.select(focusedAction)
        beginEditing(rename: true)
        return .handled
      }
      return .ignored
    }
  }

  private var actionBar: some View {
    HStack(spacing: 10) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          HStack(spacing: 2) {
            ForEach(actions) { action in
              segment(action).id(action.id)
            }
            Button {
              editor.create(model.settings)
              nameFocused = true
            } label: {
              LucideIcon(.plus, size: 12).frame(width: 28, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(CidaDesign.textSecondary)
            .disabled(editor.isDirty)
            .opacity(editor.isDirty ? 0.45 : 1)
            .accessibilityLabel("新建动作")
            .accessibilityIdentifier("settings-action-add")
            .id("actions-add")
          }
          .padding(2)
          .background(CidaDesign.surfaceDim)
          .clipShape(.rect(cornerRadius: CidaDesign.Radius.segment))
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: editor.selected) { proxy.scrollTo(editor.selected, anchor: .center) }
        .onChange(of: editor.draft == nil) {
          if editor.draft == nil, editor.selected == actions.last?.id {
            proxy.scrollTo("actions-add", anchor: .trailing)
          }
        }
        .onAppear { proxy.scrollTo(editor.selected, anchor: .center) }
      }
      if editor.isDirty {
        Text("Esc 放弃").font(CidaDesign.ui(11)).foregroundStyle(CidaDesign.textTertiary).fixedSize()
      }
      if editor.draft != nil {
        Button {
          if editor.apply(to: &model.settings) {
            nameFocused = false
            focusedAction = editor.selected
          }
        } label: {
          barLabel("完成", key: "⌘↵")
        }
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityIdentifier("settings-action-done")
        .buttonStyle(SettingsBorderedButtonStyle(fontSize: 11.5))
      } else if isRunning {
        Button(action: editor.stopPreview) { barLabel("停止", key: "⌘.") }
          .keyboardShortcut(".", modifiers: .command)
          .accessibilityIdentifier("settings-action-stop")
          .buttonStyle(SettingsBorderedButtonStyle(fontSize: 11.5))
      } else {
        Button { beginEditing() } label: { barLabel("编辑", key: "⌘E") }
          .keyboardShortcut("e", modifiers: .command)
          .accessibilityIdentifier("settings-action-edit")
          .buttonStyle(SettingsBorderedButtonStyle(fontSize: 11.5))
      }
    }
    .buttonStyle(.plain)
    .font(CidaDesign.ui(11.5, weight: .medium))
    .foregroundStyle(CidaDesign.textSecondary)
  }

  private func barLabel(_ title: String, key: String) -> some View {
    HStack(spacing: 8) {
      Text(title).font(CidaDesign.ui(11.5, weight: .semibold))
      Text(key).font(CidaDesign.ui(11)).foregroundStyle(CidaDesign.textTertiary)
    }
    .frame(width: 56)
  }

  @ViewBuilder
  private func segment(_ action: TextAction) -> some View {
    let selected = editor.selected == action.id
    let disabled = editor.isDirty && !selected
    Group {
      if selected, editor.draft != nil {
        TextField(
          "动作名称",
          text: Binding(
            get: { editor.draft?.action.name ?? action.name },
            set: { editor.draft?.action.name = $0 })
        )
        .textFieldStyle(.plain)
        .focused($nameFocused)
        .onSubmit {
          nameFocused = false
          promptFocus += 1
        }
        .frame(width: actionNameWidth(editor.draft?.action.name ?? action.name))
        .overlay(alignment: .bottom) {
          Rectangle().fill(nameFocused ? CidaDesign.accent : .clear).frame(height: 1)
        }
        .padding(.horizontal, 12)
        .accessibilityIdentifier("settings-action-name")
      } else {
        Button {
          editor.select(action.id)
        } label: {
          Text(action.name)
            .lineLimit(1)
            .frame(width: actionNameWidth(action.name))
            .padding(.horizontal, 12)
            .frame(height: 24)
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($focusedAction, equals: action.id)
        .overlay {
          ActionDragSource(
            name: action.name, id: action.id, enabled: !disabled,
            click: { count in
              editor.select(action.id)
              focusedAction = action.id
              if count == 2 { beginEditing(rename: true) }
            },
            began: {
              dragging = action.id
              focusedAction = action.id
            },
            ended: {
              dragging = nil
              dropTarget = nil
            }
          )
          .accessibilityHidden(true)
        }
        .accessibilityIdentifier("settings-action-\(action.id.rawValue)")
        .accessibilityAction(named: "改名") {
          editor.select(action.id)
          beginEditing(rename: true)
        }
        .accessibilityAction(named: "左移") { move(action.id, -1) }
        .accessibilityAction(named: "右移") { move(action.id, 1) }
        .accessibilityAction(named: "删除") { editor.delete(action.id, from: &model.settings) }
      }
    }
    .font(CidaDesign.ui(11.5, weight: selected ? .semibold : .medium))
    .foregroundStyle(selected ? CidaDesign.accent : CidaDesign.textSecondary)
    .frame(height: 24)
    .background(selected ? CidaDesign.surface : .clear)
    .clipShape(.rect(cornerRadius: CidaDesign.Radius.segmentItem))
    .overlay(alignment: dropTarget?.after == true ? .trailing : .leading) {
      if dropTarget?.id == action.id { Rectangle().fill(CidaDesign.accent).frame(width: 2) }
    }
    .accessibilityAddTraits(selected ? [.isSelected] : [])
    .disabled(disabled)
    .opacity(disabled ? 0.45 : 1)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      segmentWidths[action.id] = $0
    }
    .onDrop(
      of: [.text],
      delegate: ActionReorderDrop(
        target: action.id, width: segmentWidths[action.id] ?? 50, dragging: $dragging,
        insertion: $dropTarget, editor: editor, model: model))
  }

  private var paper: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let draft = editor.draft {
        HStack {
          Text("提示词")
          Spacer()
          if draft.action.id == .translate || draft.action.id == .improve,
            draft.action.prompt != CidaSettings.defaultPrompt(for: draft.action.id)
          {
            Button("恢复默认", action: editor.restoreDefault)
              .accessibilityIdentifier("settings-action-reset")
          }
          if draft.action.id != .translate {
            Button("删除动作") { editor.delete(editor.selected, from: &model.settings) }
              .accessibilityIdentifier("settings-action-delete")
          }
        }
        .buttonStyle(.plain)
        .font(CidaDesign.ui(11))
        .foregroundStyle(CidaDesign.textTertiary)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        PromptTextEditor(
          text: Binding(
            get: { editor.draft?.action.prompt ?? "" },
            set: { editor.draft?.action.prompt = $0 }),
          accessibilityLabel: "\(draft.action.name)提示词",
          accessibilityIdentifier: "settings-action-prompt",
          focusRequest: promptFocus,
          onEscape: { editor.discard(settings: model.settings) },
          onApply: { _ = editor.apply(to: &model.settings) }
        )
        .frame(height: promptHeight)
        if preview != nil {
          Hairline().padding(.horizontal, 16)
        }
      }
      if let error = editor.error {
        Text(error).font(CidaDesign.ui(11)).foregroundStyle(CidaDesign.textSecondary)
          .padding(16).accessibilityIdentifier("settings-action-validation")
      }
      if editor.draft == nil || preview != nil {
        ActionPreviewText(
          text: preview?.text ?? (isRunning ? "" : "完成提示词编辑后，在这里看它的效果。"),
          isRunning: isRunning)
          .font(
            preview == nil ? Font(Self.sampleFont) : Font(
              CidaDesign.appKitResult(
                for: TextLanguageDetector.typography(of: preview?.text ?? "") ?? .chinese, size: 15))
          )
          .lineSpacing(preview == nil ? Self.sampleLineSpacing : 7)
          .foregroundStyle(
            preview == nil
              ? CidaDesign.textTertiary : stale ? CidaDesign.textSecondary : CidaDesign.textInk
          )
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
          .padding(16)
          .accessibilityIdentifier("settings-action-preview")
      }
      HStack(spacing: 6) {
        Text(previewNote)
          .font(CidaDesign.ui(11))
          .foregroundStyle(CidaDesign.textTertiary)
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 12)
      .accessibilityIdentifier("settings-action-preview-status")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CidaDesign.surfacePaper)
  }

  private var promptHeight: CGFloat {
    let style = NSMutableParagraphStyle()
    style.minimumLineHeight = PromptTextEditor.lineHeight
    style.maximumLineHeight = PromptTextEditor.lineHeight
    let text = NSAttributedString(
      string: (editor.draft?.action.prompt ?? "") + " ",
      attributes: [
        .font: PromptTextEditor.font, .paragraphStyle: style,
      ])
    return min(
      240,
      max(
        PromptTextEditor.lineHeight * 2 + 28,
        ceil(
          text.boundingRect(
            with: NSSize(width: 476, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
          ).height) + 28))
  }

  private var previewNote: String {
    if isRunning { return "正在按新提示词更新 · ⌘. 停止" }
    if editor.draft != nil, preview == nil { return "完成后预览 · ⌘↵" }
    if editor.isDirty { return preview == nil ? "完成后，看看这个动作的效果" : "上次的结果 · 完成后更新" }
    if let note = editor.previewNotes[editor.selected] { return note }
    return preview == nil ? "使用当前模型 · 固定样例" : stale ? "上次的结果 · 完成后更新" : "当前提示词的效果"
  }
  private func actionNameWidth(_ name: String) -> CGFloat {
    let font = NSFont(name: "Inter-SemiBold", size: 11.5) ?? CidaDesign.appKitBody(11.5)
    return max(24, min(130, ceil((name as NSString).size(withAttributes: [.font: font]).width)))
  }
  private func beginEditing(rename: Bool = false) {
    editor.begin(model.settings)
    focusedAction = nil
    if rename { nameFocused = true } else { promptFocus += 1 }
  }
  private func move(_ id: ProcessingMode, _ offset: Int) {
    guard let index = model.settings.actions.firstIndex(where: { $0.id == id }) else { return }
    editor.move(id, to: index + offset, settings: &model.settings)
  }
}

private struct ActionInsertion: Equatable {
  let id: ProcessingMode
  let after: Bool
}

private struct ActionReorderDrop: DropDelegate {
  let target: ProcessingMode
  let width: CGFloat
  @Binding var dragging: ProcessingMode?
  @Binding var insertion: ActionInsertion?
  let editor: ActionEditor
  let model: AppModel

  func validateDrop(info: DropInfo) -> Bool { dragging != nil && !editor.isDirty }
  func dropEntered(info: DropInfo) {
    insertion = ActionInsertion(id: target, after: info.location.x > width / 2)
  }
  func dropExited(info: DropInfo) { if insertion?.id == target { insertion = nil } }
  func dropUpdated(info: DropInfo) -> DropProposal? {
    insertion = ActionInsertion(id: target, after: info.location.x > width / 2)
    return DropProposal(operation: .move)
  }
  func performDrop(info: DropInfo) -> Bool {
    guard let dragging, let index = model.settings.actions.firstIndex(where: { $0.id == target })
    else { return false }
    guard let source = model.settings.actions.firstIndex(where: { $0.id == dragging }) else {
      return false
    }
    let slot = index + (info.location.x > width / 2 ? 1 : 0)
    editor.move(dragging, to: slot - (source < slot ? 1 : 0), settings: &model.settings)
    self.dragging = nil
    insertion = nil
    return true
  }
}

/// A native drag session reports cancellation as well as a successful drop, so the deletion
/// target cannot linger when a segment is dropped outside Settings.
private struct ActionDragSource: NSViewRepresentable {
  let name: String
  let id: ProcessingMode
  let enabled: Bool
  let click: (Int) -> Void
  let began: () -> Void
  let ended: () -> Void
  func makeNSView(context: Context) -> DragView { DragView() }
  func updateNSView(_ view: DragView, context: Context) {
    view.source = self
  }
  final class DragView: NSView, NSDraggingSource {
    var source: ActionDragSource?
    private var start: NSPoint?
    override func mouseDown(with event: NSEvent) {
      start = convert(event.locationInWindow, from: nil)
    }
    override func mouseUp(with event: NSEvent) {
      if start != nil, source?.enabled == true { source?.click(event.clickCount) }
      start = nil
    }
    override func mouseDragged(with event: NSEvent) {
      guard let start, let source, source.enabled else { return }
      let point = convert(event.locationInWindow, from: nil)
      guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
      self.start = nil
      let item = NSDraggingItem(pasteboardWriter: source.id.rawValue as NSString)
      let image = NSImage(size: bounds.size, flipped: false) { rect in
        source.name.draw(
          at: NSPoint(x: 10, y: 4),
          withAttributes: [
            .font: CidaDesign.appKitBody(12), .foregroundColor: NSColor.labelColor,
          ])
        return true
      }
      item.setDraggingFrame(bounds, contents: image)
      source.began()
      beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(
      _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .move }
    func draggingSession(
      _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) { source?.ended() }
  }
}

/// The sample waits with the same ink caret as the panel, without an idle animation clock.
private struct ActionPreviewText: View {
  let text: String
  let isRunning: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if isRunning && !reduceMotion {
        TimelineView(.animation) { context in
          paragraph(
            opacity: Double(
              StatusItemMark.caretOpacity(after: context.date.timeIntervalSinceReferenceDate)))
        }
      } else {
        paragraph(opacity: isRunning ? 1 : nil)
      }
    }
    .accessibilityLabel(text)
  }

  private func paragraph(opacity: Double?) -> Text {
    guard let opacity else { return Text(text) }
    return Text(text)
      + Text(Image(nsImage: PaperCaret.image(opacity: opacity)))
      .baselineOffset(-ResultTextStyle.caretDescent)
  }
}
