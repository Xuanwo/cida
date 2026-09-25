import XCTest

@testable import Cida

final class ModelServiceTests: XCTestCase {
  private let prompt = ModelPrompt(
    systemMessage: "SYSTEM",
    userMessage: "hello",
    parameters: ModelTaskParameters(
      request: ProcessingRequest(
        text: "hello", mode: .translate, myLanguage: "简体中文", foreignLanguage: "English"))
  )

  private func service(
    _ format: ModelRequestFormat, endpoint: String = "https://api.example.com/v1/x"
  ) -> ModelConfiguration {
    ModelConfiguration(endpoint: endpoint, format: format, model: "m")
  }

  private func headers(_ request: PreparedModelRequest) -> [String: String] {
    request.urlRequest.allHTTPHeaderFields ?? [:]
  }

  // MARK: - Request

  func testChatCompletionsBodyIsModelStreamMessagesWithABearerKey() throws {
    let request = try ModelRequestBuilder.build(
      prompt: prompt, configuration: service(.chatCompletions), apiKey: "sk-secret-1234")
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(
      request.body.compactText,
      #"{"model":"m","stream":true,"messages":[{"role":"system","content":"SYSTEM"},{"role":"user","content":"hello"}]}"#
    )
    XCTAssertEqual(String(decoding: request.urlRequest.httpBody!, as: UTF8.self), request.body.compactText)
    XCTAssertEqual(headers(request)["Authorization"], "Bearer sk-secret-1234")
    XCTAssertEqual(headers(request)["Content-Type"], "application/json")
    XCTAssertEqual(headers(request)["Accept"], "text/event-stream")
    XCTAssertEqual(request.displayHeaders, [.init(name: "Authorization", value: "Bearer ••••")])
  }

  func testResponsesBodyCarriesInstructionsAndInput() throws {
    let request = try ModelRequestBuilder.build(
      prompt: prompt, configuration: service(.responses), apiKey: "sk-secret-1234")
    XCTAssertEqual(
      request.body.compactText,
      #"{"model":"m","stream":true,"store":false,"instructions":"SYSTEM","input":[{"role":"user","content":"hello"}]}"#
    )
    XCTAssertEqual(headers(request)["Authorization"], "Bearer sk-secret-1234")
  }

  func testAnthropicMessagesSendsSystemMaxTokensVersionAndXAPIKey() throws {
    let request = try ModelRequestBuilder.build(
      prompt: prompt, configuration: service(.anthropicMessages), apiKey: "sk-ant-secret")
    XCTAssertEqual(
      request.body.compactText,
      #"{"model":"m","max_tokens":8192,"stream":true,"system":"SYSTEM","messages":[{"role":"user","content":"hello"}]}"#
    )
    XCTAssertEqual(headers(request)["x-api-key"], "sk-ant-secret")
    XCTAssertNil(headers(request)["Authorization"])
    XCTAssertEqual(headers(request)["anthropic-version"], "2023-06-01")
    XCTAssertEqual(
      request.displayHeaders,
      [.init(name: "x-api-key", value: "••••"), .init(name: "anthropic-version", value: "2023-06-01")])
  }

  func testAuthHeadersFollowTheSetting() throws {
    var configuration = service(.chatCompletions)
    configuration.auth = .apiKey
    var request = try ModelRequestBuilder.build(
      prompt: prompt, configuration: configuration, apiKey: "azure-key")
    XCTAssertEqual(headers(request)["api-key"], "azure-key")
    XCTAssertNil(headers(request)["Authorization"])

    configuration.auth = ModelAuthentication.none
    request = try ModelRequestBuilder.build(
      prompt: prompt, configuration: configuration, apiKey: "unused-key")
    XCTAssertNil(headers(request)["api-key"])
    XCTAssertNil(headers(request)["Authorization"])

    configuration.auth = .bearer
    request = try ModelRequestBuilder.build(prompt: prompt, configuration: configuration, apiKey: "")
    XCTAssertNil(headers(request)["Authorization"], "No key, no header")
  }

  func testExtraHeadersReplaceCidasOwnAndBodyMergesDeeply() throws {
    var configuration = service(.anthropicMessages)
    configuration.headers = ["anthropic-version": "2024-01-01", "X-Title": "Cida"]
    configuration.body = [
      "max_tokens": .integer(1024),
      "thinking": .object(["type": .string("disabled")]),
      "stream": .null,
    ]
    let request = try ModelRequestBuilder.build(
      prompt: prompt, configuration: configuration, apiKey: "k-1234")
    XCTAssertEqual(headers(request)["anthropic-version"], "2024-01-01")
    XCTAssertEqual(headers(request)["X-Title"], "Cida")
    XCTAssertEqual(
      request.displayHeaders.map(\.name), ["x-api-key", "anthropic-version", "X-Title"])
    XCTAssertEqual(request.body["max_tokens"], .integer(1024))
    XCTAssertEqual(request.body["thinking"]?["type"], .string("disabled"))
    XCTAssertNil(request.body["stream"], "null removes a member")
    XCTAssertEqual(request.body["system"], .string("SYSTEM"))
  }

  func testMergingIsRecursiveForObjectsAndReplacesEverythingElse() {
    let base: JSONValue = .object([
      "a": .object(["x": .integer(1), "y": .integer(2)]), "b": .array([.integer(1)]),
    ])
    let merged = base.merging(
      .object(["a": .object(["y": .integer(3)]), "b": .array([.integer(2)]), "c": .bool(true)]))
    XCTAssertEqual(
      merged,
      .object([
        "a": .object(["x": .integer(1), "y": .integer(3)]), "b": .array([.integer(2)]),
        "c": .bool(true),
      ]))
  }

  func testIncompleteConfigurationIsRefusedBeforeAnyRequest() {
    var settings = CidaSettings.designPreview
    settings.apiKey = ""
    XCTAssertThrowsError(
      try ModelServiceClient.prepare(
        ProcessingRequest(
          text: "x", mode: .translate, myLanguage: "简体中文", foreignLanguage: "English"),
        settings: settings)
    ) { error in
      XCTAssertEqual(error as? ModelServiceError, .incompleteConfiguration(missing: ["api-key"]))
    }
  }

  // MARK: - Response parsing

  func testServerSentEventsJoinDataLinesAndSkipComments() {
    var parser = ServerSentEventParser()
    XCTAssertNil(parser.consume(line: ": comment"))
    XCTAssertNil(parser.consume(line: "event: message_start"))
    XCTAssertNil(parser.consume(line: "data: {\"a\":"))
    XCTAssertNil(parser.consume(line: "data:1}"))
    XCTAssertEqual(
      parser.consume(line: ""), ServerSentEvent(name: "message_start", data: "{\"a\":\n1}"))
    XCTAssertNil(parser.consume(line: ""), "An empty line alone dispatches nothing")
    XCTAssertNil(parser.consume(line: "data: [DONE]"))
    XCTAssertEqual(parser.finish(), ServerSentEvent(name: nil, data: "[DONE]"))
  }

  func testEachFormatReadsItsOwnTextEvents() {
    func event(_ data: String, _ name: String? = nil) -> ServerSentEvent {
      ServerSentEvent(name: name, data: data)
    }
    let chat = ModelRequestFormat.chatCompletions
    XCTAssertEqual(chat.streamEvent(from: event(#"{"choices":[{"delta":{"content":"你"}}]}"#)), .text("你"))
    XCTAssertEqual(chat.streamEvent(from: event(#"{"choices":[{"delta":{"role":"assistant"}}]}"#)), .recognized)
    XCTAssertEqual(chat.streamEvent(from: event("[DONE]")), .done)
    XCTAssertEqual(chat.streamEvent(from: event(#"{"error":{"message":"boom"}}"#)), .failure("boom"))
    XCTAssertEqual(chat.streamEvent(from: event(#"{"type":"message_start"}"#)), .unrecognized)

    let responses = ModelRequestFormat.responses
    XCTAssertEqual(
      responses.streamEvent(from: event(#"{"type":"response.output_text.delta","delta":"好"}"#)),
      .text("好"))
    XCTAssertEqual(responses.streamEvent(from: event(#"{"type":"response.created"}"#)), .recognized)
    XCTAssertEqual(responses.streamEvent(from: event(#"{"type":"response.completed"}"#)), .done)
    XCTAssertEqual(
      responses.streamEvent(
        from: event(#"{"type":"response.failed","response":{"error":{"message":"quota"}}}"#)),
      .failure("quota"))

    let anthropic = ModelRequestFormat.anthropicMessages
    XCTAssertEqual(
      anthropic.streamEvent(
        from: event(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}"#)),
      .text("你好"))
    XCTAssertEqual(
      anthropic.streamEvent(
        from: event(#"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"…"}}"#)),
      .recognized, "Reasoning is not part of the reply")
    XCTAssertEqual(anthropic.streamEvent(from: event(#"{"type":"message_stop"}"#)), .done)
    XCTAssertEqual(
      anthropic.streamEvent(from: event(#"{"type":"error","error":{"message":"overloaded"}}"#)),
      .failure("overloaded"))
  }

  func testEachFormatReadsItsCompleteReply() throws {
    XCTAssertEqual(
      ModelRequestFormat.chatCompletions.completeReply(
        in: try XCTUnwrap(JSONValue.parse(#"{"choices":[{"message":{"content":"你好"}}]}"#))),
      "你好")
    XCTAssertEqual(
      ModelRequestFormat.responses.completeReply(
        in: try XCTUnwrap(
          JSONValue.parse(
            #"{"output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"你好"}]}]}"#
          ))),
      "你好")
    XCTAssertEqual(
      ModelRequestFormat.anthropicMessages.completeReply(
        in: try XCTUnwrap(
          JSONValue.parse(#"{"content":[{"type":"thinking"},{"type":"text","text":"你好"}]}"#))),
      "你好")
    XCTAssertNil(
      ModelRequestFormat.anthropicMessages.completeReply(
        in: try XCTUnwrap(JSONValue.parse(#"{"choices":[]}"#))))
  }

  // MARK: - Redaction

  func testRedactionReplacesTheKeyInEveryFormItCanTake() {
    let redactor = SecretRedactor(secret: "sk-a/b\"c-1234")
    XCTAssertEqual(redactor.redact("Bearer sk-a/b\"c-1234"), "Bearer ••••")
    XCTAssertEqual(redactor.redact(#"{"key":"sk-a\/b\"c-1234"}"#), #"{"key":"••••"}"#)
    XCTAssertEqual(redactor.redact(#"{"key":"sk-a/b\"c-1234"}"#), #"{"key":"••••"}"#)
    XCTAssertEqual(redactor.redact("?key=sk-a/b%22c-1234"), "?key=••••")
    XCTAssertEqual(SecretRedactor(secret: "").redact("text"), "text")
    XCTAssertEqual(SecretRedactor(secret: "ab").redact("abc"), "abc", "Too short to be a key")
  }

  // MARK: - Against a local service

  private func settings(for server: LocalModelServiceServer, format: ModelRequestFormat)
    -> CidaSettings
  {
    var settings = CidaSettings()
    settings.modelService = ModelConfiguration(
      endpoint: server.endpoint(for: format).absoluteString, format: format, model: "mock-model")
    settings.apiKey = "sk-local-secret-9876"
    return settings
  }

  private func streamedText(_ settings: CidaSettings, text: String = "hello") async throws -> String
  {
    var result = ""
    for try await chunk in ModelServiceClient().stream(
      ProcessingRequest(
        text: text, mode: .translate, myLanguage: "简体中文", foreignLanguage: "English"),
      settings: settings)
    {
      result += chunk
    }
    return result
  }

  func testEveryFormatStreamsAndAnswersInOnePieceAgainstALocalService() async throws {
    for format in ModelRequestFormat.allCases {
      for stream in [true, false] {
        let server = try LocalModelServiceServer(
          plan: .init(format: format, chunks: ["你", "好", "。"], stream: stream, delay: 0.01))
        defer { server.stop() }

        let text = try await streamedText(settings(for: server, format: format))
        XCTAssertEqual(text, "你好。", "\(format) stream=\(stream)")

        let request = try server.recordedRequest()
        XCTAssertEqual(request.body["model"], .string("mock-model"))
        XCTAssertEqual(request.body["stream"], .bool(true))
        switch format {
        case .chatCompletions:
          XCTAssertEqual(request.path, "/v1/chat/completions")
          XCTAssertEqual(request.headers["authorization"], "Bearer sk-local-secret-9876")
        case .responses:
          XCTAssertEqual(request.path, "/v1/responses")
          XCTAssertEqual(request.body["input"]?.arrayValue?.first?["content"], .string("hello"))
          XCTAssertNotNil(request.body["instructions"]?.stringValue)
        case .anthropicMessages:
          XCTAssertEqual(request.path, "/v1/messages")
          XCTAssertEqual(request.headers["x-api-key"], "sk-local-secret-9876")
          XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
          XCTAssertEqual(request.body["max_tokens"], .integer(8192))
          XCTAssertNotNil(request.body["system"]?.stringValue)
        }
      }
    }
  }

  func testHTTPErrorsCarryTheStatusAndTheProviderTextWithTheKeyRedacted() async throws {
    let server = try LocalModelServiceServer(
      plan: .init(
        status: 401,
        errorBody: #"{"error":{"message":"Invalid key {authorization}","type":"auth"}}"#))
    defer { server.stop() }

    do {
      _ = try await streamedText(settings(for: server, format: .chatCompletions))
      XCTFail("A 401 fails")
    } catch let error as ModelServiceError {
      XCTAssertEqual(error.statusCode, 401)
      XCTAssertEqual(error.reason, "服务商拒绝了 API Key")
      XCTAssertEqual(error.localizedDescription, "Invalid key Bearer ••••")
      XCTAssertEqual(
        error.providerText, #"{"error":{"message":"Invalid key Bearer ••••","type":"auth"}}"#)
    }
  }

  func testErrorEventsInAStreamFailTheRequest() async throws {
    for format in ModelRequestFormat.allCases {
      let server = try LocalModelServiceServer(
        plan: .init(format: format, chunks: ["部分"], streamError: "overloaded sk-local-secret-9876"))
      defer { server.stop() }
      do {
        _ = try await streamedText(settings(for: server, format: format))
        XCTFail("\(format): an error event fails the request")
      } catch let error as ModelServiceError {
        XCTAssertEqual(error, .provider(message: "overloaded ••••"), "\(format)")
      }
    }
  }

  func testAStreamInAnotherFormatIsReportedAsAFormatMismatch() async throws {
    let server = try LocalModelServiceServer(
      plan: .init(format: .anthropicMessages, chunks: ["你好"]))
    defer { server.stop() }
    var settings = settings(for: server, format: .anthropicMessages)
    settings.modelService.format = .responses

    let result = await ModelServiceCheck.run(settings: settings)

    XCTAssertFalse(result.passed)
    XCTAssertEqual(result.failure?.reason, "返回的格式与 format 不符")
    XCTAssertEqual(result.responseStatus, 200)
    XCTAssertTrue(result.responseBody.contains("content_block_delta"), "The raw stream is kept")
  }

  func testCheckReportsTheReplyDurationAndARecordForThisConfiguration() async throws {
    let server = try LocalModelServiceServer(plan: .init(format: .responses, chunks: ["你", "好"]))
    defer { server.stop() }
    let settings = settings(for: server, format: .responses)

    let result = await ModelServiceCheck.run(settings: settings)

    XCTAssertTrue(result.passed)
    XCTAssertEqual(result.reply, "你好")
    XCTAssertGreaterThan(result.duration, 0)
    XCTAssertEqual(result.record.fingerprint, settings.modelServiceFingerprint)
    XCTAssertTrue(result.record.passed)
    XCTAssertEqual(try server.recordedRequest().body["input"]?.arrayValue?.first?["content"], .string("hello"))
  }

  func testUnreachableServicesFailWithoutAStatus() async {
    var settings = CidaSettings()
    settings.modelService = ModelConfiguration(
      endpoint: "http://127.0.0.1:9/v1/chat/completions", model: "m")
    let result = await ModelServiceCheck.run(settings: settings)
    XCTAssertFalse(result.passed)
    XCTAssertNil(result.record.statusCode)
    XCTAssertEqual(result.record.failureSummary, "连不上服务")
  }
}
