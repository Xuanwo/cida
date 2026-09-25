import CryptoKit
import Foundation

/// How a request and its streamed reply are shaped (`Design/spec/configuration.md` §三).
enum ModelRequestFormat: String, CaseIterable, Codable, Sendable {
  /// OpenAI Chat Completions and the many services compatible with it.
  case chatCompletions = "chat-completions"
  /// OpenAI Responses.
  case responses
  /// Anthropic Messages.
  case anthropicMessages = "anthropic-messages"

  /// The name Settings shows beside the host.
  var displayName: String {
    switch self {
    case .chatCompletions: "Chat Completions"
    case .responses: "Responses"
    case .anthropicMessages: "Anthropic Messages"
    }
  }

  var defaultAuthentication: ModelAuthentication {
    self == .anthropicMessages ? .xAPIKey : .bearer
  }
}

/// Which request header carries the API key.
enum ModelAuthentication: String, CaseIterable, Codable, Sendable {
  /// `Authorization: Bearer <key>`.
  case bearer
  /// `x-api-key: <key>`, as Anthropic expects.
  case xAPIKey = "x-api-key"
  /// `api-key: <key>`, as Azure OpenAI expects.
  case apiKey = "api-key"
  /// No key is sent.
  case none

  var headerName: String? {
    switch self {
    case .bearer: "Authorization"
    case .xAPIKey: "x-api-key"
    case .apiKey: "api-key"
    case .none: nil
    }
  }

  func headerValue(for apiKey: String) -> String {
    self == .bearer ? "Bearer \(apiKey)" : apiKey
  }
}

/// The model service every request goes to. The command line writes it and Settings only
/// shows it (`Design/spec/configuration.md`). The API key is not part of it: it lives in the
/// Keychain and travels beside it in `CidaSettings.apiKey`.
struct ModelConfiguration: Equatable, Sendable {
  /// The complete URL requests are posted to; empty until configured.
  var endpoint = ""
  var format = ModelRequestFormat.chatCompletions
  /// The model name; empty until configured.
  var model = ""
  /// The key's header; nil follows `format`.
  var auth: ModelAuthentication?
  /// Extra request headers, sent after Cida's own so they can replace them.
  var headers: [String: String] = [:]
  /// Extra body members, merged into the body Cida builds (`JSONValue.merging`).
  var body = JSONObject()

  var resolvedAuth: ModelAuthentication {
    auth ?? format.defaultAuthentication
  }

  /// The endpoint when it is an http(s) URL with a host.
  var endpointURL: URL? {
    Self.endpointURL(from: endpoint)
  }

  static func endpointURL(from text: String) -> URL? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let url = URL(string: value),
      let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      let host = url.host(percentEncoded: false), !host.isEmpty
    else {
      return nil
    }
    return url
  }

  var host: String? {
    endpointURL?.host(percentEncoded: false)
  }

  /// A server on this Mac, which may run without a key.
  var isLocalEndpoint: Bool {
    guard let host = host?.lowercased() else { return false }
    let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return bare == "localhost" || bare == "127.0.0.1" || bare == "::1"
  }

  var requiresAPIKey: Bool {
    resolvedAuth != .none && !isLocalEndpoint
  }

  var isUnset: Bool {
    self == ModelConfiguration()
  }

  /// The fields a request still needs, in the command line's names.
  func missingFields(hasAPIKey: Bool) -> [String] {
    var missing: [String] = []
    if endpointURL == nil { missing.append("endpoint") }
    if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("model") }
    if requiresAPIKey, !hasAPIKey { missing.append("api-key") }
    return missing
  }

  /// Whether requests can be sent: the predicate behind Settings' onboarding card and the
  /// panel's welcome.
  func isComplete(hasAPIKey: Bool) -> Bool {
    missingFields(hasAPIKey: hasAPIKey).isEmpty
  }

  /// `api.deepseek.com · Chat Completions`: where requests go and in which shape.
  var hostAndFormat: String {
    "\(host ?? "未设置端点") · \(format.displayName)"
  }

  /// `deepseek-chat · api.deepseek.com · Chat Completions`.
  var summary: String {
    let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(modelName.isEmpty ? "未设置模型" : modelName) · \(hostAndFormat)"
  }

  /// Identifies what a check tested: the service, the request shape and the key. A recorded
  /// check counts only while the fingerprint still matches (`Design/spec/configuration.md` §四).
  /// Only a digest leaves this function, so the key cannot be read back from it.
  func fingerprint(apiKey: String) -> String {
    var headerObject = JSONObject()
    for name in headers.keys.sorted() {
      headerObject[name] = .string(headers[name]!)
    }
    let canonical: JSONObject = [
      "endpoint": .string(endpoint),
      "format": .string(format.rawValue),
      "model": .string(model),
      "auth": .string(resolvedAuth.rawValue),
      "headers": .object(headerObject),
      "body": .object(body.sortedByKey),
    ]
    var hasher = SHA256()
    hasher.update(data: Data(JSONValue.object(canonical).compactText.utf8))
    hasher.update(data: Data([0]))
    hasher.update(data: Data(apiKey.utf8))
    return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Migration

  /// The configuration a 1.0 provider preset stood for. 1.0 stored `provider` (a preset name),
  /// `model`, and `openAIEndpoint` (the custom endpoint; before presets, "OpenAI" with a
  /// non-official endpoint meant any compatible server). Every preset was Chat Completions with
  /// a bearer key, which is what the defaults here send.
  static func migrating(
    legacyProvider provider: String?, model: String?, endpoint: String?
  ) -> ModelConfiguration {
    let presetEndpoints = [
      "DeepSeek": "https://api.deepseek.com/chat/completions",
      "OpenAI": "https://api.openai.com/v1/chat/completions",
      "Moonshot": "https://api.moonshot.cn/v1/chat/completions",
      "Zhipu": "https://open.bigmodel.cn/api/paas/v4/chat/completions",
    ]
    let provider = provider ?? "DeepSeek"
    let customEndpoint = endpoint ?? ""
    var configuration = ModelConfiguration()
    configuration.model = model ?? "deepseek-chat"
    if provider == "Custom"
      || (provider == "OpenAI" && !customEndpoint.isEmpty
        && customEndpoint != presetEndpoints["OpenAI"])
    {
      configuration.endpoint = customEndpoint
    } else {
      configuration.endpoint = presetEndpoints[provider] ?? presetEndpoints["DeepSeek"]!
    }
    return configuration
  }
}

extension ModelConfiguration: Codable {
  private enum CodingKeys: String, CodingKey {
    case endpoint, format, model, auth, headers, body
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
    format =
      try container.decodeIfPresent(ModelRequestFormat.self, forKey: .format) ?? .chatCompletions
    model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
    auth = try container.decodeIfPresent(ModelAuthentication.self, forKey: .auth)
    headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    body = try container.decodeIfPresent(JSONValue.self, forKey: .body)?.objectValue ?? JSONObject()
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(endpoint, forKey: .endpoint)
    try container.encode(format, forKey: .format)
    try container.encode(model, forKey: .model)
    try container.encodeIfPresent(auth, forKey: .auth)
    try container.encode(headers, forKey: .headers)
    try container.encode(JSONValue.object(body), forKey: .body)
  }
}
