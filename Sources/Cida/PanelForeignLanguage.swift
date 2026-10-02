import SwiftUI

/// The foreign language written after 翻译 inside the selected segment, read as
/// 「翻译成 English」 (`Design/spec/panel.md` §三). It shows while the source is in my language
/// and turns into a field on ⌘L or a click. Showing and hiding it is written in and out with
/// the result's own stroke (`Design/spec/streaming-motion.md` §四).
///
/// The segment's title keeps its 12 pt trailing padding. 成 starts at the end of the verb, all
/// 12 pt into it, and the language follows 5 pt later; a renamed 翻译 has no 成, so the language
/// starts 7 pt into the padding, 5 pt after the name. Either way the segment ends with the same
/// 12 pt, and collapsed to zero width it is exactly what it is without a language.
struct PanelForeignLanguage: View {
  @Bindable var model: AppModel
  static let gapAfterTitle: CGFloat = 5
  /// How far into the title's trailing padding a language without 成 starts.
  static let titleOverlap = PanelSegmentedControlMetrics.titlePadding - gapAfterTitle

  @State private var isPresented = false
  /// Seconds into writing the language in; the whole word is written at `writtenSeconds`.
  @State private var elapsed = 0.0
  /// Seconds into writing 成 in. A rewritten language leaves it as it is.
  @State private var jointElapsed = 0.0
  /// 1 while 成 is written first and the language follows it, 0 when only the language is.
  @State private var languageFirstGlyph = 0
  /// 0 while the language is on screen, 1 once it has faded out.
  @State private var fade = 0.0
  @State private var wordWidth: CGFloat = 0
  @State private var jointGlyphWidth: CGFloat = 0
  @State private var draft = ""
  @State private var draftWidth: CGFloat = 0
  @State private var leaveTask: Task<Void, Never>?
  @FocusState private var isFieldFocused: Bool

  var body: some View {
    content
      .offset(x: -overlap)
      .frame(width: width, alignment: .leading)
      // The glyphs start in the title's padding, so the visible part is the frame moved back
      // by that much: nothing at zero width, the whole word once open.
      .mask(alignment: .leading) {
        Rectangle()
          .frame(width: width)
          .padding(.vertical, -4)
          .offset(x: -overlap)
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
        jointElapsed = CidaMotion.characterInSeconds
        if model.isEditingForeignLanguage { startEditing() }
      }
      .onChange(of: model.showsForeignLanguage) { _, shows in
        let animated = model.animatesForeignLanguageChange && !CidaMotion.reducesMotion
        if shows { writeIn(animated: animated) } else { leave(animated: animated) }
      }
      .onChange(of: model.foreignLanguageRewriteRevision) {
        writeIn(animated: !CidaMotion.reducesMotion, rewriting: true)
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

  private var content: some View {
    HStack(spacing: Self.gapAfterTitle) {
      if let joint {
        Text(joint)
          .font(Self.jointFont)
          .foregroundStyle(CidaDesign.accent)
          .fixedSize()
          .textRenderer(
            WriteInRenderer(
              elapsed: jointElapsed, fade: fade, blursGlyphs: !CidaMotion.reducesMotion)
          )
          .accessibilityHidden(true)
      }
      language
    }
  }

  @ViewBuilder
  private var language: some View {
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
          WriteInRenderer(
            elapsed: elapsed, fade: fade, blursGlyphs: !CidaMotion.reducesMotion,
            firstGlyph: languageFirstGlyph)
        )
    }
  }

  private static let font = CidaDesign.mainUI(11.5, weight: .medium)
  /// 成 is part of the verb, so it is set like the selected title.
  private static let jointFont = CidaDesign.mainUI(11.5, weight: .semibold)

  /// 成 belongs to the built-in verb alone; a 翻译 renamed in Settings is followed by the
  /// language as it was.
  private var joint: String? {
    let name = model.settings.actions.first { $0.id == .translate }?.name
    return name == ProcessingMode.translate.title ? "成" : nil
  }

  /// How far into the title's trailing padding the content starts: 成 sits against the verb.
  private var overlap: CGFloat {
    joint == nil ? Self.titleOverlap : PanelSegmentedControlMetrics.titlePadding
  }

  /// The widths 成, the word and the draft take, measured off screen so the segment opens to
  /// the final width before the first glyph is written.
  private var measurements: some View {
    ZStack {
      Text("成").font(Self.jointFont).fixedSize()
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { jointGlyphWidth = $0 }
      Text(model.foreignLanguage).font(Self.font).fixedSize()
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { wordWidth = $0 }
      Text(draft.isEmpty ? " " : draft).font(Self.font).fixedSize()
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { draftWidth = $0 }
    }
    .hidden()
    .accessibilityHidden(true)
  }

  /// 成 and the language, then the segment's own trailing padding.
  private var width: CGFloat {
    let joint = joint == nil ? 0 : jointGlyphWidth + Self.gapAfterTitle
    let trailing = PanelSegmentedControlMetrics.titlePadding - overlap
    if model.isEditingForeignLanguage { return joint + draftWidth + 2 + trailing }
    return isPresented ? joint + wordWidth + trailing : 0
  }

  private var writtenSeconds: Double {
    WriteInRenderer.duration(glyphs: languageFirstGlyph + model.foreignLanguage.count)
  }

  /// The segment opens to its final width while the glyphs are written in one after another,
  /// so a glyph is never written where the segment has not made room. 成 is the first glyph; a
  /// rewritten language is written in again behind the 成 that stayed.
  private func writeIn(animated: Bool, rewriting: Bool = false) {
    leaveTask?.cancel()
    languageFirstGlyph = joint != nil && !rewriting ? 1 : 0
    guard animated else {
      withAnimation(nil) {
        isPresented = true
        elapsed = writtenSeconds
        jointElapsed = CidaMotion.characterInSeconds
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
    if !rewriting {
      jointElapsed = 0
      withAnimation(.linear(duration: CidaMotion.characterInSeconds)) {
        jointElapsed = CidaMotion.characterInSeconds
      }
    }
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
/// word out again with the same blur. `firstGlyph` counts the glyphs written before this word.
struct WriteInRenderer: TextRenderer, Animatable {
  var elapsed: Double
  var fade: Double
  var blursGlyphs: Bool
  var firstGlyph = 0

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
    var index = firstGlyph
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
