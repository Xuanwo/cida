import AppKit
import XCTest

@MainActor
final class CidaCriticalFlowUITests: XCTestCase {
  private var app: XCUIApplication!

  func testSettingsMultilineInputAndSubmittedStreamRemainVisible() throws {
    continueAfterFailure = false

    let environment = ProcessInfo.processInfo.environment
    let workRoot = environment["CIDA_UI_TEST_WORK_ROOT"] ?? "/Users/admin/cida-ui-test-work"
    launchApp(arguments: ["--ui-testing", "--ui-testing-history-count", "80"])

    let endpoint: String
    if let configuredEndpoint = environment["CIDA_UI_TEST_ENDPOINT"] {
      endpoint = configuredEndpoint
    } else {
      let port = try String(
        contentsOfFile: "\(workRoot)/mock-port",
        encoding: .utf8
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      endpoint = "http://127.0.0.1:\(port)/v1/chat/completions"
    }
    let recordPath =
      environment["CIDA_UI_TEST_RECORD_PATH"]
      ?? "/Volumes/My Shared Files/artifacts/openai-request.json"
    let history = app.scrollViews["history-scroll-view"]
    XCTAssertTrue(history.waitForExistence(timeout: 5))

    XCTContext.runActivity(named: "Detach history and configure the local endpoint") { _ in
      history.swipeDown()
      history.swipeDown()
      XCTAssertTrue(waitForValue("detached", in: history, timeout: 5))

      let settingsButton = app.buttons["model-settings-button"]
      XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
      settingsButton.click()

      let settingsWindow = app.windows["设置"]
      XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
      let providerMenu = app.menuButtons.matching(
        NSPredicate(
          format: "identifier == %@ AND label == %@",
          "settings-provider-menu",
          "DeepSeek"
        )
      ).firstMatch
      XCTAssertTrue(providerMenu.waitForExistence(timeout: 5))
      providerMenu.click()
      let openAIItem = app.menuItems["OpenAI"]
      XCTAssertTrue(openAIItem.waitForExistence(timeout: 5))
      openAIItem.click()

      replaceText(in: app.textFields["settings-openai-endpoint"], with: endpoint)
      replaceText(in: app.textFields["settings-model"], with: "cida-ui-mock-model")

      let apiKey = app.secureTextFields["settings-api-key-editor"]
      XCTAssertTrue(apiKey.waitForExistence(timeout: 5))
      replaceText(in: apiKey, with: "sk-isolated-ui-test")

      let closeButton = settingsWindow.buttons[XCUIIdentifierCloseWindow]
      XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
      closeButton.click()
      XCTAssertFalse(settingsWindow.waitForExistence(timeout: 2))
    }

    let composer = app.textViews["composer-input"]
    XCTContext.runActivity(named: "Grow and shrink the multiline composer") { _ in
      paste(
        String(repeating: "A multiline input should make the editor comfortable.\n", count: 18),
        into: composer
      )
      XCTAssertTrue(waitForFrameHeight(atLeast: 150, in: composer, timeout: 5))

      composer.typeKey("a", modifierFlags: .command)
      composer.typeKey(.delete, modifierFlags: [])
      XCTAssertTrue(waitForFrameHeight(atMost: 30, in: composer, timeout: 5))
      XCTAssertEqual(composer.value as? String, "")
    }

    let submittedText = String(
      repeating: "A submitted line must remain visible after the composer collapses.\n",
      count: 20
    )
    let completedResult = app.textViews.matching(
      NSPredicate(format: "value CONTAINS %@", "CIDA_UI_E2E_COMPLETE")
    ).firstMatch
    XCTContext.runActivity(named: "Submit and follow the complete streamed result") { activity in
      paste(submittedText, into: composer)
      let submitButton = app.buttons["composer-submit-button"]
      XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
      XCTAssertTrue(submitButton.isEnabled)
      submitButton.click()

      XCTAssertTrue(waitForFrameHeight(atMost: 30, in: composer, timeout: 5))
      XCTAssertTrue(waitForValue("bottom", in: history, timeout: 10))
      XCTAssertTrue(waitForLabel("停止生成", in: submitButton, timeout: 2))

      let streamingResult = app.textViews.matching(
        NSPredicate(
          format: "value CONTAINS %@",
          "The response starts after a short backend pause."
        )
      ).firstMatch
      XCTAssertTrue(streamingResult.waitForExistence(timeout: 5))
      hoverVisibleIntersection(of: streamingResult, inside: history)
      let visibleActions = app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "history-action-")
      )
      XCTAssertEqual(visibleActions.count, 0, "Streaming entries must not expose record icons")

      XCTAssertTrue(completedResult.waitForExistence(timeout: 30))
      XCTAssertTrue(waitForValue("bottom", in: history, timeout: 5))
      XCTAssertTrue(waitForLabel("翻译", in: submitButton, timeout: 2))

      let visibleFrame = completedResult.frame.intersection(history.frame)
      XCTAssertGreaterThan(visibleFrame.height, 20)
      XCTAssertGreaterThan(visibleFrame.width, 100)
      hoverVisibleIntersection(of: completedResult, inside: history)
      XCTAssertTrue(waitForCount(3, in: visibleActions, timeout: 2))

      let attachment = XCTAttachment(screenshot: app.windows["辞达"].screenshot())
      attachment.name = "Completed stream pinned with faded-in record actions"
      attachment.lifetime = .keepAlways
      activity.add(attachment)
    }

    XCTContext.runActivity(named: "Use history as the only result scroll surface") { _ in
      let nestedResultScrollAreas = history.descendants(matching: .scrollView)
      XCTAssertEqual(
        nestedResultScrollAreas.count,
        0,
        "Translation results must not install an independent scroll area: \(history.debugDescription)"
      )
    }

    let request = try recordedRequest(at: recordPath)
    XCTAssertEqual(request["path"] as? String, "/v1/chat/completions")
    let body = try XCTUnwrap(request["body"] as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "cida-ui-mock-model")
    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.last?["content"] as? String, submittedText)
  }

  func testHistoryOnlyUsesThePencilScrollIndicator() {
    continueAfterFailure = false
    launchApp(arguments: ["--ui-testing", "--ui-testing-history-count", "80"])

    let history = app.scrollViews["history-scroll-view"]
    XCTAssertTrue(history.waitForExistence(timeout: 5))
    XCTAssertTrue(waitForValue("bottom", in: history, timeout: 5))

    let bottomThumbCenterY = XCTContext.runActivity(
      named: "History thumb starts at the bottom"
    ) { activity in
      assertPencilScrollIndicator(
        in: history,
        activity: activity,
        attachmentName: "History scroll indicator at the bottom"
      )
    }

    history.swipeDown()
    history.swipeDown()
    XCTAssertTrue(waitForValue("detached", in: history, timeout: 5))

    let detachedThumbCenterY = XCTContext.runActivity(
      named: "History uses one fixed Pencil scroll indicator"
    ) { activity in
      assertPencilScrollIndicator(
        in: history,
        activity: activity,
        attachmentName: "History scroll indicator after scrolling toward older records"
      )
    }
    XCTAssertLessThan(
      detachedThumbCenterY,
      bottomThumbCenterY - 2,
      "Scrolling toward older records must move the visible thumb upward"
    )
  }

  func testSubmittedStreamFollowsAndDoesNotLeakHistoricalHoverActions() throws {
    continueAfterFailure = false
    let endpoint = try localOpenAIEndpoint()
    launchApp(
      arguments: [
        "--ui-testing",
        "--ui-testing-history-count",
        "80",
        "--automation-openai-endpoint",
        endpoint,
      ]
    )

    let history = app.scrollViews["history-scroll-view"]
    let composer = app.textViews["composer-input"]
    let submitButton = app.buttons["composer-submit-button"]
    XCTAssertTrue(history.waitForExistence(timeout: 5))
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertTrue(submitButton.waitForExistence(timeout: 5))

    history.swipeDown()
    history.swipeDown()
    XCTAssertTrue(waitForValue("detached", in: history, timeout: 5))

    let foldedCards = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "history-expand-")
    )
    let visibleFoldedCard = (0..<foldedCards.count)
      .map { foldedCards.element(boundBy: $0) }
      .first { $0.frame.intersection(history.frame).height > 20 }
    let hoveredCard = try XCTUnwrap(
      visibleFoldedCard,
      "The regression fixture must expose a folded row inside the history viewport"
    )
    hoverVisibleIntersection(of: hoveredCard, inside: history)
    let visibleActions = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "history-action-")
    )
    let hasExactlyOneActionPair = waitForCount(2, in: visibleActions, timeout: 2)
    let observedActionIdentifiers = visibleActions.allElementsBoundByIndex.map(\.identifier)
    XCTAssertTrue(
      hasExactlyOneActionPair,
      "Hovering one recycled row must expose exactly that row's two actions; observed \(observedActionIdentifiers)"
    )
    let hoveredActionEntryIDs = Set(
      observedActionIdentifiers.compactMap { identifier in
        for prefix in ["history-action-redo-", "history-action-copy-result-"]
        where identifier.hasPrefix(prefix) {
          return String(identifier.dropFirst(prefix.count))
        }
        return nil
      })
    XCTAssertEqual(
      hoveredActionEntryIDs.count,
      1,
      "A single pointer location cannot expose actions from multiple history rows"
    )

    paste(
      String(repeating: "The submitted stream must remain visible while it grows.\n", count: 20),
      into: composer
    )
    submitButton.click()
    XCTAssertTrue(waitForValue("bottom", in: history, timeout: 10))
    XCTAssertTrue(waitForLabel("停止生成", in: submitButton, timeout: 2))

    let streamingResult = app.textViews.matching(
      NSPredicate(
        format: "value CONTAINS %@",
        "The response starts after a short backend pause."
      )
    ).firstMatch
    XCTAssertTrue(streamingResult.waitForExistence(timeout: 5))
    hoverVisibleIntersection(of: streamingResult, inside: history)
    XCTAssertEqual(
      visibleActions.count,
      0,
      "Submitting after history scrolling must clear every recycled hover action"
    )

    let completedResult = app.textViews.matching(
      NSPredicate(format: "value CONTAINS %@", "CIDA_UI_E2E_COMPLETE")
    ).firstMatch
    XCTAssertTrue(completedResult.waitForExistence(timeout: 30))
    XCTAssertTrue(waitForValue("bottom", in: history, timeout: 5))
    XCTAssertTrue(waitForLabel("翻译", in: submitButton, timeout: 2))
    let visibleFrame = completedResult.frame.intersection(history.frame)
    XCTAssertGreaterThan(visibleFrame.height, 20)
    XCTAssertGreaterThan(visibleFrame.width, 100)
  }

  func testProductionShapedHistoryPreservesVisibleContinuityAcrossConsecutiveSubmissions() throws {
    continueAfterFailure = false

    launchApp(arguments: ["--ui-testing", "--ui-testing-scenario", "history-continuity"])
    let endpoint = try localOpenAIEndpoint()
    configureOpenAI(endpoint: endpoint)

    let history = app.scrollViews["history-scroll-view"]
    let composer = app.textViews["composer-input"]
    let submitButton = app.buttons["composer-submit-button"]
    XCTAssertTrue(history.waitForExistence(timeout: 5))
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(visibleHistoryEntryCount(in: history), 0)
    let persistedFocus = element(
      identifier: "history-entry-30000000-0000-0000-0000-000000000007"
    )
    XCTAssertTrue(persistedFocus.waitForExistence(timeout: 2))
    let persistedExpand = element(
      identifier: "history-expand-30000000-0000-0000-0000-000000000007"
    )
    let persistedSource = element(
      identifier: "history-source-30000000-0000-0000-0000-000000000007"
    )
    XCTAssertTrue(persistedSource.waitForExistence(timeout: 2))
    XCTAssertFalse(persistedExpand.exists)

    let firstSubmittedID = try submitAndAssertVisibleContinuity(
      "CIDA_CONTINUITY_FIRST",
      completionMarker: "CIDA_UI_E2E_COMPLETE_FIRST",
      composer: composer,
      submitButton: submitButton,
      history: history
    )
    XCTAssertTrue(persistedExpand.waitForExistence(timeout: 2))
    XCTAssertTrue(persistedSource.waitForNonExistence(timeout: 2))
    let firstSubmittedResult = app.textViews[
      "history-result-\(firstSubmittedID.uppercased())"
    ]
    XCTAssertTrue(firstSubmittedResult.waitForExistence(timeout: 2))

    _ = try submitAndAssertVisibleContinuity(
      "CIDA_CONTINUITY_SECOND",
      completionMarker: "CIDA_UI_E2E_COMPLETE_SECOND",
      composer: composer,
      submitButton: submitButton,
      history: history
    )
    XCTAssertTrue(
      element(identifier: "history-expand-\(firstSubmittedID)").waitForExistence(timeout: 2),
      "A new submission must fold the previous automatic focus without blanking history"
    )
    XCTAssertTrue(firstSubmittedResult.waitForNonExistence(timeout: 2))
  }

  func testNewSubmissionClearsReusedResultPixelsBeforeFirstByte() throws {
    continueAfterFailure = false

    launchApp(arguments: ["--ui-testing", "--ui-testing-scenario", "history-continuity"])
    let endpoint = try localOpenAIEndpoint()
    configureOpenAI(endpoint: endpoint)

    let history = app.scrollViews["history-scroll-view"]
    let composer = app.textViews["composer-input"]
    let submitButton = app.buttons["composer-submit-button"]
    XCTAssertTrue(history.waitForExistence(timeout: 5))
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertTrue(submitButton.waitForExistence(timeout: 5))

    let previousEntryIdentifiers = historyEntryIdentifiers()
    paste("CIDA_STALE_PIXEL_PROBE", into: composer)
    submitButton.click()
    XCTAssertTrue(waitForLabel("停止生成", in: submitButton, timeout: 2))

    let newEntryIdentifier = try XCTUnwrap(
      waitForNewHistoryEntry(excluding: previousEntryIdentifiers, timeout: 3),
      "Submitting must materialize a new current history entry before the first response byte"
    )
    let entryID = String(newEntryIdentifier.dropFirst("history-entry-".count))
    let result = app.textViews["history-result-\(entryID.uppercased())"]
    XCTAssertTrue(result.waitForExistence(timeout: 2))
    XCTAssertEqual(result.value as? String, "")

    XCTContext.runActivity(named: "The new result is visibly empty before the first byte") {
      activity in
      let screenshot = result.screenshot()
      let attachment = XCTAttachment(screenshot: screenshot)
      attachment.name = "CIDA-E2E-010 new result before first byte"
      attachment.lifetime = .keepAlways
      activity.add(attachment)

      let staleNeutralInkPixels = neutralDarkPixelCount(
        in: screenshot,
        logicalWidth: result.frame.width,
        topPoints: 64
      )
      XCTAssertLessThanOrEqual(
        staleNeutralInkPixels,
        24,
        "The Accessibility value is empty, but the compositor still exposes "
          + "\(staleNeutralInkPixels) neutral text pixels from the recycled result layer"
      )
    }
  }

  func testHistoryFoldingFocusExpansionAndFullCopyContract() {
    continueAfterFailure = false
    launchApp(arguments: ["--ui-testing", "--ui-testing-scenario", "history-folding"])

    let firstID = "40000000-0000-0000-0000-000000000001"
    let secondID = "40000000-0000-0000-0000-000000000002"
    let latestID = "40000000-0000-0000-0000-000000000003"
    let firstEntry = element(identifier: "history-entry-\(firstID)")
    let secondEntry = element(identifier: "history-entry-\(secondID)")
    let latestEntry = element(identifier: "history-entry-\(latestID)")
    XCTAssertTrue(firstEntry.waitForExistence(timeout: 5))
    XCTAssertTrue(secondEntry.waitForExistence(timeout: 5))
    XCTAssertTrue(latestEntry.waitForExistence(timeout: 5))
    let firstExpand = element(identifier: "history-expand-\(firstID)")
    let secondExpand = element(identifier: "history-expand-\(secondID)")
    XCTAssertTrue(firstExpand.waitForExistence(timeout: 2))
    XCTAssertTrue(secondExpand.waitForExistence(timeout: 2))
    XCTAssertFalse(element(identifier: "history-expand-\(latestID)").exists)

    XCTAssertFalse(element(identifier: "history-source-\(firstID)").exists)
    XCTAssertFalse(app.textViews["history-result-\(firstID.uppercased())"].exists)
    XCTAssertTrue(app.textViews["history-result-\(latestID.uppercased())"].exists)

    firstExpand.click()
    XCTAssertTrue(element(identifier: "history-source-\(firstID)").waitForExistence(timeout: 2))
    XCTAssertTrue(
      app.textViews["history-result-\(firstID.uppercased())"].waitForExistence(timeout: 2)
    )

    secondExpand.click()
    XCTAssertTrue(
      app.textViews["history-result-\(firstID.uppercased())"].exists,
      "Expanding another history row must preserve existing comparisons"
    )
    XCTAssertTrue(app.textViews["history-result-\(secondID.uppercased())"].exists)

    element(identifier: "history-collapse-\(firstID)").click()
    XCTAssertTrue(firstExpand.waitForExistence(timeout: 2))
    XCTAssertTrue(
      app.textViews["history-result-\(firstID.uppercased())"].waitForNonExistence(timeout: 2)
    )
    XCTAssertTrue(app.textViews["history-result-\(secondID.uppercased())"].exists)
    XCTAssertTrue(app.textViews["history-result-\(latestID.uppercased())"].exists)

    firstEntry.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).hover()
    let copyResult = app.buttons["history-action-copy-result-\(firstID)"]
    XCTAssertTrue(copyResult.waitForExistence(timeout: 2))
    let copyResultCoordinate = copyResult.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
    )
    copyResultCoordinate.hover()
    copyResultCoordinate.click()
    XCTAssertTrue(
      waitForPasteboard(
        "FOLDING_FIRST_RESULT line one remains visible. Line two remains visible. Line three must be clipped until expansion.",
        timeout: 2
      ),
      "Folding must never truncate the copied result"
    )

    XCTContext.runActivity(named: "History focus and folding states") { activity in
      let attachment = XCTAttachment(screenshot: app.windows["辞达"].screenshot())
      attachment.name = "Multiple history rows expand independently and fold in place"
      attachment.lifetime = .keepAlways
      activity.add(attachment)
    }
  }

  func testFoldedHistoryMatchesThePencilGeometry() {
    continueAfterFailure = false
    launchApp(arguments: ["--ui-testing", "--ui-testing-scenario", "history-folding"])

    let firstID = "40000000-0000-0000-0000-000000000001"
    let entry = element(identifier: "history-entry-\(firstID)")
    let card = element(identifier: "history-expand-\(firstID)")
    let preview = element(identifier: "history-collapsed-result-\(firstID)")
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    XCTAssertTrue(card.waitForExistence(timeout: 2))
    XCTAssertTrue(preview.waitForExistence(timeout: 2))
    XCTAssertEqual(card.frame.height, 96, accuracy: 1)
    XCTAssertEqual(preview.frame.minX - card.frame.minX, 10, accuracy: 1)
    XCTAssertEqual(preview.frame.height, 52, accuracy: 1)

    card.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).hover()
    let redo = app.buttons["history-action-redo-\(firstID)"]
    let copy = app.buttons["history-action-copy-result-\(firstID)"]
    XCTAssertTrue(redo.waitForExistence(timeout: 2))
    XCTAssertTrue(copy.waitForExistence(timeout: 2))
    for action in [redo, copy] {
      XCTAssertGreaterThanOrEqual(action.frame.width, 12)
      XCTAssertLessThanOrEqual(
        action.frame.width,
        14,
        "XCUI may expand the native 12 pt button by one accessibility point per edge"
      )
      XCTAssertGreaterThanOrEqual(action.frame.height, 12)
      XCTAssertLessThanOrEqual(action.frame.height, 14)
      XCTAssertEqual(card.frame.maxX - action.frame.maxX, 10, accuracy: 2)
    }
    XCTAssertEqual(redo.frame.minY - card.frame.minY, 12, accuracy: 2)
    XCTAssertEqual(copy.frame.minY - card.frame.minY, 38, accuracy: 2)
    XCTAssertGreaterThanOrEqual(
      copy.frame.minX - preview.frame.maxX,
      11,
      "The two-line preview must end before the 12 pt action gap"
    )

    let window = app.windows["辞达"]
    let screenshot = window.screenshot()
    XCTContext.runActivity(named: "Folded history Pencil geometry") { activity in
      let attachment = XCTAttachment(screenshot: screenshot)
      attachment.name = "Folded row uses a 96 pt card and 12 pt aligned actions"
      attachment.lifetime = .keepAlways
      activity.add(attachment)
      let componentAttachment = XCTAttachment(screenshot: card.screenshot())
      componentAttachment.name = "Folded record component against Pencil ErIgo"
      componentAttachment.lifetime = .keepAlways
      activity.add(componentAttachment)
    }
    assertActionIconInkFitsThePencilBounds(redo, in: window, screenshot: screenshot)
    assertActionIconInkFitsThePencilBounds(copy, in: window, screenshot: screenshot)
  }

  func testExpandedHistoryActionsReserveThePencilColumn() {
    continueAfterFailure = false
    launchApp(arguments: ["--ui-testing", "--ui-testing-scenario", "record-actions"])

    let latestID = "10000000-0000-0000-0000-000000000002"
    let expand = element(identifier: "history-expand-\(latestID)")
    XCTAssertTrue(expand.waitForExistence(timeout: 5))
    expand.click()
    let entry = element(identifier: "history-entry-\(latestID)")
    let source = element(identifier: "history-source-\(latestID)")
    let result = app.textViews["history-result-\(latestID.uppercased())"]
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    XCTAssertTrue(source.waitForExistence(timeout: 2))
    XCTAssertTrue(result.waitForExistence(timeout: 2))
    result.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()

    let redo = app.buttons["history-action-redo-\(latestID)"]
    let copySource = app.buttons["history-action-copy-source-\(latestID)"]
    let copyResult = app.buttons["history-action-copy-result-\(latestID)"]
    XCTAssertTrue(redo.waitForExistence(timeout: 2))
    XCTAssertTrue(copySource.waitForExistence(timeout: 2))
    XCTAssertTrue(copyResult.waitForExistence(timeout: 2))
    for action in [redo, copySource, copyResult] {
      XCTAssertGreaterThanOrEqual(action.frame.width, 12)
      XCTAssertLessThanOrEqual(action.frame.width, 14)
      XCTAssertGreaterThanOrEqual(action.frame.height, 12)
      XCTAssertLessThanOrEqual(action.frame.height, 14)
      XCTAssertEqual(action.frame.maxX, entry.frame.maxX, accuracy: 2)
    }
    XCTAssertGreaterThanOrEqual(
      copySource.frame.minX - source.frame.maxX,
      11,
      "Source text must not run underneath its copy action"
    )
    XCTAssertGreaterThanOrEqual(
      copyResult.frame.minX - result.frame.maxX,
      11,
      "Result text must not run underneath its sticky copy action"
    )

    let window = app.windows["辞达"]
    let screenshot = window.screenshot()
    for action in [redo, copySource, copyResult] {
      assertActionIconInkFitsThePencilBounds(action, in: window, screenshot: screenshot)
    }

    XCTContext.runActivity(named: "Expanded action Pencil column") { activity in
      let attachment = XCTAttachment(screenshot: screenshot)
      attachment.name = "Expanded row reserves one aligned 12 pt action column"
      attachment.lifetime = .keepAlways
      activity.add(attachment)
      let componentAttachment = XCTAttachment(screenshot: entry.screenshot())
      componentAttachment.name = "Expanded record component against Pencil A6fVtk"
      componentAttachment.lifetime = .keepAlways
      activity.add(componentAttachment)
    }
  }

  func testRecordActionsCopyFeedbackAndCommandCPrecedence() {
    continueAfterFailure = false
    launchApp(arguments: ["--ui-testing", "--ui-testing-scenario", "record-actions"])

    let window = app.windows["辞达"]
    let olderID = "10000000-0000-0000-0000-000000000001"
    let latestID = "10000000-0000-0000-0000-000000000002"
    let streamingID = "10000000-0000-0000-0000-000000000003"
    let olderResult = app.textViews["history-result-\(olderID.uppercased())"]
    let latestResult = app.textViews["history-result-\(latestID.uppercased())"]
    let streamingResult = app.textViews["history-result-\(streamingID.uppercased())"]
    XCTAssertFalse(olderResult.exists)
    XCTAssertFalse(latestResult.exists)
    XCTAssertTrue(streamingResult.waitForExistence(timeout: 5))

    let redo = app.buttons["history-action-redo-\(latestID)"]
    let copySource = app.buttons["history-action-copy-source-\(latestID)"]
    let copyResult = app.buttons["history-action-copy-result-\(latestID)"]
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).hover()
    XCTAssertFalse(redo.exists)
    XCTAssertFalse(copySource.exists)
    XCTAssertFalse(copyResult.exists)

    element(identifier: "history-expand-\(latestID)").click()
    XCTAssertTrue(latestResult.waitForExistence(timeout: 2))
    latestResult.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    XCTAssertTrue(redo.waitForExistence(timeout: 2))
    XCTAssertTrue(copySource.waitForExistence(timeout: 2))
    XCTAssertTrue(copyResult.waitForExistence(timeout: 2))
    let latestEntry = element(identifier: "history-entry-\(latestID)")
    XCTAssertLessThanOrEqual(
      copyResult.frame.maxX,
      latestEntry.frame.maxX + 1,
      "The result action must remain completely inside the hoverable record."
    )
    XCTAssertEqual(
      copyResult.frame.maxX,
      latestEntry.frame.maxX,
      accuracy: 1,
      "The result action must share the Pencil trailing action column."
    )

    copyResult.click()
    XCTAssertTrue(waitForPasteboard(pencilRecordActionResult, timeout: 2))
    XCTAssertEqual(copyResult.value as? String, "copied")

    XCTContext.runActivity(named: "Record hover and copied feedback") { activity in
      let attachment = XCTAttachment(screenshot: window.screenshot())
      attachment.name = "Record actions with copied checkmark"
      attachment.lifetime = .keepAlways
      activity.add(attachment)
    }

    XCTAssertTrue(waitForValue("idle", in: copyResult, timeout: 2))
    streamingResult.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    XCTAssertFalse(app.buttons["history-action-redo-\(streamingID)"].waitForExistence(timeout: 0.3))
    XCTAssertFalse(
      app.buttons["history-action-copy-source-\(streamingID)"].waitForExistence(timeout: 0.3)
    )
    XCTAssertFalse(
      app.buttons["history-action-copy-result-\(streamingID)"].waitForExistence(timeout: 0.3)
    )

    latestResult.click()
    latestResult.typeKey("c", modifierFlags: .command)
    XCTAssertTrue(waitForPasteboard(pencilRecordActionResult, timeout: 2))

    element(identifier: "history-expand-\(olderID)").click()
    XCTAssertTrue(olderResult.waitForExistence(timeout: 2))
    olderResult.click()
    olderResult.typeKey("a", modifierFlags: .command)
    olderResult.typeKey("c", modifierFlags: .command)
    XCTAssertTrue(
      waitForPasteboard("OLDER_SELECTED_RESULT", timeout: 2),
      "A native text selection must take precedence over the latest-result shortcut"
    )
  }

  func testLongResultCopyActionSticksToTheOuterHistoryViewport() {
    continueAfterFailure = false
    let launchArguments = ["--ui-testing", "--ui-testing-scenario", "sticky-long-result"]
    launchApp(arguments: launchArguments)

    let primingHistory = app.scrollViews["history-scroll-view"]
    XCTAssertTrue(primingHistory.waitForExistence(timeout: 5))
    primingHistory.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    app.terminate()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    app.launch()

    let longID = "20000000-0000-0000-0000-000000000001"
    let history = app.scrollViews["history-scroll-view"]
    let result = app.textViews["history-result-\(longID.uppercased())"]
    let copyResult = app.buttons["history-action-copy-result-\(longID)"]
    XCTAssertTrue(history.waitForExistence(timeout: 5))
    XCTAssertTrue(result.waitForExistence(timeout: 5))
    XCTAssertEqual(history.descendants(matching: .scrollView).count, 0)

    hoverVisibleIntersection(of: result, inside: history)
    XCTAssertTrue(copyResult.waitForExistence(timeout: 2))
    assertStickyAction(copyResult, followsVisibleIntersectionOf: result, inside: history)

    history.swipeDown()
    hoverVisibleIntersection(of: result, inside: history)
    XCTAssertTrue(copyResult.waitForExistence(timeout: 2))
    assertStickyAction(copyResult, followsVisibleIntersectionOf: result, inside: history)

    XCTContext.runActivity(named: "Sticky long-result action") { activity in
      let attachment = XCTAttachment(screenshot: app.windows["辞达"].screenshot())
      attachment.name = "Long result uses one scroll region with a sticky copy action"
      attachment.lifetime = .keepAlways
      activity.add(attachment)
    }
  }

  private func replaceText(in element: XCUIElement, with value: String) {
    XCTAssertTrue(element.waitForExistence(timeout: 5))
    element.click()
    element.typeKey("a", modifierFlags: .command)
    element.typeText(value)
  }

  private var pencilRecordActionResult: String {
    "Our system adopts a brand-new storage engine that significantly improves read and write performance."
  }

  private func paste(_ value: String, into element: XCUIElement) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString(value, forType: .string))
    element.click()
    element.typeKey("v", modifierFlags: .command)
  }

  private func localOpenAIEndpoint() throws -> String {
    let environment = ProcessInfo.processInfo.environment
    if let configuredEndpoint = environment["CIDA_UI_TEST_ENDPOINT"] {
      return configuredEndpoint
    }
    let workRoot = environment["CIDA_UI_TEST_WORK_ROOT"] ?? "/Users/admin/cida-ui-test-work"
    let port = try String(
      contentsOfFile: "\(workRoot)/mock-port",
      encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return "http://127.0.0.1:\(port)/v1/chat/completions"
  }

  private func configureOpenAI(endpoint: String) {
    let settingsButton = app.buttons["model-settings-button"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
    settingsButton.click()

    let settingsWindow = app.windows["设置"]
    XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
    let providerMenu = app.menuButtons.matching(
      NSPredicate(
        format: "identifier == %@ AND label == %@",
        "settings-provider-menu",
        "DeepSeek"
      )
    ).firstMatch
    XCTAssertTrue(providerMenu.waitForExistence(timeout: 5))
    providerMenu.click()
    let openAIItem = app.menuItems["OpenAI"]
    XCTAssertTrue(openAIItem.waitForExistence(timeout: 5))
    openAIItem.click()

    replaceText(in: app.textFields["settings-openai-endpoint"], with: endpoint)
    replaceText(in: app.textFields["settings-model"], with: "cida-ui-mock-model")
    replaceText(in: app.secureTextFields["settings-api-key-editor"], with: "sk-isolated-ui-test")

    let closeButton = settingsWindow.buttons[XCUIIdentifierCloseWindow]
    XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
    closeButton.click()
    XCTAssertFalse(settingsWindow.waitForExistence(timeout: 2))
  }

  private func submitAndAssertVisibleContinuity(
    _ text: String,
    completionMarker: String,
    composer: XCUIElement,
    submitButton: XCUIElement,
    history: XCUIElement
  ) throws -> String {
    paste(text, into: composer)
    XCTAssertTrue(submitButton.isEnabled)
    submitButton.click()
    XCTAssertTrue(waitForLabel("停止生成", in: submitButton, timeout: 2))

    let visibleDuringBackendPause = visibleHistoryEntryCount(in: history)
    XCTAssertGreaterThan(
      visibleDuringBackendPause,
      0,
      "Submitting must never leave the history viewport blank during first-byte latency"
    )

    let completedResult = app.textViews.matching(
      NSPredicate(format: "value CONTAINS %@", completionMarker)
    ).firstMatch
    XCTAssertTrue(completedResult.waitForExistence(timeout: 30))
    XCTAssertTrue(waitForLabel("翻译", in: submitButton, timeout: 3))
    XCTAssertTrue(waitForValue("bottom", in: history, timeout: 3))
    let visibleFrame = completedResult.frame.intersection(history.frame)
    XCTAssertGreaterThan(visibleFrame.height, 20)
    XCTAssertGreaterThan(visibleFrame.width, 100)
    XCTAssertGreaterThanOrEqual(
      completedResult.frame.maxY,
      history.frame.maxY - 120,
      "The completed result bottom must remain near the history viewport bottom"
    )

    XCTContext.runActivity(named: "\(text) remains visible through completion") { activity in
      let attachment = XCTAttachment(screenshot: app.windows["辞达"].screenshot())
      attachment.name = "\(text) completed at the bottom of production-shaped history"
      attachment.lifetime = .keepAlways
      activity.add(attachment)
    }

    let resultID = completedResult.identifier.replacingOccurrences(
      of: "history-result-",
      with: ""
    )
    let contentEnd = app.groups["history-result-content-end-\(resultID)"]
    XCTAssertTrue(contentEnd.waitForExistence(timeout: 3))
    XCTAssertGreaterThanOrEqual(
      contentEnd.frame.maxY,
      history.frame.maxY - 120,
      "The final rendered glyph must remain near the history viewport bottom"
    )
    return resultID.lowercased()
  }

  private func visibleHistoryEntryCount(in history: XCUIElement) -> Int {
    let entries = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "history-entry-")
    )
    return (0..<entries.count).reduce(into: 0) { count, index in
      let entry = entries.element(boundBy: index)
      guard entry.exists else { return }
      let intersection = entry.frame.intersection(history.frame)
      if intersection.height > 8, intersection.width > 100 {
        count += 1
      }
    }
  }

  private func historyEntryIdentifiers() -> Set<String> {
    let entries = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "history-entry-")
    )
    return Set(entries.allElementsBoundByIndex.map(\.identifier))
  }

  private func waitForNewHistoryEntry(
    excluding existingIdentifiers: Set<String>,
    timeout: TimeInterval
  ) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let identifier = historyEntryIdentifiers().first(where: {
        !existingIdentifiers.contains($0)
      }) {
        return identifier
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return nil
  }

  private func neutralDarkPixelCount(
    in screenshot: XCUIScreenshot,
    logicalWidth: CGFloat,
    topPoints: CGFloat
  ) -> Int {
    guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation) else {
      XCTFail("Could not decode the result screenshot")
      return .max
    }

    let scale = CGFloat(bitmap.pixelsWide) / max(1, logicalWidth)
    let maximumY = min(bitmap.pixelsHigh, max(1, Int(ceil(topPoints * scale))))
    var count = 0
    for y in 0..<maximumY {
      for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        let maximumChannel = channels.max() ?? 1
        let minimumChannel = channels.min() ?? 0
        if color.alphaComponent > 0.5
          && maximumChannel < 0.82
          && maximumChannel - minimumChannel < 0.08
        {
          count += 1
        }
      }
    }
    return count
  }

  private func element(identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == %@", identifier)
    ).firstMatch
  }

  private func waitForFrameHeight(
    atLeast minimumHeight: CGFloat? = nil,
    atMost maximumHeight: CGFloat? = nil,
    in element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let height = element.frame.height
      if minimumHeight.map({ height >= $0 }) ?? true,
        maximumHeight.map({ height <= $0 }) ?? true
      {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return false
  }

  private func waitForValue(
    _ expectedValue: String,
    in element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    let predicate = NSPredicate(format: "value == %@", expectedValue)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitForLabel(
    _ expectedLabel: String,
    in element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    let predicate = NSPredicate(format: "label == %@", expectedLabel)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitForCount(
    _ expectedCount: Int,
    in query: XCUIElementQuery,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if query.count == expectedCount { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return false
  }

  private func launchApp(arguments: [String]) {
    let environment = ProcessInfo.processInfo.environment
    let workRoot = environment["CIDA_UI_TEST_WORK_ROOT"] ?? "/Users/admin/cida-ui-test-work"
    let appPath =
      environment["CIDA_UI_TEST_APP_PATH"]
      ?? "\(workRoot)/Cida UI Testing.app"
    app = XCUIApplication(url: URL(fileURLWithPath: appPath))
    app.launchEnvironment["CIDA_ISOLATED_AUTOMATION"] = "1"
    app.launchArguments = arguments
    app.launch()
    app.activate()

    XCTAssertTrue(waitForForegroundApp(timeout: 10))
    XCTAssertTrue(app.windows["辞达"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.textViews["composer-input"].waitForExistence(timeout: 5))
    addTeardownBlock { [app] in
      app?.terminate()
    }
  }

  private func waitForPasteboard(_ expectedValue: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if NSPasteboard.general.string(forType: .string) == expectedValue {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return false
  }

  private func hoverVisibleIntersection(of element: XCUIElement, inside container: XCUIElement) {
    let visibleFrame = element.frame.intersection(container.frame)
    XCTAssertGreaterThan(visibleFrame.height, 20)
    let normalizedY = min(
      0.95,
      max(0.05, (visibleFrame.minY + 16 - container.frame.minY) / container.frame.height)
    )
    container.coordinate(
      withNormalizedOffset: CGVector(dx: 0.72, dy: normalizedY)
    ).hover()
  }

  private func assertStickyAction(
    _ action: XCUIElement,
    followsVisibleIntersectionOf result: XCUIElement,
    inside history: XCUIElement,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let visibleFrame = result.frame.intersection(history.frame)
    XCTAssertGreaterThan(visibleFrame.height, 20, file: file, line: line)
    XCTAssertGreaterThanOrEqual(action.frame.minY, visibleFrame.minY, file: file, line: line)
    XCTAssertLessThanOrEqual(
      action.frame.minY - visibleFrame.minY,
      10,
      "The action must remain at the top of the currently visible result slice",
      file: file,
      line: line
    )
    XCTAssertLessThanOrEqual(action.frame.maxY, visibleFrame.maxY, file: file, line: line)
  }

  private func assertActionIconInkFitsThePencilBounds(
    _ action: XCUIElement,
    in window: XCUIElement,
    screenshot: XCUIScreenshot,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation) else {
      XCTFail("Could not decode the record-action screenshot", file: file, line: line)
      return
    }

    let scale = CGFloat(bitmap.pixelsWide) / max(1, window.frame.width)
    let actionRect = action.frame.offsetBy(
      dx: -window.frame.minX,
      dy: -window.frame.minY
    )
    let searchRect = actionRect.insetBy(dx: -6, dy: -6)
    let minimumPixelX = max(0, Int(floor(searchRect.minX * scale)))
    let maximumPixelX = min(bitmap.pixelsWide - 1, Int(ceil(searchRect.maxX * scale)))
    let minimumTopPixelY = max(0, Int(floor(searchRect.minY * scale)))
    let maximumTopPixelY = min(
      bitmap.pixelsHigh - 1,
      Int(ceil(searchRect.maxY * scale))
    )
    var inkPixelCount = 0
    var outsideActionPixelCount = 0
    var inkMinimumX = Int.max
    var inkMinimumTopY = Int.max
    var inkMaximumX = Int.min
    var inkMaximumTopY = Int.min

    for topPixelY in minimumTopPixelY...maximumTopPixelY {
      for pixelX in minimumPixelX...maximumPixelX {
        guard
          let color = bitmap.colorAt(x: pixelX, y: topPixelY)?.usingColorSpace(.deviceRGB)
        else {
          continue
        }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        let maximum = channels.max() ?? 1
        let minimum = channels.min() ?? 0
        let isActionInk =
          color.alphaComponent > 0.5
          && maximum > 0.50
          && maximum < 0.84
          && maximum - minimum < 0.12
        guard isActionInk else { continue }

        inkPixelCount += 1
        inkMinimumX = min(inkMinimumX, pixelX)
        inkMinimumTopY = min(inkMinimumTopY, topPixelY)
        inkMaximumX = max(inkMaximumX, pixelX)
        inkMaximumTopY = max(inkMaximumTopY, topPixelY)
        let localPoint = CGPoint(
          x: (CGFloat(pixelX) + 0.5) / scale,
          y: (CGFloat(topPixelY) + 0.5) / scale
        )
        if !actionRect.insetBy(dx: -0.5, dy: -0.5).contains(localPoint) {
          outsideActionPixelCount += 1
        }
      }
    }

    XCTAssertGreaterThan(
      inkPixelCount,
      12,
      "The record action must paint a visible Lucide icon",
      file: file,
      line: line
    )
    XCTAssertEqual(
      outsideActionPixelCount,
      0,
      "The icon ink escaped its 12 × 12 pt Pencil frame",
      file: file,
      line: line
    )
    guard inkPixelCount > 0 else { return }
    let inkWidth = CGFloat(inkMaximumX - inkMinimumX + 1) / scale
    let inkHeight = CGFloat(inkMaximumTopY - inkMinimumTopY + 1) / scale
    XCTAssertLessThanOrEqual(inkWidth, 12, file: file, line: line)
    XCTAssertLessThanOrEqual(inkHeight, 12, file: file, line: line)
  }

  private func assertPencilScrollIndicator(
    in scrollView: XCUIElement,
    activity: XCTActivity,
    attachmentName: String
  ) -> CGFloat {
    scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.5)).hover()
    scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    let screenshot = scrollView.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = attachmentName
    attachment.lifetime = .keepAlways
    activity.add(attachment)

    guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation) else {
      XCTFail("Could not decode the history screenshot")
      return 0
    }

    let scale = CGFloat(bitmap.pixelsWide) / max(1, scrollView.frame.width)
    let trailingPixelWidth = min(bitmap.pixelsWide, Int(ceil(12 * scale)))
    let minimumThumbRun = max(1, Int(floor(2 * scale)))
    let edgeBorderInset = min(bitmap.pixelsHigh / 2, Int(ceil(4 * scale)))
    var maximumHorizontalRun = 0
    var currentVerticalRun = 0
    var currentVerticalRunStart = 0
    var maximumVerticalRun = 0
    var maximumVerticalRunStart = 0
    var maximumVerticalRunEnd = 0

    for y in edgeBorderInset..<(bitmap.pixelsHigh - edgeBorderInset) {
      var currentHorizontalRun = 0
      var rowMaximumHorizontalRun = 0
      for x in (bitmap.pixelsWide - trailingPixelWidth)..<bitmap.pixelsWide {
        guard
          let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        else {
          currentHorizontalRun = 0
          continue
        }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        let maximumChannel = channels.max() ?? 1
        let minimumChannel = channels.min() ?? 0
        let isNeutralDarkPixel =
          color.alphaComponent > 0.5
          && maximumChannel < 0.94
          && maximumChannel - minimumChannel < 0.08
        if isNeutralDarkPixel {
          currentHorizontalRun += 1
          rowMaximumHorizontalRun = max(rowMaximumHorizontalRun, currentHorizontalRun)
        } else {
          currentHorizontalRun = 0
        }
      }

      maximumHorizontalRun = max(maximumHorizontalRun, rowMaximumHorizontalRun)
      if rowMaximumHorizontalRun >= minimumThumbRun {
        if currentVerticalRun == 0 {
          currentVerticalRunStart = y
        }
        currentVerticalRun += 1
        if currentVerticalRun > maximumVerticalRun {
          maximumVerticalRun = currentVerticalRun
          maximumVerticalRunStart = currentVerticalRunStart
          maximumVerticalRunEnd = y
        }
      } else {
        currentVerticalRun = 0
      }
    }

    let maximumWidth = CGFloat(maximumHorizontalRun) / scale
    let maximumHeight = CGFloat(maximumVerticalRun) / scale
    XCTAssertGreaterThanOrEqual(maximumWidth, 3)
    XCTAssertLessThanOrEqual(
      maximumWidth,
      6,
      "An AppKit proportional overlay thumb appeared beside the 4 pt Pencil thumb"
    )
    XCTAssertGreaterThanOrEqual(maximumHeight, 80)
    XCTAssertLessThanOrEqual(
      maximumHeight,
      100,
      "The history indicator must keep its fixed 90 pt Pencil length while active"
    )
    return CGFloat(maximumVerticalRunStart + maximumVerticalRunEnd + 1) / (2 * scale)
  }

  private func waitForForegroundApp(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if app.state == .runningForeground {
        return true
      }
      app.activate()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return false
  }

  private func recordedRequest(at path: String) throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: path), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
