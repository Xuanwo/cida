import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import Cida

@MainActor
final class StreamingIntegrationTests: XCTestCase {
  func testLocalOpenAIEndpointStreamsLargeInputThroughTheFullModelFlow() async throws {
    let responseChunks = ["Local", " streaming", " response", " complete."]
    let server = try LocalOpenAIStreamingServer(responseChunks: responseChunks)
    defer { server.stop() }

    let largeInput = String(repeating: "Large input paragraph. ", count: 6_000)
    var settings = CidaSettings()
    settings.provider = .openAI
    settings.model = "local-model"
    settings.apiKey = ""
    settings.openAIEndpoint = server.endpoint.absoluteString
    let model = AppModel(
      inputText: largeInput,
      entries: [],
      settings: settings,
      service: OpenAICompatibleTextProcessingService()
    )

    let processing = Task { await model.process(text: largeInput) }
    try await waitUntil { model.entries.last?.result.hasPrefix("Local") == true }
    XCTAssertTrue(model.isProcessing)
    await processing.value

    XCTAssertEqual(model.entries.last?.result, responseChunks.joined())
    XCTAssertEqual(model.entries.last?.state, .completed)
    XCTAssertFalse(model.isProcessing)

    let request = try server.recordedRequest()
    XCTAssertEqual(request.path, "/v1/chat/completions")
    XCTAssertNil(request.authorization)
    XCTAssertEqual(request.body.model, "local-model")
    XCTAssertTrue(request.body.stream)
    XCTAssertEqual(request.body.messages.map(\.role), ["system", "user"])
    XCTAssertEqual(request.body.messages.count, 2)
    XCTAssertFalse(request.body.messages[0].content.contains(largeInput))
    XCTAssertFalse(request.body.messages[0].content.contains("{text}"))
    XCTAssertFalse(request.body.messages[0].content.contains("{target_lang}"))
    XCTAssertTrue(request.body.messages[0].content.contains(#""operation":"translate""#))
    XCTAssertTrue(request.body.messages[0].content.contains(#""source_language":"chinese""#))
    XCTAssertTrue(request.body.messages[0].content.contains(#""target_language":"english""#))
    XCTAssertEqual(request.body.messages.last?.content, largeInput)
  }

  func testRemoteOpenAIEndpointStillRequiresAnAPIKey() async {
    var settings = CidaSettings()
    settings.provider = .openAI
    settings.apiKey = ""
    settings.openAIEndpoint = "https://api.openai.com/v1/chat/completions"
    let model = AppModel(
      inputText: "Draft",
      entries: [],
      settings: settings,
      service: OpenAICompatibleTextProcessingService()
    )

    await model.process(text: "Draft")

    XCTAssertEqual(model.entries.last?.state, .failed)
    XCTAssertEqual(model.errorMessage, TextProcessingError.missingAPIKey.localizedDescription)
  }

  func testHiddenUIRunsSettingsToStreamingCompletionAgainstLocalMock() async throws {
    let responseChunks = ["Visible", " streamed", " result."]
    let server = try LocalOpenAIStreamingServer(responseChunks: responseChunks)
    defer { server.stop() }

    var settings = CidaSettings()
    settings.provider = .openAI
    settings.model = "gpt-5"
    let model = AppModel(
      entries: [],
      settings: settings,
      service: OpenAICompatibleTextProcessingService(),
      saveSettings: { _ in }
    )

    let (settingsWindow, settingsHost) = makeHiddenHost(
      SettingsWindowView(model: model),
      size: CGSize(width: 560, height: 660)
    )
    let endpointField = try XCTUnwrap(
      allTextFields(in: settingsHost).first {
        $0.stringValue == CidaSettings.officialOpenAIEndpoint
      }
    )
    endpointField.stringValue = server.endpoint.absoluteString
    endpointField.delegate?.controlTextDidChange?(
      Notification(name: NSControl.textDidChangeNotification, object: endpointField)
    )
    let modelField = try XCTUnwrap(
      allTextFields(in: settingsHost).first { $0.stringValue == "gpt-5" }
    )
    modelField.stringValue = "mock-local-model"
    modelField.delegate?.controlTextDidChange?(
      Notification(name: NSControl.textDidChangeNotification, object: modelField)
    )
    try await Task.sleep(for: .milliseconds(30))

    let (mainWindow, mainHost) = makeHiddenHost(
      MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    let composer = try XCTUnwrap(
      firstTextView(in: mainHost, identifier: "composer-input")
    )
    let input = String(repeating: "UI large input. ", count: 3_000)
    composer.string = input
    composer.delegate?.textDidChange?(
      Notification(name: NSText.didChangeNotification, object: composer)
    )
    XCTAssertTrue(
      composer.delegate?.textView?(
        composer,
        doCommandBy: #selector(NSResponder.insertNewline(_:))
      ) == true
    )

    try await waitUntil { model.entries.last?.result.hasPrefix("Visible") == true }
    XCTAssertEqual(model.entries.last?.state, .streaming)
    try await waitUntil { model.entries.last?.state == .completed }
    XCTAssertEqual(model.entries.last?.result, responseChunks.joined())
    XCTAssertEqual(model.entries.last?.source, input)
    XCTAssertEqual(try server.recordedRequest().body.model, "mock-local-model")
    XCTAssertFalse(NSApp.isActive)
    XCTAssertNotEqual(
      NSWorkspace.shared.frontmostApplication?.processIdentifier,
      ProcessInfo.processInfo.processIdentifier
    )
    withExtendedLifetime((settingsWindow, settingsHost, mainWindow, mainHost)) {}
  }

  func testSubmittingFromDetachedHistoryFollowsNewStreamThroughCompletion() async throws {
    let responseChunks = (0..<30).map { index in
      "Streamed line \(index) stays visible while the response grows.\n"
    }
    let server = try LocalOpenAIStreamingServer(responseChunks: responseChunks)
    defer { server.stop() }

    var settings = CidaSettings()
    settings.provider = .openAI
    settings.model = "follow-regression-model"
    settings.openAIEndpoint = server.endpoint.absoluteString
    let existingEntries = (0..<24).map { index in
      HistoryEntry(
        mode: .translate,
        source: "Existing source \(index)",
        result: "Existing result \(index)\nwith enough content to fill history",
        detail: "中文 → English",
        timestamp: "17:30"
      )
    }
    let model = AppModel(
      entries: existingEntries,
      settings: settings,
      service: OpenAICompatibleTextProcessingService(),
      streamPresentationPolicy: .fastTests
    )
    let (window, host) = makeHiddenHost(
      MainWindowView(
        model: model,
        automaticallyFocusInput: false,
        animatesHistoryTransitions: false
      ),
      size: CGSize(width: 860, height: 640)
    )
    let historyScrollView = try XCTUnwrap(outerHistoryScrollView(in: host))
    historyScrollView.contentView.scroll(to: .zero)
    historyScrollView.reflectScrolledClipView(historyScrollView.contentView)
    NotificationCenter.default.post(
      name: NSScrollView.didLiveScrollNotification,
      object: historyScrollView
    )
    XCTAssertFalse(isScrolledToBottom(historyScrollView))

    let composer = try XCTUnwrap(
      firstTextView(in: host, identifier: "composer-input")
    )
    let submittedDocument = String(
      repeating: "A submitted line that expands the composer before sending.\n",
      count: 24
    )
    composer.string = submittedDocument
    composer.delegate?.textDidChange?(
      Notification(name: NSText.didChangeNotification, object: composer)
    )
    try await waitUntil(timeout: .seconds(2)) {
      (composer.enclosingScrollView?.frame.height ?? 0) >= 150
    }
    XCTAssertGreaterThanOrEqual(composer.enclosingScrollView?.frame.height ?? 0, 150)
    XCTAssertTrue(
      composer.delegate?.textView?(
        composer,
        doCommandBy: #selector(NSResponder.insertNewline(_:))
      ) == true
    )

    try await waitUntil(timeout: .seconds(8)) {
      model.entries.last?.result.contains("Streamed line 10") == true
    }
    try await waitUntil(timeout: .seconds(2)) {
      let currentComposer = self.firstTextView(in: host, identifier: "composer-input")
      return currentComposer?.string.isEmpty == true
        && (currentComposer?.enclosingScrollView?.frame.height ?? .greatestFiniteMagnitude) <= 27.5
    }
    let resetComposer = try XCTUnwrap(
      firstTextView(in: host, identifier: "composer-input")
    )
    XCTAssertEqual(model.entries.last?.source, submittedDocument)
    XCTAssertTrue(resetComposer.string.isEmpty)
    XCTAssertEqual(resetComposer.enclosingScrollView?.frame.height ?? 0, 27, accuracy: 0.5)
    XCTAssertTrue(isScrolledToBottom(historyScrollView), scrollDescription(historyScrollView))

    try await waitUntil(timeout: .seconds(8)) {
      model.entries.last?.state == .completed
    }
    try await waitUntil(timeout: .seconds(2)) {
      self.isScrolledToBottom(historyScrollView)
    }
    let entryID = try XCTUnwrap(model.entries.last?.id)
    let resultTextView = try XCTUnwrap(
      firstTextView(in: host, identifier: "history-result-\(entryID.uuidString)")
    )
    let resultContainer = try XCTUnwrap(
      resultTextView.superview as? HistoryResultTextContainer
    )
    let resultFrameInHost = resultContainer.convert(resultContainer.bounds, to: host)
    let historyViewportInHost = historyScrollView.contentView.convert(
      historyScrollView.contentView.bounds,
      to: host
    )
    let visibleResultFrame = resultFrameInHost.intersection(historyViewportInHost)

    XCTAssertTrue(isScrolledToBottom(historyScrollView), scrollDescription(historyScrollView))
    XCTAssertTrue(resultTextView.enclosingScrollView === historyScrollView)
    XCTAssertTrue(allScrollViews(in: resultContainer).isEmpty)
    XCTAssertGreaterThan(visibleResultFrame.height, 20)
    XCTAssertFalse(NSApp.isActive)
    XCTAssertNotEqual(
      NSWorkspace.shared.frontmostApplication?.processIdentifier,
      ProcessInfo.processInfo.processIdentifier
    )
    withExtendedLifetime((window, host)) {}
  }

  private func waitUntil(
    timeout: Duration = .seconds(3),
    condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      if clock.now >= deadline {
        XCTFail("Timed out waiting for condition", file: file, line: line)
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func makeHiddenHost<Content: View>(
    _ rootView: Content,
    size: CGSize
  ) -> (CidaWindow, NSHostingView<Content>) {
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: size)
    let window = CidaWindow(
      contentRect: hostingView.frame,
      styleMask: [.borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.contentView = hostingView
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    return (window, hostingView)
  }

  private func allTextFields(in view: NSView) -> [NSTextField] {
    var fields: [NSTextField] = []
    if let field = view as? NSTextField {
      fields.append(field)
    }
    for child in view.subviews {
      fields.append(contentsOf: allTextFields(in: child))
    }
    return fields
  }

  private func outerHistoryScrollView(in view: NSView) -> NSScrollView? {
    allScrollViews(in: view)
      .max { $0.frame.height < $1.frame.height }
  }

  private func allScrollViews(in view: NSView) -> [NSScrollView] {
    var scrollViews: [NSScrollView] = []
    if let scrollView = view as? NSScrollView {
      scrollViews.append(scrollView)
    }
    for child in view.subviews {
      scrollViews.append(contentsOf: allScrollViews(in: child))
    }
    return scrollViews
  }

  private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
    guard let documentView = scrollView.documentView else { return false }
    let visibleRect = scrollView.contentView.documentVisibleRect
    if documentView.isFlipped {
      return visibleRect.maxY >= documentView.bounds.maxY - 24
    }
    return visibleRect.minY <= documentView.bounds.minY + 24
  }

  private func scrollDescription(_ scrollView: NSScrollView) -> String {
    guard let documentView = scrollView.documentView else { return "missing document view" }
    return
      "visible=\(scrollView.contentView.documentVisibleRect) document=\(documentView.bounds) flipped=\(documentView.isFlipped) frame=\(scrollView.frame)"
  }

  private func firstTextView(in view: NSView, identifier: String) -> NSTextView? {
    if let textView = view as? NSTextView,
      textView.accessibilityIdentifier() == identifier
    {
      return textView
    }
    if let container = view as? HistoryResultTextContainer,
      container.subviews.contains(where: {
        $0.accessibilityIdentifier() == identifier
      })
    {
      return container.textView
    }
    for child in view.subviews {
      if let result = firstTextView(in: child, identifier: identifier) {
        return result
      }
    }
    return nil
  }
}

@MainActor
private final class LocalOpenAIStreamingServer {
  struct RecordedRequest: Decodable {
    struct Body: Decodable {
      struct Message: Decodable {
        let role: String
        let content: String
      }

      let model: String
      let messages: [Message]
      let stream: Bool
    }

    let path: String
    let authorization: String?
    let body: Body
  }

  let endpoint: URL

  private let process: Process
  private let recordURL: URL

  init(responseChunks: [String]) throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/openai_stream_mock.py")
    recordURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("cida-openai-request-\(UUID().uuidString).json")

    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      fixtureURL.path,
      recordURL.path,
      String(data: try JSONEncoder().encode(responseChunks), encoding: .utf8)!,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    self.process = process

    let data = output.fileHandleForReading.availableData
    guard
      let line = String(data: data, encoding: .utf8)?
        .split(separator: "\n", maxSplits: 1)
        .first,
      let port = Int(line)
    else {
      process.terminate()
      throw MockServerError.failedToStart
    }
    endpoint = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
  }

  func recordedRequest() throws -> RecordedRequest {
    let data = try Data(contentsOf: recordURL)
    return try JSONDecoder().decode(RecordedRequest.self, from: data)
  }

  func stop() {
    guard process.isRunning else { return }
    process.terminate()
    process.waitUntilExit()
    try? FileManager.default.removeItem(at: recordURL)
  }

  private enum MockServerError: Error {
    case failedToStart
  }
}
