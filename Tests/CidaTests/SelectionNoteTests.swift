import XCTest

@testable import Cida

/// The note action (`Design/spec/notes.md` §二): what it reads, what the pill says, and what
/// lands in the file. The selection reader and the application lookup are injected, so no test
/// touches another application or the user's own notes.
@MainActor
final class SelectionNoteTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("cida-selection-note-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private var fileURL: URL { directory.appendingPathComponent("notes.jsonl") }

  private func makeNote(
    selection: String?,
    clipboard: String? = nil,
    application: NoteSourceApplication? = NoteSourceApplication(
      name: "Safari", bundleIdentifier: "com.apple.Safari"),
    path: String = ""
  ) -> (SelectionNote, () -> [NoteFeedback?], () -> [String]) {
    var settings = CidaSettings()
    settings.noteFile = path
    let note = SelectionNote(
      store: NoteStore(fileURL: fileURL),
      readSelection: { selection },
      readClipboard: { clipboard },
      frontmostApplication: { application })
    var feedbacks: [NoteFeedback?] = []
    var events: [String] = []
    note.onFeedback = { feedbacks.append($0) }
    note.recordEvent = { events.append($0) }
    return (note, { feedbacks }, { events })
  }

  private func settings(path: String = "") -> CidaSettings {
    var settings = CidaSettings()
    settings.noteFile = path
    return settings
  }

  private func savedNotes() throws -> [SavedNote] {
    try NoteStore(fileURL: fileURL).savedNotes()
  }

  func testASelectionIsWrittenWithItsApplication() async throws {
    let (note, feedbacks, events) = makeNote(selection: "要记下来的这句话")
    await note.saveSelection(settings: settings())

    let saved = try savedNotes()
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved[0].text, "要记下来的这句话")
    XCTAssertEqual(saved[0].source, "selection")
    XCTAssertEqual(saved[0].app?.name, "Safari")
    XCTAssertEqual(saved[0].app?.bundleIdentifier, "com.apple.Safari")
    XCTAssertEqual(saved[0].schema, 1)
    XCTAssertNil(saved[0].copied)
    XCTAssertEqual(feedbacks().last??.text, "已存入笔记 · Safari")
    XCTAssertEqual(events(), ["note-saved source=selection"])
  }

  func testNoSelectionAndNoClipboardWritesNothingAndSaysSo() async throws {
    let (note, feedbacks, events) = makeNote(selection: nil)
    await note.saveSelection(settings: settings())

    XCTAssertEqual(try savedNotes().count, 0)
    XCTAssertEqual(feedbacks().last??.text, "请先选中文字，或复制一段")
    XCTAssertEqual(events(), ["note-no-selection"])
  }

  /// Nothing selected but text on the clipboard: the press means "keep this", so the clipboard is
  /// what is kept, marked as such (`Design/spec/notes.md` §一).
  func testWithNothingSelectedTheClipboardIsSaved() async throws {
    let (note, feedbacks, events) = makeNote(selection: nil, clipboard: "刚复制的那句话")
    await note.saveSelection(settings: settings())

    let saved = try savedNotes()
    XCTAssertEqual(saved.map(\.text), ["刚复制的那句话"])
    XCTAssertEqual(saved[0].source, "clipboard")
    XCTAssertEqual(saved[0].app?.name, "Safari", "仍然记下当时在哪工作")
    XCTAssertEqual(feedbacks().last??.text, "已存入笔记 · 剪贴板")
    XCTAssertEqual(events(), ["note-saved source=clipboard"])
  }

  /// A selection wins over the clipboard: the user selected something on purpose.
  func testASelectionWinsOverTheClipboard() async throws {
    let (note, feedbacks, _) = makeNote(selection: "选中的", clipboard: "剪贴板里的")
    await note.saveSelection(settings: settings())

    XCTAssertEqual(try savedNotes().map(\.text), ["选中的"])
    XCTAssertEqual(try savedNotes()[0].source, "selection")
    XCTAssertEqual(feedbacks().last??.text, "已存入笔记 · Safari")
  }

  /// Two presses in a row are one note: the pill says so instead of writing it twice.
  func testAPressTwiceIsOneNote() async throws {
    let (note, feedbacks, events) = makeNote(selection: "同一段话")
    await note.saveSelection(settings: settings())
    await note.saveSelection(settings: settings())

    XCTAssertEqual(try savedNotes().count, 1)
    XCTAssertEqual(feedbacks().last??.text, "刚刚已存过这条")
    XCTAssertEqual(events(), ["note-saved source=selection", "note-duplicate"])
  }

  /// The panel's ⌘S: the text is already in hand, and the application is the one the panel was
  /// summoned from.
  func testTextHandedInIsSavedWithThePanelApplication() throws {
    let (note, feedbacks, _) = makeNote(selection: nil, application: nil)
    note.save(
      text: "面板里的话",
      application: NoteSourceApplication(name: "Notes", bundleIdentifier: "com.apple.Notes"),
      settings: settings())

    let saved = try savedNotes()
    XCTAssertEqual(saved.map(\.text), ["面板里的话"])
    XCTAssertEqual(saved[0].app?.bundleIdentifier, "com.apple.Notes")
    XCTAssertEqual(feedbacks().last??.text, "已存入笔记 · Notes")
  }

  /// A note from the panel that names no application says just what happened.
  func testThePillWithoutAnApplication() throws {
    let (note, feedbacks, _) = makeNote(selection: nil, application: nil)
    note.save(text: "来自截图的话", application: nil, settings: settings())

    XCTAssertEqual(feedbacks().last??.text, "已存入笔记")
    XCTAssertNil(try savedNotes()[0].app)
  }

  /// The settings name the file; `~` is the user's home, not a literal directory.
  func testTheConfiguredFileIsUsed() throws {
    let custom = directory.appendingPathComponent("custom/notes.jsonl")
    let (note, _, _) = makeNote(selection: nil)
    note.save(text: "写到别处", application: nil, settings: settings(path: custom.path))

    XCTAssertEqual(try NoteStore(fileURL: custom).savedNotes().map(\.text), ["写到别处"])
  }

  /// A file that cannot be written says so instead of failing quietly.
  func testAFailureIsReported() throws {
    let blocked = directory.appendingPathComponent("blocked.jsonl")
    FileManager.default.createFile(atPath: blocked.path, contents: Data("x".utf8))
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: blocked.path)

    let (note, feedbacks, events) = makeNote(selection: nil)
    note.save(text: "写不进去", application: nil, settings: settings(path: blocked.path))

    XCTAssertTrue(
      feedbacks().last??.text.hasPrefix("存入失败：") == true,
      "应当报告失败：\(String(describing: feedbacks().last))")
    XCTAssertEqual(events(), ["note-failed"])
  }

  // MARK: - 结果笔记

  /// A generated result is kept beside its source, quietly: no pill — nobody pressed a note key
  /// for this one — and the event says what was written (`Design/spec/notes.md` §四).
  func testAGeneratedResultIsSavedQuietlyWithItsSource() throws {
    let (note, feedbacks, events) = makeNote(selection: nil, application: nil)
    note.saveResult(
      text: "原文", note: "译文", kind: .translation,
      application: NoteSourceApplication(name: "Safari", bundleIdentifier: "com.apple.Safari"),
      settings: settings())

    let saved = try savedNotes()
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved[0].text, "原文")
    XCTAssertEqual(saved[0].note, "译文")
    XCTAssertEqual(saved[0].source, "translation")
    XCTAssertEqual(saved[0].app?.bundleIdentifier, "com.apple.Safari")
    XCTAssertTrue(feedbacks().isEmpty, "自动记下的一条不该弹胶囊")
    XCTAssertEqual(events(), ["note-saved-result source=translation"])
  }

  /// The same source generated twice into different words is two notes: the pair is the unit,
  /// not the source.
  func testTwoResultsForTheSameSourceAreTwoNotes() throws {
    let (note, _, events) = makeNote(selection: nil, application: nil)
    note.saveResult(
      text: "原文", note: "First", kind: .improvement, application: nil, settings: settings())
    note.saveResult(
      text: "原文", note: "Second", kind: .improvement, application: nil, settings: settings())

    XCTAssertEqual(try savedNotes().map(\.note), ["First", "Second"])
    XCTAssertEqual(
      events(), ["note-saved-result source=improvement", "note-saved-result source=improvement"])
  }

  /// A failed write is the one thing that speaks, even for a quiet save.
  func testAFailedResultSaveIsReported() throws {
    let blocked = directory.appendingPathComponent("blocked.jsonl")
    FileManager.default.createFile(atPath: blocked.path, contents: Data("x".utf8))
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: blocked.path)

    let (note, feedbacks, events) = makeNote(selection: nil, application: nil)
    note.saveResult(
      text: "原文", note: "译文", kind: .translation, application: nil,
      settings: settings(path: blocked.path))

    XCTAssertTrue(
      feedbacks().last??.text.hasPrefix("存入失败：") == true,
      "应当报告失败：\(String(describing: feedbacks().last))")
    XCTAssertEqual(events(), ["note-result-failed source=translation"])
  }

  // MARK: - The panel's ⌘S

  /// Only ⌘S: ⇧⌘S and a bare s are not this action, and neither is ⌘C.
  func testThePanelShortcutIsCommandSOnly() throws {
    func event(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16) throws -> NSEvent {
      try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
          context: nil, characters: characters, charactersIgnoringModifiers: characters,
          isARepeat: false, keyCode: keyCode))
    }

    XCTAssertTrue(NoteShortcutRouting.isNoteShortcut(try event("s", .command, keyCode: 1)))
    XCTAssertTrue(
      NoteShortcutRouting.isNoteShortcut(try event("s", [.command, .capsLock], keyCode: 1)),
      "大写锁定不算另一个组合")
    XCTAssertFalse(NoteShortcutRouting.isNoteShortcut(try event("S", [.command, .shift], keyCode: 1)))
    XCTAssertFalse(NoteShortcutRouting.isNoteShortcut(try event("s", [], keyCode: 1)))
    XCTAssertFalse(NoteShortcutRouting.isNoteShortcut(try event("c", .command, keyCode: 8)))
  }

  /// The panel hands its own text to the owner's saver: `saveNoteFromPanel` is `⌘S`'s whole job.
  @MainActor
  func testThePanelSavesItsOwnText() {
    var saved: [String] = []
    let model = AppModel(
      inputText: "面板里正在改的文字",
      saveNote: { saved.append($0) })

    model.saveNoteFromPanel()

    XCTAssertEqual(saved, ["面板里正在改的文字"])
  }
}
