import AppKit
import QuartzCore

@MainActor
final class MillionCharacterPasteWorkload {
  static let documentCharacterCount = 1_000_000
  static let maximumAcceptanceDurationMilliseconds = 50.0

  private let model: AppModel
  private weak var rootView: NSView?
  private let warmupPasteboard = NSPasteboard.withUniqueName()
  private let document: String
  private let preparedDocument: ComposerPreparedPaste
  private var textView: NSTextView?
  private(set) var didAttemptPaste = false
  private(set) var pasteAccepted = false
  private(set) var operationDurationMilliseconds: Double?
  private(set) var pasteAcceptanceDurationMilliseconds: Double?
  private var didWarmUpNativePaste = false

  init(model: AppModel, rootView: NSView) {
    self.model = model
    self.rootView = rootView

    let line = String(repeating: "A", count: 99) + "\n"
    document = String(repeating: line, count: 10_000)
    precondition(document.count == Self.documentCharacterCount)
    preparedDocument = ComposerPreparedPaste(document)

    warmupPasteboard.clearContents()
    warmupPasteboard.setString(
      String(repeating: "W", count: ComposerNativeTextView.virtualDocumentThreshold),
      forType: .string
    )
  }

  @discardableResult
  func performPaste() -> Bool {
    guard !didAttemptPaste else { return false }
    didAttemptPaste = true

    guard
      let textView = (textView ?? composerTextView()) as? ComposerNativeTextView
    else {
      return true
    }

    self.textView = textView
    textView.setSelectedRange(NSRange(location: 0, length: textView.textStorage?.length ?? 0))

    let startedAt = CACurrentMediaTime()
    pasteAccepted = textView.performPaste(preparedDocument)
    pasteAcceptanceDurationMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
    operationDurationMilliseconds = textView.lastLargeDocumentPasteDurationMilliseconds
    return true
  }

  func warmUpNativePaste() {
    guard
      !didWarmUpNativePaste,
      let textView = composerTextView() as? ComposerNativeTextView
    else {
      return
    }
    didWarmUpNativePaste = true
    self.textView = textView
    textView.requestPaste(from: warmupPasteboard)
  }

  func resetAfterWarmup() {
    guard
      didWarmUpNativePaste,
      let textView = (textView ?? composerTextView()) as? ComposerNativeTextView
    else {
      return
    }
    self.textView = textView
    textView.replaceDocumentFromBinding("")
    textView.didChangeText()
    model.stageInputDocument(nil)
    model.inputText = ""
    warmupPasteboard.releaseGlobally()
  }

  func metrics() -> FramePacingWorkloadMetrics {
    let nativeCharacterCount =
      (textView as? ComposerNativeTextView)?.documentUTF16Length
      ?? textView?.textStorage?.length
    let modelCharacterCount = model.inputDocumentUTF16Count
    let completedPasteDuration =
      (textView as? ComposerNativeTextView)?.lastLargeDocumentPasteDurationMilliseconds
      ?? operationDurationMilliseconds
    let completed =
      didAttemptPaste && pasteAccepted
      && nativeCharacterCount == Self.documentCharacterCount
      && modelCharacterCount == Self.documentCharacterCount
      && (completedPasteDuration ?? .infinity) <= Self.maximumAcceptanceDurationMilliseconds

    return FramePacingWorkloadMetrics(
      completed: completed,
      inputCharacterCount: nativeCharacterCount,
      operationDurationMilliseconds: completedPasteDuration
    )
  }

  private func composerTextView() -> NSTextView? {
    guard let rootView else { return nil }
    return findComposerTextView(in: rootView)
  }

  private func findComposerTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView,
      textView.accessibilityIdentifier() == "composer-input"
    {
      return textView
    }

    for child in view.subviews {
      if let result = findComposerTextView(in: child) {
        return result
      }
    }
    return nil
  }
}
