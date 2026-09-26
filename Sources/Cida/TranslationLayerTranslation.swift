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

/// Translations by masked source text, shared by every pane: a paragraph scrolled away and
/// back, or shown in two windows, is requested once.
@MainActor
final class LayerTranslationCache {
  private var translations: [String: String] = [:]
  private var order: [String] = []
  private let capacity: Int

  init(capacity: Int = 4_000) {
    self.capacity = capacity
  }

  subscript(source: String) -> String? {
    translations[source]
  }

  func store(_ translation: String, for source: String) {
    if translations[source] == nil { order.append(source) }
    translations[source] = translation
    if order.count > capacity {
      let evicted = order.removeFirst()
      translations[evicted] = nil
    }
  }

  func removeAll() {
    translations = [:]
    order = []
  }
}
