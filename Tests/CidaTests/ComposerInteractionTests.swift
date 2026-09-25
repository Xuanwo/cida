import AppKit
import QuartzCore
import SwiftUI
import XCTest

@testable import Cida

@MainActor
extension InteractionReproductionTests {
  func testSettingsChangesAreForwardedToPersistence() async throws {
    var persistedSettings: CidaSettings?
    let model = AppModel(
      settings: .designPreview,
      saveSettings: { settings in persistedSettings = settings }
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: SettingsWindowView(model: model, updates: UpdateState()),
      size: CGSize(width: 560, height: 660)
    )

    model.settings.translationPrompt = "Updated translation policy."
    try await waitUntil(timeout: .seconds(2)) {
      persistedSettings?.translationPrompt == "Updated translation policy."
    }

    XCTAssertEqual(persistedSettings?.translationPrompt, "Updated translation policy.")
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
    XCTAssertTrue(inputScrollView.hasVerticalScroller, "The source pane scrolls with the system scroll bar")
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
    // A configured service: without one the empty panel also carries the welcome.
    let model = AppModel(inputText: "", service: ImmediateStreamingService())
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

    let coordinator = try XCTUnwrap(input.delegate as? ComposerTextEditor.Coordinator)
    XCTAssertFalse(coordinator.metrics.wrappedValue.hasText)

    input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(input.hasMarkedText())
    XCTAssertEqual(input.string, "ni")
    XCTAssertEqual(model.inputText, "", "Marked text never reaches the binding")
    XCTAssertTrue(
      coordinator.metrics.wrappedValue.isComposing,
      "The composition counts as text, so the placeholder hides under it")
    XCTAssertTrue(coordinator.metrics.wrappedValue.hasText)
    XCTAssertTrue(
      InputMethodRouting.isComposing(in: controller.panel),
      "Escape and Tab belong to the input method while it composes")

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
    XCTAssertFalse(coordinator.metrics.wrappedValue.isComposing)
    XCTAssertTrue(coordinator.metrics.wrappedValue.hasText)
    XCTAssertFalse(InputMethodRouting.isComposing(in: controller.panel))

    input.setMarkedText("h", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(coordinator.metrics.wrappedValue.isComposing)
    input.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: input.markedRange())
    XCTAssertFalse(input.hasMarkedText(), "An empty marked string cancels the composition")
    XCTAssertFalse(coordinator.metrics.wrappedValue.isComposing)
    XCTAssertEqual(model.inputText, "你")
    assertTestProcessIsNotFrontmost()
  }

  func testLongInputAndResultScrollWithSystemScrollBarsOnOneEdge() async throws {
    let model = AppModel(inputText: ResultRecord.designLongInput, settings: .designPreview)
    model.setResultForTesting(ResultRecord.designLong())
    let controller = makeHiddenPanel(model: model)
    let window = controller.panel
    let hostingView = try XCTUnwrap(controller.contentView)
    window.orderBack(nil)
    try await Task.sleep(for: .milliseconds(100))
    hostingView.layoutSubtreeIfNeeded()

    let resultScrollView = try XCTUnwrap(firstResultScrollView(in: hostingView))
    let composer = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))
    let composerScrollView = try XCTUnwrap(composer.enclosingScrollView)
    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return resultScrollView.container.frame.height > resultScrollView.contentView.bounds.height
    }

    // Both panes scroll with the system overlay scroll bar whatever the
    // user's scroll-bar preference or pointing device: both scroll views
    // reach the panel's right edge so the bars share it, the bar takes no
    // width from the text, and both texts start at the same 28 pt inset.
    for scrollView in [resultScrollView, composerScrollView] {
      XCTAssertTrue(scrollView.hasVerticalScroller)
      XCTAssertTrue(scrollView.autohidesScrollers)
      scrollView.scrollerStyle = .legacy
      XCTAssertEqual(scrollView.scrollerStyle, .overlay, "The overlay style survives AppKit re-applying the preferred style")
      XCTAssertEqual(scrollView.verticalScroller?.scrollerStyle, .overlay)
      XCTAssertEqual(scrollView.convert(scrollView.bounds, to: nil).maxX, CidaDesign.Panel.width, accuracy: 0.5)
      XCTAssertEqual(scrollView.contentView.bounds.width, scrollView.bounds.width, accuracy: 0.5, "The overlay bar takes no width")
    }
    let textColumn = resultScrollView.container.textColumnFrameForTesting
    XCTAssertEqual(textColumn.minX, CidaDesign.Spacing.windowHorizontal, accuracy: 0.5)
    XCTAssertEqual(
      textColumn.width,
      resultScrollView.container.frame.width - CidaDesign.Spacing.windowHorizontal * 2, accuracy: 0.5)
    XCTAssertEqual(composer.textContainerInset.width, CidaDesign.Spacing.windowHorizontal, accuracy: 0.5)

    XCTAssertEqual(resultScrollView.contentView.bounds.minY, 0, accuracy: 0.5, "A completed result starts at its top")

    // A narrower clip re-wraps the column at once.
    let layoutsBefore = resultScrollView.container.documentLayoutCount
    let narrowerWidth = resultScrollView.contentView.bounds.width - 17
    resultScrollView.container.setFrameSize(
      NSSize(width: narrowerWidth, height: resultScrollView.container.frame.height))
    try await waitUntil(timeout: .seconds(1)) {
      resultScrollView.container.documentLayoutCount > layoutsBefore
    }
    XCTAssertEqual(
      resultScrollView.container.textColumnFrameForTesting.width,
      narrowerWidth - CidaDesign.Spacing.windowHorizontal * 2, accuracy: 0.5,
      "The text column re-wraps to the narrower width")
    let bottom = NSPoint(x: 0, y: resultScrollView.container.frame.height - resultScrollView.contentView.bounds.height)
    resultScrollView.contentView.scroll(to: bottom)
    resultScrollView.reflectScrolledClipView(resultScrollView.contentView)
    XCTAssertTrue(isScrolledToBottom(resultScrollView), scrollDescription(resultScrollView))
    window.orderOut(nil)
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

  func testImportedSelectionReplacesTheWholeDocumentEvenAVirtualOne() async throws {
    let model = AppModel(inputText: "", service: ImmediateStreamingService())
    let controller = makeHiddenPanel(model: model)
    let hostingView = try XCTUnwrap(controller.contentView)
    let input = try XCTUnwrap(
      firstTextView(in: hostingView, identifier: "composer-input") as? ComposerNativeTextView
    )
    let pastedDocument = String(repeating: "Pasted page.\n", count: 9_000)
    XCTAssertTrue(input.performPaste(pastedDocument))
    try await waitUntil(timeout: .seconds(1)) {
      input.isVirtualizingLargeDocument
        && model.inputDocumentUTF16Count == pastedDocument.utf16.count
    }

    XCTAssertTrue(model.importSelection("A short selection."))
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return input.string == "A short selection."
    }
    XCTAssertFalse(input.isVirtualizingLargeDocument)
    XCTAssertEqual(model.currentInputDocument, "A short selection.")
    XCTAssertEqual(model.result?.source, "A short selection.")

    let largeSelection = String(repeating: "Selected paragraph.\n", count: 6_000)
    XCTAssertTrue(model.importSelection(largeSelection))
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return input.isVirtualizingLargeDocument
    }
    XCTAssertEqual(
      input.documentStringForBinding(), largeSelection,
      "The selection is the whole document, not spliced into the previous one")
    XCTAssertEqual(model.inputDocumentUTF16Count, largeSelection.utf16.count)
    try await waitUntil(timeout: .seconds(2)) { model.result?.phase == .completed }
    XCTAssertEqual(model.result?.source, largeSelection)
    XCTAssertFalse(model.isResultStale)
    assertTestProcessIsNotFrontmost()
  }
}
