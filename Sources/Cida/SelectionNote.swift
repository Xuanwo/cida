import AppKit
import Foundation

/// What the hint pill says after a note action; `dismissAfter` nil keeps it until it is replaced.
struct NoteFeedback: Equatable {
  let text: String
  var dismissAfter: Double?
}

/// Saves the frontmost application's selection as a note (`Design/spec/notes.md`).
///
/// It is Cida's shortest path: no panel, no request, no focus change. The selection comes from
/// the same reader ⌥A uses, so an application that cannot answer through Accessibility is still
/// read through a temporary ⌘C. The same file also takes the results of 翻译 and 改进 (§四),
/// which is why the store and the file lookup live here rather than with the key handler.
@MainActor
final class SelectionNote {
  private let defaultStore: NoteStore
  private let readSelection: @MainActor () async -> String?
  private let readClipboard: @MainActor () -> String?
  private let frontmostApplication: @MainActor () -> NoteSourceApplication?

  var onFeedback: (NoteFeedback?) -> Void = { _ in }
  var recordEvent: (String) -> Void = { _ in }
  private(set) var isSaving = false

  init(
    store: NoteStore = NoteStore(),
    readSelection: @escaping @MainActor () async -> String? = {
      await SelectedText.read(
        from: AccessibilitySelectedTextSource(), copyingWith: PasteboardSelectionCopier())
    },
    readClipboard: @escaping @MainActor () -> String? = {
      // Only text counts, and a copy of files is not text (`PasteboardSelectionCopier`).
      PasteboardSelectionCopier.copiedText(on: .general)
    },
    frontmostApplication: @escaping @MainActor () -> NoteSourceApplication? = {
      SelectionNote.currentApplication()
    }
  ) {
    self.defaultStore = store
    self.readSelection = readSelection
    self.readClipboard = readClipboard
    self.frontmostApplication = frontmostApplication
  }

  /// The application the user is working in; nil in Cida itself.
  static func currentApplication(
    processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
  ) -> NoteSourceApplication? {
    guard let application = NSWorkspace.shared.frontmostApplication,
      application.processIdentifier != processIdentifier
    else { return nil }
    return NoteSourceApplication(
      name: application.localizedName, bundleIdentifier: application.bundleIdentifier)
  }

  /// Reads the selection and saves it. The file comes from the settings, so a change in Settings
  /// applies to the next press.
  ///
  /// With nothing selected the clipboard is saved instead (`Design/spec/notes.md` §一): the press
  /// means "keep this", and a line copied a moment ago is as good a "this" as a line selected.
  func saveSelection(settings: CidaSettings) async {
    guard !isSaving else { return }
    isSaving = true
    defer { isSaving = false }

    // Read the source application before the selection: reading may ask another application to
    // copy, and the note should name where the user was working, not where the copy landed.
    let application = frontmostApplication()
    let selection = await readSelection()
    guard let text = selection ?? readClipboard() else {
      onFeedback(NoteFeedback(text: "请先选中文字，或复制一段", dismissAfter: 2.5))
      recordEvent("note-no-selection")
      return
    }
    save(
      text: text, application: application,
      source: selection == nil ? "clipboard" : "selection", settings: settings)
  }

  /// Saves text the caller already holds — the panel's ⌘S.
  func save(
    text: String, application: NoteSourceApplication?, source: String = "selection",
    settings: CidaSettings
  ) {
    let draft = NoteDraft(text: text, source: source, application: application, note: nil)
    switch append(draft, settings: settings) {
    case .written:
      let name = application?.name
      let origin = source == "clipboard" ? "剪贴板" : name
      onFeedback(
        NoteFeedback(
          text: origin.map { "已存入笔记 · \($0)" } ?? "已存入笔记",
          dismissAfter: CidaHintPanel.briefSeconds))
      recordEvent("note-saved source=\(draft.source)")
    case .duplicate:
      onFeedback(NoteFeedback(text: "刚刚已存过这条", dismissAfter: CidaHintPanel.briefSeconds))
      recordEvent("note-duplicate")
    case .failed(let reason):
      onFeedback(NoteFeedback(text: "存入失败：\(reason)", dismissAfter: 2.5))
      recordEvent("note-failed")
    }
  }

  /// Keeps a completed translation or improvement beside its source (`Design/spec/notes.md` §四):
  /// `text` is what the model was given, `note` is what came back. Quietly — nobody pressed a
  /// note key for this one — except when the write fails, which the pill has to say rather than
  /// lose the note without a word.
  func saveResult(
    text: String, note: String, kind: NoteResultKind, application: NoteSourceApplication?,
    settings: CidaSettings
  ) {
    let draft = NoteDraft(text: text, source: kind.rawValue, application: application, note: note)
    switch append(draft, settings: settings) {
    case .written:
      recordEvent("note-saved-result source=\(kind.rawValue)")
    case .duplicate:
      recordEvent("note-result-duplicate source=\(kind.rawValue)")
    case .failed(let reason):
      onFeedback(NoteFeedback(text: "存入失败：\(reason)", dismissAfter: 2.5))
      recordEvent("note-result-failed source=\(kind.rawValue)")
    }
  }

  private enum AppendOutcome {
    case written
    case duplicate
    /// The user-facing reason, as `NoteStoreError.message` or the system's own words.
    case failed(String)
  }

  private func append(_ draft: NoteDraft, settings: CidaSettings) -> AppendOutcome {
    let store = store(for: settings)
    guard !store.isRecentDuplicate(draft) else { return .duplicate }
    do {
      try store.append(draft)
      return .written
    } catch let error as NoteStoreError {
      return .failed(error.message)
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// The file the settings name, or the one Cida was given.
  private func store(for settings: CidaSettings) -> NoteStore {
    let path = settings.noteFile.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return defaultStore }
    return NoteStore(fileURL: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
  }
}
