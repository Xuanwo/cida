import XCTest

@testable import Cida

/// Saving notes (`Design/spec/notes.md`): the line format, the append-only write,
/// and the double-press window.
final class NoteStoreTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("cida-note-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func store(file: String = "notes.jsonl") -> NoteStore {
    NoteStore(fileURL: directory.appendingPathComponent(file))
  }

  private func lines(of store: NoteStore) throws -> [String] {
    let text = try String(contentsOf: store.fileURL, encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  // MARK: - The line

  func testANoteIsOneLineWithEveryField() throws {
    let store = store()
    try store.append(
      NoteDraft(
        text: "多行\n文本也只是一行 JSON",
        application: NoteSourceApplication(name: "Safari", bundleIdentifier: "com.apple.Safari")
      ))

    let written = try lines(of: store)
    XCTAssertEqual(written.filter { !$0.isEmpty }.count, 1, "一条笔记只占一行")

    let line = written[0]
    for key in ["\"schema\"", "\"id\"", "\"ts\"", "\"source\"", "\"text\"", "\"note\"", "\"app\"", "\"copied\""] {
      XCTAssertTrue(line.contains(key), "缺字段 \(key)：\(line)")
    }
    XCTAssertTrue(line.contains("\"note\":null"), "缺省字段写 null")
    XCTAssertTrue(line.contains("\"copied\":null"))
    XCTAssertTrue(line.contains("\"source\":\"selection\""))
    XCTAssertTrue(line.contains("\"bundle_id\":\"com.apple.Safari\""))
  }

  /// The file is read by `jq` and by `grep`; keys stay sorted and Chinese and slashes
  /// stay as they were typed.
  func testTheLineStaysReadable() throws {
    let store = store()
    try store.append(NoteDraft(text: "中文不转义，斜杠 https://example.com/a/b 也不转义"))

    let line = try lines(of: store)[0]
    XCTAssertTrue(line.contains("中文不转义，斜杠 https://example.com/a/b 也不转义"))
    XCTAssertLessThan(
      line.range(of: "\"id\"")!.lowerBound, line.range(of: "\"ts\"")!.lowerBound,
      "键按字母序")
  }

  func testTheTimestampIsISO8601WithMillisecondsAndAnOffset() throws {
    let store = store()
    try store.append(NoteDraft(text: "x", timestamp: Date(timeIntervalSince1970: 1_800_000_000)))

    let line = try lines(of: store)[0]
    let pattern = #""ts":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2}""#
    XCTAssertNotNil(line.range(of: pattern, options: .regularExpression), line)
    let text = NoteStore.timestampText(from: Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertEqual(NoteStore.timestamp(from: text).map { Int($0.timeIntervalSince1970) }, 1_800_000_000)
  }

  func testAnUnknownApplicationIsWrittenAsNull() throws {
    let store = store()
    try store.append(NoteDraft(text: "x", application: NoteSourceApplication()))

    XCTAssertTrue(try lines(of: store)[0].contains("\"app\":null"))
  }

  // MARK: - Appending

  func testEveryNoteAppendsAndNothingIsLost() throws {
    let store = store()
    for index in 0..<5 {
      try store.append(NoteDraft(text: "第 \(index) 条"))
    }

    let written = try lines(of: store)
    XCTAssertEqual(written.filter { !$0.isEmpty }.count, 5)
    XCTAssertEqual(try store.savedNotes().map(\.text), (0..<5).map { "第 \($0) 条" })
    XCTAssertEqual(try store.savedNotes(limit: 2).map(\.text), ["第 3 条", "第 4 条"])
  }

  func testTheFileAndItsDirectoryAreCreated() throws {
    let store = NoteStore(fileURL: directory.appendingPathComponent("nested/deeper/notes.jsonl"))
    try store.append(NoteDraft(text: "x"))

    XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    XCTAssertTrue(try lines(of: store)[0].contains("\"text\":\"x\""))
  }

  func testSavedNotesOfAMissingFileAreEmpty() throws {
    XCTAssertEqual(try store(file: "nothing-here.jsonl").savedNotes(), [])
  }

  // MARK: - The double press

  func testARepeatFromTheSameApplicationInsideTheWindowIsRecognized() throws {
    let store = store()
    let application = NoteSourceApplication(name: "Safari", bundleIdentifier: "com.apple.Safari")
    try store.append(NoteDraft(text: "同一段话", application: application))

    XCTAssertTrue(
      store.isRecentDuplicate(NoteDraft(text: "同一段话", application: application)),
      "刚存过的同一条不算新笔记")
  }

  func testAnotherApplicationOrAnotherTextIsNotARepeat() throws {
    let store = store()
    try store.append(
      NoteDraft(
        text: "同一段话",
        application: NoteSourceApplication(name: "Safari", bundleIdentifier: "com.apple.Safari")))

    XCTAssertFalse(
      store.isRecentDuplicate(
        NoteDraft(
          text: "同一段话",
          application: NoteSourceApplication(name: "Chrome", bundleIdentifier: "com.google.Chrome"))))
    XCTAssertFalse(store.isRecentDuplicate(NoteDraft(text: "另一段话")))
  }

  func testARepeatAfterTheWindowIsANewNote() throws {
    let store = store()
    let old = Date().addingTimeInterval(-NoteStore.duplicateWindow - 5)
    try store.append(NoteDraft(text: "同一段话", timestamp: old))

    XCTAssertFalse(store.isRecentDuplicate(NoteDraft(text: "同一段话")))
  }

  /// The check reads the end of the file only, so a long inbox costs nothing; a line longer than
  /// the window must not stop it from finding the one after it.
  func testTheCheckSurvivesALongFile() throws {
    let store = store()
    try store.append(NoteDraft(text: String(repeating: "很长的一条 ", count: 2_000)))
    try store.append(NoteDraft(text: "刚刚存的那条"))

    XCTAssertTrue(store.isRecentDuplicate(NoteDraft(text: "刚刚存的那条")))
  }

  // MARK: - The default file

  /// The default inbox is Cida's own (`Design/spec/notes.md` §二): notes do not depend on
  /// another tool being installed, while the line format stays a plain JSONL inbox.
  func testTheDefaultFileIsCidasOwnInbox() {
    XCTAssertEqual(
      NoteStore.defaultFileURL.path,
      (NSHomeDirectory() as NSString).appendingPathComponent(".cida/items.jsonl"))
  }

  // MARK: - Result notes

  /// A result note keeps both halves (`Design/spec/notes.md` §四): the source in `text`, what
  /// the model made of it in `note`.
  func testAResultNoteCarriesItsOutput() throws {
    let store = store()
    try store.append(
      NoteDraft(text: "原文", source: NoteResultKind.translation.rawValue, note: "Translation"))

    let saved = try store.savedNotes()
    XCTAssertEqual(saved[0].text, "原文")
    XCTAssertEqual(saved[0].note, "Translation")
    XCTAssertEqual(saved[0].source, "translation")
  }

  /// The same source turned into different words is a new note, not a repeat; the same pair
  /// inside the window is the repeat the check exists for. A draft without a note still matches
  /// any note of the same text, which is how ⌥N keeps behaving.
  func testTheDuplicateCheckComparesTheOutputOfAResultNote() throws {
    let store = store()
    try store.append(NoteDraft(text: "原文", source: "translation", note: "First translation"))

    XCTAssertTrue(
      store.isRecentDuplicate(
        NoteDraft(text: "原文", source: "translation", note: "First translation")))
    XCTAssertFalse(
      store.isRecentDuplicate(
        NoteDraft(text: "原文", source: "translation", note: "Another translation")))
    XCTAssertTrue(
      store.isRecentDuplicate(NoteDraft(text: "原文", source: "selection")),
      "⌥N 不因为那条笔记带着结果就重复写入")
  }
}
