import XCTest

@testable import Cida

/// The command line of `Design/spec/configuration.md` §二, run in process against memory.
final class CommandLineInterfaceTests: XCTestCase {
  private let secret = "sk-cli-secret-5678"

  private func run(
    _ arguments: [String], in store: InMemoryConfigurationStore,
    check: (@Sendable (CidaSettings) async -> ModelServiceCheckResult)? = nil
  ) async -> Int32 {
    store.clearOutput()
    if let check {
      return await CommandLineInterface.run(arguments, context: store.context(check: check))
    }
    return await CommandLineInterface.run(arguments, context: store.context())
  }

  private func expect(
    _ status: Int32, _ arguments: [String], in store: InMemoryConfigurationStore,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    let actual = await run(arguments, in: store)
    XCTAssertEqual(actual, status, arguments.joined(separator: " "), file: file, line: line)
  }

  func testOnlyCommandsSkipTheApplication() {
    XCTAssertTrue(CommandLineInterface.handles(arguments: ["config", "show"]))
    XCTAssertTrue(CommandLineInterface.handles(arguments: ["check", "--verbose"]))
    XCTAssertTrue(CommandLineInterface.handles(arguments: ["--help"]))
    XCTAssertFalse(CommandLineInterface.handles(arguments: []))
    XCTAssertFalse(CommandLineInterface.handles(arguments: ["--design-state", "settings"]))
    XCTAssertFalse(CommandLineInterface.handles(arguments: ["-NSDocumentRevisionsDebugMode", "YES"]))
  }

  func testSetWritesSeveralFieldsAtOnceAndTellsTheRunningApp() async {
    let store = InMemoryConfigurationStore()
    let status = await run(
      [
        "config", "set", "endpoint=https://api.deepseek.com/chat/completions",
        "format=chat-completions", "model=deepseek-chat",
      ], in: store)

    XCTAssertEqual(status, 0)
    XCTAssertEqual(store.output, "已更新 3 项：endpoint、format、model")
    XCTAssertEqual(store.settings.modelService.model, "deepseek-chat")
    XCTAssertEqual(store.notificationCount, 1)
  }

  func testAnInvalidValueChangesNothing() async {
    let store = InMemoryConfigurationStore(settings: .designPreview)
    let status = await run(
      ["config", "set", "model=new-model", "endpoint=ftp://example.com", "format=soap"], in: store)

    XCTAssertEqual(status, 64)
    XCTAssertEqual(store.settings.modelService.model, "deepseek-chat", "Nothing was written")
    XCTAssertEqual(store.notificationCount, 0)
    XCTAssertEqual(
      store.errorOutput,
      """
      ✗ endpoint 不是有效的 http 或 https 地址：ftp://example.com
      ✗ format 只能是 chat-completions、responses 或 anthropic-messages
      没有改动任何配置
      """)

    await expect(64, ["config", "set", "colour=red"], in: store)
    await expect(64, ["config", "set", "model=a", "model=b"], in: store)
    await expect(64, ["config", "set"], in: store)
    await expect(64, ["config", "frobnicate"], in: store)
  }

  func testAPlainAPIKeyIsRefusedWithTheGuidance() async {
    let store = InMemoryConfigurationStore()
    let status = await run(["config", "set", "model=m", "api-key=\(secret)"], in: store)

    XCTAssertEqual(status, 64)
    XCTAssertEqual(
      store.errorOutput,
      """
      ✗ api-key 不接受写在命令里的值，改用 --stdin、--file 或 --env，例如：
        pbpaste | Cida config set api-key --stdin
      """)
    XCTAssertFalse(store.errorOutput.contains(secret))
    XCTAssertNil(store.apiKey)
    XCTAssertEqual(store.settings.modelService.model, "", "The whole command was refused")

    await expect(64, ["config", "set", "api-key=\(secret)", "--json"], in: store)
    XCTAssertFalse(store.output.contains(secret))
    XCTAssertTrue(store.output.contains(#""ok": false"#))
  }

  func testTheKeyIsReadOnceFromStandardInputAFileOrTheEnvironment() async {
    let store = InMemoryConfigurationStore()
    store.standardInput = Data("\(secret)\n".utf8)
    await expect(0, ["config", "set", "api-key", "--stdin"], in: store)
    XCTAssertEqual(store.apiKey, secret, "Trailing newlines from pbpaste or echo are trimmed")
    XCTAssertEqual(store.output, "已把 API Key 存进钥匙串")

    store.files["/tmp/key.txt"] = Data("sk-from-file-1111".utf8)
    await expect(0, ["config", "set", "model=m", "api-key", "--file", "/tmp/key.txt"], in: store)
    XCTAssertEqual(store.apiKey, "sk-from-file-1111")
    XCTAssertEqual(store.output, "已更新 1 项：model\n已把 API Key 存进钥匙串")

    store.environment["PROVIDER_KEY"] = "sk-from-env-2222"
    await expect(0, ["config", "set", "api-key", "--env", "PROVIDER_KEY"], in: store)
    XCTAssertEqual(store.apiKey, "sk-from-env-2222")

    await expect(64, ["config", "set", "api-key", "--env", "MISSING"], in: store)
    XCTAssertEqual(store.errorOutput, "✗ 环境变量 MISSING 不存在或为空\n没有改动任何配置")
    await expect(64, ["config", "set", "api-key", "--file", "/nope"], in: store)
    store.standardInput = Data("\n".utf8)
    await expect(64, ["config", "set", "api-key", "--stdin"], in: store)
    XCTAssertEqual(store.apiKey, "sk-from-env-2222", "Failed reads keep the stored key")
    await expect(64, ["config", "set", "api-key"], in: store)
  }

  func testPromptsAndBodiesCanComeFromFiles() async {
    let store = InMemoryConfigurationStore()
    store.files["prompt.txt"] = Data("Translate like a poet.\n".utf8)
    store.standardInput = Data(#"{"thinking": {"type": "disabled"}}"#.utf8)
    let status = await run(
      ["config", "set", "translation-prompt", "--file", "prompt.txt", "body", "--stdin"], in: store)
    XCTAssertEqual(status, 0)
    XCTAssertEqual(store.settings.translationPrompt, "Translate like a poet.")
    XCTAssertEqual(store.settings.modelService.body["thinking"]?["type"], .string("disabled"))
  }

  func testShowNeverPrintsTheKey() async {
    let store = InMemoryConfigurationStore(settings: .designPreview, apiKey: secret)
    await expect(0, ["config", "show"], in: store)
    XCTAssertEqual(
      store.output,
      """
      endpoint   https://api.deepseek.com/chat/completions
      format     chat-completions
      model      deepseek-chat
      api-key    已保存在钥匙串
      auth       bearer （随 format）
      """)

    await expect(0, ["config", "set", "body={\"temperature\": 0.3}"], in: store)
    await expect(0, ["config", "show"], in: store)
    XCTAssertTrue(store.output.hasSuffix("body       {\"temperature\": 0.3}"), store.output)

    await expect(0, ["config", "show", "--json"], in: store)
    let json = JSONValue.parse(store.output)
    XCTAssertEqual(json?["fields"]?["api-key"], .string("stored"))
    XCTAssertEqual(json?["complete"], .bool(true))
    XCTAssertFalse(store.output.contains(secret))

    let empty = InMemoryConfigurationStore()
    await expect(0, ["config", "show"], in: empty)
    XCTAssertTrue(empty.output.hasPrefix("endpoint   未设置"))
    XCTAssertTrue(empty.output.contains("api-key    未设置"))
  }

  func testUnsetAndResetRestoreDefaults() async {
    let store = InMemoryConfigurationStore(settings: .designPreview, apiKey: secret)
    await expect(0, ["config", "set", "auth=api-key", "launch-at-login=true"], in: store)
    XCTAssertTrue(store.launchAtLogin)
    await expect(0, ["config", "unset", "auth", "api-key"], in: store)
    XCTAssertEqual(store.output, "已恢复默认 2 项：auth、api-key")
    XCTAssertNil(store.settings.modelService.auth)
    XCTAssertNil(store.apiKey)

    await expect(0, ["config", "set", "automatic-updates=false"], in: store)
    XCTAssertFalse(store.automaticUpdates)
    await expect(0, ["config", "reset"], in: store)
    XCTAssertEqual(store.output, "已恢复全部默认")
    XCTAssertTrue(store.settings.modelService.isUnset)
    XCTAssertTrue(store.automaticUpdates)
    XCTAssertFalse(store.launchAtLogin)
  }

  func testLanguagesTakeAnyWordingAndResetToChinese() async {
    let store = InMemoryConfigurationStore()
    await expect(0, ["config", "set", "my-language=粤语", "foreign-language=英式英语"], in: store)
    XCTAssertEqual(store.settings.myLanguage, "粤语")
    XCTAssertEqual(store.settings.foreignLanguage, "英式英语")
    await expect(64, ["config", "set", "my-language="], in: store)
    XCTAssertEqual(store.settings.myLanguage, "粤语", "An empty language is refused")
    await expect(0, ["config", "unset", "my-language"], in: store)
    XCTAssertEqual(store.settings.myLanguage, CidaSettings.defaultLanguages().my)
  }

  func testSchemaListsEveryFieldInJSON() async throws {
    let store = InMemoryConfigurationStore()
    await expect(0, ["config", "schema", "--json"], in: store)
    let fields = try XCTUnwrap(JSONValue.parse(store.output)?["fields"]?.arrayValue)
    XCTAssertEqual(
      fields.compactMap { $0["name"]?.stringValue }, ConfigurationField.allCases.map(\.rawValue))
    let apiKey = try XCTUnwrap(fields.first { $0["name"] == .string("api-key") })
    XCTAssertEqual(apiKey["secret"], .bool(true))
    XCTAssertEqual(
      apiKey["sources"], .array([.string("stdin"), .string("file"), .string("env")]))

    await expect(0, ["config", "schema"], in: store)
    XCTAssertTrue(store.output.contains("chat-completions | responses | anthropic-messages"))
    await expect(0, ["--help"], in: store)
    XCTAssertTrue(store.output.contains("退出码：成功 0；配置不合法 64；检查失败 69"))
  }

  // MARK: - check

  func testCheckRefusesAnIncompleteConfiguration() async {
    let store = InMemoryConfigurationStore(settings: .designPreview)
    await expect(64, ["check"], in: store)
    XCTAssertEqual(store.errorOutput, "✗ 配置还不完整，缺少 api-key；用 Cida config schema 查看字段")
    XCTAssertNil(store.lastCheck)
  }

  func testAPassingCheckReportsTheReplyAndRecordsIt() async throws {
    let server = try LocalModelServiceServer(
      plan: .init(format: .anthropicMessages, chunks: ["你", "好"]))
    defer { server.stop() }
    let store = InMemoryConfigurationStore()
    store.standardInput = Data(secret.utf8)
    await expect(0, [
          "config", "set",
          "endpoint=\(server.endpoint(for: .anthropicMessages).absoluteString)",
          "format=anthropic-messages", "model=claude-test",
        ], in: store)
    await expect(0, ["config", "set", "api-key", "--stdin"], in: store)
    let notificationsBefore = store.notificationCount

    await expect(0, ["check"], in: store)

    let output = store.output
    XCTAssertTrue(output.hasPrefix("✓ 可用 · claude-test · "), output)
    XCTAssertTrue(output.hasSuffix(" 秒 · 回复「你好」"), output)
    let record = try XCTUnwrap(store.lastCheck)
    XCTAssertTrue(record.passed)
    XCTAssertEqual(record.fingerprint, store.settingsWithAPIKey.modelServiceFingerprint)
    XCTAssertEqual(store.notificationCount, notificationsBefore + 1, "The running app hears it")
    XCTAssertEqual(try server.recordedRequest().headers["x-api-key"], secret)
  }

  func testAFailingVerboseCheckShowsTheRequestAndTheProviderTextRedacted() async throws {
    let server = try LocalModelServiceServer(
      plan: .init(
        status: 400,
        errorBody:
          #"{"error": {"message": "Not found the model kimi-k2 or Permission denied ({authorization})", "type": "resource_not_found_error"}}"#
      ))
    defer { server.stop() }
    var settings = CidaSettings()
    settings.modelService = ModelConfiguration(
      endpoint: server.endpoint(for: .chatCompletions).absoluteString, model: "kimi-k2")
    let store = InMemoryConfigurationStore(settings: settings, apiKey: secret)

    await expect(69, ["check", "--verbose"], in: store)

    let endpoint = server.endpoint(for: .chatCompletions).absoluteString
    XCTAssertEqual(
      store.output,
      """
      ✗ 检查失败 · HTTP 400
      POST \(endpoint)
      Authorization: Bearer ••••
      {"model": "kimi-k2", "stream": true, "messages": [ … ]}
      服务商返回：{"error": {"message": "Not found the model kimi-k2 or Permission denied (Bearer ••••)", "type": "resource_not_found_error"}}
      """)
    XCTAssertFalse(store.output.contains(secret))
    let record = try XCTUnwrap(store.lastCheck)
    XCTAssertFalse(record.passed)
    XCTAssertEqual(record.failureSummary, "400 · 服务商拒绝了请求")

    await expect(69, ["check"], in: store)
    XCTAssertEqual(
      store.output,
      "✗ 检查失败 · HTTP 400 · 服务商拒绝了请求\n用 Cida check --verbose 查看实际请求与服务商返回的原文")

    await expect(69, ["check", "--verbose", "--json"], in: store)
    let json = try XCTUnwrap(JSONValue.parse(store.output))
    XCTAssertEqual(json["ok"], .bool(false))
    XCTAssertEqual(json["status"], .integer(400))
    XCTAssertEqual(json["request"]?["headers"]?["Authorization"], .string("Bearer ••••"))
    XCTAssertFalse(store.output.contains(secret))
  }

  func testBodiesAreElidedTheWayTheBoardShowsThem() {
    let chat: JSONValue = .object([
      "model": .string("m"), "stream": .bool(true),
      "messages": .array([.object(["role": .string("user")])]),
      "thinking": .object(["type": .string("disabled")]),
    ])
    XCTAssertEqual(
      CommandLineInterface.elidedBody(chat),
      #"{"model": "m", "stream": true, "messages": [ … ], "thinking": {"type": "disabled"}}"#)
    let anthropic: JSONValue = .object([
      "model": .string("m"), "max_tokens": .integer(8192), "system": .string("long policy"),
      "messages": .array([]),
    ])
    XCTAssertEqual(
      CommandLineInterface.elidedBody(anthropic),
      #"{"model": "m", "max_tokens": 8192, "system": "…", "messages": [ … ]}"#)
  }
}
