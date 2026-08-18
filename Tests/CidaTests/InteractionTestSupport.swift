import AppKit
import QuartzCore
import SwiftUI
import XCTest

@testable import Cida

@MainActor
extension InteractionReproductionTests {

  func makeHiddenWindow<Content: View>(
    rootView: Content,
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
    window.contentView = hostingView
    retainedTestWindows.append(window)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    return (window, hostingView)
  }

  func waitUntil(
    timeout: Duration,
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      if clock.now >= deadline {
        XCTFail("Timed out waiting for condition")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func assertTestProcessIsNotFrontmost(
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertFalse(NSApp.isActive, file: file, line: line)
    XCTAssertNotEqual(
      NSWorkspace.shared.frontmostApplication?.processIdentifier,
      ProcessInfo.processInfo.processIdentifier,
      file: file,
      line: line
    )
  }

  func makeNativeWindow<Content: View>(
    rootView: Content,
    size: CGSize
  ) -> (CidaWindow, NSHostingView<Content>) {
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.autoresizingMask = [.width, .height]
    let window = CidaWindowFactory.makeWindow(size: size, title: "Test")
    window.contentView = hostingView
    window.setContentSize(size)
    retainedTestWindows.append(window)
    hostingView.layoutSubtreeIfNeeded()
    return (window, hostingView)
  }

  func firstTextField(
    in view: NSView,
    identifier: String
  ) -> NSTextField? {
    let fields = allTextFields(in: view)
    return fields.first { $0.accessibilityIdentifier() == identifier }
      ?? fields.first { $0.isEditable }
  }

  func allTextFields(in view: NSView) -> [NSTextField] {
    var fields: [NSTextField] = []
    if let field = view as? NSTextField {
      fields.append(field)
    }
    for child in view.subviews {
      fields.append(contentsOf: allTextFields(in: child))
    }
    return fields
  }

  func allScrollViews(in view: NSView) -> [NSScrollView] {
    var scrollViews: [NSScrollView] = []
    if let scrollView = view as? NSScrollView {
      scrollViews.append(scrollView)
    }
    for child in view.subviews {
      scrollViews.append(contentsOf: allScrollViews(in: child))
    }
    return scrollViews
  }

  func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
    guard let documentView = scrollView.documentView else { return false }
    let visibleRect = scrollView.contentView.documentVisibleRect
    if documentView.isFlipped {
      return visibleRect.maxY >= documentView.bounds.maxY - 24
    }
    return visibleRect.minY <= documentView.bounds.minY + 24
  }

  func scrollDescription(_ scrollView: NSScrollView) -> String {
    guard let documentView = scrollView.documentView else { return "missing document view" }
    return
      "visible=\(scrollView.contentView.documentVisibleRect) document=\(documentView.bounds) flipped=\(documentView.isFlipped) frame=\(scrollView.frame)"
  }

  func firstTextView(in view: NSView, identifier: String) -> NSTextView? {
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

  func allHistoryResultContainers(in view: NSView) -> [HistoryResultTextContainer] {
    var containers: [HistoryResultTextContainer] = []
    if let container = view as? HistoryResultTextContainer {
      containers.append(container)
    }
    for child in view.subviews {
      containers.append(contentsOf: allHistoryResultContainers(in: child))
    }
    return containers
  }

  func minimumAncestorAlpha(from view: NSView) -> CGFloat {
    var minimumAlpha = view.alphaValue
    var ancestor = view.superview
    while let current = ancestor {
      minimumAlpha = min(minimumAlpha, current.alphaValue)
      ancestor = current.superview
    }
    return minimumAlpha
  }

  func firstHistoryResultContainer(
    in view: NSView,
    identifier: String
  ) -> HistoryResultTextContainer? {
    if let container = view as? HistoryResultTextContainer,
      container.subviews.contains(where: {
        $0.accessibilityIdentifier() == identifier
      })
    {
      return container
    }
    for child in view.subviews {
      if let result = firstHistoryResultContainer(in: child, identifier: identifier) {
        return result
      }
    }
    return nil
  }

  func nativeHistoryEntryAncestor(of view: NSView) -> HistoryEntryNSView? {
    var ancestor = view.superview
    while let current = ancestor {
      if let historyEntry = current as? HistoryEntryNSView {
        return historyEntry
      }
      ancestor = current.superview
    }
    return nil
  }

  func firstScroller(in view: NSView, identifier: String) -> CidaScrollIndicator? {
    if let scroller = view as? CidaScrollIndicator,
      scroller.accessibilityIdentifier() == identifier
    {
      return scroller
    }
    for child in view.subviews {
      if let result = firstScroller(in: child, identifier: identifier) {
        return result
      }
    }
    return nil
  }

  func firstVirtualizedHistoryList(
    in view: NSView
  ) -> VirtualizedFoldedHistoryListNSView? {
    if let list = view as? VirtualizedFoldedHistoryListNSView {
      return list
    }
    for child in view.subviews {
      if let result = firstVirtualizedHistoryList(in: child) {
        return result
      }
    }
    return nil
  }

  func firstHistoryEntryHoverTracker(
    in view: NSView
  ) -> HistoryEntryHoverTrackingNSView? {
    if let tracker = view as? HistoryEntryHoverTrackingNSView {
      return tracker
    }
    for child in view.subviews {
      if let result = firstHistoryEntryHoverTracker(in: child) {
        return result
      }
    }
    return nil
  }

  func click(window: NSWindow, at point: NSPoint) {
    Self.clickEventNumber += 1
    let eventNumber = Self.clickEventNumber
    let down = NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: 1,
      pressure: 1
    )!
    let up = NSEvent.mouseEvent(
      with: .leftMouseUp,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: 1,
      pressure: 0
    )!
    window.sendEvent(down)
    window.sendEvent(up)
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
  }

  func type(_ value: String, in window: NSWindow) {
    for character in value {
      let text = String(character)
      let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: text,
        charactersIgnoringModifiers: text,
        isARepeat: false,
        keyCode: 0
      )!
      window.sendEvent(event)
    }
  }

  func clickTextInput(window: NSWindow, at point: NSPoint) {
    Self.clickEventNumber += 1
    let eventNumber = Self.clickEventNumber
    let down = NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: 1,
      pressure: 1
    )!
    let up = NSEvent.mouseEvent(
      with: .leftMouseUp,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: 1,
      pressure: 0
    )!
    NSApp.postEvent(up, atStart: true)
    window.sendEvent(down)
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
  }

}

final class HistoryResultHeightProbeView: NSView, HistoryResultHeightChangeHosting {
  private(set) var publishedHeightDeltas: [CGFloat] = []

  func historyResultHeightWillChange(by delta: CGFloat) {
    publishedHeightDeltas.append(delta)
  }
}

@MainActor
final class FlippedTestDocumentView: NSView {
  override var isFlipped: Bool { true }
}

struct ImmediateStreamingService: TextProcessingService {
  func stream(
    _ request: ProcessingRequest,
    settings: CidaSettings
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield("Done")
      continuation.finish()
    }
  }
}

struct BackendPauseStreamingService: TextProcessingService {
  func stream(
    _ request: ProcessingRequest,
    settings: CidaSettings
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await Task.sleep(for: .seconds(5))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
