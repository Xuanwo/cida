import Foundation

/// One real request with the current configuration: the model is asked to translate "hello"
/// into Chinese through the same prompt contract and request path the panel uses
/// (`Design/spec/configuration.md` §二 `check`). Settings' 检查 and the command line's `check`
/// both run it and both record the outcome.
enum ModelServiceCheck {
  static let source = "hello"
  static let timeout: TimeInterval = 60

  static func run(
    settings: CidaSettings,
    client: ModelServiceClient = ModelServiceClient(),
    now: @Sendable () -> Date = Date.init
  ) async -> ModelServiceCheckResult {
    let startedAt = now()
    let redactor = SecretRedactor(secret: settings.apiKey)
    let transcript = ModelResponseTranscript()
    var prepared: PreparedModelRequest?
    var reply = ""
    var failure: ModelServiceError?
    do {
      let request = ProcessingRequest(
        text: source, mode: .translate, myLanguage: "简体中文", foreignLanguage: "English")
      let preparedRequest = try ModelServiceClient.prepare(
        request, settings: settings, timeout: timeout)
      prepared = preparedRequest
      try await client.send(
        preparedRequest,
        format: settings.modelService.format,
        redactor: redactor,
        transcript: transcript
      ) { reply += $0 }
      reply = redactor.redact(reply.trimmingCharacters(in: .whitespacesAndNewlines))
      if reply.isEmpty { failure = .emptyResult }
    } catch let error as ModelServiceError {
      failure = error
    } catch {
      failure = .unexpectedResponse(redactor.redact(error.localizedDescription))
    }
    let finishedAt = now()
    return ModelServiceCheckResult(
      model: settings.modelService.model,
      duration: finishedAt.timeIntervalSince(startedAt),
      reply: reply,
      failure: failure,
      request: prepared,
      responseStatus: transcript.statusCode,
      responseBody: transcript.body,
      record: ModelServiceCheckRecord(
        passed: failure == nil,
        statusCode: failure?.statusCode,
        reason: failure?.reason,
        checkedAt: finishedAt,
        fingerprint: settings.modelServiceFingerprint
      )
    )
  }
}

struct ModelServiceCheckResult: Sendable {
  let model: String
  let duration: TimeInterval
  /// The model's reply, trimmed and redacted.
  let reply: String
  let failure: ModelServiceError?
  /// What was sent; nil when the configuration was incomplete.
  let request: PreparedModelRequest?
  let responseStatus: Int?
  /// The raw reply, redacted and capped.
  let responseBody: String
  let record: ModelServiceCheckRecord

  var passed: Bool { failure == nil }
}

/// The outcome of the latest check, kept with the settings so Settings and the command line
/// agree on it. It applies only while `fingerprint` matches the configuration (§四).
struct ModelServiceCheckRecord: Codable, Equatable, Sendable {
  var passed: Bool
  var statusCode: Int?
  var reason: String?
  var checkedAt: Date
  var fingerprint: String

  /// `401 · 服务商拒绝了 API Key`, or the reason alone when no response arrived.
  var failureSummary: String? {
    guard !passed else { return nil }
    let reason = reason ?? "检查失败"
    return statusCode.map { "\($0) · \(reason)" } ?? reason
  }
}

/// What Settings' 模型服务 row says under its label (`Design/spec/configuration.md` §四).
enum ModelServiceStatus: Equatable, Sendable {
  case ready
  case checking
  /// The latest check of this configuration failed: `401 · 服务商拒绝了 API Key`.
  case failed(String)

  var caption: String {
    switch self {
    case .ready: "已就绪"
    case .checking: "正在检查…"
    case .failed: "检查失败"
    }
  }

  /// Only 已就绪 gets the accent dot.
  var isReady: Bool { self == .ready }

  /// The line under the row that says what failed and how to fix it.
  var failureNote: String? {
    guard case .failed(let summary) = self else { return nil }
    return "\(summary)。复制配置提示词，让 AI 助手修好。"
  }
}
