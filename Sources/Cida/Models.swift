import Foundation
import Observation

extension Notification.Name {
  static let cidaResultStorageDidAppend = Notification.Name(
    "com.xuanwo.Cida.result-storage-did-append"
  )
}

enum ResultStorageNotificationKey {
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

/// A model service. Every preset is one OpenAI-compatible Chat Completions
/// endpoint with its suggested models; `custom` points Cida at any compatible
/// server, including a local one. Adding a provider is one more preset here
/// (`Design/spec/settings.md`).
enum ModelProvider: String, CaseIterable, Codable, Sendable {
  case deepSeek = "DeepSeek"
  case openAI = "OpenAI"
  case moonshot = "Moonshot"
  case zhipu = "Zhipu"
  case custom = "Custom"

  var displayName: String {
    switch self {
    case .deepSeek: "DeepSeek"
    case .openAI: "OpenAI"
    case .moonshot: "Moonshot"
    case .zhipu: "智谱 GLM"
    case .custom: "自定义（OpenAI 兼容）"
    }
  }

  /// The preset's Chat Completions endpoint; `nil` for `custom`, whose
  /// endpoint lives in `CidaSettings.customEndpoint`.
  var presetEndpoint: URL? {
    switch self {
    case .deepSeek: URL(string: "https://api.deepseek.com/chat/completions")
    case .openAI: URL(string: "https://api.openai.com/v1/chat/completions")
    case .moonshot: URL(string: "https://api.moonshot.cn/v1/chat/completions")
    case .zhipu: URL(string: "https://open.bigmodel.cn/api/paas/v4/chat/completions")
    case .custom: nil
    }
  }

  /// Shown under the provider menu so the user knows where requests go.
  var endpointCaption: String? {
    presetEndpoint?.host().map { "\($0) · Chat Completions" }
  }

  var suggestedModels: [String] {
    switch self {
    case .deepSeek: ["deepseek-chat", "deepseek-reasoner"]
    case .openAI: ["gpt-5", "gpt-5-mini"]
    case .moonshot: ["kimi-k3", "kimi-k2.6"]
    case .zhipu: ["glm-5.3", "glm-5.3-flash"]
    case .custom: []
    }
  }

  var isCustom: Bool {
    self == .custom
  }
}

/// What the model group can tell without a network request (the readiness
/// row of `Spec — 设置`).
enum SettingsReadiness: Equatable, Sendable {
  case ready
  case missingAPIKey
  case localEndpoint
  case invalidEndpoint
  case missingModel

  var text: String {
    switch self {
    case .ready: "已就绪"
    case .missingAPIKey: "还差 API Key"
    case .localEndpoint: "本地端点 · 无需 API Key"
    case .invalidEndpoint: "端点无效"
    case .missingModel: "还差模型"
    }
  }

  /// Whether requests can be sent as configured.
  var isReady: Bool {
    self == .ready || self == .localEndpoint
  }
}

struct ProcessingRequest: Equatable, Sendable {
  let text: String
  let mode: ProcessingMode
  let sourceLanguage: Language
  let targetLanguage: Language
}

/// The text of one result. The stream presenter appends to it on the main
/// actor and the result renderer observes the append notification, so TextKit
/// only lays out the missing suffix instead of the whole document.
final class ResultTextStorage: @unchecked Sendable {
  private let value: NSMutableString

  init(_ value: String) {
    self.value = NSMutableString(string: value)
  }

  var string: String {
    value as String
  }

  var utf16Length: Int {
    value.length
  }

  func append(_ suffix: String) {
    value.append(suffix)
  }

  func replace(with string: String) {
    value.setString(string)
  }

  func suffix(fromUTF16Offset offset: Int) -> String? {
    guard (0...value.length).contains(offset) else { return nil }
    return value.substring(from: offset)
  }
}

enum ResultPhase: Equatable, Sendable {
  /// The request is running; the renderer shows the caret and streamed text.
  case streaming
  case completed
  case stopped
  case failed(message: String)
  /// A capture held no text, so nothing was requested.
  case unrecognized

  var isTerminal: Bool {
    self != .streaming
  }
}

/// The single result the panel shows: the source it was made from, the action
/// that made it, and its streamed text. A new submission replaces the record.
@Observable
final class ResultRecord: Identifiable, @unchecked Sendable {
  let id: UUID
  let mode: ProcessingMode
  let source: String
  let sourceCharacterCount: Int
  /// The language the result is written in; it selects the CJK or Latin
  /// result typography.
  let outputLanguage: Language
  let storage: ResultTextStorage
  var phase: ResultPhase
  @ObservationIgnored var presentationRevision: Int
  @ObservationIgnored var latestPresentationDelta: String?

  init(
    id: UUID = UUID(),
    mode: ProcessingMode,
    source: String,
    sourceCharacterCount: Int? = nil,
    outputLanguage: Language,
    result: String = "",
    phase: ResultPhase = .streaming,
    presentationRevision: Int = 0
  ) {
    self.id = id
    self.mode = mode
    self.source = source
    self.sourceCharacterCount = sourceCharacterCount ?? source.count
    self.outputLanguage = outputLanguage
    storage = ResultTextStorage(result)
    self.phase = phase
    self.presentationRevision = presentationRevision
  }

  var result: String {
    storage.string
  }

  var resultUTF16Length: Int {
    storage.utf16Length
  }

  var resultCharacterCount: Int {
    storage.string.count
  }

  /// A result that can be copied: text exists and the stream is no longer
  /// writing into it.
  var isCopyable: Bool {
    phase.isTerminal && storage.utf16Length > 0
  }

  @MainActor
  func appendPresentationDelta(_ delta: String) {
    guard !delta.isEmpty else { return }
    storage.append(delta)
    presentationRevision &+= 1
    latestPresentationDelta = delta
    NotificationCenter.default.post(
      name: .cidaResultStorageDidAppend,
      object: storage,
      userInfo: [
        ResultStorageNotificationKey.presentationRevision: presentationRevision
      ]
    )
  }

  /// The note shown under the result for the terminal states that need one.
  var note: ResultNote? {
    switch phase {
    case .streaming, .completed:
      nil
    case .stopped:
      ResultNote(kind: .stopped, text: "已停止 · ⏎ 重新生成")
    case .failed(let message):
      ResultNote(kind: .failed, text: "请求失败：\(message) 按 ⏎ 重试")
    case .unrecognized:
      ResultNote(kind: .unrecognized, text: "截图里没有识别到文字")
    }
  }
}

struct ResultNote: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case stale
    case stopped
    case failed
    case unrecognized
  }

  let kind: Kind
  let text: String

  static let stale = ResultNote(kind: .stale, text: "原文已修改 · ⏎ 重新生成")
}

struct CidaSettings: Codable, Equatable, Sendable {
  static let officialOpenAIEndpoint = ModelProvider.openAI.presetEndpoint!.absoluteString
  static let defaultTranslationPrompt =
    "Translate the user-provided text into the target language specified by the application. Preserve meaning, tone, and terminology. Return only the translated text."
  static let defaultImprovementPrompt =
    "You are a writing assistant. Improve the user-provided text for clarity, grammar, and natural tone. Keep the original language and meaning. Prefer precise technical wording. Return only the improved text."

  private static let currentPromptContractVersion = 2

  var provider: ModelProvider = .deepSeek
  var apiKey = ""
  var model = "deepseek-chat"
  /// The Chat Completions URL used when `provider` is `.custom`.
  var customEndpoint = ""
  var translationPrompt = defaultTranslationPrompt
  var improvementPrompt = defaultImprovementPrompt
  var launchAtLogin = false
  /// The combination that shows the panel from any application.
  var shortcut = GlobalShortcut.optionSpace
  /// The combination that captures text on screen and translates it.
  var captureShortcut = GlobalShortcut.optionS
  private var promptContractVersion = currentPromptContractVersion

  /// The endpoint requests go to: the preset's, or a valid http(s) custom URL.
  var resolvedEndpoint: URL? {
    if let preset = provider.presetEndpoint { return preset }
    let value = customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let candidate = URL(string: value),
      let scheme = candidate.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      candidate.host != nil
    else {
      return nil
    }
    return candidate
  }

  /// A custom endpoint on this machine, which may omit the API key.
  var usesLocalEndpoint: Bool {
    guard
      provider.isCustom,
      let url = resolvedEndpoint,
      let rawHost = url.host(percentEncoded: false)?.lowercased()
    else {
      return false
    }
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
  }

  var readiness: SettingsReadiness {
    if resolvedEndpoint == nil { return .invalidEndpoint }
    if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .missingModel }
    if usesLocalEndpoint { return .localEndpoint }
    if apiKey.isEmpty { return .missingAPIKey }
    return .ready
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case apiKey
    case model
    /// Historic key: it held the OpenAI endpoint before providers became presets.
    case customEndpoint = "openAIEndpoint"
    case translationPrompt
    case improvementPrompt
    case launchAtLogin
    case shortcut
    case captureShortcut
    case promptContractVersion
  }

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedProvider =
      try container.decodeIfPresent(ModelProvider.self, forKey: .provider) ?? .deepSeek
    apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    model = try container.decodeIfPresent(String.self, forKey: .model) ?? "deepseek-chat"
    let decodedEndpoint =
      try container.decodeIfPresent(String.self, forKey: .customEndpoint) ?? ""
    // Before presets, "OpenAI" with a non-official endpoint was the way to
    // reach any compatible server; that configuration is now `custom`.
    if decodedProvider == .openAI, !decodedEndpoint.isEmpty,
      decodedEndpoint != Self.officialOpenAIEndpoint
    {
      provider = .custom
      customEndpoint = decodedEndpoint
    } else {
      provider = decodedProvider
      customEndpoint = decodedProvider.isCustom ? decodedEndpoint : ""
    }
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
    shortcut =
      try container.decodeIfPresent(GlobalShortcut.self, forKey: .shortcut) ?? .optionSpace
    captureShortcut =
      try container.decodeIfPresent(GlobalShortcut.self, forKey: .captureShortcut) ?? .optionS
  }

  func shortcut(for action: GlobalShortcutAction) -> GlobalShortcut {
    switch action {
    case .showPanel: shortcut
    case .captureText: captureShortcut
    }
  }

  mutating func setShortcut(_ newShortcut: GlobalShortcut, for action: GlobalShortcutAction) {
    switch action {
    case .showPanel: shortcut = newShortcut
    case .captureText: captureShortcut = newShortcut
    }
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
  extension ResultRecord {
    static let designTranslateSource =
      "我们的系统采用了全新的存储引擎,在保证数据一致性的前提下,显著提升了读写性能。"
    static let designTranslateResult =
      "Our system adopts a brand-new storage engine that significantly improves read and write performance while preserving data consistency."
    static let designImproveSource =
      "这个功能通过复用已有的缓存结果,使得整体的处理流程在大多数的情况下都能够得到比较明显的加速。"
    static let designImproveResult =
      "通过复用已有缓存结果，该功能可在大多数情况下显著加速整体处理流程。"

    static func designCompleted(mode: ProcessingMode) -> ResultRecord {
      switch mode {
      case .translate:
        ResultRecord(
          mode: .translate,
          source: designTranslateSource,
          outputLanguage: .english,
          result: designTranslateResult,
          phase: .completed
        )
      case .improve:
        ResultRecord(
          mode: .improve,
          source: designImproveSource,
          outputLanguage: .chinese,
          result: designImproveResult,
          phase: .completed
        )
      }
    }

    static let designLongInput: String = {
      let visible =
        "在过去的十年里,我们团队的存储架构经历了三次大的演进。最初的单机数据库在业务量突破百万级之后开始频繁出现性能瓶颈,主从复制的延迟问题让读写分离的方案变得不再可靠。第二阶段我们引入了分库分表,虽然缓解了单点压力,但跨分片的事务和查询让业务代码变得越来越复杂,每一次扩容都需要停机迁移数据,运维成本居高不下。第三阶段,也就是现在,我们把核心链路迁移到了分布式数据库上,把冷数据下沉到对象存储,通过统一的数据访问层屏蔽底层差异。这个过程中最大的教训是:架构演进的节奏必须与业务发展的节奏匹配,过早引入复杂性和过晚偿还技术债,代价同样高昂。"
      return visible + String(repeating: " ", count: max(0, 2_148 - visible.count))
    }()

    static let designLongResult =
      "Over the past decade, our team's storage architecture has gone through three major evolutions. The initial single-node database began to hit performance bottlenecks frequently once traffic passed the million mark, and replication lag made read/write splitting unreliable. In the second phase we introduced sharding, which relieved the single point of pressure but made cross-shard transactions and queries increasingly complex; every scale-out required downtime to migrate data, and operating costs stayed high. In the third phase, which is where we are now, we moved the core path onto a distributed database, sank cold data into object storage, and hid the underlying differences behind a unified data-access layer. The biggest lesson from this process is that the pace of architectural evolution must match the pace of the business: introducing complexity too early and repaying technical debt too late are equally expensive."

    static func designLong() -> ResultRecord {
      ResultRecord(
        mode: .translate,
        source: designLongInput,
        sourceCharacterCount: 1_846,
        outputLanguage: .english,
        result: String(repeating: designLongResult + "\n\n", count: 3),
        phase: .completed
      )
    }
  }
#endif
