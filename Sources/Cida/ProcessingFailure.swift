import Foundation

/// Safe recovery information for one request. Provider text stays in CLI diagnostics.
struct ProcessingFailure: Equatable, Sendable {
  enum Category: String, Equatable, Sendable {
    case timeout, offline, configuration, limited, secureConnection, unknown

    static func classify(_ error: Error) -> Self {
      if let error = error as? URLError { return transport(error) }
      guard let error = error as? ModelServiceError else { return .unknown }
      switch error {
      case .incompleteConfiguration, .invalidRequest, .unexpectedResponse, .lengthRecoveryExhausted:
        return .configuration
      case .http(let status, _, _):
        if error.isLengthLimit { return .configuration }
        switch status {
        case 401, 403, 404: return .configuration
        case 408, 504: return .timeout
        case 429: return .limited
        default: return .unknown
        }
      case .transport(let error): return transport(error)
      case .provider, .emptyResult: return .unknown
      }
    }

    private static func transport(_ error: URLError) -> Self {
      switch error.code {
      case .timedOut: .timeout
      case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .notConnectedToInternet, .networkConnectionLost: .offline
      case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        .clientCertificateRejected, .clientCertificateRequired: .secureConnection
      default: .unknown
      }
    }

    var explanation: String {
      switch self {
      case .timeout: "请求超时。重试会从头执行，并替换已有输出。"
      case .offline: "连不上模型服务。检查网络后重试；辞达不会自动重试。"
      case .configuration: "模型配置需要检查。在模型设置里复制配置提示词，交给 AI 助手继续检查；配置更新后即可重试。"
      case .limited: "服务商暂时限制了请求。请稍后重试；一直出现时，到服务商后台查看用量与额度。"
      case .secureConnection: "无法建立安全连接。检查网络或代理后重试；辞达不会跳过安全校验。"
      case .unknown: "请求没有完成，可以重试。反复出现时，在模型设置里复制配置提示词，交给 AI 助手继续检查。"
      }
    }
  }

  let category: Category
  let modelName: String
  let configurationFingerprint: String

  init(category: Category, settings: CidaSettings) {
    self.category = category
    modelName = settings.modelService.model
    configurationFingerprint = settings.modelServiceFingerprint
  }

  init(error: Error, settings: CidaSettings) {
    self.init(category: Category.classify(error), settings: settings)
  }
}
