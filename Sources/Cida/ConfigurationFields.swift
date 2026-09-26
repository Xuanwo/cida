import Foundation

/// Everything the command line can read and write, as one value: the settings (without the
/// key) and the two preferences kept outside them. Commands change a copy and store it only
/// when every change is valid (`Design/spec/configuration.md` §二).
struct EditableConfiguration: Equatable {
  var settings: CidaSettings
  var automaticUpdates: Bool
  var launchAtLogin: Bool
}

/// A setting by its command-line name (`Design/spec/configuration.md` §三). The schema,
/// parsing, validation and display of each field live here, so `config schema`, `set`,
/// `unset` and `show` cannot disagree about a field.
enum ConfigurationField: String, CaseIterable, Sendable {
  case endpoint
  case format
  case model
  case apiKey = "api-key"
  case auth
  case headers
  case body
  case myLanguage = "my-language"
  case foreignLanguage = "foreign-language"
  case translationPrompt = "translation-prompt"
  case improvementPrompt = "improvement-prompt"
  case shortcut
  case captureShortcut = "capture-shortcut"
  case capturePresentation = "capture-presentation"
  case launchAtLogin = "launch-at-login"
  case automaticUpdates = "automatic-updates"

  /// The fields that describe the model service; `show` always lists these.
  static let modelServiceFields: [ConfigurationField] = [
    .endpoint, .format, .model, .apiKey, .auth, .headers, .body,
  ]

  /// Written only from `--stdin`, `--file` or `--env`, and never printed.
  var isSecret: Bool { self == .apiKey }

  // MARK: Schema

  struct Schema {
    let type: String
    let values: [String]?
    /// What the field holds before anyone sets it, as `show` would print it.
    let defaultValue: String
    let example: String
    let description: String
  }

  var schema: Schema {
    switch self {
    case .endpoint:
      Schema(
        type: "url", values: nil, defaultValue: "未设置",
        example: "https://api.deepseek.com/chat/completions",
        description: "请求发往的完整地址（http 或 https，包含路径）")
    case .format:
      Schema(
        type: "enum", values: ModelRequestFormat.allCases.map(\.rawValue),
        defaultValue: ModelRequestFormat.chatCompletions.rawValue,
        example: ModelRequestFormat.anthropicMessages.rawValue,
        description:
          "请求与流式响应的格式：chat-completions 为 OpenAI Chat Completions 及兼容它的服务，responses 为 OpenAI Responses，anthropic-messages 为 Anthropic Messages")
    case .model:
      Schema(
        type: "string", values: nil, defaultValue: "未设置", example: "deepseek-chat",
        description: "模型名，原样写进请求体的 model")
    case .apiKey:
      Schema(
        type: "secret", values: nil, defaultValue: "未设置",
        example: "pbpaste | Cida config set api-key --stdin",
        description:
          "API Key，存进钥匙串；只能用 --stdin、--file 或 --env 写入，不接受写在命令里的值，也不会被输出；端点在本机（localhost、127.0.0.1、::1）或 auth 为 none 时可不设")
    case .auth:
      Schema(
        type: "enum", values: ModelAuthentication.allCases.map(\.rawValue),
        defaultValue: "随 format：anthropic-messages 为 x-api-key，其余为 bearer",
        example: ModelAuthentication.apiKey.rawValue,
        description:
          "API Key 放在哪个请求头：bearer 为 Authorization: Bearer <key>，x-api-key 与 api-key 为同名请求头，none 不发送 Key")
    case .headers:
      Schema(
        type: "json-object", values: nil, defaultValue: "{}",
        example: #"{"HTTP-Referer": "https://example.com"}"#,
        description: "额外请求头，值都是字符串；与辞达自己的请求头同名时以这里为准")
    case .body:
      Schema(
        type: "json-object", values: nil, defaultValue: "{}",
        example: #"{"thinking": {"type": "disabled"}}"#,
        description:
          "合并进请求体的额外参数（如关闭推理、改 max_tokens）；对象逐层合并，值为 null 的键会从请求里去掉")
    case .myLanguage:
      Schema(
        type: "text", values: nil, defaultValue: CidaSettings.defaultLanguages().my,
        example: "粤语",
        description:
          "我的语言，与设置里的相同：其他语言都译成它；可写任何语言、方言、地区写法或文体，由模型理解")
    case .foreignLanguage:
      Schema(
        type: "text", values: nil, defaultValue: CidaSettings.defaultLanguages().foreign,
        example: "英式英语",
        description: "常用外语，与设置里的相同：原文是我的语言时译成它；写法同 my-language")
    case .translationPrompt:
      Schema(
        type: "text", values: nil, defaultValue: CidaSettings.defaultTranslationPrompt,
        example: "Cida config set translation-prompt --file prompt.txt",
        description: "翻译的提示词，与设置里的相同；目标语言与任务由辞达传入，不必写占位符；长文本可用 --file 或 --stdin")
    case .improvementPrompt:
      Schema(
        type: "text", values: nil, defaultValue: CidaSettings.defaultImprovementPrompt,
        example: "Cida config set improvement-prompt --file prompt.txt",
        description: "改进的提示词，与设置里的相同；长文本可用 --file 或 --stdin")
    case .shortcut:
      Schema(
        type: "shortcut", values: nil, defaultValue: GlobalShortcut.optionSpace.configurationText,
        example: "control+option+t",
        description:
          "显示辞达的全局快捷键，与设置里的相同：修饰键（control、option、shift、command）加一个键，用 + 连接，至少带 control、option、command 之一")
    case .captureShortcut:
      Schema(
        type: "shortcut", values: nil, defaultValue: GlobalShortcut.optionS.configurationText,
        example: "control+option+s",
        description: "截图翻译的快捷键，写法同 shortcut，两者不能相同")
    case .capturePresentation:
      Schema(
        type: "enum", values: CapturePresentation.allCases.map(\.rawValue), defaultValue: "overlay",
        example: "image-window", description: "截图结果展示方式：overlay 原屏幕覆盖，image-window 独立图片窗口，下次截图生效")
    case .launchAtLogin:
      Schema(
        type: "boolean", values: ["true", "false"], defaultValue: "false", example: "true",
        description: "开机启动，与设置里的开关相同")
    case .automaticUpdates:
      Schema(
        type: "boolean", values: ["true", "false"], defaultValue: "true", example: "false",
        description: "每天自动检查更新，与设置里的开关相同")
    }
  }

  // MARK: Writing

  struct InvalidValue: Error, Equatable {
    let field: String
    let message: String
  }

  /// Parses `text` and writes it into `configuration`. The key is not handled here: it goes
  /// straight to the Keychain.
  func apply(_ text: String, to configuration: inout EditableConfiguration) throws(InvalidValue) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var settings = configuration.settings
    switch self {
    case .endpoint:
      guard !value.isEmpty else { throw invalid("不能为空；要清除用 config unset endpoint") }
      guard ModelConfiguration.endpointURL(from: value) != nil else {
        throw invalid("不是有效的 http 或 https 地址：\(value)")
      }
      settings.modelService.endpoint = value
    case .format:
      guard let format = ModelRequestFormat(rawValue: value) else {
        throw invalid("只能是 \(Self.list(ModelRequestFormat.allCases.map(\.rawValue)))")
      }
      settings.modelService.format = format
    case .model:
      guard !value.isEmpty else { throw invalid("不能为空；要清除用 config unset model") }
      settings.modelService.model = value
    case .apiKey:
      break
    case .auth:
      guard let auth = ModelAuthentication(rawValue: value) else {
        throw invalid("只能是 \(Self.list(ModelAuthentication.allCases.map(\.rawValue)))")
      }
      settings.modelService.auth = auth
    case .headers:
      settings.modelService.headers = try parseHeaders(value)
    case .body:
      guard let object = JSONValue.parse(value)?.objectValue else {
        throw invalid(#"要是一个 JSON 对象，例如 {"thinking": {"type": "disabled"}}"#)
      }
      settings.modelService.body = object
    case .myLanguage, .foreignLanguage:
      guard !value.isEmpty, !value.contains("\n") else {
        throw invalid("要是一行文字，例如 \(schema.example)；要恢复默认用 config unset \(rawValue)")
      }
      if self == .myLanguage {
        settings.myLanguage = value
      } else {
        settings.foreignLanguage = value
      }
    case .translationPrompt, .improvementPrompt:
      guard !value.isEmpty else {
        throw invalid("不能为空；要恢复默认用 config unset \(rawValue)")
      }
      if self == .translationPrompt {
        settings.translationPrompt = value
      } else {
        settings.improvementPrompt = value
      }
    case .shortcut, .captureShortcut:
      guard let shortcut = GlobalShortcut(configurationText: value) else {
        throw invalid("写成修饰键加一个键，至少带 control、option 或 command，例如 \(schema.example)")
      }
      settings.setShortcut(shortcut, for: self == .shortcut ? .showPanel : .captureText)
    case .capturePresentation:
      guard let presentation = CapturePresentation(rawValue: value) else {
        throw invalid("只能是 overlay 或 image-window")
      }
      settings.capturePresentation = presentation
    case .launchAtLogin, .automaticUpdates:
      guard let enabled = ["true": true, "false": false][value] else {
        throw invalid("只能是 true 或 false")
      }
      if self == .launchAtLogin {
        configuration.launchAtLogin = enabled
        settings.launchAtLogin = enabled
      } else {
        configuration.automaticUpdates = enabled
      }
    }
    configuration.settings = settings
  }

  /// Puts the field back to its default.
  func reset(in configuration: inout EditableConfiguration) {
    let defaults = CidaSettings()
    switch self {
    case .endpoint: configuration.settings.modelService.endpoint = ""
    case .format: configuration.settings.modelService.format = .chatCompletions
    case .model: configuration.settings.modelService.model = ""
    case .apiKey: break
    case .auth: configuration.settings.modelService.auth = nil
    case .headers: configuration.settings.modelService.headers = [:]
    case .body: configuration.settings.modelService.body = JSONObject()
    case .myLanguage: configuration.settings.myLanguage = defaults.myLanguage
    case .foreignLanguage: configuration.settings.foreignLanguage = defaults.foreignLanguage
    case .translationPrompt: configuration.settings.translationPrompt = defaults.translationPrompt
    case .improvementPrompt: configuration.settings.improvementPrompt = defaults.improvementPrompt
    case .shortcut: configuration.settings.shortcut = defaults.shortcut
    case .captureShortcut: configuration.settings.captureShortcut = defaults.captureShortcut
    case .capturePresentation: configuration.settings.capturePresentation = defaults.capturePresentation
    case .launchAtLogin:
      configuration.launchAtLogin = false
      configuration.settings.launchAtLogin = false
    case .automaticUpdates: configuration.automaticUpdates = true
    }
  }

  /// Rules that span fields; checked after every change in a command is applied.
  static func validate(_ configuration: EditableConfiguration) throws(InvalidValue) {
    if configuration.settings.shortcut == configuration.settings.captureShortcut {
      throw InvalidValue(field: "capture-shortcut", message: "capture-shortcut 不能与 shortcut 相同")
    }
  }

  private func parseHeaders(_ value: String) throws(InvalidValue) -> [String: String] {
    guard let object = JSONValue.parse(value)?.objectValue else {
      throw invalid(#"要是一个 JSON 对象，例如 {"HTTP-Referer": "https://example.com"}"#)
    }
    var headers: [String: String] = [:]
    let tokenCharacters = CharacterSet(
      charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    for member in object.members {
      guard !member.key.isEmpty,
        member.key.unicodeScalars.allSatisfy(tokenCharacters.contains)
      else {
        throw invalid("里的「\(member.key)」不是有效的请求头名")
      }
      guard let text = member.value.stringValue, !text.contains("\n"), !text.contains("\r") else {
        throw invalid("里「\(member.key)」的值要是单行字符串")
      }
      headers[member.key] = text
    }
    return headers
  }

  private func invalid(_ message: String) -> InvalidValue {
    InvalidValue(field: rawValue, message: "\(rawValue) \(message)")
  }

  private static func list(_ values: [String]) -> String {
    guard values.count > 1 else { return values.first ?? "" }
    return values.dropLast().joined(separator: "、") + " 或 " + values.last!
  }

  // MARK: Reading

  func isDefault(in configuration: EditableConfiguration, hasAPIKey: Bool) -> Bool {
    let defaults = EditableConfiguration(
      settings: CidaSettings(), automaticUpdates: true, launchAtLogin: false)
    switch self {
    case .apiKey: return !hasAPIKey
    default:
      return jsonValue(in: configuration, hasAPIKey: hasAPIKey)
        == jsonValue(in: defaults, hasAPIKey: hasAPIKey)
    }
  }

  /// The value for `show --json`. The key appears only as `stored` or `unset`.
  func jsonValue(in configuration: EditableConfiguration, hasAPIKey: Bool) -> JSONValue {
    let settings = configuration.settings
    let service = settings.modelService
    switch self {
    case .endpoint: return service.endpoint.isEmpty ? .null : .string(service.endpoint)
    case .format: return .string(service.format.rawValue)
    case .model: return service.model.isEmpty ? .null : .string(service.model)
    case .apiKey: return .string(hasAPIKey ? "stored" : "unset")
    case .auth: return .string(service.resolvedAuth.rawValue)
    case .headers:
      var object = JSONObject()
      for name in service.headers.keys.sorted() { object[name] = .string(service.headers[name]!) }
      return .object(object)
    case .body: return .object(service.body)
    case .myLanguage: return .string(settings.myLanguage)
    case .foreignLanguage: return .string(settings.foreignLanguage)
    case .translationPrompt: return .string(settings.translationPrompt)
    case .improvementPrompt: return .string(settings.improvementPrompt)
    case .shortcut: return .string(settings.shortcut.configurationText)
    case .captureShortcut: return .string(settings.captureShortcut.configurationText)
    case .capturePresentation: return .string(configuration.settings.capturePresentation.rawValue)
    case .launchAtLogin: return .bool(configuration.launchAtLogin)
    case .automaticUpdates: return .bool(configuration.automaticUpdates)
    }
  }

  /// The value for `show`: one line, the key never, and `auth` marked when it follows `format`.
  func displayValue(in configuration: EditableConfiguration, hasAPIKey: Bool) -> String {
    let service = configuration.settings.modelService
    switch self {
    case .endpoint, .model:
      if case .string(let text) = jsonValue(in: configuration, hasAPIKey: hasAPIKey) {
        return text
      }
      return "未设置"
    case .apiKey:
      return hasAPIKey ? "已保存在钥匙串" : "未设置"
    case .auth:
      return service.auth == nil
        ? "\(service.resolvedAuth.rawValue) （随 format）" : service.resolvedAuth.rawValue
    case .headers, .body:
      return jsonValue(in: configuration, hasAPIKey: hasAPIKey).displayText
    case .translationPrompt, .improvementPrompt:
      let prompt = self == .translationPrompt
        ? configuration.settings.translationPrompt : configuration.settings.improvementPrompt
      let line = prompt.replacingOccurrences(of: "\n", with: " ")
      return line.count > 60 ? String(line.prefix(60)) + "…" : line
    case .format, .myLanguage, .foreignLanguage, .shortcut, .captureShortcut, .capturePresentation, .launchAtLogin,
      .automaticUpdates:
      let value = jsonValue(in: configuration, hasAPIKey: hasAPIKey)
      return value.stringValue ?? value.compactText
    }
  }
}
