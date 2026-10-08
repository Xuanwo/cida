import Foundation

/// The text 复制配置提示词 puts on the pasteboard for an AI assistant
/// (`Design/spec/configuration.md` §五): the command line's absolute path, the current
/// configuration, and the steps that keep the key out of the conversation.
enum ConfigurationPrompt {
  /// The executable the assistant runs; inside the app bundle it is
  /// `/Applications/Cida.app/Contents/MacOS/Cida`.
  static var executablePath: String {
    Bundle.main.executablePath ?? "/Applications/Cida.app/Contents/MacOS/Cida"
  }

  /// `deepseek-chat · api.deepseek.com · Chat Completions`, 还没配置 when nothing is set, and
  /// what is still missing when a configuration is partial.
  static func currentConfiguration(_ settings: CidaSettings) -> String {
    let service = settings.modelService
    if service.isUnset { return "还没配置" }
    let missing = service.missingFields(hasAPIKey: !settings.apiKey.isEmpty)
    guard !missing.isEmpty else { return service.summary }
    return "\(service.summary)（还缺 \(missing.joined(separator: "、"))）"
  }

  static func text(
    executablePath: String = executablePath, settings: CidaSettings,
    lastCheck: ModelServiceCheckRecord? = nil,
    requestFailure: ProcessingFailure? = nil, previewFailure: ProcessingFailure? = nil
  ) -> String {
    let failures = [("面板请求", requestFailure), ("动作试运行", previewFailure)].compactMap { context, failure -> String? in
      guard let failure, failure.configurationFingerprint == settings.modelServiceFingerprint else { return nil }
      return "\(context)未完成，错误类别为 \(failure.category.rawValue)"
    }
    let task: String
    if settings.modelService.isUnset {
      task = "从头配置：问我想用哪家模型服务和哪个模型；我没想好时推荐两三个并说明差别。"
    } else if !settings.isModelServiceComplete {
      task = "继续配置：保留已选的服务与模型，读取当前缺项并补齐，不重新从头选择服务。"
    } else if !failures.isEmpty {
      task = """
        继续检查：\(failures.joined(separator: "；"))。这不是一次连接检查的结果。
        先运行 `Cida config show --json` 与 `Cida check --verbose`，按诊断证据修正并验证，默认保留现有服务与模型。
        请求原文、输出和服务商原文未附带；普通连接检查成功不能证明原请求已恢复，自动分段仍无法完成时，应检查模型容量、提示词和请求参数。不索取用户原文来盲目重现。
        """
    } else if let lastCheck, !lastCheck.passed,
      lastCheck.fingerprint == settings.modelServiceFingerprint
    {
      task = """
        继续检查：最近一次检查未通过（\(ISO8601DateFormatter().string(from: lastCheck.checkedAt))）。
        先运行 `Cida config show --json` 与 `Cida check --verbose` 读取当前配置和诊断，找出原因后修改，再运行 `Cida check` 验证。默认保留现有服务与模型。
        """
    } else {
      task = "调整配置：先问我想调整什么，默认保留现有服务与模型；只有需要我选择替代方案时才问。"
    }
    return """
      帮我配置辞达（macOS 上的翻译与改写应用）使用的模型服务。

      辞达的命令行：\(executablePath)
      下文的 `Cida` 均指这个可执行文件，请使用带引号的绝对路径运行。
      当前配置：\(currentConfiguration(settings))

      这次任务：\(task)

      请这样做：
      1. 运行 `Cida config show --json` 读取最新配置和缺项，再运行 `Cida config schema` 了解字段。以上配置是复制时的快照，以命令行的当前结果为准。
      2. 查这家服务的官方文档，确定端点、请求格式和需要的参数。辞达只用来翻译和改写，用不上思考：模型能关闭思考就在 `body` 里关掉，关不掉就设到它支持的最低档。
      3. 用 `Cida config set 字段=值 …` 一次写入需要修改的字段，不擅自更换服务或模型。
      4. API Key 不要让我发给你，也不要打印或写进文件：需要 Key 时请我先复制，再运行 `pbpaste | Cida config set api-key --stdin`；Key 已经在环境变量或文件里时，用 `--env` 或 `--file`。已有 Key 不需要重新提供。
      5. 修改后运行 `Cida check`；失败时用 `Cida check --verbose` 读取诊断，按新证据调整后再验证，不反复重试同一个失败。需要我提供信息、授权或处理账户付费时，说明我需要做什么并等待，不承诺一定修好。
      6. 最后用 `Cida config show --json` 核对配置与检查结果，简短告诉我是否可用，以及是否还有需要我做的事，不转述技术诊断。

      如果你不能运行命令，请明确告诉我需要一个能在本机运行辞达命令行的 AI 助手。
      """
  }
}
