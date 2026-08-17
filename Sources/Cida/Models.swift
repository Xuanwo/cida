import Foundation
import Observation

extension Notification.Name {
  static let cidaHistoryResultStorageDidAppend = Notification.Name(
    "com.xuanwo.Cida.history-result-storage-did-append"
  )
}

enum HistoryResultStorageNotificationKey {
  static let presentationRevision = "presentationRevision"
}

enum ProcessingMode: String, CaseIterable, Codable, Sendable {
  case translate
  case improve

  var title: String {
    switch self {
    case .translate: "翻译"
    case .improve: "改进"
    }
  }
}

enum Language: String, CaseIterable, Codable, Sendable {
  case chinese
  case english

  var title: String {
    switch self {
    case .chinese: "中文"
    case .english: "English"
    }
  }
}

enum ModelProvider: String, CaseIterable, Codable, Sendable {
  case deepSeek = "DeepSeek"
  case openAI = "OpenAI"

  var models: [String] {
    switch self {
    case .deepSeek: ["deepseek-chat", "deepseek-reasoner"]
    case .openAI: ["gpt-5", "gpt-5-mini"]
    }
  }
}

struct ProcessingRequest: Equatable, Sendable {
  let text: String
  let mode: ProcessingMode
  let sourceLanguage: Language
  let targetLanguage: Language
}

final class HistoryResultStorage: @unchecked Sendable {
  private let value: NSMutableString
  private var foldedPreviewValue: String
  private var foldedPreviewNeedsFadeValue: Bool
  private var foldedPreviewCharacterCount: Int
  private var foldedPreviewNewlineCount: Int
  #if DEBUG
    private(set) var fullStringReadCount = 0
    private(set) var foldedPreviewReadCount = 0
  #endif

  init(_ value: String) {
    self.value = NSMutableString(string: value)
    let foldedPresentation = Self.makeFoldedPresentation(value)
    foldedPreviewValue = foldedPresentation.preview
    foldedPreviewNeedsFadeValue = foldedPresentation.needsFade
    foldedPreviewCharacterCount = foldedPresentation.characterCount
    foldedPreviewNewlineCount = foldedPresentation.newlineCount
  }

  var string: String {
    #if DEBUG
      fullStringReadCount += 1
    #endif
    return value as String
  }

  #if DEBUG
    func resetRenderingReadCounts() {
      fullStringReadCount = 0
      foldedPreviewReadCount = 0
    }
  #endif

  var utf16Length: Int {
    value.length
  }

  var foldedPreview: String {
    #if DEBUG
      foldedPreviewReadCount += 1
    #endif
    return foldedPreviewValue
  }

  var foldedPreviewNeedsFade: Bool {
    foldedPreviewNeedsFadeValue
  }

  func append(_ suffix: String) {
    value.append(suffix)
    appendToFoldedPresentation(suffix)
  }

  func replace(with string: String) {
    value.setString(string)
    let foldedPresentation = Self.makeFoldedPresentation(string)
    foldedPreviewValue = foldedPresentation.preview
    foldedPreviewNeedsFadeValue = foldedPresentation.needsFade
    foldedPreviewCharacterCount = foldedPresentation.characterCount
    foldedPreviewNewlineCount = foldedPresentation.newlineCount
  }

  func suffix(fromUTF16Offset offset: Int) -> String? {
    guard (0...value.length).contains(offset) else { return nil }
    return value.substring(from: offset)
  }

  private func appendToFoldedPresentation(_ suffix: String) {
    guard foldedPreviewCharacterCount < 420 else { return }

    for character in suffix {
      guard foldedPreviewCharacterCount < 420 else { break }
      foldedPreviewValue.append(character)
      foldedPreviewCharacterCount += 1
      if character == "\n" {
        foldedPreviewNewlineCount = min(2, foldedPreviewNewlineCount + 1)
      }
      if foldedPreviewCharacterCount > 120 || foldedPreviewNewlineCount >= 2 {
        foldedPreviewNeedsFadeValue = true
      }
    }
  }

  private static func makeFoldedPresentation(
    _ string: String
  ) -> (preview: String, needsFade: Bool, characterCount: Int, newlineCount: Int) {
    var preview = ""
    var characterCount = 0
    var newlineCount = 0
    for character in string {
      guard characterCount < 420 else { break }
      preview.append(character)
      characterCount += 1
      if character == "\n" {
        newlineCount = min(2, newlineCount + 1)
      }
    }
    return (
      preview,
      characterCount > 120 || newlineCount >= 2,
      characterCount,
      newlineCount
    )
  }
}

@Observable
final class HistoryEntry: Identifiable, Equatable, @unchecked Sendable {
  let id: UUID
  let mode: ProcessingMode
  let source: String
  let resultStorage: HistoryResultStorage
  let detail: String
  let timestamp: String
  let reportedSourceCharacterCount: Int?
  let reportedResultCharacterCount: Int?
  private let measuredSourceCharacterCount: Int
  var state: HistoryEntryState
  var isLatestInHistory = false
  @ObservationIgnored var presentationRevision: Int
  @ObservationIgnored var latestPresentationDelta: String?

  init(
    id: UUID = UUID(),
    mode: ProcessingMode,
    source: String,
    result: String,
    detail: String,
    timestamp: String,
    reportedSourceCharacterCount: Int? = nil,
    reportedResultCharacterCount: Int? = nil,
    state: HistoryEntryState = .completed,
    presentationRevision: Int = 0,
    latestPresentationDelta: String? = nil
  ) {
    self.id = id
    self.mode = mode
    self.source = source
    resultStorage = HistoryResultStorage(result)
    self.detail = detail
    self.timestamp = timestamp
    self.reportedSourceCharacterCount = reportedSourceCharacterCount
    self.reportedResultCharacterCount = reportedResultCharacterCount
    measuredSourceCharacterCount = reportedSourceCharacterCount ?? source.count
    self.state = state
    self.presentationRevision = presentationRevision
    self.latestPresentationDelta = latestPresentationDelta
  }

  var result: String {
    get { resultStorage.string }
    set { resultStorage.replace(with: newValue) }
  }

  var resultUTF16Length: Int {
    resultStorage.utf16Length
  }

  @MainActor
  func appendPresentationDelta(_ delta: String) {
    guard !delta.isEmpty else { return }
    resultStorage.append(delta)
    presentationRevision &+= 1
    latestPresentationDelta = delta
    NotificationCenter.default.post(
      name: .cidaHistoryResultStorageDidAppend,
      object: resultStorage,
      userInfo: [
        HistoryResultStorageNotificationKey.presentationRevision: presentationRevision
      ]
    )
  }

  var metadata: String {
    let presentedDetail = mode == .improve ? "跟随原文" : detail
    return switch state {
    case .streaming:
      "\(presentedDetail) · 生成中"
    case .cancelled:
      "\(presentedDetail) · 已停止"
    case .failed:
      "\(presentedDetail) · 出错 · 重试"
    case .completed where isLongDocument:
      "\(presentedDetail) · \(timestamp) · \(sourceCharacterCount.formatted()) → \(resultCharacterCount.formatted()) 字"
    case .completed:
      "\(presentedDetail) · \(timestamp)"
    }
  }

  var isLongDocument: Bool {
    sourceCharacterCount >= 800 || resultCharacterCount >= 1_200
  }

  private var sourceCharacterCount: Int {
    measuredSourceCharacterCount
  }

  private var resultCharacterCount: Int {
    reportedResultCharacterCount ?? resultUTF16Length
  }

  static func == (lhs: HistoryEntry, rhs: HistoryEntry) -> Bool {
    if lhs === rhs { return true }
    guard lhs.id == rhs.id else { return false }
    let resultsMatch = lhs.resultStorage === rhs.resultStorage || lhs.result == rhs.result
    return lhs.mode == rhs.mode && lhs.source == rhs.source
      && resultsMatch && lhs.detail == rhs.detail
      && lhs.timestamp == rhs.timestamp && lhs.state == rhs.state
      && lhs.isLatestInHistory == rhs.isLatestInHistory
      && lhs.reportedSourceCharacterCount == rhs.reportedSourceCharacterCount
      && lhs.reportedResultCharacterCount == rhs.reportedResultCharacterCount
      && lhs.presentationRevision == rhs.presentationRevision
      && lhs.latestPresentationDelta == rhs.latestPresentationDelta
  }
}

enum HistoryEntryState: String, Codable, Equatable, Sendable {
  case streaming
  case completed
  case cancelled
  case failed
}

struct CidaSettings: Codable, Equatable, Sendable {
  static let officialOpenAIEndpoint = "https://api.openai.com/v1/chat/completions"
  static let defaultTranslationPrompt =
    "Translate the user-provided text into the target language specified by the application. Preserve meaning, tone, and terminology. Return only the translated text."
  static let defaultImprovementPrompt =
    "You are a writing assistant. Improve the user-provided text for clarity, grammar, and natural tone. Keep the original language and meaning. Prefer precise technical wording. Return only the improved text."

  private static let currentPromptContractVersion = 2

  var provider: ModelProvider = .deepSeek
  var apiKey = ""
  var model = "deepseek-chat"
  var openAIEndpoint = officialOpenAIEndpoint
  var translationPrompt = defaultTranslationPrompt
  var improvementPrompt = defaultImprovementPrompt
  var launchAtLogin = false
  private var promptContractVersion = currentPromptContractVersion

  var usesLocalOpenAIEndpoint: Bool {
    guard
      provider == .openAI,
      let url = URL(string: openAIEndpoint),
      let rawHost = url.host(percentEncoded: false)?.lowercased()
    else {
      return false
    }
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case apiKey
    case model
    case openAIEndpoint
    case translationPrompt
    case improvementPrompt
    case launchAtLogin
    case promptContractVersion
  }

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decodeIfPresent(ModelProvider.self, forKey: .provider) ?? .deepSeek
    apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    model = try container.decodeIfPresent(String.self, forKey: .model) ?? "deepseek-chat"
    openAIEndpoint =
      try container.decodeIfPresent(String.self, forKey: .openAIEndpoint)
      ?? Self.officialOpenAIEndpoint
    let decodedPromptContractVersion =
      try container.decodeIfPresent(Int.self, forKey: .promptContractVersion) ?? 1
    let decodedTranslationPrompt =
      try container.decodeIfPresent(String.self, forKey: .translationPrompt)
      ?? Self.defaultTranslationPrompt
    let decodedImprovementPrompt =
      try container.decodeIfPresent(String.self, forKey: .improvementPrompt)
      ?? Self.defaultImprovementPrompt
    if decodedPromptContractVersion < Self.currentPromptContractVersion {
      translationPrompt = Self.migratingLegacyPrompt(decodedTranslationPrompt)
      improvementPrompt = Self.migratingLegacyPrompt(decodedImprovementPrompt)
    } else {
      translationPrompt = decodedTranslationPrompt
      improvementPrompt = decodedImprovementPrompt
    }
    promptContractVersion = Self.currentPromptContractVersion
    launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
  }

  func prompt(for mode: ProcessingMode) -> String {
    mode == .translate ? translationPrompt : improvementPrompt
  }

  static func defaultPrompt(for mode: ProcessingMode) -> String {
    mode == .translate ? defaultTranslationPrompt : defaultImprovementPrompt
  }

  private static func migratingLegacyPrompt(_ prompt: String) -> String {
    prompt
      .replacingOccurrences(of: "{text}", with: "the user-provided text")
      .replacingOccurrences(
        of: "{target_lang}",
        with: "the target language specified in the trusted runtime parameters"
      )
  }

  #if DEBUG
    static var designPreview: CidaSettings {
      var settings = CidaSettings()
      settings.apiKey = "sk-preview-key-3f2a"
      return settings
    }
  #endif
}

#if DEBUG
  extension HistoryEntry {
    static let designSamples: [HistoryEntry] = [
      HistoryEntry(
        mode: .improve,
        source:
          "This feature are very useful for user, it can makes the process more faster and easy to use.",
        result:
          "This feature is very useful — it makes the whole process faster and easier to use.",
        detail: "English · 语气与语法",
        timestamp: "11:32"
      ),
      HistoryEntry(
        mode: .translate,
        source: "缓存失效是计算机科学中的两大难题之一。",
        result: "Cache invalidation is one of the two hard problems in computer science.",
        detail: "中文 → English",
        timestamp: "14:02"
      ),
      HistoryEntry(
        mode: .translate,
        source: "我们的系统采用了全新的存储引擎,在保证数据一致性的前提下,显著提升了读写性能。",
        result:
          "Our system adopts a brand-new storage engine that significantly improves read and write performance while preserving data consistency.",
        detail: "中文 → English",
        timestamp: "14:05"
      ),
    ]

    static let longDesignSamples: [HistoryEntry] = [
      HistoryEntry(
        mode: .translate,
        source:
          "分布式系统的设计从来都不是单纯的技术选型问题。当我们讨论一致性、可用性与分区容忍性之间的取舍时,实际上是在讨论业务对错误的容忍程度:一个支付系统和一个信息流推荐服务可能运行在完全相同的基础设施之上,但它们对「出错之后会发生什么」这个问题的回答截然不同。",
        result:
          "Designing distributed systems has never been a matter of simply picking technologies. When we discuss the trade-offs between consistency, availability, and partition tolerance, we are really discussing how much failure the business can tolerate. A payment system and a feed-recommendation service may run on exactly the same infrastructure, yet their answers to the question of what happens after something goes wrong are entirely different. For payments, an inconsistent state means real money lost and trust broken, so we accept higher latency and stricter coordination. For recommendations, a stale feed is a minor annoyance at worst, so we choose availability and let the data converge later. Once you frame the discussion this way, most architecture debates become much shorter.",
        detail: "中文 → English",
        timestamp: "15:12",
        reportedSourceCharacterCount: 1_846,
        reportedResultCharacterCount: 3_214
      )
    ]

    static let interactionTestStickyLongResult = HistoryEntry(
      id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
      mode: .translate,
      source:
        "分布式系统的设计从来都不是单纯的技术选型问题。当我们讨论一致性、可用性与分区容忍性之间的取舍时,实际上是在讨论业务对错误的容忍程度:一个支付系统和一个信息流推荐服务可能运行在完全相同的基础设施之上,但它们对「出错之后会发生什么」这个问题的回答截然不同。",
      result: String(
        repeating:
          "Designing distributed systems has never been a matter of simply picking technologies. When we discuss the trade-offs between consistency, availability, and partition tolerance, we are really discussing how much failure the business can tolerate. A payment system and a feed-recommendation service may run on exactly the same infrastructure, yet their answers to the question of what happens after something goes wrong are entirely different. For payments, an inconsistent state means real money lost and trust broken, so we accept higher latency and stricter coordination. For recommendations, a stale feed is a minor annoyance at worst, so we choose availability and let the data converge later. Once you frame the discussion this way, most architecture debates become much shorter. ",
        count: 4
      ),
      detail: "中文 → English",
      timestamp: "15:12",
      reportedSourceCharacterCount: 1_846,
      reportedResultCharacterCount: 3_214
    )

    static let interactionTestHistoryContinuitySamples: [HistoryEntry] = {
      let leadingMultilineResult = (0...10).map { index in
        "Earlier persisted result line \(index) keeps the production-shaped history geometry realistic."
      }.joined(separator: "\n")
      let longPersistedSource = (0...144).map { index in
        "Persisted source line \(index) contains enough text to reproduce a real multiline document."
      }.joined(separator: "\n")
      let longPersistedResult = (0...143).map { index in
        "Persisted result line \(index) keeps a large natural TextKit height in virtualized history."
      }.joined(separator: "\n")
      return [
        HistoryEntry(
          id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
          mode: .translate,
          source: String(repeating: "Earlier source paragraph.\n", count: 10),
          result: leadingMultilineResult,
          detail: "中文 → English",
          timestamp: "15:40"
        ),
        HistoryEntry(
          id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
          mode: .improve,
          source: "Persisted source 2",
          result: "Persisted result 2 remains short.",
          detail: "English",
          timestamp: "15:45"
        ),
        HistoryEntry(
          id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
          mode: .translate,
          source: "Persisted source 3",
          result: "Persisted result 3",
          detail: "中文 → English",
          timestamp: "15:48"
        ),
        HistoryEntry(
          id: UUID(uuidString: "30000000-0000-0000-0000-000000000004")!,
          mode: .translate,
          source: longPersistedSource,
          result: longPersistedResult,
          detail: "中文 → English",
          timestamp: "15:50"
        ),
        HistoryEntry(
          id: UUID(uuidString: "30000000-0000-0000-0000-000000000005")!,
          mode: .improve,
          source: "Persisted source 4",
          result: "Persisted result 4",
          detail: "English",
          timestamp: "15:55"
        ),
        HistoryEntry(
          id: UUID(uuidString: "30000000-0000-0000-0000-000000000006")!,
          mode: .translate,
          source: "Persisted source 5",
          result: "Persisted result 5",
          detail: "中文 → English",
          timestamp: "16:00"
        ),
        HistoryEntry(
          id: UUID(uuidString: "30000000-0000-0000-0000-000000000007")!,
          mode: .translate,
          source: "Persisted source 6",
          result: "Persisted result 6",
          detail: "中文 → English",
          timestamp: "16:05"
        ),
      ]
    }()

    static let designLongInput: String = {
      let visible =
        "在过去的十年里,我们团队的存储架构经历了三次大的演进。最初的单机数据库在业务量突破百万级之后开始频繁出现性能瓶颈,主从复制的延迟问题让读写分离的方案变得不再可靠。第二阶段我们引入了分库分表,虽然缓解了单点压力,但跨分片的事务和查询让业务代码变得越来越复杂,每一次扩容都需要停机迁移数据,运维成本居高不下。第三阶段,也就是现在,我们把核心链路迁移到了分布式数据库上,把冷数据下沉到对象存储,通过统一的数据访问层屏蔽底层差异。这个过程中最大的教训是:架构演进的节奏必须与业务发展的节奏匹配,过早引入复杂性和过晚偿还技术债,代价同样高昂。"
      return visible + String(repeating: " ", count: max(0, 2_148 - visible.count))
    }()
  }
#endif
