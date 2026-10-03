import Foundation

/// The application a note was captured from; the shape written for `app`.
struct NoteSourceApplication: Codable, Equatable, Sendable {
  var name: String?
  var bundleIdentifier: String?

  enum CodingKeys: String, CodingKey {
    case name
    case bundleIdentifier = "bundle_id"
  }

  init(name: String? = nil, bundleIdentifier: String? = nil) {
    self.name = name
    self.bundleIdentifier = bundleIdentifier
  }

  var isEmpty: Bool {
    (name ?? "").isEmpty && (bundleIdentifier ?? "").isEmpty
  }
}

/// Where the clipboard's text came from (`{ts, app}`), for writers that track it. Cida does not,
/// so a note saved here has none; the key is still written, as null, so every line in the file
/// carries the same fields.
struct NoteClipboardOrigin: Codable, Equatable, Sendable {
  var ts: String
  var app: NoteSourceApplication?
}

/// A note about to be saved.
struct NoteDraft: Equatable, Sendable {
  var text: String
  /// What the note was taken from: `selection` or `clipboard` (a generated result adds
  /// `translation` and `improvement`).
  var source: String
  var application: NoteSourceApplication?
  var note: String?
  var id: UUID
  var timestamp: Date

  init(
    text: String,
    source: String = "selection",
    application: NoteSourceApplication? = nil,
    note: String? = nil,
    id: UUID = UUID(),
    timestamp: Date = Date()
  ) {
    self.text = text
    self.source = source
    self.application = application
    self.note = note
    self.id = id
    self.timestamp = timestamp
  }
}

/// What a result note records besides the text itself (`Design/spec/notes.md` §四): the two
/// actions whose output is kept beside its source.
enum NoteResultKind: String, Sendable {
  case translation
  case improvement
}

/// One line of the notes file, read back.
struct SavedNote: Codable, Equatable, Sendable {
  var schema: Int
  var id: String
  var ts: String
  var source: String
  var text: String
  var note: String?
  var app: NoteSourceApplication?
  var copied: NoteClipboardOrigin?

  enum CodingKeys: String, CodingKey {
    case schema, id, ts, source, text, note, app, copied
  }

  /// Every key is written even when its value is empty, so a reader meets no missing field.
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(id, forKey: .id)
    try container.encode(ts, forKey: .ts)
    try container.encode(source, forKey: .source)
    try container.encode(text, forKey: .text)
    try Self.encodeOrNull(note, into: &container, forKey: .note)
    try Self.encodeOrNull(app, into: &container, forKey: .app)
    try Self.encodeOrNull(copied, into: &container, forKey: .copied)
  }

  private static func encodeOrNull<T: Encodable>(
    _ value: T?, into container: inout KeyedEncodingContainer<CodingKeys>, forKey key: CodingKeys
  ) throws {
    if let value {
      try container.encode(value, forKey: key)
    } else {
      try container.encodeNil(forKey: key)
    }
  }
}

enum NoteStoreError: Error, Equatable {
  case cannotCreateDirectory(path: String, reason: String)
  case cannotWrite(path: String, reason: String)

  /// The line under the hint pill; short, and it says what failed.
  var message: String {
    switch self {
    case .cannotCreateDirectory(let path, let reason):
      "无法创建 \(path)：\(reason)"
    case .cannotWrite(let path, let reason):
      "无法写入 \(path)：\(reason)"
    }
  }
}

/// Appends notes as one JSON line each (`Design/spec/notes.md`), so another JSONL writer's file
/// can be used as it is, and its notes read here.
///
/// `O_APPEND` with a single write per line is what makes two writers safe: neither can overwrite
/// the other's lines, whatever order they arrive in.
struct NoteStore: Sendable {
  /// Where notes go when the user has not named a file: Cida's own inbox.
  static var defaultFileURL: URL {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(".cida/items.jsonl")
  }

  /// A source this long is not kept beside its result (`Design/spec/notes.md` §四): a notebook
  /// does not need a copy of every long document, and one such line would dwarf the file.
  static let maximumResultCharacters = 100_000

  /// The same text from the same application inside this window is one press too many, not two
  /// notes.
  static let duplicateWindow: TimeInterval = 60
  /// How much of the end of the file is read to find that repeat.
  private static let duplicateTailBytes = 8 * 1024

  let fileURL: URL

  init(fileURL: URL = NoteStore.defaultFileURL) {
    self.fileURL = fileURL
  }

  /// Writes one line and answers with the file it went into.
  @discardableResult
  func append(_ draft: NoteDraft) throws -> URL {
    let directory = fileURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw NoteStoreError.cannotCreateDirectory(
        path: directory.path, reason: error.localizedDescription)
    }
    let note = SavedNote(
      schema: 1,
      id: draft.id.uuidString,
      ts: Self.timestampText(from: draft.timestamp),
      source: draft.source,
      text: draft.text,
      note: draft.note,
      app: draft.application?.isEmpty == true ? nil : draft.application,
      copied: nil
    )
    var data = try Self.encoder.encode(note)
    data.append(0x0A)
    try Self.write(data, to: fileURL)
    return fileURL
  }

  /// Whether the file's most recent notes already hold this text, from this application, inside
  /// the duplicate window. Only the end of the file is read, so a long inbox costs nothing.
  ///
  /// A draft without a `note` matches any saved note of the same text, which is how ⌥N keeps
  /// behaving as before; a draft with one — a generated result — matches only the same result, so
  /// regenerating a translation into different words is a new note rather than a repeat.
  func isRecentDuplicate(_ draft: NoteDraft) -> Bool {
    guard let tail = try? Self.tail(of: fileURL, bytes: Self.duplicateTailBytes) else { return false }
    for line in tail.split(separator: 0x0A).reversed() {
      guard let note = try? Self.decoder.decode(SavedNote.self, from: Data(line)),
        let savedAt = Self.timestamp(from: note.ts)
      else { continue }
      let age = draft.timestamp.timeIntervalSince(savedAt)
      if age > Self.duplicateWindow { return false }
      if note.text == draft.text,
        note.app?.bundleIdentifier == draft.application?.bundleIdentifier,
        draft.note == nil || note.note == draft.note
      {
        return true
      }
    }
    return false
  }

  /// The notes in the file, in the order they were written.
  func savedNotes(limit: Int? = nil) throws -> [SavedNote] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    var notes = data.split(separator: 0x0A).compactMap { line in
      try? Self.decoder.decode(SavedNote.self, from: Data(line))
    }
    if let limit, notes.count > limit {
      notes = Array(notes.suffix(limit))
    }
    return notes
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    // Stable key order, and slashes and Chinese left readable.
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()
  private static let decoder = JSONDecoder()

  /// The file's time: ISO 8601 with milliseconds and the local offset.
  static func timestampText(from date: Date) -> String {
    timestampFormatter().string(from: date)
  }

  static func timestamp(from text: String) -> Date? {
    timestampFormatter().date(from: text)
  }

  private static func timestampFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone.current
    return formatter
  }

  private static func write(_ data: Data, to url: URL) throws {
    let path = url.path
    let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard descriptor >= 0 else {
      throw NoteStoreError.cannotWrite(path: path, reason: String(cString: strerror(errno)))
    }
    defer { close(descriptor) }
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      guard let base = buffer.baseAddress else { return }
      var written = 0
      while written < buffer.count {
        let count = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
        if count <= 0 {
          if errno == EINTR { continue }
          throw NoteStoreError.cannotWrite(path: path, reason: String(cString: strerror(errno)))
        }
        written += count
      }
    }
  }

  private static func tail(of url: URL, bytes: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
    try handle.seek(toOffset: start)
    return try handle.read(upToCount: bytes) ?? Data()
  }
}
