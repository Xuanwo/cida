import Foundation

/// Cida's own executable as a command line (`Design/spec/configuration.md` §二): an AI assistant
/// reads the schema, writes the configuration, stores the key from stdin, a file or an
/// environment variable, and checks the service, all without the interface starting. Output for
/// people is Chinese; `--json` gives the same content in stable English field names.
enum CommandLineInterface {
  enum ExitCode: Int32 {
    case success = 0
    /// A command or value that is not valid; nothing was changed.
    case invalid = 64
    /// The check's request failed.
    case checkFailed = 69
    /// The Keychain or the login item refused a change.
    case storageFailed = 74
  }

  /// Whether a launch with these arguments (without the executable) is a command rather than
  /// the application.
  static func handles(arguments: [String]) -> Bool {
    guard let first = arguments.first else { return false }
    return ["config", "check", "help", "--help", "-h"].contains(first)
  }

  /// What the commands read and write; tests replace the parts that touch the system.
  struct Context: Sendable {
    var store: ConfigurationStore
    var environment: [String: String]
    var readStandardInput: @Sendable () -> Data
    var readFile: @Sendable (String) throws -> Data
    var output: @Sendable (String) -> Void
    var errorOutput: @Sendable (String) -> Void
    var check: @Sendable (CidaSettings) async -> ModelServiceCheckResult

    static func production(environment: [String: String]) -> Context {
      let namespace = SettingsStore.commandLineNamespace(environment: environment)
      return Context(
        store: .production(namespace: namespace),
        environment: environment,
        readStandardInput: { FileHandle.standardInput.readDataToEndOfFile() },
        readFile: { try Data(contentsOf: URL(fileURLWithPath: $0)) },
        output: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
        errorOutput: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
        check: { await ModelServiceCheck.run(settings: $0) }
      )
    }
  }

  /// Runs the command in `arguments` and exits, without starting NSApplication.
  static func runAndExit(arguments: [String]) -> Never {
    final class Result: @unchecked Sendable { var code = ExitCode.success.rawValue }
    let result = Result()
    let finished = DispatchSemaphore(value: 0)
    let context = Context.production(environment: ProcessInfo.processInfo.environment)
    Task.detached {
      result.code = await run(arguments, context: context)
      finished.signal()
    }
    finished.wait()
    exit(result.code)
  }

  static func run(_ arguments: [String], context: Context) async -> Int32 {
    let command = Command(context: context, json: arguments.contains("--json"))
    let words = arguments.filter { $0 != "--json" }
    return await command.run(words).rawValue
  }
}

/// One invocation: the words after the executable and where its output goes.
private struct Command {
  let context: CommandLineInterface.Context
  let json: Bool

  init(context: CommandLineInterface.Context, json: Bool) {
    self.context = context
    self.json = json
  }

  private var store: ConfigurationStore { context.store }

  func run(_ words: [String]) async -> CommandLineInterface.ExitCode {
    switch (words.first, words.dropFirst().first) {
    case ("help", _), ("--help", _), ("-h", _):
      return help()
    case ("config", "schema"):
      return schema()
    case ("config", "show"):
      return show()
    case ("config", "set"):
      return set(Array(words.dropFirst(2)))
    case ("config", "unset"):
      return unset(Array(words.dropFirst(2)))
    case ("config", "reset"):
      return reset()
    case ("check", _):
      let options = words.dropFirst()
      guard options.allSatisfy({ $0 == "--verbose" }) else {
        return usageError("check 只接受 --verbose 与 --json")
      }
      return await check(verbose: options.contains("--verbose"))
    default:
      return usageError("不认识的命令：\(words.joined(separator: " "))")
    }
  }

  // MARK: help

  private func help() -> CommandLineInterface.ExitCode {
    let commands: [(usage: String, summary: String)] = [
      ("config schema", "全部字段的名称、类型、取值、默认值、示例与说明"),
      ("config show", "当前配置；API Key 只显示是否已保存"),
      ("config set 字段=值 …", "一次写入多项，全部合法才生效"),
      ("config set 字段 --stdin | --file 路径 | --env 名称", "从标准输入、文件或环境变量读取值；api-key 只能这样写入"),
      ("config unset 字段 …", "恢复默认"),
      ("config reset", "全部恢复默认，并删除钥匙串里的 API Key"),
      ("check [--verbose]", "用当前配置真的请求一次；--verbose 在失败时列出实际请求与服务商的原文"),
    ]
    if json {
      emit(
        .object([
          "commands": .array(
            commands.map {
              .object(["usage": .string($0.usage), "summary": .string($0.summary)])
            }),
          "exitCodes": .object([
            "success": .integer(0), "invalid": .integer(64), "checkFailed": .integer(69),
            "storageFailed": .integer(74),
          ]),
        ]))
    } else {
      var lines = ["辞达的命令行：配置辞达使用的模型服务，并检查它是否可用。", "", "用法："]
      for command in commands {
        lines.append("  Cida \(command.usage)")
        lines.append("      \(command.summary)")
      }
      lines += [
        "",
        "每个命令都可以加 --json，输出稳定的 JSON。",
        "退出码：成功 0；配置不合法 64；检查失败 69；钥匙串或开机启动写入失败 74。",
      ]
      context.output(lines.joined(separator: "\n"))
    }
    return .success
  }

  // MARK: config schema

  private func schema() -> CommandLineInterface.ExitCode {
    if json {
      let fields = ConfigurationField.allCases.map { field -> JSONValue in
        let schema = field.schema
        var object: JSONObject = [
          "name": .string(field.rawValue),
          "type": .string(schema.type),
        ]
        if let values = schema.values { object["values"] = .array(values.map(JSONValue.string)) }
        object["default"] = .string(schema.defaultValue)
        object["example"] = .string(schema.example)
        object["description"] = .string(schema.description)
        object["secret"] = .bool(field.isSecret)
        object["sources"] = .array(
          (field.isSecret ? ["stdin", "file", "env"] : ["value", "stdin", "file", "env"])
            .map(JSONValue.string))
        return .object(object)
      }
      emit(.object(["fields": .array(fields)]))
      return .success
    }
    let width = ConfigurationField.allCases.map(\.rawValue.count).max()! + 3
    var blocks: [String] = []
    for field in ConfigurationField.allCases {
      let schema = field.schema
      let indent = String(repeating: " ", count: width)
      var lines = [field.rawValue.padded(to: width) + (schema.values?.joined(separator: " | ") ?? schema.type)]
      lines.append(indent + schema.description)
      let defaultValue =
        schema.defaultValue.count > 60 ? String(schema.defaultValue.prefix(60)) + "…" : schema.defaultValue
      lines.append(indent + "默认：\(defaultValue)")
      lines.append(indent + "例：\(schema.example)")
      blocks.append(lines.joined(separator: "\n"))
    }
    context.output(
      blocks.joined(separator: "\n\n")
        + "\n\n写入：Cida config set 字段=值 …；文本也可以用 字段 --stdin、--file 路径 或 --env 名称。")
    return .success
  }

  // MARK: config show

  private func show() -> CommandLineInterface.ExitCode {
    let configuration = loadConfiguration()
    let hasAPIKey = store.hasAPIKey()
    let service = configuration.settings.modelService
    if json {
      var fields = JSONObject()
      var defaults: [JSONValue] = []
      for field in ConfigurationField.allCases {
        fields[field.rawValue] = field.jsonValue(in: configuration, hasAPIKey: hasAPIKey)
        if field.isDefault(in: configuration, hasAPIKey: hasAPIKey) {
          defaults.append(.string(field.rawValue))
        }
      }
      var object: JSONObject = [
        "complete": .bool(service.isComplete(hasAPIKey: hasAPIKey)),
        "missing": .array(service.missingFields(hasAPIKey: hasAPIKey).map(JSONValue.string)),
        "fields": .object(fields),
        "defaults": .array(defaults),
      ]
      object["lastCheck"] = lastCheckJSON(for: configuration.settings)
      emit(.object(object))
      return .success
    }
    // The model service always; everything else only once it differs from the default.
    let shown = ConfigurationField.allCases.filter { field in
      [.endpoint, .format, .model, .apiKey, .auth].contains(field)
        || !field.isDefault(in: configuration, hasAPIKey: hasAPIKey)
    }
    let width = shown.map(\.rawValue.count).max()! + 3
    context.output(
      shown.map {
        $0.rawValue.padded(to: width) + $0.displayValue(in: configuration, hasAPIKey: hasAPIKey)
      }.joined(separator: "\n"))
    return .success
  }

  private func lastCheckJSON(for settings: CidaSettings) -> JSONValue {
    guard let record = store.loadLastCheck() else { return .null }
    var apiKeySettings = settings
    apiKeySettings.apiKey = store.readAPIKey() ?? ""
    return .object([
      "passed": .bool(record.passed),
      "status": record.statusCode.map { .integer(Int64($0)) } ?? .null,
      "reason": record.reason.map(JSONValue.string) ?? .null,
      "checkedAt": .string(ISO8601DateFormatter().string(from: record.checkedAt)),
      "current": .bool(record.fingerprint == apiKeySettings.modelServiceFingerprint),
    ])
  }

  // MARK: config set

  private enum Source {
    case inline(String)
    case standardInput
    case file(String)
    case environment(String)

    var description: String {
      switch self {
      case .inline: "命令"
      case .standardInput: "标准输入"
      case .file(let path): "文件 \(path)"
      case .environment(let name): "环境变量 \(name)"
      }
    }
  }

  private func set(_ words: [String]) -> CommandLineInterface.ExitCode {
    var assignments: [(field: ConfigurationField, source: Source)] = []
    var index = 0
    while index < words.count {
      let word = words[index]
      if let equals = word.firstIndex(of: "=") {
        let name = String(word[..<equals])
        guard let field = ConfigurationField(rawValue: name) else { return unknownField(name) }
        if field.isSecret { return refusePlainSecret(field) }
        assignments.append((field, .inline(String(word[word.index(after: equals)...]))))
        index += 1
        continue
      }
      guard let field = ConfigurationField(rawValue: word) else { return unknownField(word) }
      let option = words.indices.contains(index + 1) ? words[index + 1] : nil
      let argument = words.indices.contains(index + 2) ? words[index + 2] : nil
      switch (option, argument) {
      case ("--stdin", _):
        assignments.append((field, .standardInput))
        index += 2
      case ("--file", let path?):
        assignments.append((field, .file(path)))
        index += 3
      case ("--env", let name?):
        assignments.append((field, .environment(name)))
        index += 3
      default:
        return invalid([
          .init(
            field: field.rawValue,
            message:
              "\(field.rawValue) 后面要跟 =值，或者 --stdin、--file 路径、--env 名称")
        ])
      }
    }
    guard !assignments.isEmpty else {
      return usageError("config set 需要至少一项，例如 Cida config set model=deepseek-chat")
    }
    let names = assignments.map(\.field.rawValue)
    if let duplicate = names.first(where: { name in names.filter { $0 == name }.count > 1 }) {
      return usageError("\(duplicate) 在同一条命令里出现了不止一次")
    }
    if assignments.filter({ if case .standardInput = $0.source { true } else { false } }).count > 1 {
      return usageError("--stdin 在一条命令里只能用一次")
    }

    var configuration = loadConfiguration()
    let original = configuration
    var apiKey: String?
    var errors: [ConfigurationField.InvalidValue] = []
    for assignment in assignments {
      let text: String
      switch read(assignment.source) {
      case .success(let value): text = value
      case .failure(let error):
        errors.append(.init(field: assignment.field.rawValue, message: error.message))
        continue
      }
      if assignment.field == .apiKey {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
          errors.append(
            .init(field: "api-key", message: "没有从\(assignment.source.description)读到 API Key"))
        } else {
          apiKey = key
        }
        continue
      }
      do {
        try assignment.field.apply(text, to: &configuration)
      } catch {
        errors.append(error)
      }
    }
    if errors.isEmpty {
      do {
        try ConfigurationField.validate(configuration)
      } catch {
        errors.append(error)
      }
    }
    guard errors.isEmpty else { return invalid(errors) }

    if let apiKey {
      do {
        try store.saveAPIKey(apiKey)
      } catch {
        return storageFailed(error.localizedDescription)
      }
    }
    if let failure = persist(configuration, over: original) { return failure }

    let fieldNames = assignments.map(\.field.rawValue).filter { $0 != "api-key" }
    if json {
      emit(
        .object([
          "ok": .bool(true),
          "updated": .array(fieldNames.map(JSONValue.string)),
          "apiKeyStored": .bool(apiKey != nil),
        ]))
    } else {
      var lines: [String] = []
      if !fieldNames.isEmpty {
        lines.append("已更新 \(fieldNames.count) 项：\(fieldNames.joined(separator: "、"))")
      }
      if apiKey != nil { lines.append("已把 API Key 存进钥匙串") }
      context.output(lines.joined(separator: "\n"))
    }
    return .success
  }

  private struct SourceError: Error {
    let message: String
  }

  private func read(_ source: Source) -> Result<String, SourceError> {
    switch source {
    case .inline(let value):
      return .success(value)
    case .standardInput:
      return .success(String(decoding: context.readStandardInput(), as: UTF8.self))
    case .file(let path):
      do {
        return .success(String(decoding: try context.readFile(path), as: UTF8.self))
      } catch {
        return .failure(SourceError(message: "读不到文件 \(path)：\(error.localizedDescription)"))
      }
    case .environment(let name):
      guard let value = context.environment[name], !value.isEmpty else {
        return .failure(SourceError(message: "环境变量 \(name) 不存在或为空"))
      }
      return .success(value)
    }
  }

  // MARK: config unset / reset

  private func unset(_ words: [String]) -> CommandLineInterface.ExitCode {
    guard !words.isEmpty else {
      return usageError("config unset 需要至少一个字段，例如 Cida config unset body")
    }
    var fields: [ConfigurationField] = []
    for word in words {
      guard let field = ConfigurationField(rawValue: word) else { return unknownField(word) }
      if !fields.contains(field) { fields.append(field) }
    }
    var configuration = loadConfiguration()
    let original = configuration
    for field in fields { field.reset(in: &configuration) }
    do {
      try ConfigurationField.validate(configuration)
    } catch {
      return invalid([error])
    }
    if fields.contains(.apiKey) { store.clearAPIKey() }
    if let failure = persist(configuration, over: original) { return failure }

    let names = fields.map(\.rawValue)
    if json {
      emit(.object(["ok": .bool(true), "reset": .array(names.map(JSONValue.string))]))
    } else {
      context.output("已恢复默认 \(names.count) 项：\(names.joined(separator: "、"))")
    }
    return .success
  }

  private func reset() -> CommandLineInterface.ExitCode {
    let original = loadConfiguration()
    var configuration = original
    for field in ConfigurationField.allCases { field.reset(in: &configuration) }
    let hadAPIKey = store.hasAPIKey()
    store.clearAPIKey()
    store.saveLastCheck(nil)
    if let failure = persist(configuration, over: original) { return failure }
    if json {
      emit(.object(["ok": .bool(true), "apiKeyDeleted": .bool(hadAPIKey)]))
    } else {
      context.output(hadAPIKey ? "已恢复全部默认，并删除了钥匙串里的 API Key" : "已恢复全部默认")
    }
    return .success
  }

  /// Writes a validated configuration and tells a running Cida.
  private func persist(
    _ configuration: EditableConfiguration, over original: EditableConfiguration
  ) -> CommandLineInterface.ExitCode? {
    if configuration.launchAtLogin != original.launchAtLogin {
      do {
        try store.setLaunchAtLogin(configuration.launchAtLogin)
      } catch {
        return storageFailed("无法更新开机启动：\(error.localizedDescription)")
      }
    }
    if configuration.automaticUpdates != original.automaticUpdates {
      store.setAutomaticUpdates(configuration.automaticUpdates)
    }
    store.saveSettings(configuration.settings)
    store.notifyChange()
    return nil
  }

  private func loadConfiguration() -> EditableConfiguration {
    let settings = store.loadSettings()
    var configuration = EditableConfiguration(
      settings: settings,
      automaticUpdates: store.automaticUpdates(),
      launchAtLogin: store.launchAtLogin(settings)
    )
    configuration.settings.launchAtLogin = configuration.launchAtLogin
    return configuration
  }

  // MARK: check

  private func check(verbose: Bool) async -> CommandLineInterface.ExitCode {
    var settings = store.loadSettings()
    settings.apiKey = store.readAPIKey() ?? ""
    let missing = settings.modelService.missingFields(hasAPIKey: !settings.apiKey.isEmpty)
    guard missing.isEmpty else {
      let message = "配置还不完整，缺少 \(missing.joined(separator: "、"))；用 Cida config schema 查看字段"
      if json {
        emit(
          .object([
            "ok": .bool(false),
            "missing": .array(missing.map(JSONValue.string)),
            "message": .string(message),
          ]))
      } else {
        context.errorOutput("✗ \(message)")
      }
      return .invalid
    }

    let result = await context.check(settings)
    store.saveLastCheck(result.record)
    store.notifyChange()

    if json {
      emit(checkJSON(result, verbose: verbose))
    } else if result.passed {
      context.output(
        "✓ 可用 · \(result.model) · \(String(format: "%.1f", result.duration)) 秒 · 回复「\(Self.oneLine(result.reply, limit: 40))」"
      )
    } else {
      context.output(checkFailureText(result, verbose: verbose))
    }
    return result.passed ? .success : .checkFailed
  }

  private func checkFailureText(_ result: ModelServiceCheckResult, verbose: Bool) -> String {
    let failure = result.failure ?? .emptyResult
    guard verbose else {
      let status = failure.statusCode.map { "HTTP \($0) · " } ?? ""
      return """
        ✗ 检查失败 · \(status)\(failure.reason)
        用 Cida check --verbose 查看实际请求与服务商返回的原文
        """
    }
    var lines = ["✗ 检查失败 · " + (failure.statusCode.map { "HTTP \($0)" } ?? failure.reason)]
    if let request = result.request {
      lines.append("\(request.method) \(request.url.absoluteString)")
      lines += request.displayHeaders.map { "\($0.name): \($0.value)" }
      lines.append(CommandLineInterface.elidedBody(request.body))
    }
    if case .unexpectedResponse(let detail) = failure {
      lines.append("说明：\(detail)")
    }
    if result.responseStatus != nil {
      let body = result.responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
      lines.append("服务商返回：\(body.isEmpty ? "（空）" : body)")
    } else {
      lines.append("服务商返回：（没有收到响应：\(failure.providerText ?? failure.reason)）")
    }
    return lines.joined(separator: "\n")
  }

  private func checkJSON(_ result: ModelServiceCheckResult, verbose: Bool) -> JSONValue {
    var object: JSONObject = [
      "ok": .bool(result.passed),
      "model": .string(result.model),
      "durationSeconds": .number((result.duration * 10).rounded() / 10),
      "reply": result.passed ? .string(result.reply) : .null,
      "status": result.failure?.statusCode.map { .integer(Int64($0)) } ?? .null,
      "reason": result.failure.map { .string($0.reason) } ?? .null,
    ]
    if verbose {
      if let request = result.request {
        var headers = JSONObject()
        for header in request.displayHeaders { headers[header.name] = .string(header.value) }
        object["request"] = .object([
          "method": .string(request.method),
          "url": .string(request.url.absoluteString),
          "headers": .object(headers),
          "body": request.body,
        ])
      }
      object["responseStatus"] = result.responseStatus.map { .integer(Int64($0)) } ?? .null
      object["response"] = .string(result.responseBody)
    }
    return .object(object)
  }

  private static func oneLine(_ text: String, limit: Int) -> String {
    let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    return line.count > limit ? String(line.prefix(limit)) + "…" : line
  }

  // MARK: Output

  private func emit(_ value: JSONValue) {
    context.output(value.displayText)
  }

  private func refusePlainSecret(_ field: ConfigurationField) -> CommandLineInterface.ExitCode {
    let message = "\(field.rawValue) 不接受写在命令里的值，改用 --stdin、--file 或 --env"
    if json {
      emit(
        .object([
          "ok": .bool(false),
          "errors": .array([
            .object([
              "field": .string(field.rawValue), "message": .string(message),
              "example": .string("pbpaste | Cida config set api-key --stdin"),
            ])
          ]),
        ]))
    } else {
      context.errorOutput(
        """
        ✗ \(message)，例如：
          pbpaste | Cida config set api-key --stdin
        """)
    }
    return .invalid
  }

  private func unknownField(_ name: String) -> CommandLineInterface.ExitCode {
    invalid([
      .init(field: name, message: "不认识的字段「\(name)」；用 Cida config schema 查看全部字段")
    ])
  }

  private func invalid(_ errors: [ConfigurationField.InvalidValue]) -> CommandLineInterface.ExitCode {
    if json {
      emit(
        .object([
          "ok": .bool(false),
          "errors": .array(
            errors.map {
              .object(["field": .string($0.field), "message": .string($0.message)])
            }),
        ]))
    } else {
      context.errorOutput(errors.map { "✗ \($0.message)" }.joined(separator: "\n") + "\n没有改动任何配置")
    }
    return .invalid
  }

  private func usageError(_ message: String) -> CommandLineInterface.ExitCode {
    if json {
      emit(.object(["ok": .bool(false), "errors": .array([.object(["message": .string(message)])])]))
    } else {
      context.errorOutput("✗ \(message)\n用 Cida --help 查看用法")
    }
    return .invalid
  }

  private func storageFailed(_ message: String) -> CommandLineInterface.ExitCode {
    if json {
      emit(.object(["ok": .bool(false), "errors": .array([.object(["message": .string(message)])])]))
    } else {
      context.errorOutput("✗ \(message)")
    }
    return .storageFailed
  }
}

extension CommandLineInterface {
  /// The body on one line with the prompt and the source elided, as the board shows it:
  /// `{"model": "kimi-k2", "stream": true, "messages": [ … ]}`.
  static func elidedBody(_ body: JSONValue) -> String {
    guard var object = body.objectValue else { return body.displayText }
    let arrayMarker = "__CIDA_ELIDED_ARRAY__"
    let textMarker = "__CIDA_ELIDED_TEXT__"
    for key in ["system", "instructions", "messages", "input"] {
      switch object[key] {
      case .array: object[key] = .string(arrayMarker)
      case .string: object[key] = .string(textMarker)
      default: break
      }
    }
    return JSONValue.object(object).displayText
      .replacingOccurrences(of: "\"\(arrayMarker)\"", with: "[ … ]")
      .replacingOccurrences(of: "\"\(textMarker)\"", with: "\"…\"")
  }
}

extension String {
  /// Pads to `width` terminal columns; CJK characters take two.
  fileprivate func padded(to width: Int) -> String {
    let columns = unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) }
    return columns >= width ? self + " " : self + String(repeating: " ", count: width - columns)
  }
}
