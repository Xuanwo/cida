import AppKit
import XCTest

@testable import Cida

@MainActor
final class ProcessingFailureTests: XCTestCase {
  func testRecoveryCategoriesUseStatusAndStructuredCodesNotProviderProse() {
    func http(_ status: Int, _ body: String = "") -> ModelServiceError {
      .http(status: status, providerMessage: "private source and key", body: body)
    }
    for status in [401, 403, 404] {
      XCTAssertEqual(ProcessingFailure.Category.classify(http(status)), .configuration)
    }
    XCTAssertEqual(ProcessingFailure.Category.classify(http(429)), .limited)
    XCTAssertEqual(ProcessingFailure.Category.classify(http(413)), .configuration)
    XCTAssertEqual(ProcessingFailure.Category.classify(http(400,
      #"{"error":{"code":"context_length_exceeded"}}"#)), .configuration)
    XCTAssertEqual(ProcessingFailure.Category.classify(http(400, "input is too long")), .unknown)
    XCTAssertEqual(ProcessingFailure.Category.classify(http(500)), .unknown)
    XCTAssertEqual(ProcessingFailure.Category.classify(URLError(.timedOut)), .timeout)
    XCTAssertEqual(ProcessingFailure.Category.classify(ModelServiceError.transport(URLError(.networkConnectionLost))), .offline)
    XCTAssertEqual(ProcessingFailure.Category.classify(URLError(.serverCertificateHasUnknownRoot)), .secureConnection)
    XCTAssertEqual(ProcessingFailure.Category.classify(ModelServiceError.unexpectedResponse("private")), .configuration)
  }

  func testConfigurationFailureBlocksSubmitUntilSettingsOrInputChange() async {
    let model = failedModel(.configuration)
    let original = model.result
    let settings = model.settings
    XCTAssertEqual(model.barActionPresentation, .modelSettings)
    XCTAssertFalse(model.submit())
    XCTAssertTrue(model.result === original)
    model.settings.apiKey = "updated-key"
    XCTAssertTrue(model.failureConfigurationChanged)
    XCTAssertEqual(model.barActionPresentation, .retry)
    XCTAssertTrue(model.canSubmit)
    model.settings = settings
    XCTAssertFalse(model.canSubmit, "Restoring the failed configuration restores its recovery state")
    model.inputText = "Different source"
    XCTAssertEqual(model.barActionPresentation, .execute)
    XCTAssertTrue(model.canSubmit)
    XCTAssertTrue(model.failureExplanation?.contains("上次请求") == true)
    model.inputText = "Original source"
    XCTAssertFalse(model.canSubmit)
    model.setMode(.improve)
    XCTAssertTrue(model.canSubmit)
    model.setMode(.translate)
    XCTAssertFalse(model.canSubmit)
    model.inputText = ""
    XCTAssertFalse(model.canSubmit)
    XCTAssertTrue(model.canCopyResult)
  }

  func testTransientFailuresCanRetry() {
    for category in [ProcessingFailure.Category.timeout, .offline, .limited, .secureConnection, .unknown] {
      let retry = failedModel(category)
      XCTAssertEqual(retry.barActionPresentation, .retry)
      XCTAssertTrue(retry.canSubmit)
    }
  }

  func testAgentHandoffIncludesOnlySafeCurrentFailureContext() {
    let model = failedModel(.configuration)
    XCTAssertTrue(model.configurationPrompt.contains("面板请求未完成"))
    XCTAssertTrue(model.configurationPrompt.contains("configuration"))
    XCTAssertTrue(model.configurationPrompt.contains("不是一次连接检查"))
    XCTAssertFalse(model.configurationPrompt.contains("Original source"))
    XCTAssertFalse(model.configurationPrompt.contains("Partial output"))
    XCTAssertFalse(model.configurationPrompt.contains(model.settings.apiKey))
    XCTAssertNil(model.currentModelServiceCheck, "Panel failures are not connection checks")
    model.settings.modelService.model = "a-new-model"
    XCTAssertFalse(model.configurationPrompt.contains("面板请求未完成"), "An old configuration's failure cannot diagnose the new one")
  }

  func testIncompleteImageMarksTheDisplayedResultAndTextCopyRemainsVerbatim() throws {
    let pasteboard = NSPasteboard(name: .init("io.xuanwo.cida.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let record = ResultRecord(mode: .translate, source: "Original", outputLanguage: .english,
      result: "Partial", phase: .stopped)
    let model = AppModel(inputText: "Changed", result: record, pasteboard: pasteboard)
    for phase in [ResultPhase.stopped, .failed(ProcessingFailure(category: .timeout, settings: model.settings))] {
      record.phase = phase
      XCTAssertTrue(model.copyResult())
      XCTAssertEqual(pasteboard.string(forType: .string), "Partial")
      XCTAssertTrue(model.copyResultImage())
      let expected = try ShareCard.render(source: "Original", result: "Partial", language: .english,
        incomplete: phase.incompleteMark).get()
      XCTAssertEqual(pasteboard.data(forType: .png), expected.png)
      XCTAssertNil(pasteboard.string(forType: .string))
      let complete = try ShareCard.render(source: "Original", result: "Partial", language: .english).get()
      XCTAssertGreaterThan(expected.size.height, complete.size.height)
      XCTAssertNotEqual(expected.png, complete.png)
    }
  }

  private func failedModel(_ category: ProcessingFailure.Category) -> AppModel {
    let settings = CidaSettings.designPreview
    let record = ResultRecord(mode: .translate, source: "Original source", outputLanguage: .english,
      result: "Partial output", phase: .failed(ProcessingFailure(category: category, settings: settings)))
    return AppModel(inputText: record.source, result: record, settings: settings)
  }
}
