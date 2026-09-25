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

  static func text(executablePath: String = executablePath, settings: CidaSettings) -> String {
    """
    帮我配置辞达（macOS 上的翻译与改写应用）使用的模型服务。

    辞达的命令行：\(executablePath)
    当前配置：\(currentConfiguration(settings))

    请这样做：
    1. 问我想用哪家模型服务和哪个模型；我没想好时推荐两三个并说明差别。
    2. 运行 `Cida config schema` 了解全部字段，查这家服务的官方文档，确定端点、请求格式和需要的参数。
    3. 用 `Cida config set 字段=值 …` 一次写入。
    4. API Key 不要让我发给你，也不要打印或写进文件：请我先复制 Key，再运行 `pbpaste | Cida config set api-key --stdin`；Key 已经在环境变量或文件里时，用 `--env` 或 `--file`。
    5. 运行 `Cida check`；失败时用 `Cida check --verbose` 找原因、修改配置，直到通过。
    6. 最后用 `Cida config show` 告诉我配置结果。

    如果你不能运行命令，就把每一步的命令写给我，我粘贴到「终端」里运行，再把输出贴给你。
    """
  }
}
