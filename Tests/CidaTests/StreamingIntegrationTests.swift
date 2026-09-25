import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import Cida

@MainActor
final class StreamingIntegrationTests: XCTestCase {
  func testLocalOpenAIEndpointStreamsLargeInputThroughTheFullModelFlow() async throws {
    let responseChunks = ["Local", " streaming", " response", " complete."]
    let server = try LocalModelServiceServer(plan: .init(chunks: responseChunks, delay: 0.05))
    defer { server.stop() }

    let largeInput = String(repeating: "Large input paragraph. ", count: 6_000)
    var settings = CidaSettings()
    settings.modelService.endpoint = server.endpoint(for: .chatCompletions).absoluteString
    settings.modelService.model = "local-model"
    let model = AppModel(
      inputText: largeInput,
      settings: settings,
      service: ModelServiceClient()
    )

    let processing = Task { await model.process(text: largeInput) }
    try await waitUntil { model.result?.result.hasPrefix("Local") == true }
    XCTAssertTrue(model.isProcessing)
    await processing.value

    XCTAssertEqual(model.result?.result, responseChunks.joined())
    XCTAssertEqual(model.result?.phase, .completed)
    XCTAssertFalse(model.isProcessing)

    let request = try server.recordedRequest()
    XCTAssertEqual(request.path, "/v1/chat/completions")
    XCTAssertNil(request.headers["authorization"], "A local endpoint runs without a key")
    XCTAssertEqual(request.body["model"], .string("local-model"))
    XCTAssertEqual(request.body["stream"], .bool(true))
    let messages = try XCTUnwrap(request.body["messages"]?.arrayValue)
    XCTAssertEqual(messages.map { $0["role"]?.stringValue }, ["system", "user"])
    let system = try XCTUnwrap(messages[0]["content"]?.stringValue)
    XCTAssertFalse(system.contains(largeInput))
    XCTAssertFalse(system.contains("{text}"))
    XCTAssertFalse(system.contains("{target_lang}"))
    XCTAssertTrue(system.contains(#""operation":"translate""#))
    XCTAssertTrue(
      system.contains(#""source_language":"english""#),
      "The source language is detected from the text")
    XCTAssertTrue(system.contains(#""target_language":"chinese""#))
    XCTAssertEqual(messages.last?["content"]?.stringValue, largeInput)
  }

  func testRemoteEndpointStillRequiresAnAPIKey() async {
    var settings = CidaSettings.designPreview
    settings.apiKey = ""
    let model = AppModel(
      inputText: "Draft",
      settings: settings,
      service: ModelServiceClient()
    )

    await model.process(text: "Draft")

    XCTAssertEqual(
      model.result?.phase,
      .failed(
        message: ModelServiceError.incompleteConfiguration(missing: ["api-key"])
          .localizedDescription)
    )
    XCTAssertEqual(model.resultNote?.kind, .failed)
  }

  /// The command line configures the service, the running model takes the change as it
  /// would from the change notification, and the hidden panel streams from the new endpoint.
  func testHiddenUIStreamsFromAServiceTheCommandLineConfigured() async throws {
    let responseChunks = ["Visible", " streamed", " result."]
    let server = try LocalModelServiceServer(
      plan: .init(format: .responses, chunks: responseChunks, delay: 0.05))
    defer { server.stop() }

    let store = InMemoryConfigurationStore()
    let model = AppModel(
      settings: store.settings,
      service: ModelServiceClient(),
      saveSettings: { _ in }
    )
    XCTAssertFalse(model.isModelServiceConfigured)
    let status = await CommandLineInterface.run(
      [
        "config", "set", "endpoint=\(server.endpoint(for: .responses).absoluteString)",
        "format=responses", "model=mock-local-model",
      ],
      context: store.context()
    )
    XCTAssertEqual(status, 0)
    XCTAssertEqual(store.notificationCount, 1)
    model.applyExternalSettings(store.settingsWithAPIKey, lastCheck: store.lastCheck)
    XCTAssertTrue(model.isModelServiceConfigured)
    XCTAssertTrue(model.isModelServiceRecentlyUpdated)

    let (mainWindow, mainHost) = makeHiddenHost(
      PanelView(model: model, heightBudget: .automation),
      size: CGSize(width: 800, height: 400)
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

    try await waitUntil { model.result?.result.hasPrefix("Visible") == true }
    XCTAssertEqual(model.result?.phase, .streaming)
    try await waitUntil { model.result?.phase == .completed }
    XCTAssertEqual(model.result?.result, responseChunks.joined())
    XCTAssertEqual(model.result?.source, input)
    let request = try server.recordedRequest()
    XCTAssertEqual(request.path, "/v1/responses")
    XCTAssertEqual(request.body["model"], .string("mock-local-model"))
    XCTAssertFalse(NSApp.isActive)
    XCTAssertNotEqual(
      NSWorkspace.shared.frontmostApplication?.processIdentifier,
      ProcessInfo.processInfo.processIdentifier
    )
    withExtendedLifetime((mainWindow, mainHost)) {}
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
    if let container = view as? ResultTextContainer,
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
