import AppKit
import QuartzCore
import SwiftUI
import XCTest

@testable import Cida

@MainActor
final class InteractionReproductionTests: XCTestCase {
  static var clickEventNumber = 0
  var retainedTestWindows: [NSWindow] = []

  override func tearDown() async throws {
    CATransaction.flush()
    let retainedContentViews = retainedTestWindows.compactMap(\.contentView)
    for window in retainedTestWindows {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }
    CATransaction.flush()
    retainedTestWindows.removeAll(keepingCapacity: false)
    withExtendedLifetime(retainedContentViews) {}
    try await Task.sleep(for: .milliseconds(10))
    try await super.tearDown()
  }

  func testWindowSupportsCloseMinimizeZoomAndControlInteraction() {
    let window = CidaWindowFactory.makeWindow(
      size: CGSize(width: 860, height: 640),
      title: "Test"
    )

    XCTAssertTrue(window.styleMask.contains(.titled))
    XCTAssertTrue(window.styleMask.contains(.closable))
    XCTAssertTrue(window.styleMask.contains(.miniaturizable))
    XCTAssertTrue(window.styleMask.contains(.resizable))
    XCTAssertTrue(window.titlebarAppearsTransparent)
    XCTAssertFalse(window.isMovableByWindowBackground)
    XCTAssertNotNil(window.standardWindowButton(.closeButton))
    XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
    XCTAssertNotNil(window.standardWindowButton(.zoomButton))
    XCTAssertGreaterThan(window.maxSize.width, window.minSize.width)
    XCTAssertGreaterThan(window.maxSize.height, window.minSize.height)

    let originalLayoutSize = window.contentLayoutRect.size
    window.setContentSize(CGSize(width: 960, height: 740))
    XCTAssertGreaterThan(window.contentLayoutRect.size.width, originalLayoutSize.width)
    XCTAssertGreaterThan(window.contentLayoutRect.size.height, originalLayoutSize.height)
  }

  func testMainAndSettingsContentFillResizedNativeWindows() {
    let model = AppModel(entries: [], settings: .designPreview)
    let (mainWindow, mainHostingView) = makeNativeWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    let (settingsWindow, settingsHostingView) = makeNativeWindow(
      rootView: SettingsWindowView(model: model),
      size: CGSize(width: 560, height: 660)
    )

    mainWindow.setContentSize(CGSize(width: 960, height: 740))
    settingsWindow.setContentSize(CGSize(width: 720, height: 820))
    mainHostingView.layoutSubtreeIfNeeded()
    settingsHostingView.layoutSubtreeIfNeeded()

    XCTAssertEqual(mainHostingView.frame.size.width, 960, accuracy: 0.5)
    XCTAssertEqual(mainHostingView.frame.size.height, 740, accuracy: 0.5)
    XCTAssertEqual(settingsHostingView.frame.size.width, 720, accuracy: 0.5)
    XCTAssertEqual(settingsHostingView.frame.size.height, 820, accuracy: 0.5)
  }

  func testMainAndSettingsWindowsBothZoomAndRestoreInTheBackground() {
    let configurations: [(title: String, size: CGSize, minimumSize: CGSize)] = [
      ("Main", CGSize(width: 860, height: 640), CGSize(width: 640, height: 480)),
      ("Settings", CGSize(width: 560, height: 660), CGSize(width: 500, height: 500)),
    ]

    for configuration in configurations {
      let window = CidaWindowFactory.makeWindow(
        size: configuration.size,
        minimumSize: configuration.minimumSize,
        title: configuration.title
      )
      window.animationBehavior = .none
      window.alphaValue = 0
      window.center()
      window.orderBack(nil)
      let originalFrame = window.frame
      window.zoom(nil)
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      let zoomedFrame = window.frame
      window.zoom(nil)
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      let restoredFrame = window.frame
      window.orderOut(nil)

      XCTAssertNotEqual(zoomedFrame, originalFrame, configuration.title)
      XCTAssertEqual(restoredFrame.origin.x, originalFrame.origin.x, accuracy: 0.5)
      XCTAssertEqual(restoredFrame.origin.y, originalFrame.origin.y, accuracy: 0.5)
      XCTAssertEqual(restoredFrame.width, originalFrame.width, accuracy: 0.5)
      XCTAssertEqual(restoredFrame.height, originalFrame.height, accuracy: 0.5)
    }
    assertTestProcessIsNotFrontmost()
  }

  func testNativeCloseButtonClosesARealBackgroundSettingsWindow() throws {
    let (window, _) = makeNativeWindow(
      rootView: SettingsWindowView(model: AppModel(entries: [])),
      size: CGSize(width: 560, height: 660)
    )
    window.alphaValue = 0
    window.orderBack(nil)
    XCTAssertTrue(window.isVisible)

    let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
    closeButton.performClick(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))

    XCTAssertFalse(window.isVisible)
    assertTestProcessIsNotFrontmost()
  }

  func testSettingsContentRemainsScrollableAtItsMinimumWindowSize() throws {
    var settings = CidaSettings.designPreview
    settings.provider = .openAI
    settings.model = "local-model"
    let (_, hostingView) = makeNativeWindow(
      rootView: SettingsWindowView(model: AppModel(entries: [], settings: settings)),
      size: CGSize(width: 500, height: 500)
    )
    let scrollView = try XCTUnwrap(
      allScrollViews(in: hostingView).max { lhs, rhs in
        (lhs.documentView?.bounds.height ?? 0) < (rhs.documentView?.bounds.height ?? 0)
      }
    )
    let documentView = try XCTUnwrap(scrollView.documentView)

    XCTAssertGreaterThan(documentView.bounds.height, scrollView.contentView.bounds.height)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    let settingsIndicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "settings-scroll-indicator")
    )
    XCTAssertFalse(settingsIndicator.isHidden)
    XCTAssertEqual(settingsIndicator.knobDrawingRect.width, 4, accuracy: 0.1)
    XCTAssertEqual(settingsIndicator.knobDrawingRect.height, 64, accuracy: 0.1)
    let bottomOrigin = NSPoint(
      x: 0,
      y: max(0, documentView.bounds.maxY - scrollView.contentView.bounds.height)
    )
    scrollView.contentView.scroll(to: bottomOrigin)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    XCTAssertTrue(isScrolledToBottom(scrollView))
  }

  func testSettingsHidesItsScrollIndicatorAtThePencilWindowSize() throws {
    let (window, hostingView) = makeHiddenWindow(
      rootView: SettingsWindowView(
        model: AppModel(entries: [], settings: .designPreview)
      ),
      size: CGSize(width: 560, height: 660)
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    hostingView.layoutSubtreeIfNeeded()

    let indicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "settings-scroll-indicator")
    )
    let scrollView = try XCTUnwrap(indicator.observedScrollView)
    let documentView = try XCTUnwrap(scrollView.documentView)
    XCTAssertTrue(
      indicator.isHidden,
      "document=\(documentView.bounds) visible=\(scrollView.contentView.documentVisibleRect)"
    )
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testModelStatusButtonOpensSettings() {
    var settingsRequestCount = 0
    let model = AppModel(entries: [], settings: .designPreview)
    let (window, _) = makeHiddenWindow(
      rootView: MainWindowView(model: model) {
        settingsRequestCount += 1
      },
      size: CGSize(width: 860, height: 640)
    )
    window.alphaValue = 0
    window.orderBack(nil)

    click(window: window, at: NSPoint(x: 786, y: 617))
    window.orderOut(nil)

    XCTAssertEqual(settingsRequestCount, 1)
    assertTestProcessIsNotFrontmost()
  }

  func testClickingComposerThenTypingUsesTheRealResponderChain() async throws {
    let model = AppModel(entries: [])
    let (window, hostingView) = makeNativeWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    window.alphaValue = 0
    window.orderBack(nil)
    hostingView.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    hostingView.layoutSubtreeIfNeeded()
    let input = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))
    let scrollView = try XCTUnwrap(input.enclosingScrollView)
    let indicator = try XCTUnwrap(CidaScrollIndicator.installed(in: scrollView))
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      scrollView.layoutSubtreeIfNeeded()
      indicator.refresh()
      return (indicator.superview?.frame.height ?? 0) > 0 && indicator.isHidden
    }
    XCTAssertTrue(
      indicator.isHidden,
      "document=\(String(describing: scrollView.documentView?.bounds)) visible=\(scrollView.contentView.documentVisibleRect) indicator=\(indicator.frame) host=\(String(describing: indicator.superview?.frame))"
    )
    let clickPoint = input.convert(NSPoint(x: 12, y: 12), to: nil)
    let hitView = window.contentView?.hitTest(clickPoint)
    XCTAssertTrue(
      hitView === input,
      "hit=\(String(describing: hitView)) input=\(input.frame) scroll=\(String(describing: input.enclosingScrollView?.frame)) point=\(clickPoint)"
    )
    guard hitView === input else { return }
    let trailingClickPoint = input.convert(
      NSPoint(x: input.bounds.maxX - 4, y: 12),
      to: nil
    )
    XCTAssertTrue(window.contentView?.hitTest(trailingClickPoint) === input)

    clickTextInput(window: window, at: clickPoint)
    XCTAssertTrue(window.firstResponder === input || window.makeFirstResponder(input))

    type("Real keyboard input", in: window)
    try await Task.sleep(for: .milliseconds(50))

    XCTAssertEqual(input.string, "Real keyboard input")
    XCTAssertEqual(model.inputText, "Real keyboard input")
    assertTestProcessIsNotFrontmost()
  }

}
