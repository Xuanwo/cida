import SwiftUI

/// The foreign language written after 翻译 inside the selected segment, read as
/// 「翻译 English」 (`Design/spec/panel.md` §三). It shows while the source is in my language
/// and turns into a field on ⌘L or a click. Showing and hiding it is written in and out with
/// the result's own stroke (`Design/spec/streaming-motion.md` §四).
///
/// The segment's title keeps its 12 pt trailing padding; this view starts 7 pt into it, so
/// the language sits 5 pt after the verb and ends with the same 12 pt. Collapsed to zero
/// width, the segment is exactly what it is without a language.
struct PanelForeignLanguage: View {
  @Bindable var model: AppModel
  static let gapAfterTitle: CGFloat = 5
  /// How far into the title's trailing padding the language starts.
  static let titleOverlap = PanelSegmentedControlMetrics.titlePadding - gapAfterTitle

  @State private var isPresented = false
  /// Seconds into writing the language in; the whole word is written at `writtenSeconds`.
  @State private var elapsed = 0.0
  /// 0 while the language is on screen, 1 once it has faded out.
  @State private var fade = 0.0
  @State private var wordWidth: CGFloat = 0
  @State private var draft = ""
  @State private var draftWidth: CGFloat = 0
  @State private var leaveTask: Task<Void, Never>?
  @FocusState private var isFieldFocused: Bool

  var body: some View {
    content
      .offset(x: -Self.titleOverlap)
      .frame(width: width, alignment: .leading)
      // The glyphs start in the title's padding, so the visible part is the frame moved back
      // by that much: nothing at zero width, the whole word once open.
      .mask(alignment: .leading) {
        Rectangle()
          .frame(width: width)
          .padding(.vertical, -4)
          .offset(x: -Self.titleOverlap)
      }
      .background(measurements)
      .contentShape(Rectangle())
      .onTapGesture { model.beginEditingForeignLanguage() }
      .accessibilityElement(children: model.isEditingForeignLanguage ? .contain : .ignore)
      .accessibilityLabel("要译成的语言")
      .accessibilityValue(model.foreignLanguage)
      .accessibilityAddTraits(.isButton)
      .accessibilityHidden(!model.showsForeignLanguage)
      .accessibilityIdentifier("foreign-language")
      .onAppear {
        isPresented = model.showsForeignLanguage
        elapsed = writtenSeconds
        if model.isEditingForeignLanguage { startEditing() }
      }
      .onChange(of: model.showsForeignLanguage) { _, shows in
        let animated = model.animatesForeignLanguageChange && !CidaMotion.reducesMotion
        if shows { writeIn(animated: animated) } else { leave(animated: animated) }
      }
      .onChange(of: model.foreignLanguageRewriteRevision) {
        writeIn(animated: !CidaMotion.reducesMotion)
      }
      .onChange(of: model.isEditingForeignLanguage) { _, editing in
        if editing { startEditing() } else { isFieldFocused = false }
      }
      .onChange(of: isFieldFocused) { _, focused in
        if !focused { model.cancelForeignLanguageEditing() }
      }
  }

  private func startEditing() {
    draft = model.foreignLanguage
    Task { @MainActor in isFieldFocused = true }
  }

  @ViewBuilder
  private var content: some View {
    if model.isEditingForeignLanguage {
      TextField("", text: $draft)
        .textFieldStyle(.plain)
        .font(Self.font)
        .foregroundStyle(CidaDesign.textPrimary)
        .focused($isFieldFocused)
        .onSubmit { model.commitForeignLanguage(draft) }
        .frame(width: draftWidth + 2, alignment: .leading)
        .overlay(alignment: .bottom) {
          Rectangle()
            .fill(CidaDesign.textTertiary)
            .frame(height: 1)
            .offset(y: 2)
        }
        .accessibilityLabel("要译成的语言")
        .accessibilityIdentifier("foreign-language-editor")
    } else {
      Text(model.foreignLanguage)
        .font(Self.font)
        .foregroundStyle(CidaDesign.textSecondary)
        .fixedSize()
        .textRenderer(
          WriteInRenderer(elapsed: elapsed, fade: fade, blursGlyphs: !CidaMotion.reducesMotion)
        )
    }
  }

  private static let font = CidaDesign.mainUI(11.5, weight: .medium)

  /// The widths the word and the draft take, measured off screen so the segment opens to the
  /// final width before the first glyph is written.
  private var measurements: some View {
    ZStack {
      Text(model.foreignLanguage).font(Self.font).fixedSize()
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { wordWidth = $0 }
      Text(draft.isEmpty ? " " : draft).font(Self.font).fixedSize()
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { draftWidth = $0 }
    }
    .hidden()
    .accessibilityHidden(true)
  }

  /// The language, then the segment's own trailing padding.
  private var width: CGFloat {
    let trailing = PanelSegmentedControlMetrics.titlePadding - Self.titleOverlap
    if model.isEditingForeignLanguage { return draftWidth + 2 + trailing }
    return isPresented ? wordWidth + trailing : 0
  }

  private var writtenSeconds: Double {
    WriteInRenderer.duration(glyphs: model.foreignLanguage.count)
  }

  /// The segment opens to its final width while the glyphs are written in one after another,
  /// so a glyph is never written where the segment has not made room.
  private func writeIn(animated: Bool) {
    leaveTask?.cancel()
    guard animated else {
      withAnimation(nil) {
        isPresented = true
        elapsed = writtenSeconds
      }
      if CidaMotion.reducesMotion {
        fade = 1
        withAnimation(.linear(duration: CidaMotion.iconSwapSeconds)) { fade = 0 }
      } else {
        fade = 0
      }
      return
    }
    fade = 0
    elapsed = 0
    withAnimation(CidaMotion.heightCurve.animation(duration: CidaMotion.heightSeconds)) {
      isPresented = true
    }
    withAnimation(.linear(duration: writtenSeconds)) { elapsed = writtenSeconds }
  }

  /// The word fades out whole; halfway through, the segment closes behind it.
  private func leave(animated: Bool) {
    leaveTask?.cancel()
    guard animated else {
      if CidaMotion.reducesMotion, isPresented {
        withAnimation(.linear(duration: CidaMotion.iconSwapSeconds)) { fade = 1 }
        leaveTask = Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(CidaMotion.iconSwapMilliseconds))
          guard !Task.isCancelled else { return }
          isPresented = false
        }
      } else {
        isPresented = false
      }
      return
    }
    withAnimation(CidaMotion.characterInCurve.animation(duration: CidaMotion.characterInSeconds)) {
      fade = 1
    }
    leaveTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(CidaMotion.characterInMilliseconds / 2))
      guard !Task.isCancelled else { return }
      withAnimation(CidaMotion.heightCurve.animation(duration: CidaMotion.heightSeconds)) {
        isPresented = false
      }
    }
  }
}

/// Draws a word glyph by glyph as the result streams in: each glyph fades in and sharpens over
/// `motion-char-in-ms`, the next one `motion-language-stagger-ms` later; `fade` takes the whole
/// word out again with the same blur.
struct WriteInRenderer: TextRenderer, Animatable {
  var elapsed: Double
  var fade: Double
  var blursGlyphs: Bool

  var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(elapsed, fade) }
    set {
      elapsed = newValue.first
      fade = newValue.second
    }
  }

  static let stagger = Double(CidaMotion.languageStaggerMilliseconds) / 1_000

  /// How long a word of `glyphs` takes to be written in full.
  static func duration(glyphs: Int) -> Double {
    Double(max(0, glyphs - 1)) * stagger + CidaMotion.characterInSeconds
  }

  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    var index = 0
    for line in layout {
      for run in line {
        for glyph in run {
          let time = (elapsed - Double(index) * Self.stagger) / CidaMotion.characterInSeconds
          let written = CidaMotion.characterInCurve.progress(at: time)
          var glyphContext = context
          glyphContext.opacity = written * (1 - fade)
          if blursGlyphs {
            let blur = CidaMotion.characterBlurRadius * CGFloat(max(1 - written, fade))
            if blur > 0.01 { glyphContext.addFilter(.blur(radius: blur)) }
          }
          glyphContext.draw(glyph)
          index += 1
        }
      }
    }
  }
}
