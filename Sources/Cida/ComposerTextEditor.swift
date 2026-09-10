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

  var hasText: Bool {
    characterCount > 0
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

enum ComposerResetResolution: Equatable, Sendable {
  case none
  case clearSubmittedDocument
  case preserveNewerNativeEdit
}

enum ComposerResetSynchronizer {
  static func resolve(
    revision: Int,
    lastAppliedRevision: Int,
    nativeEditRevision: Int
  ) -> ComposerResetResolution {
    guard revision != lastAppliedRevision else { return .none }
    return nativeEditRevision == revision
      ? .preserveNewerNativeEdit
      : .clearSubmittedDocument
  }
}

struct ComposerTextEditor: NSViewRepresentable {
  @Binding var text: String
  @Binding var metrics: ComposerTextMetrics
  let isFocused: FocusState<Bool>.Binding
  /// Distance from the editor's edges to the text column; the editor spans the
  /// window so its scroll indicator stays at the window edge.
  let horizontalInset: CGFloat
  let resetRevision: Int
  let currentResetRevision: @MainActor () -> Int
  let onSubmit: @MainActor () -> Bool
  let onVirtualDocumentChange: @MainActor (String?, Int?, Bool?) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      text: $text,
      metrics: $metrics,
      isFocused: isFocused,
      resetRevision: resetRevision,
      currentResetRevision: currentResetRevision,
      onSubmit: onSubmit,
      onVirtualDocumentChange: onVirtualDocumentChange
    )
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = false
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
    let scrollIndicator = CidaScrollIndicator.install(
      on: scrollView,
      configuration: .composer
    )
    scrollIndicator.setForceVisible(
      ComposerTextMetrics(text: text).presentationState.showsDocumentChrome
    )
    scrollIndicator.refresh()
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? ComposerNativeTextView else { return }
    context.coordinator.text = $text
    context.coordinator.metrics = $metrics
    context.coordinator.isFocused = isFocused
    context.coordinator.currentResetRevision = currentResetRevision
    context.coordinator.onSubmit = onSubmit
    context.coordinator.onVirtualDocumentChange = onVirtualDocumentChange
    if abs(textView.textContainerInset.width - horizontalInset) > 0.5 {
      textView.textContainerInset = NSSize(width: horizontalInset, height: 0)
      textView.needsLayout = true
      textView.needsDisplay = true
    }
    let scrollIndicator = CidaScrollIndicator.install(
      on: scrollView,
      configuration: .composer
    )
    scrollIndicator.setForceVisible(metrics.presentationState.showsDocumentChrome)

    switch context.coordinator.consumeResetRevision(resetRevision) {
    case .clearSubmittedDocument:
      textView.replaceDocumentFromBinding("")
      context.coordinator.onVirtualDocumentChange(nil, nil, nil)
      context.coordinator.publishMetrics(for: "")
    case .preserveNewerNativeEdit:
      break
    case .none:
      if textView.isPerformingLargeDocumentPaste {
        return
      } else if context.coordinator.consumeNativeBindingEcho() {
        // The native editor already contains this exact change.
      } else if !textView.isVirtualizingLargeDocument, textView.string != text {
        textView.replaceDocumentFromBinding(text)
        applyTypography(to: textView)
        context.coordinator.publishMetrics(for: text)
      }
    }
    scrollIndicator.refresh()

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
    private var lastResetRevision: Int
    private var nativeEditRevision: Int
    var currentResetRevision: @MainActor () -> Int
    var onSubmit: @MainActor () -> Bool
    var onVirtualDocumentChange: @MainActor (String?, Int?, Bool?) -> Void
    private var expectsNativeBindingEcho = false

    init(
      text: Binding<String>,
      metrics: Binding<ComposerTextMetrics>,
      isFocused: FocusState<Bool>.Binding,
      resetRevision: Int,
      currentResetRevision: @escaping @MainActor () -> Int,
      onSubmit: @escaping @MainActor () -> Bool,
      onVirtualDocumentChange: @escaping @MainActor (String?, Int?, Bool?) -> Void
    ) {
      self.text = text
      self.metrics = metrics
      self.isFocused = isFocused
      lastResetRevision = resetRevision
      nativeEditRevision = resetRevision
      self.currentResetRevision = currentResetRevision
      self.onSubmit = onSubmit
      self.onVirtualDocumentChange = onVirtualDocumentChange
    }

    func configure(_ textView: ComposerNativeTextView) {
      textView.largeDocumentPasteDidBegin = { [weak self] pasteMetrics in
        self?.publishLargeDocumentMetrics(pasteMetrics)
      }
      textView.virtualDocumentDidInstall = { [weak self] document, metrics in
        guard let self else { return }
        self.recordNativeEdit()
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
      if onSubmit() {
        (textView as? ComposerNativeTextView)?.replaceDocumentFromBinding("")
        onVirtualDocumentChange(nil, nil, nil)
        text.wrappedValue = ""
      }
      return true
    }

    func consumeNativeBindingEcho() -> Bool {
      guard expectsNativeBindingEcho else { return false }
      expectsNativeBindingEcho = false
      return true
    }

    func consumeResetRevision(_ revision: Int) -> ComposerResetResolution {
      let resolution = ComposerResetSynchronizer.resolve(
        revision: revision,
        lastAppliedRevision: lastResetRevision,
        nativeEditRevision: nativeEditRevision
      )
      guard resolution != .none else { return .none }
      lastResetRevision = revision
      expectsNativeBindingEcho = false
      return resolution
    }

    func publishMetrics(for text: String) {
      let updatedMetrics = ComposerTextMetrics(text: text)
      guard metrics.wrappedValue != updatedMetrics else { return }
      Task { @MainActor [weak self] in
        self?.metrics.wrappedValue = updatedMetrics
      }
    }

    private func synchronizeText(from textView: NSTextView) {
      recordNativeEdit()
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
        metrics.wrappedValue = ComposerTextMetrics(text: updatedText)
      }
    }

    private func recordNativeEdit() {
      nativeEditRevision = currentResetRevision()
    }

    private func publishLargeDocumentMetrics(_ completedMetrics: ComposerTextMetrics) {
      metrics.wrappedValue = completedMetrics.presented(as: .document)
    }
  }
}
