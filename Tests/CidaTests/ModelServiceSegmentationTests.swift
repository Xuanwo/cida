import Foundation
import XCTest

@testable import Cida

@MainActor
final class ModelServiceSegmentationTests: XCTestCase {
  func testOnlyExplicitTypedLengthErrorsTriggerSegmentation() {
    for message in ["prompt is too long: 200 tokens > 100 maximum",
      "input length and max_tokens exceed context limit: 200 + 100 > 256",
      "This model's maximum context length is 100 tokens. However, you requested 200 tokens."] {
      let body = JSONValue.object(["error": .object([
        "type": .string("invalid_request_error"), "message": .string(message)])]).compactText
      XCTAssertTrue(ModelServiceError.http(status: 400, providerMessage: nil, body: body).isLengthLimit)
      XCTAssertFalse(ModelServiceError.http(status: 429, providerMessage: nil, body: body).isLengthLimit)
    }
    let ordinary = #"{"error":{"type":"invalid_request_error","message":"max_tokens must be positive"}}"#
    XCTAssertFalse(ModelServiceError.http(status: 400, providerMessage: nil, body: ordinary).isLengthLimit)
    XCTAssertFalse(ModelServiceError.http(status: 400, providerMessage: "input too long", body: "").isLengthLimit)
  }

  func testPartitionPreservesAllSourceAndExtendedGraphemes() throws {
    for text in ["First paragraph.\n\nSecond paragraph.", "你好。接着处理下一句。再下一句。",
      String(repeating: "👨‍👩‍👧‍👦e\u{301}", count: 15), "aaaaaaaaaa", " \n "] {
      let split = try XCTUnwrap(SourcePartition.split(text))
      XCTAssertEqual(split.first + split.separator + split.second, text)
      XCTAssertLessThan(split.first.count, text.count)
      XCTAssertLessThan(split.second.count, text.count)
      XCTAssertFalse(split.first.isEmpty)
      XCTAssertFalse(split.second.isEmpty)
    }
    XCTAssertNil(SourcePartition.split("👨‍👩‍👧‍👦"))
    XCTAssertNil(SourcePartition.split("⟦1234567890⟧", preservingPlaceholders: true))
  }

  func testAllWireFormatsAutomaticallySplitAndKeepOneOrderedResult() async throws {
    let source = (1...8).map { "Paragraph \($0): 保留所有原文与次序，包括 emoji 👨‍👩‍👧‍👦。" }.joined(separator: "\n\n")
    for format in ModelRequestFormat.allCases {
      let server = try LocalModelServiceServer(plan: .init(format: format, delay: 0.001,
        maximumInputBytes: 120, echoInput: true))
      defer { server.stop() }
      let result = try await run(source, settings: settings(server, format: format))
      XCTAssertEqual(result, source)
      let layerResult = try await LayerTranslationRequest.translate([source], into: "English",
        settings: settings(server, format: format), service: ModelServiceClient())
      XCTAssertEqual(layerResult, [source])
      let requests = try server.recordedRequests()
      XCTAssertGreaterThan(requests.count, 2)
      XCTAssertLessThan(requests.count, 80, "Learn a smaller segment size instead of rejecting every sibling")
    }
  }

  func testLengthRecoveryCannotLoopOnAnOversizedPromptOrMinimumUnit() async throws {
    let server = try LocalModelServiceServer(plan: .init(delay: 0, maximumInputBytes: 0, echoInput: true))
    defer { server.stop() }
    do {
      _ = try await run("abc", settings: settings(server))
      XCTFail("A service rejecting even one character cannot complete")
    } catch {
      XCTAssertEqual(error as? ModelServiceError, .lengthRecoveryExhausted)
      XCTAssertEqual(ProcessingFailure.Category.classify(error), .configuration)
    }
    XCTAssertLessThanOrEqual(try server.recordedRequests().count, 3)
  }

  func testOtherFailuresNeverStartSegmentation() async throws {
    let server = try LocalModelServiceServer(plan: .init(status: 503, errorBody: "unavailable", delay: 0))
    defer { server.stop() }
    do {
      _ = try await run(String(repeating: "text ", count: 100), settings: settings(server))
      XCTFail("Expected the original service failure")
    } catch {
      XCTAssertEqual((error as? ModelServiceError)?.statusCode, 503)
    }
    XCTAssertEqual(try server.recordedRequests().count, 1)
  }

  func testCustomActionAssemblesOneStructuredResult() async throws {
    let server = try LocalModelServiceServer(plan: .init(delay: 0.001,
      maximumInputBytes: 160, structuredOutput: true))
    defer { server.stop() }
    var settings = settings(server)
    let action = ProcessingMode(rawValue: "extract")
    settings.actions.append(TextAction(id: action, name: "Extract", prompt: "Return one JSON object with an items array."))
    let source = (1...10).map { "Item\($0) " + String(repeating: "context ", count: 6) }.joined(separator: "\n\n")
    let result = try await run(source, settings: settings, mode: action)
    let document = try XCTUnwrap(JSONValue.parse(result))
    XCTAssertGreaterThan(try XCTUnwrap(document["items"]?.arrayValue).count, 1)
    let requests = try server.recordedRequests()
    XCTAssertTrue(requests.contains { request in
      request["body"]?["messages"]?.arrayValue?.first?["content"]?.stringValue?
        .contains("Result assembly contract:") == true
    })
  }

  func testCancellationStopsTheSegmentSequence() async throws {
    let server = try LocalModelServiceServer(plan: .init(delay: 0.5,
      maximumInputBytes: 20, echoInput: true))
    defer { server.stop() }
    let model = AppModel(settings: settings(server), service: ModelServiceClient())
    model.inputText = String(repeating: "alpha beta. ", count: 12)
    XCTAssertTrue(model.submit())
    let deadline = Date().addingTimeInterval(5)
    while (model.result?.resultUTF16Length ?? 0) == 0, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertGreaterThan(model.result?.resultUTF16Length ?? 0, 0)
    model.cancelProcessing()
    let count = try server.recordedRequests().count
    try await Task.sleep(for: .milliseconds(650))
    XCTAssertEqual(try server.recordedRequests().count, count)
    XCTAssertEqual(model.result?.phase, .stopped)
  }

  func testTranslationLayerSplitsJSONBatchesAndLongParagraphsWithoutLosingIDs() async throws {
    let source = ["One short paragraph.", String(repeating: "Long paragraph. ", count: 12), String(repeating: "a", count: 38) + "⟦123⟧" + String(repeating: "b", count: 38), "Final paragraph."]
    let result = try await LayerTranslationRequest.translate(source, into: "English",
      settings: .designPreview, service: LengthLimitedLayerService())
    XCTAssertEqual(result, source.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
  }

  private func settings(_ server: LocalModelServiceServer, format: ModelRequestFormat = .chatCompletions) -> CidaSettings {
    var settings = CidaSettings.designPreview
    settings.modelService = ModelConfiguration(endpoint: server.endpoint(for: format).absoluteString,
      format: format, model: "test-model")
    return settings
  }

  private func run(_ text: String, settings: CidaSettings, mode: ProcessingMode = .translate) async throws -> String {
    var output = ""
    for try await chunk in ModelServiceClient().stream(ProcessingRequest(text: text, mode: mode,
      myLanguage: "简体中文", foreignLanguage: "English"), settings: settings) {
      output += chunk
    }
    return output
  }
}

private struct LengthLimitedLayerService: TextProcessingService {
  func stream(_ request: ProcessingRequest, settings: CidaSettings) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      do {
        let items = try JSONDecoder().decode([LayerTranslationRequest.Item].self, from: Data(request.text.utf8))
        for item in items {
          guard item.text.filter({ $0 == "⟦" }).count == item.text.filter({ $0 == "⟧" }).count else {
            throw ModelServiceError.unexpectedResponse("A placeholder was split")
          }
        }
        if items.reduce(0, { $0 + $1.text.utf8.count }) > 45 {
          throw ModelServiceError.http(status: 413, providerMessage: nil, body: "")
        }
        continuation.yield(request.text)
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
  }
}
