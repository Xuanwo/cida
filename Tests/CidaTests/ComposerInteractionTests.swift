import AppKit
import QuartzCore
import SwiftUI
import XCTest

@testable import Cida

@MainActor
extension InteractionReproductionTests {
  func testAPIKeyIsBackedByAnEditableSecureFieldWithoutViewReplacement() {
    var apiKey = "sk-existing-key"
    let binding = Binding(
      get: { apiKey },
      set: { apiKey = $0 }
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: MaskedAPIKeyField(apiKey: binding)
        .frame(width: 159, height: 27),
      size: CGSize(width: 159, height: 27)
    )

    let editor = firstTextField(in: hostingView, identifier: "settings-api-key-editor")

    XCTAssertNotNil(editor)
    XCTAssertTrue(editor?.isEditable == true)
    XCTAssertTrue(editor?.isSelectable == true)

    editor?.stringValue = "sk-updated-key"
    editor?.delegate?.controlTextDidChange?(
      Notification(name: NSControl.textDidChangeNotification, object: editor)
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    XCTAssertEqual(apiKey, "sk-updated-key")
  }

  func testSettingsChangesAreForwardedToPersistence() async throws {
    var persistedSettings: CidaSettings?
    let model = AppModel(
      settings: .designPreview,
      saveSettings: { settings in persistedSettings = settings }
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: SettingsWindowView(model: model),
      size: CGSize(width: 560, height: 660)
    )

    model.settings.apiKey = "sk-updated-key"
    try await waitUntil(timeout: .seconds(2)) {
      persistedSettings?.apiKey == "sk-updated-key"
    }

    XCTAssertEqual(persistedSettings?.apiKey, "sk-updated-key")
    withExtendedLifetime(hostingView) {}
  }

  func testComposerPreservesLargeMultilineTextAndSubmitsWithReturnAction() async throws {
    let model = AppModel(inputText: "", service: ImmediateStreamingService())
    let controller = makeHiddenPanel(model: model)
    let hostingView = try XCTUnwrap(controller.contentView)
    let input = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))
    let largeInput = String(repeating: "First line\nSecond line with context.\n", count: 2_000)
    input.string = largeInput
    input.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: input))
    await Task.yield()
    try await Task.sleep(for: .milliseconds(50))
    hostingView.layoutSubtreeIfNeeded()
    XCTAssertEqual(model.inputText, largeInput)
    let inputScrollView = try XCTUnwrap(input.enclosingScrollView)
    let sourceCap = controller.heightBudget.sourceEditorMaxHeight
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return abs(inputScrollView.frame.height - sourceCap) <= 0.5
    }
    XCTAssertFalse(inputScrollView.hasVerticalScroller)
    XCTAssertFalse(CidaScrollIndicator.installed(in: inputScrollView)?.isHidden ?? true)
    XCTAssertGreaterThan(input.bounds.height, inputScrollView.frame.height)

    XCTAssertTrue(
      input.delegate?.textView?(input, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        == true)
    try await waitUntil(timeout: .seconds(2)) {
      model.result?.phase == .completed
    }
    XCTAssertEqual(model.result?.source, largeInput)
    XCTAssertEqual(model.inputText, largeInput, "The source stays in the editor after ⏎")
    XCTAssertEqual(input.string, largeInput)
    XCTAssertEqual(inputScrollView.frame.height, sourceCap, accuracy: 0.5)
  }

  func testComposerShrinksAsNativeMultilineInputIsDeleted() async throws {
    let model = AppModel(inputText: "")
    let controller = makeHiddenPanel(model: model)
    let hostingView = try XCTUnwrap(controller.contentView)
    let panel = controller.panel
    let input = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))

    func assertPanelFollowsTheEditor(file: StaticString = #filePath, line: UInt = #line) {
      let editorHeight = input.enclosingScrollView?.frame.height ?? 0
      XCTAssertEqual(
        panel.frame.height,
        editorHeight + CidaDesign.Spacing.paneVertical * 2 + CidaDesign.Panel.controlBarHeight,
        accuracy: 1,
        "The panel is exactly as tall as its content.",
        file: file,
        line: line
      )
    }

    let threeLines = "First line\nSecond line\nThird line"
    input.insertText(threeLines, replacementRange: NSRange(location: 0, length: 0))
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.inputText == threeLines
        && abs((input.enclosingScrollView?.frame.height ?? 0) - 78) <= 0.5
        && abs(panel.frame.height - (78 + 36 + 50)) <= 1
    }
    XCTAssertEqual(input.enclosingScrollView?.frame.height ?? 0, 78, accuracy: 0.5)
    assertPanelFollowsTheEditor()

    let thirdLineRange = (input.string as NSString).range(of: "\nThird line")
    input.insertText("", replacementRange: thirdLineRange)
    let twoLines = "First line\nSecond line"
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.inputText == twoLines
        && abs((input.enclosingScrollView?.frame.height ?? 0) - 52) <= 0.5
        && abs(panel.frame.height - (52 + 36 + 50)) <= 1
    }
    assertPanelFollowsTheEditor()

    input.insertText(
      "",
      replacementRange: NSRange(location: 0, length: (input.string as NSString).length)
    )
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.inputText.isEmpty
        && abs((input.enclosingScrollView?.frame.height ?? 0) - 27) <= 0.5
        && abs(panel.frame.height - (27 + 36 + 50)) <= 1
    }
    assertPanelFollowsTheEditor()
    assertTestProcessIsNotFrontmost()
  }

  /// An input method's provisional text lives only in the native view; a
  /// SwiftUI update while it is composing must not write the binding back.
  func testBindingWriteBackIsSkippedWhileAnInputMethodIsComposing() async throws {
    let model = AppModel(inputText: "")
    let controller = makeHiddenPanel(model: model)
    let hostingView = try XCTUnwrap(controller.contentView)
    let input = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))
    controller.panel.orderBack(nil)
    _ = controller.panel.makeFirstResponder(input)

    input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(input.hasMarkedText())
    XCTAssertEqual(input.string, "ni")
    XCTAssertEqual(model.inputText, "", "Marked text never reaches the binding")

    // Any unrelated state change re-renders the panel content.
    model.requestInputFocus()
    model.setMode(.improve)
    try await Task.sleep(for: .milliseconds(80))
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertTrue(input.hasMarkedText(), "The composition survives the SwiftUI update")
    XCTAssertEqual(input.string, "ni")
    input.insertText("你", replacementRange: input.markedRange())
    XCTAssertFalse(input.hasMarkedText())
    XCTAssertEqual(model.inputText, "你")
    assertTestProcessIsNotFrontmost()
  }

  func testLongInputAndResultUseThePencilScrollIndicators() async throws {
    let model = AppModel(inputText: ResultRecord.designLongInput, settings: .designPreview)
    model.setResultForTesting(ResultRecord.designLong())
    let controller = makeHiddenPanel(model: model)
    let window = controller.panel
    let hostingView = try XCTUnwrap(controller.contentView)
    window.orderBack(nil)
    try await Task.sleep(for: .milliseconds(100))
    hostingView.layoutSubtreeIfNeeded()

    let resultIndicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "result-scroll-indicator")
    )
    let composerIndicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "composer-scroll-indicator")
    )
    try await waitUntil(timeout: .seconds(2)) {
      window.displayIfNeeded()
      hostingView.layoutSubtreeIfNeeded()
      resultIndicator.observedScrollView?.layoutSubtreeIfNeeded()
      resultIndicator.refresh()
      composerIndicator.refresh()
      return !resultIndicator.isHidden && !composerIndicator.isHidden
    }
    XCTAssertEqual(resultIndicator.knobDrawingRect.width, 4, accuracy: 0.1)
    XCTAssertEqual(resultIndicator.knobDrawingRect.height, 90, accuracy: 0.1)
    XCTAssertLessThan(resultIndicator.doubleValue, 0.1, "A completed result starts at its top")
    XCTAssertEqual(composerIndicator.knobDrawingRect.width, 4, accuracy: 0.1)
    XCTAssertEqual(composerIndicator.knobDrawingRect.height, 64, accuracy: 0.1)

    let resultScrollView = try XCTUnwrap(resultIndicator.observedScrollView)
    resultIndicator.scroll(toNormalizedValue: 1)
    XCTAssertGreaterThan(resultIndicator.doubleValue, 0.9)
    XCTAssertTrue(isScrolledToBottom(resultScrollView), scrollDescription(resultScrollView))
    resultIndicator.scroll(toNormalizedValue: 0)
    XCTAssertLessThan(resultIndicator.doubleValue, 0.1)
    XCTAssertFalse(isScrolledToBottom(resultScrollView), scrollDescription(resultScrollView))
    window.orderOut(nil)
    assertTestProcessIsNotFrontmost()
  }

  func testPencilScrollIndicatorMovesDownFromDocumentTopToBottom() throws {
    let documentViews: [NSView] = [
      FlippedTestDocumentView(frame: NSRect(x: 0, y: 0, width: 320, height: 600)),
      NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 600)),
    ]

    for documentView in documentViews {
      let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
      scrollView.borderType = .noBorder
      scrollView.hasVerticalScroller = false
      scrollView.hasHorizontalScroller = false
      scrollView.documentView = documentView
      scrollView.layoutSubtreeIfNeeded()

      let indicator = CidaScrollIndicator.install(on: scrollView, configuration: .result)
      indicator.refresh()
      let clipView = scrollView.contentView
      let visibleHeight = clipView.documentVisibleRect.height
      let topOriginY =
        documentView.isFlipped
        ? documentView.bounds.minY
        : documentView.bounds.maxY - visibleHeight
      clipView.scroll(to: NSPoint(x: 0, y: topOriginY))
      scrollView.reflectScrolledClipView(clipView)
      indicator.refresh()

      XCTAssertTrue(indicator.isFlipped)
      XCTAssertEqual(indicator.doubleValue, 0, accuracy: 0.001)
      XCTAssertEqual(
        indicator.knobDrawingRect.minY,
        indicator.rect(for: .knobSlot).minY,
        accuracy: 0.001
      )
      let topKnobOriginY = indicator.knobDrawingRect.minY

      let bottomOriginY =
        documentView.isFlipped
        ? documentView.bounds.maxY - visibleHeight
        : documentView.bounds.minY
      clipView.scroll(to: NSPoint(x: 0, y: bottomOriginY))
      scrollView.reflectScrolledClipView(clipView)
      indicator.refresh()

      XCTAssertEqual(indicator.doubleValue, 1, accuracy: 0.001)
      XCTAssertEqual(
        indicator.knobDrawingRect.maxY,
        indicator.rect(for: .knobSlot).maxY,
        accuracy: 0.001
      )
      XCTAssertGreaterThan(indicator.knobDrawingRect.minY, topKnobOriginY)
    }
  }

  func testPencilScrollIndicatorsNeverUseSystemOverlayRendering() throws {
    let mainModel = AppModel(inputText: ResultRecord.designLongInput, settings: .designPreview)
    mainModel.setResultForTesting(ResultRecord.designLong())
    let controller = makeHiddenPanel(model: mainModel)
    let mainHostingView = try XCTUnwrap(controller.contentView)

    var settings = CidaSettings.designPreview
    settings.provider = .openAI
    settings.model = "local-model"
    let (settingsWindow, settingsHostingView) = makeHiddenWindow(
      rootView: SettingsWindowView(model: AppModel(settings: settings)),
      size: CGSize(width: 500, height: 500)
    )

    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    mainHostingView.layoutSubtreeIfNeeded()
    settingsHostingView.layoutSubtreeIfNeeded()

    let indicators = try [
      XCTUnwrap(firstScroller(in: mainHostingView, identifier: "result-scroll-indicator")),
      XCTUnwrap(firstScroller(in: mainHostingView, identifier: "composer-scroll-indicator")),
      XCTUnwrap(firstScroller(in: settingsHostingView, identifier: "settings-scroll-indicator")),
    ]

    XCTAssertFalse(CidaScrollIndicator.isCompatibleWithOverlayScrollers)
    for indicator in indicators {
      let originalValue = indicator.doubleValue
      indicator.refresh()
      indicator.scroll(toNormalizedValue: 0.5)
      indicator.layoutSubtreeIfNeeded()
      indicator.displayIfNeeded()

      let systemOverlayLayers =
        indicator.layer?.sublayers?.filter {
          String(describing: $0.delegate).contains("OverlayScroller")
        } ?? []
      let pencilKnobLayers =
        indicator.layer?.sublayers?.filter {
          $0.delegate == nil
            && abs($0.frame.width - CidaScrollIndicator.knobWidth) <= 0.1
            && abs($0.frame.height - indicator.configuration.knobLength) <= 0.1
            && abs($0.cornerRadius - CidaScrollIndicator.knobWidth / 2) <= 0.1
        } ?? []
      XCTAssertEqual(indicator.scrollerStyle, .legacy)
      XCTAssertFalse(
        indicator.observedScrollView?.hasVerticalScroller ?? true,
        indicator.configuration.accessibilityIdentifier
      )
      XCTAssertTrue(systemOverlayLayers.isEmpty)
      XCTAssertEqual(pencilKnobLayers.count, 1, indicator.configuration.accessibilityIdentifier)
      XCTAssertEqual(indicator.layer?.sublayers?.count, 1)
      XCTAssertEqual(
        pencilKnobLayers.first?.backgroundColor,
        CidaScrollIndicator.knobColor.cgColor
      )
      XCTAssertEqual(indicator.knobDrawingRect.width, 4, accuracy: 0.1)

      indicator.scroll(toNormalizedValue: originalValue)
    }

    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(settingsWindow) {}
  }

  func testPencilScrollIndicatorRemovesScrollerReinstalledDuringLiveScroll() throws {
    let model = AppModel(inputText: ResultRecord.designLongInput, settings: .designPreview)
    model.setResultForTesting(ResultRecord.designLong())
    let controller = makeHiddenPanel(model: model)
    let hostingView = try XCTUnwrap(controller.contentView)

    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    hostingView.layoutSubtreeIfNeeded()
    let indicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "result-scroll-indicator")
    )
    let scrollView = try XCTUnwrap(indicator.observedScrollView)

    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.verticalScroller = NSScroller()
    scrollView.hasVerticalScroller = true
    XCTAssertTrue(scrollView.hasVerticalScroller)

    NotificationCenter.default.post(
      name: NSScrollView.didLiveScrollNotification,
      object: scrollView
    )
    XCTAssertFalse(scrollView.hasVerticalScroller)
    XCTAssertNil(scrollView.verticalScroller)

    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.verticalScroller = NSScroller()
    scrollView.hasVerticalScroller = true
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))

    XCTAssertFalse(scrollView.hasVerticalScroller)
    XCTAssertNil(scrollView.verticalScroller)
    assertTestProcessIsNotFrontmost()
  }

  func testComposerVirtualizesLargeDocumentAndLoadsEarlierPagesOnDemand() async throws {
    let model = AppModel(inputText: "", service: ImmediateStreamingService())
    let controller = makeHiddenPanel(model: model)
    let hostingView = try XCTUnwrap(controller.contentView)
    let input = try XCTUnwrap(
      firstTextView(in: hostingView, identifier: "composer-input") as? ComposerNativeTextView
    )
    let largeInput = String(repeating: "123456789\n", count: 12_000)

    let clock = ContinuousClock()
    let startedAt = clock.now
    XCTAssertTrue(input.performPaste(largeInput))
    XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(50))

    try await waitUntil(timeout: .seconds(1)) {
      !input.isPerformingLargeDocumentPaste
        && model.inputDocumentUTF16Count == largeInput.utf16.count
    }
    XCTAssertEqual(input.documentUTF16Length, largeInput.utf16.count)
    XCTAssertEqual(
      input.textStorage?.length,
      ComposerNativeTextView.initialMaterializedUTF16Length
    )
    XCTAssertLessThanOrEqual(ComposerNativeTextView.initialMaterializedUTF16Length, 512)
    XCTAssertLessThanOrEqual(
      ComposerNativeTextView.materializedPageUTF16Length,
      ComposerNativeTextView.initialMaterializedUTF16Length * 2
    )
    XCTAssertGreaterThan(input.materializedDocumentRange.location, 0)
    XCTAssertEqual(input.selectedRange().location, input.textStorage?.length)

    let materializedLength = try XCTUnwrap(input.textStorage?.length)
    XCTAssertTrue(input.materializePreviousPage())
    XCTAssertGreaterThan(input.textStorage?.length ?? 0, materializedLength)
    XCTAssertEqual(input.documentStringForBinding(), largeInput)

    XCTAssertTrue(
      input.delegate?.textView?(input, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        == true
    )
    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.result?.phase == .completed
    }
    XCTAssertEqual(model.result?.source, largeInput)
    XCTAssertEqual(model.inputDocumentUTF16Count, largeInput.utf16.count, "The source stays")
    XCTAssertTrue(input.isVirtualizingLargeDocument)
    XCTAssertEqual(
      input.enclosingScrollView?.frame.height ?? 0,
      controller.heightBudget.sourceEditorMaxHeight,
      accuracy: 0.5
    )
    assertTestProcessIsNotFrontmost()
  }

  func testImmediateLargeDocumentSubmissionKeepsTheStagedDocument() async throws {
    let model = AppModel(inputText: "", service: ImmediateStreamingService())
    let controller = makeHiddenPanel(model: model)
    let hostingView = try XCTUnwrap(controller.contentView)
    let input = try XCTUnwrap(
      firstTextView(in: hostingView, identifier: "composer-input") as? ComposerNativeTextView
    )
    let largeInput = String(repeating: "Immediate staged submission.\n", count: 4_500)

    XCTAssertTrue(input.performPaste(largeInput))
    XCTAssertTrue(
      input.delegate?.textView?(input, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        == true
    )

    try await waitUntil(timeout: .seconds(2)) {
      model.result?.source == largeInput && model.result?.phase == .completed
    }
    try await Task.sleep(for: .milliseconds(80))
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertEqual(model.inputDocumentUTF16Count, largeInput.utf16.count)
    XCTAssertEqual(input.documentStringForBinding(), largeInput)
    XCTAssertFalse(model.isResultStale)
    assertTestProcessIsNotFrontmost()
  }

  func testOpenAIEndpointFieldIsEditableWhenOpenAIIsSelected() throws {
    var settings = CidaSettings.designPreview
    settings.provider = .openAI
    settings.model = "gpt-5"
    let model = AppModel(settings: settings)
    let (_, hostingView) = makeHiddenWindow(
      rootView: SettingsWindowView(model: model),
      size: CGSize(width: 560, height: 660)
    )

    let endpoint = try XCTUnwrap(
      firstTextField(in: hostingView, identifier: "settings-openai-endpoint")
    )
    endpoint.stringValue = "http://127.0.0.1:8080/v1/chat/completions"
    endpoint.delegate?.controlTextDidChange?(
      Notification(name: NSControl.textDidChangeNotification, object: endpoint)
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))

    XCTAssertEqual(model.settings.openAIEndpoint, endpoint.stringValue)
  }
}
