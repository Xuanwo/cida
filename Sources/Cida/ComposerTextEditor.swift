import AppKit
import SwiftUI

struct ComposerTextMetrics: Equatable, Sendable {
  let characterCount: Int
  let formattedCharacterCount: String
  let hasLineBreak: Bool
  let lineCount: Int
  let hasNonWhitespace: Bool
  let isImportingLargeDocument: Bool
  let presentationState: ComposerPresentationState
  /// The laid-out height of the text in the editor, measured after each native
  /// edit while the text is short enough to lay out synchronously. The panel
  /// sizes the source pane from it; `nil` means "not measured".
  var naturalHeight: CGFloat?
  /// An input method is showing provisional (marked) text that the binding
  /// and `characterCount` do not include yet.
  var isComposing = false

  init(
    text: String,
    isImportingLargeDocument: Bool = false,
    presentationState: ComposerPresentationState? = nil
  ) {
    let value = text as NSString
    let utf16Count = value.length
    characterCount =
      utf16Count >= ComposerNativeTextView.virtualDocumentThreshold
      ? utf16Count
      : text.count
    formattedCharacterCount = Self.formatCharacterCount(characterCount)
    lineCount =
      utf16Count < 800
      ? text.reduce(into: 1) { count, character in
        if character.isNewline { count += 1 }
      }
      : 1
    hasLineBreak = lineCount > 1
    hasNonWhitespace =
      value.rangeOfCharacter(from: .whitespacesAndNewlines.inverted).location != NSNotFound
    self.isImportingLargeDocument = isImportingLargeDocument
    self.presentationState =
      presentationState
      ?? Self.presentationState(
        characterCount: characterCount,
        lineCount: lineCount,
        hasLineBreak: hasLineBreak
      )
  }

  init(
    characterCount: Int,
    formattedCharacterCount: String? = nil,
    hasLineBreak: Bool,
    lineCount: Int = 1,
    hasNonWhitespace: Bool,
    isImportingLargeDocument: Bool,
    presentationState: ComposerPresentationState? = nil
  ) {
    self.characterCount = characterCount
    self.formattedCharacterCount =
      formattedCharacterCount ?? Self.formatCharacterCount(characterCount)
    self.hasLineBreak = hasLineBreak
    self.lineCount = max(lineCount, hasLineBreak ? 2 : 1)
    self.hasNonWhitespace = hasNonWhitespace
    self.isImportingLargeDocument = isImportingLargeDocument
    self.presentationState =
      presentationState
      ?? Self.presentationState(
        characterCount: characterCount,
        lineCount: self.lineCount,
        hasLineBreak: hasLineBreak
      )
  }

  /// Whether the editor shows anything, so the placeholder must not: committed
  /// text or an in-progress composition.
  var hasText: Bool {
    characterCount > 0 || isComposing
  }

  var usesMultilineEditor: Bool {
    if case .multiline = presentationState { return true }
    return presentationState == .document
  }

  var isDocument: Bool {
    characterCount >= 800
  }

  var boundedForVirtualDocumentPresentation: Self {
    guard characterCount >= ComposerNativeTextView.virtualDocumentThreshold else { return self }
    return Self(
      characterCount: characterCount,
      formattedCharacterCount: formattedCharacterCount,
      hasLineBreak: hasLineBreak,
      lineCount: lineCount,
      hasNonWhitespace: hasNonWhitespace,
      isImportingLargeDocument: isImportingLargeDocument,
      presentationState: .document
    )
  }

  func presented(as presentationState: ComposerPresentationState) -> Self {
    Self(
      characterCount: characterCount,
      formattedCharacterCount: formattedCharacterCount,
      hasLineBreak: hasLineBreak,
      lineCount: lineCount,
      hasNonWhitespace: hasNonWhitespace,
      isImportingLargeDocument: isImportingLargeDocument,
      presentationState: presentationState
    )
  }

  private static func presentationState(
    characterCount: Int,
    lineCount: Int,
    hasLineBreak: Bool
  ) -> ComposerPresentationState {
    if characterCount >= 800 {
      return .document
    }
    guard characterCount > 120 || hasLineBreak else {
      return .compact
    }
    let wrappedLineCount = max(1, Int(ceil(Double(characterCount) / 90)))
    return .multiline(visibleLineCount: min(5, max(lineCount, wrappedLineCount)))
  }

  private static func formatCharacterCount(_ value: Int) -> String {
    let digits = String(value)
    guard digits.count > 3 else { return digits }
    var result = ""
    result.reserveCapacity(digits.count + digits.count / 3)
    for (index, character) in digits.enumerated() {
      if index > 0, (digits.count - index).isMultiple(of: 3) {
        result.append(",")
      }
      result.append(character)
    }
    return result
  }
}

struct ComposerTextEditor: NSViewRepresentable {
  @Binding var text: String
  @Binding var metrics: ComposerTextMetrics
  let isFocused: FocusState<Bool>.Binding
  /// Distance from the editor's edges to the text column; the editor spans the
  /// window so its scroll indicator stays at the window edge.
  let horizontalInset: CGFloat
  /// Bumped when the whole text should be selected, e.g. when the panel is
  /// shown again with the previous source in it.
  var selectAllRevision = 0
  let onSubmit: @MainActor () -> Bool
  let onVirtualDocumentChange: @MainActor (String?, Int?, Bool?) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      text: $text,
      metrics: $metrics,
      isFocused: isFocused,
      onSubmit: onSubmit,
      onVirtualDocumentChange: onVirtualDocumentChange
    )
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    // System overlay scroll bar (Pencil `Spec — 面板模型`): appears while
    // scrolling and follows the user's scroll-bar preference.
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true

    let textView = ComposerNativeTextView(usingTextLayoutManager: true)
    textView.delegate = context.coordinator
    context.coordinator.configure(textView)
    textView.isRichText = false
    textView.importsGraphics = false
    textView.drawsBackground = false
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainerInset = NSSize(width: horizontalInset, height: 0)
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.focusRingType = .none
    textView.isContinuousSpellCheckingEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticTextCompletionEnabled = false
    textView.setAccessibilityLabel("待处理文本")
    textView.setAccessibilityIdentifier("composer-input")
    applyTypography(to: textView)
    textView.replaceDocumentFromBinding(text)

    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? ComposerNativeTextView else { return }
    context.coordinator.text = $text
    context.coordinator.metrics = $metrics
    context.coordinator.isFocused = isFocused
    context.coordinator.onSubmit = onSubmit
    context.coordinator.onVirtualDocumentChange = onVirtualDocumentChange
    if abs(textView.textContainerInset.width - horizontalInset) > 0.5 {
      textView.textContainerInset = NSSize(width: horizontalInset, height: 0)
      textView.needsLayout = true
      textView.needsDisplay = true
    }
    if textView.isPerformingLargeDocumentPaste {
      return
    } else if context.coordinator.consumeNativeBindingEcho() {
      // The native editor already contains this exact change.
    } else if textView.hasMarkedText() {
      // An input method is composing (for example pinyin). The native text
      // contains provisional marked text that the binding never sees, so
      // writing the binding back would cancel the composition.
    } else if !textView.isVirtualizingLargeDocument, textView.string != text {
      textView.replaceDocumentFromBinding(text)
      applyTypography(to: textView)
      context.coordinator.publishMetrics(for: text, in: textView)
    }

    if context.coordinator.consumeSelectAllRevision(selectAllRevision),
      !textView.isVirtualizingLargeDocument
    {
      textView.setSelectedRange(NSRange(location: 0, length: textView.textStorage?.length ?? 0))
    }

    if isFocused.wrappedValue, textView.window?.firstResponder !== textView {
      Task { @MainActor in
        await Task.yield()
        textView.window?.makeFirstResponder(textView)
      }
    }
  }

  private func applyTypography(to textView: NSTextView) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.minimumLineHeight = 26
    paragraphStyle.maximumLineHeight = 26

    let attributes: [NSAttributedString.Key: Any] = [
      .font: CidaDesign.appKitBody(16),
      .foregroundColor: CidaDesign.Palette.textPrimary.appKit,
      .paragraphStyle: paragraphStyle,
    ]

    textView.defaultParagraphStyle = paragraphStyle
    textView.typingAttributes = attributes
    textView.textStorage?.setAttributes(
      attributes,
      range: NSRange(location: 0, length: textView.textStorage?.length ?? 0)
    )
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var metrics: Binding<ComposerTextMetrics>
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: @MainActor () -> Bool
    var onVirtualDocumentChange: @MainActor (String?, Int?, Bool?) -> Void
    private var expectsNativeBindingEcho = false

    init(
      text: Binding<String>,
      metrics: Binding<ComposerTextMetrics>,
      isFocused: FocusState<Bool>.Binding,
      onSubmit: @escaping @MainActor () -> Bool,
      onVirtualDocumentChange: @escaping @MainActor (String?, Int?, Bool?) -> Void
    ) {
      self.text = text
      self.metrics = metrics
      self.isFocused = isFocused
      self.onSubmit = onSubmit
      self.onVirtualDocumentChange = onVirtualDocumentChange
    }

    func configure(_ textView: ComposerNativeTextView) {
      textView.largeDocumentPasteDidBegin = { [weak self] pasteMetrics in
        self?.publishLargeDocumentMetrics(pasteMetrics)
      }
      textView.markedTextDidChange = { [weak self] isComposing in
        guard let self, self.metrics.wrappedValue.isComposing != isComposing else { return }
        self.metrics.wrappedValue.isComposing = isComposing
      }
      textView.virtualDocumentDidInstall = { [weak self] document, metrics in
        guard let self else { return }
        self.onVirtualDocumentChange(
          document,
          metrics.characterCount,
          metrics.hasNonWhitespace
        )
      }
    }

    func textDidBeginEditing(_ notification: Notification) {
      isFocused.wrappedValue = true
    }

    func textDidEndEditing(_ notification: Notification) {
      isFocused.wrappedValue = false
    }

    func textDidChange(_ notification: Notification) {
      guard
        let textView = notification.object as? ComposerNativeTextView,
        !textView.isPerformingLargeDocumentPaste
      else {
        return
      }
      synchronizeText(from: textView)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
      if (textView as? ComposerNativeTextView)?.isPerformingLargeDocumentPaste == true {
        return true
      }
      let modifiers = NSApp.currentEvent?.modifierFlags ?? []
      if modifiers.contains(.shift) || modifiers.contains(.option) {
        return false
      }
      _ = onSubmit()
      return true
    }

    func consumeNativeBindingEcho() -> Bool {
      guard expectsNativeBindingEcho else { return false }
      expectsNativeBindingEcho = false
      return true
    }

    private var lastSelectAllRevision = 0

    func consumeSelectAllRevision(_ revision: Int) -> Bool {
      guard revision != lastSelectAllRevision else { return false }
      lastSelectAllRevision = revision
      return true
    }

    /// Measures the text height for the source pane; only short documents are
    /// laid out synchronously, long ones take the document cap anyway.
    static func naturalHeight(of textView: NSTextView) -> CGFloat? {
      guard
        let textLayoutManager = textView.textLayoutManager,
        let textContainer = textLayoutManager.textContainer,
        (textView.textStorage?.length ?? 0) < 20_000
      else {
        return nil
      }
      _ = textContainer
      textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
      // `usageBoundsForTextContainer` lags behind deletions; the fragment frames
      // are exact once layout is ensured.
      var maxY: CGFloat = 0
      textLayoutManager.enumerateTextLayoutFragments(
        from: textLayoutManager.documentRange.location,
        options: [.ensuresLayout]
      ) { fragment in
        maxY = max(maxY, fragment.layoutFragmentFrame.maxY)
        return true
      }
      let height = maxY > 0 ? maxY : textLayoutManager.usageBoundsForTextContainer.height
      return height > 0 ? ceil(height) : nil
    }

    func publishMetrics(for text: String, in textView: NSTextView? = nil) {
      var updatedMetrics = ComposerTextMetrics(text: text)
      updatedMetrics.naturalHeight = textView.flatMap(Self.naturalHeight(of:))
      guard metrics.wrappedValue != updatedMetrics else { return }
      Task { @MainActor [weak self] in
        self?.metrics.wrappedValue = updatedMetrics
      }
    }

    private func synchronizeText(from textView: NSTextView) {
      let nativeTextView = textView as? ComposerNativeTextView
      let updatedText = textView.string
      expectsNativeBindingEcho = true
      text.wrappedValue = updatedText
      if let nativeTextView, nativeTextView.isVirtualizingLargeDocument {
        onVirtualDocumentChange(
          nativeTextView.documentStringForBinding(),
          nativeTextView.documentUTF16Length,
          nativeTextView.documentMetrics.hasNonWhitespace
        )
        metrics.wrappedValue =
          nativeTextView.documentMetrics.boundedForVirtualDocumentPresentation
      } else {
        onVirtualDocumentChange(nil, nil, nil)
        var updatedMetrics = ComposerTextMetrics(text: updatedText)
        updatedMetrics.naturalHeight = Self.naturalHeight(of: textView)
        metrics.wrappedValue = updatedMetrics
      }
    }

    private func publishLargeDocumentMetrics(_ completedMetrics: ComposerTextMetrics) {
      metrics.wrappedValue = completedMetrics.presented(as: .document)
    }
  }
}
