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
      entries: [],
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
    let model = AppModel(
      inputText: "",
      entries: [],
      service: ImmediateStreamingService()
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model),
      size: CGSize(width: 860, height: 640)
    )
    let input = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))
    let largeInput = String(repeating: "First line\nSecond line with context.\n", count: 2_000)
    input.string = largeInput
    input.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: input))
    await Task.yield()
    try await Task.sleep(for: .milliseconds(50))
    hostingView.layoutSubtreeIfNeeded()
    XCTAssertEqual(model.inputText, largeInput)
    let inputScrollView = try XCTUnwrap(input.enclosingScrollView)
    let intermediateEditorHeight = inputScrollView.frame.height
    XCTAssertGreaterThan(intermediateEditorHeight, 27)
    XCTAssertLessThan(intermediateEditorHeight, 220)
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return inputScrollView.frame.height >= 150
    }
    XCTAssertFalse(inputScrollView.hasVerticalScroller)
    XCTAssertFalse(CidaScrollIndicator.installed(in: inputScrollView)?.isHidden ?? true)
    let editorHeight = try XCTUnwrap(input.enclosingScrollView?.frame.height)
    XCTAssertGreaterThanOrEqual(editorHeight, 150)
    XCTAssertLessThanOrEqual(editorHeight, 220)
    XCTAssertGreaterThan(input.bounds.height, editorHeight)

    XCTAssertTrue(
      input.delegate?.textView?(input, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        == true)
    try await waitUntil(timeout: .seconds(2)) {
      model.entries.count == 1
    }
    XCTAssertEqual(model.entries.count, 1)
    XCTAssertEqual(model.entries.first?.source, largeInput)
    XCTAssertEqual(model.inputText, "")
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      let currentInput = self.firstTextView(
        in: hostingView,
        identifier: "composer-input"
      )
      return (currentInput?.enclosingScrollView?.frame.height ?? .greatestFiniteMagnitude) <= 27.5
    }
    let resetInput = try XCTUnwrap(
      firstTextView(in: hostingView, identifier: "composer-input")
    )
    XCTAssertTrue(resetInput.string.isEmpty, "nativeLength=\(resetInput.string.utf16.count)")
    XCTAssertEqual(
      resetInput.enclosingScrollView?.frame.height ?? 0,
      27,
      accuracy: 0.5
    )
  }

  func testComposerShrinksAsNativeMultilineInputIsDeleted() async throws {
    let model = AppModel(inputText: "", entries: [])
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    let input = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))
    let inputScrollView = try XCTUnwrap(input.enclosingScrollView)
    let historyScrollView = try XCTUnwrap(
      allScrollViews(in: hostingView).first {
        $0.accessibilityIdentifier() == "history-scroll-view"
      }
    )

    func assertComposerDoesNotCoverHistory(file: StaticString = #filePath, line: UInt = #line) {
      let inputFrame = inputScrollView.convert(inputScrollView.bounds, to: hostingView)
      let historyFrame = historyScrollView.convert(historyScrollView.bounds, to: hostingView)
      XCTAssertLessThanOrEqual(
        inputFrame.intersection(historyFrame).height,
        0.5,
        "The history viewport and composer must use the same presentation state.",
        file: file,
        line: line
      )
    }

    let threeLines = "First line\nSecond line\nThird line"
    input.insertText(threeLines, replacementRange: NSRange(location: 0, length: 0))
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.inputText == threeLines
        && abs((input.enclosingScrollView?.frame.height ?? 0) - 94) <= 0.5
    }
    XCTAssertEqual(input.enclosingScrollView?.frame.height ?? 0, 94, accuracy: 0.5)
    assertComposerDoesNotCoverHistory()

    let thirdLineRange = (input.string as NSString).range(of: "\nThird line")
    input.insertText("", replacementRange: thirdLineRange)
    let twoLines = "First line\nSecond line"
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.inputText == twoLines
        && abs((input.enclosingScrollView?.frame.height ?? 0) - 68) <= 0.5
    }
    XCTAssertEqual(input.enclosingScrollView?.frame.height ?? 0, 68, accuracy: 0.5)
    assertComposerDoesNotCoverHistory()

    let secondLineRange = (input.string as NSString).range(of: "\nSecond line")
    input.insertText("", replacementRange: secondLineRange)
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.inputText == "First line"
        && abs((input.enclosingScrollView?.frame.height ?? 0) - 27) <= 0.5
    }
    XCTAssertEqual(input.enclosingScrollView?.frame.height ?? 0, 27, accuracy: 0.5)
    assertComposerDoesNotCoverHistory()

    input.insertText(
      "",
      replacementRange: NSRange(location: 0, length: (input.string as NSString).length)
    )
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.inputText.isEmpty
        && abs((input.enclosingScrollView?.frame.height ?? 0) - 27) <= 0.5
    }
    XCTAssertEqual(input.enclosingScrollView?.frame.height ?? 0, 27, accuracy: 0.5)
    assertComposerDoesNotCoverHistory()
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testNativeEditAfterPendingComposerResetIsNotCleared() async throws {
    let model = AppModel(
      inputText: "",
      entries: [],
      service: ImmediateStreamingService()
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    hostingView.layoutSubtreeIfNeeded()
    let input = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))

    input.string = "first request"
    input.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: input))
    XCTAssertEqual(model.inputText, "first request")
    XCTAssertTrue(model.submit())

    input.string = "recovery request"
    input.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: input))
    XCTAssertEqual(model.inputText, "recovery request")

    await Task.yield()
    hostingView.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertEqual(input.string, "recovery request")
    XCTAssertEqual(model.inputText, "recovery request")
    model.cancelProcessing()
  }

  func testPendingComposerResetClearsTheSubmittedNativeDocument() async throws {
    let model = AppModel(
      inputText: "",
      entries: [],
      service: ImmediateStreamingService()
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    hostingView.layoutSubtreeIfNeeded()
    let input = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))

    input.string = "submitted through the native responder"
    input.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: input))
    XCTAssertEqual(model.inputText, "submitted through the native responder")
    XCTAssertTrue(model.submit())

    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return input.string.isEmpty
        && (input.enclosingScrollView?.frame.height ?? .greatestFiniteMagnitude) <= 27.5
    }
    XCTAssertEqual(model.entries.last?.source, "submitted through the native responder")
    XCTAssertTrue(input.string.isEmpty)
    model.cancelProcessing()
  }

  func testComposerResetResolutionRejectsAStaleBindingEchoButPreservesANewerEdit() {
    XCTAssertEqual(
      ComposerResetSynchronizer.resolve(
        revision: 4,
        lastAppliedRevision: 3,
        nativeEditRevision: 3
      ),
      .clearSubmittedDocument
    )
    XCTAssertEqual(
      ComposerResetSynchronizer.resolve(
        revision: 4,
        lastAppliedRevision: 3,
        nativeEditRevision: 4
      ),
      .preserveNewerNativeEdit
    )
    XCTAssertEqual(
      ComposerResetSynchronizer.resolve(
        revision: 4,
        lastAppliedRevision: 4,
        nativeEditRevision: 4
      ),
      .none
    )
  }

  func testLongInputUsesThePencilScrollIndicators() async throws {
    let model = AppModel(
      inputText: HistoryEntry.designLongInput,
      entries: HistoryEntry.longDesignSamples,
      settings: .designPreview
    )
    let (window, hostingView) = makeNativeWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    window.alphaValue = 0
    window.orderBack(nil)
    try await Task.sleep(for: .milliseconds(100))
    hostingView.layoutSubtreeIfNeeded()

    let historyIndicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "history-scroll-indicator")
    )
    let composerIndicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "composer-scroll-indicator")
    )
    let resultTextView = try XCTUnwrap(
      firstTextView(
        in: hostingView,
        identifier: "history-result-\(model.entries[0].id.uuidString)"
      )
    )
    let resultContainer = try XCTUnwrap(resultTextView.superview as? HistoryResultTextContainer)
    try await waitUntil(timeout: .seconds(1)) {
      window.displayIfNeeded()
      hostingView.layoutSubtreeIfNeeded()
      hostingView.displayIfNeeded()
      if let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
      }
      historyIndicator.observedScrollView?.layoutSubtreeIfNeeded()
      historyIndicator.refresh()
      return !historyIndicator.isHidden && historyIndicator.doubleValue > 0.9
    }
    XCTAssertFalse(
      historyIndicator.isHidden,
      "frame=\(historyIndicator.frame) knob=\(historyIndicator.knobDrawingRect) result=\(resultContainer.frame) natural=\(resultContainer.naturalTextHeight) text=\(resultTextView.frame)"
    )
    XCTAssertFalse(
      composerIndicator.isHidden,
      "frame=\(composerIndicator.frame) knob=\(composerIndicator.knobDrawingRect)"
    )
    XCTAssertEqual(historyIndicator.knobDrawingRect.width, 4, accuracy: 0.1)
    XCTAssertEqual(historyIndicator.knobDrawingRect.height, 90, accuracy: 0.1)
    XCTAssertGreaterThan(
      historyIndicator.doubleValue,
      0.9,
      "value=\(historyIndicator.doubleValue) knob=\(historyIndicator.knobDrawingRect)"
    )
    XCTAssertEqual(composerIndicator.knobDrawingRect.width, 4, accuracy: 0.1)
    XCTAssertEqual(composerIndicator.knobDrawingRect.height, 64, accuracy: 0.1)
    XCTAssertLessThan(composerIndicator.doubleValue, 0.1)
    let composerIndicatorHost = try XCTUnwrap(composerIndicator.superview)
    let composerKnobPoint = composerIndicator.convert(
      NSPoint(
        x: composerIndicator.knobDrawingRect.midX,
        y: composerIndicator.knobDrawingRect.midY
      ),
      to: composerIndicatorHost
    )
    let composerKnobHit = composerIndicatorHost.hitTest(composerKnobPoint)
    XCTAssertTrue(
      composerKnobHit === composerIndicator,
      "hit=\(String(describing: composerKnobHit)) point=\(composerKnobPoint) hostBounds=\(composerIndicatorHost.bounds) indicator=\(composerIndicator.frame) knob=\(composerIndicator.knobDrawingRect) hidden=\(composerIndicator.isHidden)"
    )
    let historyScrollView = try XCTUnwrap(historyIndicator.observedScrollView)
    historyIndicator.scroll(toNormalizedValue: 0)
    XCTAssertLessThan(historyIndicator.doubleValue, 0.1)
    XCTAssertFalse(isScrolledToBottom(historyScrollView), scrollDescription(historyScrollView))
    historyIndicator.scroll(toNormalizedValue: 1)
    XCTAssertGreaterThan(historyIndicator.doubleValue, 0.9)
    XCTAssertTrue(isScrolledToBottom(historyScrollView), scrollDescription(historyScrollView))
    window.orderOut(nil)
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
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

      let indicator = CidaScrollIndicator.install(on: scrollView, configuration: .history)
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
    let mainModel = AppModel(
      inputText: HistoryEntry.designLongInput,
      entries: HistoryEntry.longDesignSamples,
      settings: .designPreview
    )
    let (mainWindow, mainHostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: mainModel, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )

    var settings = CidaSettings.designPreview
    settings.provider = .openAI
    settings.model = "local-model"
    let (settingsWindow, settingsHostingView) = makeHiddenWindow(
      rootView: SettingsWindowView(model: AppModel(entries: [], settings: settings)),
      size: CGSize(width: 500, height: 500)
    )

    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    mainHostingView.layoutSubtreeIfNeeded()
    settingsHostingView.layoutSubtreeIfNeeded()

    let indicators = try [
      XCTUnwrap(
        firstScroller(in: mainHostingView, identifier: "history-scroll-indicator")
      ),
      XCTUnwrap(
        firstScroller(in: mainHostingView, identifier: "composer-scroll-indicator")
      ),
      XCTUnwrap(
        firstScroller(in: settingsHostingView, identifier: "settings-scroll-indicator")
      ),
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
      XCTAssertTrue(
        systemOverlayLayers.isEmpty,
        "System overlay layers must not be mixed with the Pencil indicator: \(systemOverlayLayers)"
      )
      XCTAssertEqual(
        pencilKnobLayers.count,
        1,
        "Each scroll surface must render exactly one Pencil thumb: \(indicator.layer?.sublayers ?? [])"
      )
      XCTAssertEqual(
        indicator.layer?.sublayers?.count,
        1,
        "No second track or proportional thumb may appear while scrolling"
      )
      XCTAssertEqual(
        pencilKnobLayers.first?.backgroundColor,
        CidaScrollIndicator.knobColor.cgColor
      )
      XCTAssertEqual(indicator.knobDrawingRect.width, 4, accuracy: 0.1)

      indicator.scroll(toNormalizedValue: originalValue)
    }

    assertTestProcessIsNotFrontmost()
    withExtendedLifetime((mainWindow, settingsWindow)) {}
  }

  func testPencilScrollIndicatorRemovesScrollerReinstalledDuringLiveScroll() throws {
    let model = AppModel(
      inputText: HistoryEntry.designLongInput,
      entries: HistoryEntry.longDesignSamples,
      settings: .designPreview
    )
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )

    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    hostingView.layoutSubtreeIfNeeded()
    let indicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "history-scroll-indicator")
    )
    let scrollView = try XCTUnwrap(indicator.observedScrollView)

    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.verticalScroller = NSScroller()
    scrollView.hasVerticalScroller = true
    XCTAssertTrue(scrollView.hasVerticalScroller)
    XCTAssertNotNil(scrollView.verticalScroller)

    NotificationCenter.default.post(
      name: NSScrollView.didLiveScrollNotification,
      object: scrollView
    )
    XCTAssertFalse(scrollView.hasVerticalScroller)
    XCTAssertNil(scrollView.verticalScroller)
    XCTAssertEqual(scrollView.scrollerStyle, .overlay)
    XCTAssertTrue(scrollView.autohidesScrollers)

    // Reproduce SwiftUI restoring the native scroller after the synchronous
    // live-scroll callback. The deferred guard must remove that second copy.
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.verticalScroller = NSScroller()
    scrollView.hasVerticalScroller = true
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))

    XCTAssertFalse(scrollView.hasVerticalScroller)
    XCTAssertNil(scrollView.verticalScroller)
    XCTAssertEqual(scrollView.scrollerStyle, .overlay)
    XCTAssertTrue(scrollView.autohidesScrollers)

    window.orderOut(nil)
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testComposerVirtualizesLargeDocumentAndLoadsEarlierPagesOnDemand() async throws {
    let model = AppModel(
      inputText: "",
      entries: [],
      service: ImmediateStreamingService()
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
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
    XCTAssertLessThanOrEqual(
      ComposerNativeTextView.initialMaterializedUTF16Length,
      512,
      "The synchronous paste path must materialize only the visible tail"
    )
    XCTAssertLessThanOrEqual(
      ComposerNativeTextView.materializedPageUTF16Length,
      ComposerNativeTextView.initialMaterializedUTF16Length * 2,
      "Upward scrolling must page text in bounded chunks"
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
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.entries.first?.source.utf16.count == largeInput.utf16.count
        && model.inputText.isEmpty
        && (self.firstTextView(in: hostingView, identifier: "composer-input")?
          .enclosingScrollView?.frame.height ?? .greatestFiniteMagnitude) <= 27.5
    }
    XCTAssertEqual(model.entries.first?.source, largeInput)
    let resetInput = try XCTUnwrap(
      firstTextView(in: hostingView, identifier: "composer-input")
    )
    XCTAssertEqual(resetInput.enclosingScrollView?.frame.height ?? 0, 27, accuracy: 0.5)
    assertTestProcessIsNotFrontmost()
  }

  func testImmediateLargeDocumentSubmissionKeepsComposerCompact() async throws {
    let model = AppModel(
      inputText: "",
      entries: [],
      service: ImmediateStreamingService()
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    let input = try XCTUnwrap(
      firstTextView(in: hostingView, identifier: "composer-input") as? ComposerNativeTextView
    )
    let largeInput = String(repeating: "Immediate staged submission.\n", count: 4_500)

    XCTAssertTrue(input.performPaste(largeInput))
    XCTAssertTrue(
      input.delegate?.textView?(input, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        == true
    )

    try await waitUntil(timeout: .seconds(1)) {
      model.entries.first?.source == largeInput
    }
    try await Task.sleep(for: .milliseconds(80))
    hostingView.layoutSubtreeIfNeeded()

    let resetInput = try XCTUnwrap(
      firstTextView(in: hostingView, identifier: "composer-input")
    )
    XCTAssertEqual(model.inputDocumentUTF16Count, 0)
    XCTAssertEqual(resetInput.string, "")
    XCTAssertEqual(resetInput.enclosingScrollView?.frame.height ?? 0, 27, accuracy: 0.5)
    assertTestProcessIsNotFrontmost()
  }

  func testOpenAIEndpointFieldIsEditableWhenOpenAIIsSelected() throws {
    var settings = CidaSettings.designPreview
    settings.provider = .openAI
    settings.model = "gpt-5"
    let model = AppModel(entries: [], settings: settings)
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
