import Carbon.HIToolbox
import XCTest

@testable import Cida

final class ModelConfigurationTests: XCTestCase {
  /// The JSON 1.0 wrote under `cida.settings.v1`: every key of its `CidaSettings`, with the
  /// preset in `provider` and the custom endpoint in `openAIEndpoint`.
  private func storedByVersion1(
    provider: String, model: String, endpoint: String = "",
    shortcut: String = #"{"keyCode":49,"modifiers":2}"#
  ) -> Data {
    Data(
      """
      {"provider":"\(provider)","apiKey":"","model":"\(model)","openAIEndpoint":"\(endpoint)",\
      "translationPrompt":"Translate carefully.","improvementPrompt":"Improve carefully.",\
      "launchAtLogin":true,"shortcut":\(shortcut),\
      "captureShortcut":{"keyCode":1,"modifiers":2},"promptContractVersion":2}
      """.utf8)
  }

  func testVersion1PresetsLoadAsTheEquivalentChatCompletionsConfiguration() throws {
    let cases: [(provider: String, model: String, endpoint: String)] = [
      ("DeepSeek", "deepseek-chat", "https://api.deepseek.com/chat/completions"),
      ("OpenAI", "gpt-5", "https://api.openai.com/v1/chat/completions"),
      ("Moonshot", "kimi-k3", "https://api.moonshot.cn/v1/chat/completions"),
      ("Zhipu", "glm-5.3", "https://open.bigmodel.cn/api/paas/v4/chat/completions"),
    ]
    for (provider, model, endpoint) in cases {
      let settings = try JSONDecoder().decode(
        CidaSettings.self, from: storedByVersion1(provider: provider, model: model))
      XCTAssertEqual(settings.modelService.endpoint, endpoint, provider)
      XCTAssertEqual(settings.modelService.model, model, provider)
      XCTAssertEqual(settings.modelService.format, .chatCompletions, provider)
      XCTAssertEqual(settings.modelService.resolvedAuth, .bearer, provider)
      XCTAssertNil(settings.modelService.auth, "auth keeps following the format")
      XCTAssertEqual(settings.translationPrompt, "Translate carefully.")
      XCTAssertEqual(settings.improvementPrompt, "Improve carefully.")
      XCTAssertTrue(settings.launchAtLogin)
      XCTAssertEqual(settings.shortcut, .optionSpace)
      XCTAssertEqual(settings.captureShortcut, .optionS)

      var withKey = settings
      withKey.apiKey = "sk-existing"
      XCTAssertTrue(withKey.isModelServiceComplete, "The key 1.0 stored keeps it working")
      XCTAssertFalse(settings.isModelServiceComplete, "A preset without a key is not ready")
    }
  }

  func testVersion1CustomEndpointsKeepTheirURL() throws {
    let custom = try JSONDecoder().decode(
      CidaSettings.self,
      from: storedByVersion1(
        provider: "Custom", model: "qwen3-32b",
        endpoint: "http://127.0.0.1:8080/v1/chat/completions"))
    XCTAssertEqual(custom.modelService.endpoint, "http://127.0.0.1:8080/v1/chat/completions")
    XCTAssertEqual(custom.modelService.model, "qwen3-32b")
    XCTAssertTrue(custom.isModelServiceComplete, "A local endpoint needs no key")

    // Before presets, "OpenAI" with another endpoint meant any compatible server.
    let openAICompatible = try JSONDecoder().decode(
      CidaSettings.self,
      from: storedByVersion1(
        provider: "OpenAI", model: "local", endpoint: "https://llm.example.com/v1/chat/completions")
    )
    XCTAssertEqual(
      openAICompatible.modelService.endpoint, "https://llm.example.com/v1/chat/completions")
  }

  func testMigratedSettingsAreWrittenInTheNewShapeOnly() throws {
    let migrated = try JSONDecoder().decode(
      CidaSettings.self, from: storedByVersion1(provider: "Moonshot", model: "kimi-k3"))
    let encoded = try JSONEncoder().encode(migrated)
    let object = try XCTUnwrap(JSONValue.parse(encoded)?.objectValue)
    XCTAssertNil(object["provider"])
    XCTAssertNil(object["openAIEndpoint"])
    XCTAssertNil(object["apiKey"], "The key is never written with the settings")
    XCTAssertEqual(
      object["modelService"]?["endpoint"], .string("https://api.moonshot.cn/v1/chat/completions"))
    XCTAssertEqual(try JSONDecoder().decode(CidaSettings.self, from: encoded), migrated)
  }

  func testFreshSettingsHaveNoModelService() throws {
    let settings = try JSONDecoder().decode(CidaSettings.self, from: Data("{}".utf8))
    XCTAssertTrue(settings.modelService.isUnset)
    XCTAssertFalse(CidaSettings().isModelServiceComplete)
    XCTAssertEqual(
      CidaSettings().modelService.missingFields(hasAPIKey: false), ["endpoint", "model", "api-key"])
  }

  func testAConfigurationWithHeadersAndBodyRoundTrips() throws {
    var settings = CidaSettings()
    settings.modelService = ModelConfiguration(
      endpoint: "https://api.anthropic.com/v1/messages",
      format: .anthropicMessages,
      model: "claude-sonnet-4-5",
      auth: .bearer,
      headers: ["anthropic-beta": "context-1m"],
      body: ["thinking": .object(["type": .string("disabled")]), "max_tokens": .integer(1024)]
    )
    let decoded = try JSONDecoder().decode(
      CidaSettings.self, from: try JSONEncoder().encode(settings))
    XCTAssertEqual(decoded.modelService, settings.modelService)
  }

  func testCompletenessFollowsTheEndpointTheModelAndTheKeyRule() {
    var service = ModelConfiguration(
      endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-chat")
    XCTAssertEqual(service.missingFields(hasAPIKey: false), ["api-key"])
    XCTAssertTrue(service.isComplete(hasAPIKey: true))

    service.auth = ModelAuthentication.none
    XCTAssertTrue(service.isComplete(hasAPIKey: false), "auth none sends no key")

    service.auth = nil
    for local in ["http://localhost:1234/v1", "http://127.0.0.1:8080/x", "http://[::1]:8080/x"] {
      service.endpoint = local
      XCTAssertTrue(service.isComplete(hasAPIKey: false), local)
    }

    service.endpoint = "ftp://example.com/v1"
    XCTAssertEqual(service.missingFields(hasAPIKey: true), ["endpoint"])
    service.endpoint = "https://example.com/v1"
    service.model = "  "
    XCTAssertEqual(service.missingFields(hasAPIKey: true), ["model"])
  }

  func testAuthFollowsTheFormatUntilSet() {
    var service = ModelConfiguration()
    XCTAssertEqual(service.resolvedAuth, .bearer)
    service.format = .anthropicMessages
    XCTAssertEqual(service.resolvedAuth, .xAPIKey)
    service.format = .responses
    XCTAssertEqual(service.resolvedAuth, .bearer)
    service.auth = .apiKey
    XCTAssertEqual(service.resolvedAuth, .apiKey)
  }

  func testSummaryNamesTheModelTheHostAndTheFormat() {
    let service = CidaSettings.designPreview.modelService
    XCTAssertEqual(service.summary, "deepseek-chat · api.deepseek.com · Chat Completions")
    XCTAssertEqual(service.hostAndFormat, "api.deepseek.com · Chat Completions")
    var responses = service
    responses.format = .responses
    responses.endpoint = "https://api.openai.com/v1/responses"
    XCTAssertEqual(responses.hostAndFormat, "api.openai.com · Responses")
  }

  func testFingerprintChangesWithTheServiceAndTheKeyButNotThePrompts() {
    var settings = CidaSettings.designPreview
    let original = settings.modelServiceFingerprint
    XCTAssertFalse(original.contains("sk-preview"), "Only a digest leaves the function")

    settings.translationPrompt = "Something else."
    XCTAssertEqual(settings.modelServiceFingerprint, original)
    settings.apiKey = "sk-another-key"
    XCTAssertNotEqual(settings.modelServiceFingerprint, original)
    settings = .designPreview
    settings.modelService.body = ["temperature": .number(0.2)]
    XCTAssertNotEqual(settings.modelServiceFingerprint, original)
    settings = .designPreview
    settings.modelService.auth = .bearer
    XCTAssertEqual(
      settings.modelServiceFingerprint, original,
      "Writing the default auth explicitly sends the same request")
  }

  // MARK: - Configuration prompt (spec §五)

  func testConfigurationPromptIsTheSpecTextWithThePathAndTheCurrentConfiguration() {
    let text = ConfigurationPrompt.text(
      executablePath: "/Applications/Cida.app/Contents/MacOS/Cida",
      settings: .designPreview)
    XCTAssertEqual(
      text,
      """
      帮我配置辞达（macOS 上的翻译与改写应用）使用的模型服务。

      辞达的命令行：/Applications/Cida.app/Contents/MacOS/Cida
      当前配置：deepseek-chat · api.deepseek.com · Chat Completions

      请这样做：
      1. 问我想用哪家模型服务和哪个模型；我没想好时推荐两三个并说明差别。
      2. 运行 `Cida config schema` 了解全部字段，查这家服务的官方文档，确定端点、请求格式和需要的参数。
      3. 用 `Cida config set 字段=值 …` 一次写入。
      4. API Key 不要让我发给你，也不要打印或写进文件：请我先复制 Key，再运行 `pbpaste | Cida config set api-key --stdin`；Key 已经在环境变量或文件里时，用 `--env` 或 `--file`。
      5. 运行 `Cida check`；失败时用 `Cida check --verbose` 找原因、修改配置，直到通过。
      6. 最后用 `Cida config show` 告诉我配置结果。

      如果你不能运行命令，就把每一步的命令写给我，我粘贴到「终端」里运行，再把输出贴给你。
      """)
    XCTAssertEqual(ConfigurationPrompt.currentConfiguration(CidaSettings()), "还没配置")
    var partial = CidaSettings.designPreview
    partial.apiKey = ""
    XCTAssertEqual(
      ConfigurationPrompt.currentConfiguration(partial),
      "deepseek-chat · api.deepseek.com · Chat Completions（还缺 api-key）")
    XCTAssertFalse(
      ConfigurationPrompt.text(settings: .designPreview).contains("sk-preview"),
      "The prompt never carries the key")
  }

  // MARK: - Fields (spec §三)

  private func configuration() -> EditableConfiguration {
    EditableConfiguration(settings: CidaSettings(), automaticUpdates: true, launchAtLogin: false)
  }

  private func message(
    _ field: ConfigurationField, _ value: String, in configuration: EditableConfiguration? = nil
  ) -> String? {
    var configuration = configuration ?? self.configuration()
    do {
      try field.apply(value, to: &configuration)
      return nil
    } catch {
      return error.message
    }
  }

  func testFieldsRejectInvalidValuesWithTheFieldNameAndTheFix() {
    XCTAssertEqual(message(.endpoint, "ftp://x"), "endpoint 不是有效的 http 或 https 地址：ftp://x")
    XCTAssertEqual(message(.endpoint, " "), "endpoint 不能为空；要清除用 config unset endpoint")
    XCTAssertEqual(
      message(.format, "openai"),
      "format 只能是 chat-completions、responses 或 anthropic-messages")
    XCTAssertEqual(message(.auth, "basic"), "auth 只能是 bearer、x-api-key、api-key 或 none")
    XCTAssertEqual(message(.model, ""), "model 不能为空；要清除用 config unset model")
    XCTAssertNotNil(message(.headers, "[1]"))
    XCTAssertEqual(message(.headers, #"{"X Bad": "1"}"#), "headers 里的「X Bad」不是有效的请求头名")
    XCTAssertEqual(message(.headers, #"{"X-Count": 1}"#), "headers 里「X-Count」的值要是单行字符串")
    XCTAssertNotNil(message(.body, "not json"))
    XCTAssertNotNil(message(.body, "[]"))
    XCTAssertNotNil(message(.shortcut, "shift+t"), "A shortcut needs ⌘, ⌥ or ⌃")
    XCTAssertNotNil(message(.shortcut, "option+nokey"))
    XCTAssertEqual(message(.launchAtLogin, "yes"), "launch-at-login 只能是 true 或 false")
    XCTAssertNotNil(message(.translationPrompt, "   "))
  }

  func testFieldsApplyAndShowTheirValues() throws {
    var configuration = configuration()
    try ConfigurationField.endpoint.apply(
      " https://api.anthropic.com/v1/messages ", to: &configuration)
    try ConfigurationField.format.apply("anthropic-messages", to: &configuration)
    try ConfigurationField.model.apply("claude-sonnet-4-5", to: &configuration)
    try ConfigurationField.body.apply(#"{"max_tokens": 1024}"#, to: &configuration)
    try ConfigurationField.headers.apply(#"{"anthropic-beta": "x"}"#, to: &configuration)
    try ConfigurationField.shortcut.apply("ctrl+opt+T", to: &configuration)
    try ConfigurationField.automaticUpdates.apply("false", to: &configuration)
    try ConfigurationField.launchAtLogin.apply("true", to: &configuration)

    let service = configuration.settings.modelService
    XCTAssertEqual(service.endpoint, "https://api.anthropic.com/v1/messages")
    XCTAssertEqual(service.format, .anthropicMessages)
    XCTAssertEqual(service.body["max_tokens"], .integer(1024))
    XCTAssertEqual(service.headers, ["anthropic-beta": "x"])
    XCTAssertEqual(
      configuration.settings.shortcut,
      GlobalShortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: [.control, .option]))
    XCTAssertFalse(configuration.automaticUpdates)
    XCTAssertTrue(configuration.launchAtLogin)

    XCTAssertEqual(
      ConfigurationField.auth.displayValue(in: configuration, hasAPIKey: false),
      "x-api-key （随 format）")
    XCTAssertEqual(
      ConfigurationField.shortcut.displayValue(in: configuration, hasAPIKey: false),
      "control+option+t")
    XCTAssertEqual(
      ConfigurationField.apiKey.displayValue(in: configuration, hasAPIKey: true), "已保存在钥匙串")
    XCTAssertEqual(ConfigurationField.apiKey.jsonValue(in: configuration, hasAPIKey: true), .string("stored"))

    ConfigurationField.auth.reset(in: &configuration)
    ConfigurationField.body.reset(in: &configuration)
    ConfigurationField.shortcut.reset(in: &configuration)
    XCTAssertNil(configuration.settings.modelService.auth)
    XCTAssertTrue(configuration.settings.modelService.body.isEmpty)
    XCTAssertEqual(configuration.settings.shortcut, .optionSpace)
  }

  func testTheTwoShortcutsMustDiffer() throws {
    var configuration = configuration()
    try ConfigurationField.captureShortcut.apply("option+space", to: &configuration)
    XCTAssertThrowsError(try ConfigurationField.validate(configuration))
  }

  func testShortcutTextRoundTripsForEveryNamedKey() throws {
    for text in [
      "option+space", "option+s", "control+option+t", "shift+command+return", "command+f12",
      "control+option+shift+command+/", "option+page-down", "control+`",
    ] {
      let shortcut = try XCTUnwrap(GlobalShortcut(configurationText: text), text)
      XCTAssertEqual(shortcut.configurationText, text)
    }
    XCTAssertEqual(GlobalShortcut(configurationText: "⌥+Space"), .optionSpace)
    XCTAssertEqual(GlobalShortcut(configurationText: "alt+esc")?.configurationText, "option+escape")
  }

  func testSchemaDescribesEveryField() {
    for field in ConfigurationField.allCases {
      let schema = field.schema
      XCTAssertFalse(schema.description.isEmpty, field.rawValue)
      XCTAssertFalse(schema.example.isEmpty, field.rawValue)
      XCTAssertFalse(schema.defaultValue.isEmpty, field.rawValue)
    }
    XCTAssertEqual(ConfigurationField.format.schema.values, ModelRequestFormat.allCases.map(\.rawValue))
    XCTAssertEqual(ConfigurationField.allCases.filter(\.isSecret), [.apiKey])
  }
}
