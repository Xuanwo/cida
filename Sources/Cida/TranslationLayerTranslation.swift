import Foundation
import NaturalLanguage

/// Which paragraphs the layer sends: only those not already in the user's own language
/// (`Design/spec/translation-layer.md` §一). The language is free text in Settings, so it is
/// matched against language names; when nothing matches, the model decides and a block that
/// comes back unchanged is simply not drawn.
struct LayerLanguageFilter: Sendable {
  let myLanguage: NLLanguage?

  init(myLanguage text: String) {
    myLanguage = Self.language(named: text)
  }

  /// Whether `text` needs translating: it has letters and is not written in my language.
  func needsTranslation(_ text: String) -> Bool {
    guard text.contains(where: { $0.isLetter }) else { return false }
    guard let myLanguage else { return true }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(String(text.prefix(1_000)))
    guard let dominant = recognizer.dominantLanguage else { return true }
    return Self.family(dominant) != Self.family(myLanguage)
  }

  /// Chinese scripts count as one language: a Simplified Chinese reader needs no layer over
  /// Traditional Chinese, and the reverse.
  private static func family(_ language: NLLanguage) -> String {
    switch language {
    case .simplifiedChinese, .traditionalChinese: "zh"
    default: language.rawValue
    }
  }

  private static let candidates: [NLLanguage] = [
    .simplifiedChinese, .traditionalChinese, .english, .japanese, .korean, .french, .german,
    .spanish, .portuguese, .italian, .russian, .arabic, .hindi, .thai, .vietnamese, .indonesian,
    .malay, .turkish, .dutch, .swedish, .polish, .ukrainian, .czech, .greek, .hebrew, .danish,
    .finnish, .norwegian, .hungarian, .romanian,
  ]

  /// The language a name such as 简体中文, 繁體中文（台灣）, English, 英式英语 or 日本語 means.
  static func language(named text: String) -> NLLanguage? {
    let name = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !name.isEmpty else { return nil }
    if name.contains("中文") || name.contains("汉语") || name.contains("漢語") || name.contains("华语")
      || name.contains("chinese") || name.contains("粤语") || name.contains("粵語")
      || name.contains("文言")
    {
      return name.contains("繁") || name.contains("traditional") ? .traditionalChinese : .simplifiedChinese
    }
    let displayLocales = [Locale(identifier: "zh-Hans"), Locale(identifier: "en")]
    for language in candidates {
      let code = language.rawValue
      var names = displayLocales.compactMap { $0.localizedString(forLanguageCode: code) }
      if let own = Locale(identifier: code).localizedString(forLanguageCode: code) { names.append(own) }
      if names.contains(where: { !$0.isEmpty && name.contains($0.lowercased()) }) { return language }
    }
    return nil
  }
}

enum LayerTranslationError: LocalizedError, Equatable {
  case mismatchedReply
  case notConfigured

  var errorDescription: String? {
    switch self {
    case .mismatchedReply: "译文与原文对不上"
    case .notConfigured: "还没有模型服务"
    }
  }
}

/// One request for a batch of paragraphs: numbered JSON in, numbered JSON out. Carried over
/// from the in-place screenshot translation this layer replaces.
enum LayerTranslationRequest {
  struct Item: Codable, Equatable, Sendable {
    let id: Int
    let text: String
  }

  /// Enough for a screen of chat or an article's visible part, small enough to come back fast.
  static let maximumItems = 40
  static let maximumCharacters = 12_000

  static func request(texts: [String], settings: CidaSettings) throws -> ProcessingRequest {
    let items = texts.enumerated().map { Item(id: $0.offset, text: $0.element) }
    let data = try JSONEncoder().encode(items)
    let languages = settings.requestLanguages
    return ProcessingRequest(
      text: String(decoding: data, as: UTF8.self), mode: .translate,
      myLanguage: languages.my, foreignLanguage: languages.foreign, translatesLayerBlocks: true)
  }

  /// The reply as translations in request order. Models sometimes wrap JSON in a Markdown
  /// fence despite the contract; the fence is dropped rather than failing the batch.
  static func decode(_ reply: String, count: Int) throws -> [String] {
    var body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix("```") {
      body = body.drop(while: { $0 != "\n" }).dropFirst().description
      if let fence = body.range(of: "```", options: .backwards) { body = String(body[..<fence.lowerBound]) }
    }
    guard let start = body.firstIndex(of: "["), let end = body.lastIndex(of: "]"),
      let data = String(body[start...end]).data(using: .utf8),
      let items = try? JSONDecoder().decode([Item].self, from: data)
    else {
      throw LayerTranslationError.mismatchedReply
    }
    var byID: [Int: String] = [:]
    for item in items where (0..<count).contains(item.id) {
      byID[item.id] = item.text
    }
    guard byID.count == count,
      byID.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else {
      throw LayerTranslationError.mismatchedReply
    }
    return (0..<count).map { byID[$0]! }
  }

  /// Splits paragraphs into requests within the item and character limits.
  static func batches(of texts: [String]) -> [[String]] {
    var batches: [[String]] = []
    var current: [String] = []
    var characters = 0
    for text in texts {
      if !current.isEmpty,
        current.count >= maximumItems || characters + text.count > maximumCharacters
      {
        batches.append(current)
        current = []
        characters = 0
      }
      current.append(text)
      characters += text.count
    }
    if !current.isEmpty { batches.append(current) }
    return batches
  }

  static func translate(
    _ texts: [String], settings: CidaSettings, service: any TextProcessingService
  ) async throws -> [String] {
    guard service.isConfigured(by: settings) else { throw LayerTranslationError.notConfigured }
    let request = try request(texts: texts, settings: settings)
    var reply = ""
    for try await chunk in service.stream(request, settings: settings) {
      try Task.checkCancellation()
      reply += chunk
    }
    try Task.checkCancellation()
    return try decode(reply, count: texts.count)
  }
}

/// The settings besides the paragraph itself that decide its translation: the model service
/// (endpoint, request shape and key), the translation prompt and my language. The rest of the
/// system message is fixed for the life of the process, and so is this in-memory cache.
struct LayerTranslationContext: Hashable, Sendable {
  let modelService: String
  let prompt: String
  let myLanguage: String

  init(settings: CidaSettings) {
    modelService = settings.modelServiceFingerprint
    prompt = settings.translationPrompt
    myLanguage = settings.requestLanguages.my
  }
}

/// Translations by masked source text and the settings that produced them, shared by every
/// pane: a paragraph scrolled away and back, or shown in two windows, is requested once; after
/// a settings change it is requested again, and changing the settings back finds the earlier
/// translation.
///
/// Past `byteLimit` bytes of memory, the paragraphs looked up longest ago go first. Every
/// paragraph on screen is looked up on each read, so recency here means how recently the user
/// saw it.
@MainActor
final class LayerTranslationCache {
  private struct Key: Hashable {
    let source: String
    let context: LayerTranslationContext
  }

  /// A link in the list from most to least recently used. The dictionary owns every entry, so
  /// the links are weak.
  private final class Entry {
    let key: Key
    var translation: String
    var bytes: Int
    weak var newer: Entry?
    weak var older: Entry?

    init(key: Key, translation: String, bytes: Int) {
      self.key = key
      self.translation = translation
      self.bytes = bytes
    }
  }

  private var entries: [Key: Entry] = [:]
  private weak var newest: Entry?
  private weak var oldest: Entry?
  /// The memory the kept pairs take, estimated as their UTF-8 text (a native String's storage)
  /// plus `entryOverhead` each.
  private(set) var bytes = 0
  let byteLimit: Int

  /// What one kept pair costs beyond its text: the dictionary slot, the entry, the string
  /// headers and allocation rounding. Measured at 340 to 460 bytes on arm64, for chat lines and
  /// article paragraphs alike; without it, a cache of chat lines would take four times its limit.
  static let entryOverhead = 400

  init(byteLimit: Int = 10 * 1024 * 1024) {
    self.byteLimit = byteLimit
  }

  /// The translation, if kept, now counted as the most recently used.
  func translation(for source: String, in context: LayerTranslationContext) -> String? {
    guard let entry = entries[Key(source: source, context: context)] else { return nil }
    moveToNewest(entry)
    return entry.translation
  }

  /// A pair larger than the whole limit is not kept, rather than emptying the cache for it.
  func store(_ translation: String, for source: String, in context: LayerTranslationContext) {
    let key = Key(source: source, context: context)
    let size = source.utf8.count + translation.utf8.count + Self.entryOverhead
    if let entry = entries[key] {
      bytes += size - entry.bytes
      entry.translation = translation
      entry.bytes = size
      moveToNewest(entry)
    } else if size <= byteLimit {
      let entry = Entry(key: key, translation: translation, bytes: size)
      entries[key] = entry
      bytes += size
      moveToNewest(entry)
    }
    while bytes > byteLimit, let evicted = oldest {
      unlink(evicted)
      entries[evicted.key] = nil
      bytes -= evicted.bytes
    }
  }

  private func moveToNewest(_ entry: Entry) {
    guard newest !== entry else { return }
    unlink(entry)
    entry.older = newest
    newest?.newer = entry
    newest = entry
    if oldest == nil { oldest = entry }
  }

  private func unlink(_ entry: Entry) {
    entry.newer?.older = entry.older
    entry.older?.newer = entry.newer
    if newest === entry { newest = entry.older }
    if oldest === entry { oldest = entry.newer }
    entry.newer = nil
    entry.older = nil
  }
}
