import Foundation

protocol TextProcessingService: Sendable {
  func stream(
    _ request: ProcessingRequest,
    settings: CidaSettings
  ) -> AsyncThrowingStream<String, Error>

  /// Whether `settings` hold everything this service needs to send a request. Until they do,
  /// the panel welcomes the user instead of sending (`Design/spec/lifecycle.md` §三).
  func isConfigured(by settings: CidaSettings) -> Bool
}

extension TextProcessingService {
  /// A service that talks to no model service needs no configuration.
  func isConfigured(by settings: CidaSettings) -> Bool { true }
}

/// Sends requests to the configured model service in any of its three formats and yields the
/// reply's text as it streams (`Design/spec/configuration.md` §三). The panel and the check
/// share it, so a passing check means the panel's requests work too.
struct ModelServiceClient: TextProcessingService {
  var session: URLSession = .shared

  func isConfigured(by settings: CidaSettings) -> Bool {
    settings.isModelServiceComplete
  }

  func stream(
    _ request: ProcessingRequest,
    settings: CidaSettings
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .utility) {
        do {
          let prepared = try Self.prepare(request, settings: settings)
          try await send(
            prepared,
            format: settings.modelService.format,
            redactor: SecretRedactor(secret: settings.apiKey)
          ) { continuation.yield($0) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// The request `settings` would send for `request`; throws when the configuration is not
  /// complete.
  static func prepare(
    _ request: ProcessingRequest,
    settings: CidaSettings,
    timeout: TimeInterval = 300
  ) throws -> PreparedModelRequest {
    let missing = settings.modelService.missingFields(hasAPIKey: !settings.apiKey.isEmpty)
    guard missing.isEmpty else {
      throw ModelServiceError.incompleteConfiguration(missing: missing)
    }
    let prompt = try ModelPromptBuilder.build(request: request, settings: settings)
    return try ModelRequestBuilder.build(
      prompt: prompt,
      configuration: settings.modelService,
      apiKey: settings.apiKey,
      timeout: timeout
    )
  }

  /// Posts `prepared` and hands every piece of reply text to `onText`, whether the service
  /// streams server-sent events or answers with one JSON document. `transcript` keeps the
  /// status and the raw reply, with the key redacted, for `check --verbose`.
  func send(
    _ prepared: PreparedModelRequest,
    format: ModelRequestFormat,
    redactor: SecretRedactor,
    transcript: ModelResponseTranscript? = nil,
    onText: (String) -> Void
  ) async throws {
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (bytes, response) = try await session.bytes(for: prepared.urlRequest)
    } catch let error as URLError {
      if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
      throw ModelServiceError.transport(error)
    }
    guard let response = response as? HTTPURLResponse else {
      throw ModelServiceError.unexpectedResponse("服务商返回的不是 HTTP 响应。")
    }
    transcript?.record(statusCode: response.statusCode)

    guard (200..<300).contains(response.statusCode) else {
      let text = redactor.redact(try await bytes.collectText())
      transcript?.append(text)
      throw ModelServiceError.http(
        status: response.statusCode,
        providerMessage: JSONValue.parse(text).flatMap(Self.providerMessage(in:)),
        body: text
      )
    }

    let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
    if contentType.contains("text/event-stream") {
      try await receiveEvents(
        bytes, format: format, redactor: redactor, transcript: transcript, onText: onText)
    } else {
      let text = try await bytes.collectText()
      transcript?.append(redactor.redact(text))
      guard let document = JSONValue.parse(text) else {
        throw ModelServiceError.unexpectedResponse("服务商返回的不是 JSON，也不是事件流。")
      }
      if let message = Self.providerMessage(in: document), document["error"] != nil {
        throw ModelServiceError.provider(message: redactor.redact(message))
      }
      guard let reply = format.completeReply(in: document) else {
        throw ModelServiceError.unexpectedResponse(
          "返回的 JSON 里没有 \(format.rawValue) 格式的回复。")
      }
      guard !reply.isEmpty else { throw ModelServiceError.emptyResult }
      onText(reply)
    }
  }

  private func receiveEvents(
    _ bytes: URLSession.AsyncBytes,
    format: ModelRequestFormat,
    redactor: SecretRedactor,
    transcript: ModelResponseTranscript?,
    onText: (String) -> Void
  ) async throws {
    var parser = ServerSentEventParser()
    var recognizedAnyEvent = false
    var line: [UInt8] = []

    // Returns false once the reply is complete.
    func handle(_ event: ServerSentEvent) throws -> Bool {
      switch format.streamEvent(from: event) {
      case .text(let text):
        recognizedAnyEvent = true
        onText(text)
      case .recognized:
        recognizedAnyEvent = true
      case .done:
        return false
      case .failure(let message):
        throw ModelServiceError.provider(message: redactor.redact(message))
      case .unrecognized:
        break
      }
      return true
    }

    func handleLine(_ bytes: [UInt8]) throws -> Bool {
      var text = String(decoding: bytes, as: UTF8.self)
      if text.hasSuffix("\r") { text.removeLast() }
      transcript?.append(redactor.redact(text) + "\n")
      guard let event = parser.consume(line: text) else { return true }
      return try handle(event)
    }

    for try await byte in bytes {
      guard byte == 0x0A else {
        line.append(byte)
        continue
      }
      try Task.checkCancellation()
      let continues = try handleLine(line)
      line.removeAll(keepingCapacity: true)
      if !continues { return }
    }
    if !line.isEmpty, try !handleLine(line) { return }
    if let event = parser.finish(), try !handle(event) { return }
    if !recognizedAnyEvent {
      throw ModelServiceError.unexpectedResponse(
        "事件流里没有 \(format.rawValue) 格式的事件。")
    }
  }

  /// The message a provider put in an error document: OpenAI and Anthropic nest it under
  /// `error.message`; others use `error`, `message` or `detail`.
  static func providerMessage(in document: JSONValue) -> String? {
    document["error"]?["message"]?.stringValue
      ?? document["error"]?.stringValue
      ?? document["message"]?.stringValue
      ?? document["detail"]?.stringValue
  }
}

// MARK: - Request

/// A request ready to send, and the parts of it `check --verbose` shows.
struct PreparedModelRequest: Sendable {
  struct Header: Equatable, Sendable {
    let name: String
    let value: String
  }

  let urlRequest: URLRequest
  let body: JSONValue
  /// The headers that say something about the configuration, with the key replaced by ••••:
  /// the key's header, the Anthropic version, and the configured extra headers. The constant
  /// `Content-Type` and `Accept` appear only when the configuration replaced them.
  let displayHeaders: [Header]

  var url: URL { urlRequest.url! }
  var method: String { urlRequest.httpMethod ?? "POST" }
}

enum ModelRequestBuilder {
  static let anthropicVersion = "2023-06-01"
  /// Anthropic Messages requires `max_tokens`; `body` can change it.
  static let anthropicMaxTokens: Int64 = 8192

  static func build(
    prompt: ModelPrompt,
    configuration: ModelConfiguration,
    apiKey: String,
    timeout: TimeInterval = 300
  ) throws -> PreparedModelRequest {
    guard let endpoint = configuration.endpointURL else {
      throw ModelServiceError.incompleteConfiguration(missing: ["endpoint"])
    }
    let body = JSONValue.object(baseBody(prompt: prompt, configuration: configuration))
      .merging(.object(configuration.body))

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

    let redactor = SecretRedactor(secret: apiKey)
    var displayHeaders: [PreparedModelRequest.Header] = []
    func set(_ value: String, for name: String) {
      request.setValue(value, forHTTPHeaderField: name)
      let header = PreparedModelRequest.Header(name: name, value: redactor.redact(value))
      if let index = displayHeaders.firstIndex(where: {
        $0.name.caseInsensitiveCompare(name) == .orderedSame
      }) {
        displayHeaders[index] = header
      } else {
        displayHeaders.append(header)
      }
    }
    if !apiKey.isEmpty, let name = configuration.resolvedAuth.headerName {
      set(configuration.resolvedAuth.headerValue(for: apiKey), for: name)
    }
    if configuration.format == .anthropicMessages {
      set(anthropicVersion, for: "anthropic-version")
    }
    for name in configuration.headers.keys.sorted() {
      set(configuration.headers[name]!, for: name)
    }
    request.httpBody = Data(body.compactText.utf8)
    return PreparedModelRequest(urlRequest: request, body: body, displayHeaders: displayHeaders)
  }

  /// The body each format expects, in the order its documentation writes it.
  static func baseBody(prompt: ModelPrompt, configuration: ModelConfiguration) -> JSONObject {
    let model = JSONValue.string(configuration.model)
    let userMessage: JSONValue = .object([
      "role": .string("user"), "content": .string(prompt.userMessage),
    ])
    switch configuration.format {
    case .chatCompletions:
      return [
        "model": model,
        "stream": .bool(true),
        "messages": .array([
          .object(["role": .string("system"), "content": .string(prompt.systemMessage)]),
          userMessage,
        ]),
      ]
    case .responses:
      // Cida keeps no record of requests, so the service is asked not to either.
      return [
        "model": model,
        "stream": .bool(true),
        "store": .bool(false),
        "instructions": .string(prompt.systemMessage),
        "input": .array([userMessage]),
      ]
    case .anthropicMessages:
      return [
        "model": model,
        "max_tokens": .integer(anthropicMaxTokens),
        "stream": .bool(true),
        "system": .string(prompt.systemMessage),
        "messages": .array([userMessage]),
      ]
    }
  }
}

// MARK: - Response

/// One server-sent event: its `event:` name, if any, and its `data:` lines joined by newlines.
struct ServerSentEvent: Equatable, Sendable {
  var name: String?
  var data: String
}

/// Assembles events from lines (https://html.spec.whatwg.org/multipage/server-sent-events.html):
/// an empty line ends an event, `:` starts a comment, and several `data:` lines join.
struct ServerSentEventParser {
  private var name: String?
  private var dataLines: [String] = []

  mutating func consume(line: String) -> ServerSentEvent? {
    if line.isEmpty { return dispatch() }
    if line.hasPrefix(":") { return nil }
    let field: Substring
    var value: Substring
    if let colon = line.firstIndex(of: ":") {
      field = line[..<colon]
      value = line[line.index(after: colon)...]
      if value.hasPrefix(" ") { value = value.dropFirst() }
    } else {
      field = Substring(line)
      value = ""
    }
    switch field {
    case "data": dataLines.append(String(value))
    case "event": name = String(value)
    default: break
    }
    return nil
  }

  /// The event still open when the stream ends.
  mutating func finish() -> ServerSentEvent? {
    dispatch()
  }

  private mutating func dispatch() -> ServerSentEvent? {
    defer {
      name = nil
      dataLines = []
    }
    guard !dataLines.isEmpty else { return nil }
    return ServerSentEvent(name: name, data: dataLines.joined(separator: "\n"))
  }
}

/// What one streamed event means for the reply.
enum ModelStreamEvent: Equatable {
  case text(String)
  /// An event of this format that carries no text (a start, a stop reason, a ping).
  case recognized
  case done
  case failure(String)
  /// Not an event of this format: a sign the configured `format` is wrong.
  case unrecognized
}

extension ModelRequestFormat {
  func streamEvent(from event: ServerSentEvent) -> ModelStreamEvent {
    if self == .chatCompletions, event.data == "[DONE]" { return .done }
    guard let payload = JSONValue.parse(event.data) else { return .unrecognized }
    switch self {
    case .chatCompletions:
      if payload["error"] != nil {
        return .failure(ModelServiceClient.providerMessage(in: payload) ?? event.data)
      }
      guard let choices = payload["choices"]?.arrayValue else { return .unrecognized }
      if let text = choices.first?["delta"]?["content"]?.stringValue, !text.isEmpty {
        return .text(text)
      }
      return .recognized
    case .responses:
      let type = payload["type"]?.stringValue ?? event.name ?? ""
      switch type {
      case "response.output_text.delta":
        let text = payload["delta"]?.stringValue ?? ""
        return text.isEmpty ? .recognized : .text(text)
      case "response.completed":
        return .done
      case "response.failed":
        return .failure(
          payload["response"]?["error"]?["message"]?.stringValue ?? "服务商报告响应失败。")
      case "error":
        return .failure(ModelServiceClient.providerMessage(in: payload) ?? event.data)
      default:
        return type.hasPrefix("response.") ? .recognized : .unrecognized
      }
    case .anthropicMessages:
      let type = payload["type"]?.stringValue ?? event.name ?? ""
      switch type {
      case "content_block_delta":
        guard payload["delta"]?["type"]?.stringValue == "text_delta",
          let text = payload["delta"]?["text"]?.stringValue, !text.isEmpty
        else {
          return .recognized
        }
        return .text(text)
      case "message_stop":
        return .done
      case "error":
        return .failure(ModelServiceClient.providerMessage(in: payload) ?? event.data)
      case "message_start", "content_block_start", "content_block_stop", "message_delta", "ping":
        return .recognized
      default:
        return .unrecognized
      }
    }
  }

  /// The reply in a non-streamed response, or nil when the document is not this format's.
  func completeReply(in document: JSONValue) -> String? {
    switch self {
    case .chatCompletions:
      guard let choices = document["choices"]?.arrayValue else { return nil }
      return choices.first?["message"]?["content"]?.stringValue ?? ""
    case .responses:
      if let text = document["output_text"]?.stringValue { return text }
      guard let output = document["output"]?.arrayValue else { return nil }
      return output.compactMap { item -> String? in
        guard item["type"]?.stringValue == "message" else { return nil }
        return item["content"]?.arrayValue?
          .filter { $0["type"]?.stringValue == "output_text" }
          .compactMap { $0["text"]?.stringValue }
          .joined()
      }.joined()
    case .anthropicMessages:
      guard let content = document["content"]?.arrayValue else { return nil }
      return content
        .filter { $0["type"]?.stringValue == "text" }
        .compactMap { $0["text"]?.stringValue }
        .joined()
    }
  }
}

/// The status and raw reply of one request, kept for `check --verbose`. The text is already
/// redacted when it arrives and is capped, since a streamed reply can be long.
final class ModelResponseTranscript: @unchecked Sendable {
  static let characterLimit = 16_000

  private let lock = NSLock()
  private var status: Int?
  private var text = ""

  var statusCode: Int? { lock.withLock { status } }
  var body: String { lock.withLock { text } }

  func record(statusCode: Int) {
    lock.withLock { status = statusCode }
  }

  func append(_ part: String) {
    lock.withLock {
      guard text.count < Self.characterLimit else { return }
      text += part.prefix(Self.characterLimit - text.count)
    }
  }
}

// MARK: - Errors and redaction

enum ModelServiceError: LocalizedError, Equatable {
  /// The configuration lacks these fields (command-line names).
  case incompleteConfiguration(missing: [String])
  case invalidRequest
  /// A non-2xx status; `body` is the provider's text with the key redacted.
  case http(status: Int, providerMessage: String?, body: String)
  /// An error event in a successful stream, or an error document.
  case provider(message: String)
  /// A reply that is not in the configured format.
  case unexpectedResponse(String)
  case emptyResult
  case transport(URLError)

  var statusCode: Int? {
    if case .http(let status, _, _) = self { return status }
    return nil
  }

  /// The panel's failure note: `请求失败：<this> 按 ⏎ 重试`.
  var errorDescription: String? {
    switch self {
    case .incompleteConfiguration:
      "还没配置模型服务，在设置里复制配置提示词交给 AI 助手。"
    case .invalidRequest:
      "无法构造模型请求。"
    case .http(let status, let providerMessage, _):
      providerMessage ?? "模型服务请求失败（HTTP \(status)）。"
    case .provider(let message):
      message
    case .unexpectedResponse:
      "模型服务返回了无法识别的响应。"
    case .emptyResult:
      "模型服务没有返回文本。"
    case .transport(let error):
      "连不上模型服务：\(error.localizedDescription)"
    }
  }

  /// A short cause for the check's report and Settings' failure note.
  var reason: String {
    switch self {
    case .incompleteConfiguration(let missing):
      "配置还不完整，缺少 \(missing.joined(separator: "、"))"
    case .invalidRequest:
      "无法构造请求"
    case .http(let status, _, _):
      switch status {
      case 401, 403: "服务商拒绝了 API Key"
      case 404: "找不到端点或模型"
      case 429: "请求太频繁或额度不足"
      case 400..<500: "服务商拒绝了请求"
      default: "服务商出错"
      }
    case .provider:
      "服务商返回了错误"
    case .unexpectedResponse:
      "返回的格式与 format 不符"
    case .emptyResult:
      "没有返回文本"
    case .transport(let error):
      switch error.code {
      case .timedOut: "请求超时"
      case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet:
        "连不上服务"
      case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
        "安全连接失败"
      default: "网络出错"
      }
    }
  }

  /// What the provider said, for `check --verbose`.
  var providerText: String? {
    switch self {
    case .http(_, _, let body): body
    case .provider(let message): message
    case .unexpectedResponse(let detail): detail
    case .transport(let error): error.localizedDescription
    default: nil
    }
  }
}

/// Replaces the API key with •••• in anything Cida prints or shows, including a provider's
/// echo of it inside JSON or a URL.
struct SecretRedactor: Sendable {
  static let mask = "••••"

  let secret: String

  func redact(_ text: String) -> String {
    // Anything shorter cannot be a key, and replacing it would garble the text.
    guard secret.count >= 4 else { return text }
    var result = text
    for form in forms where result.contains(form) {
      result = result.replacingOccurrences(of: form, with: Self.mask)
    }
    return result
  }

  private var forms: [String] {
    var forms = [secret]
    let jsonEscaped = JSONValue.string(secret).compactText.dropFirst().dropLast()
    let slashEscaped = jsonEscaped.replacingOccurrences(of: "/", with: "\\/")
    let percentEncoded =
      secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? secret
    for form in [String(jsonEscaped), slashEscaped, percentEncoded] where !forms.contains(form) {
      forms.append(form)
    }
    return forms
  }
}

extension URLSession.AsyncBytes {
  /// The whole body as text, capped at 1 MB: an error page is never larger in practice.
  fileprivate func collectText() async throws -> String {
    var data = Data()
    for try await byte in self {
      data.append(byte)
      if data.count >= 1_000_000 { break }
    }
    return String(decoding: data, as: UTF8.self)
  }
}
