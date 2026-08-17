import AppKit
import QuartzCore

@MainActor
final class ComposerNativeTextView: NSTextView {
  nonisolated static let virtualDocumentThreshold = 100_000
  // Keep TextKit's synchronous paste layout close to one visible composer viewport.
  // Earlier content is materialized incrementally only when the user scrolls upward.
  nonisolated static let initialMaterializedUTF16Length = 512
  nonisolated static let materializedPageUTF16Length = 1_024

  var largeDocumentPasteDidBegin: ((ComposerTextMetrics) -> Void)?
  var virtualDocumentDidInstall: ((String, ComposerTextMetrics) -> Void)?

  private(set) var isPerformingLargeDocumentPaste = false
  private(set) var lastLargeDocumentPasteDurationMilliseconds: Double?
  private(set) var materializedDocumentRange = NSRange(location: 0, length: 0)

  private var virtualDocument: NSMutableString?
  private var originalVirtualValue: String?
  private var virtualDocumentMetrics: ComposerTextMetrics?
  private var pasteReadTask: Task<Void, Never>?
  private var isApplyingMaterializedText = false
  private var isPageLoadScheduled = false

  var isVirtualizingLargeDocument: Bool {
    virtualDocument != nil
  }

  var documentUTF16Length: Int {
    virtualDocument?.length ?? textStorage?.length ?? 0
  }

  var documentMetrics: ComposerTextMetrics {
    if let virtualDocumentMetrics {
      return ComposerTextMetrics(
        characterCount: documentUTF16Length,
        formattedCharacterCount: virtualDocumentMetrics.formattedCharacterCount,
        hasLineBreak: virtualDocumentMetrics.hasLineBreak,
        hasNonWhitespace: virtualDocumentMetrics.hasNonWhitespace,
        isImportingLargeDocument: false
      )
    }
    return ComposerTextMetrics(text: string)
  }

  override func paste(_ sender: Any?) {
    guard requestPaste(from: .general) else {
      super.paste(sender)
      return
    }
  }

  override func scrollWheel(with event: NSEvent) {
    super.scrollWheel(with: event)
    guard isVirtualizingLargeDocument, !isPageLoadScheduled else { return }
    isPageLoadScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.isPageLoadScheduled = false
      guard
        let scrollView = self.enclosingScrollView,
        scrollView.contentView.bounds.minY <= 96
      else {
        return
      }
      _ = self.materializePreviousPage()
    }
  }

  @discardableResult
  func requestPaste(from pasteboard: NSPasteboard) -> Bool {
    guard pasteReadTask == nil, !isPerformingLargeDocumentPaste else {
      NSSound.beep()
      return true
    }

    let pasteboardName = pasteboard.name
    let replacementRange = selectedRange()
    let startedAt = CACurrentMediaTime()
    isPerformingLargeDocumentPaste = true
    pasteReadTask = Task { @MainActor [weak self] in
      let preparedText = await Task.detached(priority: .background) {
        NSPasteboard(name: pasteboardName).string(forType: .string)
          .map(ComposerPreparedPaste.init)
      }.value
      guard let self, !Task.isCancelled else { return }
      self.pasteReadTask = nil
      guard let preparedText else {
        self.isPerformingLargeDocumentPaste = false
        return
      }

      if preparedText.source.length >= Self.virtualDocumentThreshold {
        self.installVirtualDocument(
          preparedText,
          replacementRange: replacementRange,
          startedAt: startedAt
        )
      } else {
        self.isPerformingLargeDocumentPaste = false
        self.insertText(preparedText.value, replacementRange: replacementRange)
        self.lastLargeDocumentPasteDurationMilliseconds =
          (CACurrentMediaTime() - startedAt) * 1_000
      }
    }
    return true
  }

  @discardableResult
  func performPaste(_ value: String) -> Bool {
    performPaste(ComposerPreparedPaste(value))
  }

  @discardableResult
  func performPaste(_ preparedText: ComposerPreparedPaste) -> Bool {
    guard preparedText.source.length >= Self.virtualDocumentThreshold else { return false }
    guard !isPerformingLargeDocumentPaste else {
      NSSound.beep()
      return true
    }

    isPerformingLargeDocumentPaste = true
    installVirtualDocument(
      preparedText,
      replacementRange: selectedRange(),
      startedAt: CACurrentMediaTime()
    )
    return true
  }

  func commitMaterializedEditsToDocument() {
    guard
      !isApplyingMaterializedText,
      let virtualDocument,
      materializedDocumentRange.location + materializedDocumentRange.length
        <= virtualDocument.length
    else {
      return
    }

    let visibleText = string
    let visibleSource = visibleText as NSString
    let currentSlice = virtualDocument.substring(with: materializedDocumentRange)
    guard currentSlice != visibleText else { return }

    virtualDocument.replaceCharacters(in: materializedDocumentRange, with: visibleText)
    materializedDocumentRange.length = visibleSource.length
    originalVirtualValue = nil
    if var metrics = virtualDocumentMetrics {
      metrics = ComposerTextMetrics(
        characterCount: virtualDocument.length,
        hasLineBreak: metrics.hasLineBreak || visibleSource.range(of: "\n").location != NSNotFound,
        hasNonWhitespace: metrics.hasNonWhitespace || !visibleText.isEmpty,
        isImportingLargeDocument: false
      )
      virtualDocumentMetrics = metrics
    }
  }

  func documentStringForBinding() -> String {
    commitMaterializedEditsToDocument()
    if let originalVirtualValue {
      return originalVirtualValue
    }
    return virtualDocument.map { $0 as String } ?? string
  }

  func replaceDocumentFromBinding(_ value: String) {
    if value.isEmpty {
      clearVirtualDocument()
      return
    }

    guard value.utf16.count >= Self.virtualDocumentThreshold else {
      virtualDocument = nil
      originalVirtualValue = nil
      virtualDocumentMetrics = nil
      materializedDocumentRange = NSRange(location: 0, length: 0)
      setMaterializedText(value)
      return
    }

    installVirtualDocument(
      ComposerPreparedPaste(value),
      replacementRange: NSRange(location: 0, length: 0),
      startedAt: CACurrentMediaTime()
    )
  }

  @discardableResult
  func materializePreviousPage() -> Bool {
    guard let virtualDocument, materializedDocumentRange.location > 0 else { return false }
    commitMaterializedEditsToDocument()

    let oldStart = materializedDocumentRange.location
    var newStart = max(0, oldStart - Self.materializedPageUTF16Length)
    if newStart > 0 {
      newStart = virtualDocument.rangeOfComposedCharacterSequence(at: newStart).location
    }
    let prefixRange = NSRange(location: newStart, length: oldStart - newStart)
    guard prefixRange.length > 0 else { return false }

    let prefix = virtualDocument.substring(with: prefixRange)
    let attributedPrefix = NSAttributedString(string: prefix, attributes: typingAttributes)
    let previousSelection = selectedRange()
    let scrollView = enclosingScrollView
    let previousDocumentHeight = frame.height
    let previousOrigin = scrollView?.contentView.bounds.origin ?? .zero

    isApplyingMaterializedText = true
    textStorage?.insert(attributedPrefix, at: 0)
    isApplyingMaterializedText = false
    materializedDocumentRange.location = newStart
    materializedDocumentRange.length += prefixRange.length
    setSelectedRange(
      NSRange(
        location: previousSelection.location + prefixRange.length,
        length: previousSelection.length
      )
    )

    layoutSubtreeIfNeeded()
    if let scrollView {
      let addedHeight = max(0, frame.height - previousDocumentHeight)
      scrollView.contentView.scroll(
        to: NSPoint(x: previousOrigin.x, y: previousOrigin.y + addedHeight)
      )
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    return true
  }

  private func installVirtualDocument(
    _ preparedText: ComposerPreparedPaste,
    replacementRange: NSRange,
    startedAt: CFTimeInterval
  ) {
    let document: ComposerPreparedPaste
    if !isVirtualizingLargeDocument, string.isEmpty, replacementRange.length == 0 {
      document = preparedText
    } else {
      let current = documentStringForBinding() as NSString
      let mutable = NSMutableString(string: current)
      let replacementLocation =
        isVirtualizingLargeDocument
        ? materializedDocumentRange.location + replacementRange.location
        : replacementRange.location
      let safeRange = NSIntersectionRange(
        NSRange(location: replacementLocation, length: replacementRange.length),
        NSRange(location: 0, length: mutable.length)
      )
      mutable.replaceCharacters(in: safeRange, with: preparedText.value)
      document = ComposerPreparedPaste(mutable as String)
    }

    virtualDocument = document.source
    originalVirtualValue = document.value
    virtualDocumentMetrics = document.metrics
    let tailRange = Self.tailRange(in: document.source)
    materializedDocumentRange = tailRange
    setMaterializedText(document.source.substring(with: tailRange))
    setSelectedRange(NSRange(location: tailRange.length, length: 0))

    let completedMetrics = ComposerTextMetrics(
      characterCount: document.source.length,
      formattedCharacterCount: document.metrics.formattedCharacterCount,
      hasLineBreak: document.metrics.hasLineBreak,
      hasNonWhitespace: document.metrics.hasNonWhitespace,
      isImportingLargeDocument: false
    )
    largeDocumentPasteDidBegin?(completedMetrics)
    virtualDocumentDidInstall?(document.value, completedMetrics)
    lastLargeDocumentPasteDurationMilliseconds =
      (CACurrentMediaTime() - startedAt) * 1_000
    isPerformingLargeDocumentPaste = false

    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
      guard let self, self.isVirtualizingLargeDocument else { return }
      self.scrollRangeToVisible(NSRange(location: self.string.utf16.count, length: 0))
    }
  }

  private func clearVirtualDocument() {
    virtualDocument = nil
    originalVirtualValue = nil
    virtualDocumentMetrics = nil
    materializedDocumentRange = NSRange(location: 0, length: 0)
    setMaterializedText("")
    setSelectedRange(NSRange(location: 0, length: 0))
  }

  private func setMaterializedText(_ value: String) {
    isApplyingMaterializedText = true
    textStorage?.setAttributedString(
      NSAttributedString(string: value, attributes: typingAttributes)
    )
    isApplyingMaterializedText = false
  }

  private static func tailRange(in source: NSString) -> NSRange {
    guard source.length > initialMaterializedUTF16Length else {
      return NSRange(location: 0, length: source.length)
    }
    var start = source.length - initialMaterializedUTF16Length
    start = source.rangeOfComposedCharacterSequence(at: start).location
    return NSRange(location: start, length: source.length - start)
  }
}

struct ComposerPreparedPaste: @unchecked Sendable {
  let value: String
  let source: NSMutableString
  let metrics: ComposerTextMetrics

  init(_ value: String) {
    self.value = value
    source = NSMutableString(string: value)
    metrics = ComposerTextMetrics(
      characterCount: source.length,
      hasLineBreak: source.rangeOfCharacter(from: .newlines).location != NSNotFound,
      hasNonWhitespace: source.rangeOfCharacter(from: .whitespacesAndNewlines.inverted).location
        != NSNotFound,
      isImportingLargeDocument: true
    )
  }
}
