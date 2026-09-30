import AppKit

/// The image ⇧⌘C puts on the pasteboard (`Design/spec/panel.md` §八,
/// `Design/boards/share-card.html`): the source a result was generated from
/// above the result, set as the panel sets them, on a card with the panel's
/// edge. The image leaves Cida for chats read on phones, so the card is
/// narrower than the panel, carries only the two texts, and is always drawn in
/// the light appearance whatever the viewer's is.
enum ShareCard {
  /// Pixels per point: a phone showing the card full screen draws it at about
  /// three device pixels per point.
  static let scale: CGFloat = 3
  /// Taller cards are refused; nobody reads a longer image in a chat, and the
  /// bitmap would run to hundreds of megabytes.
  static let maximumCardHeight: CGFloat = 6_000
  /// A document past this many UTF-16 units always sets taller than
  /// `maximumCardHeight` (even narrow Latin text wraps at about a hundred
  /// units a line), so it is refused without laying it out.
  static let maximumUTF16Length = 40_000
  /// How long the button says the card is too long, as long as a brief hint pill.
  static let tooLongHoldMilliseconds = 1_500

  enum Failure: Error, Equatable {
    case tooLong
    case cannotRender
  }

  struct Rendering {
    /// The card with its transparent margin, in points.
    let size: CGSize
    let png: Data
    let tiff: Data
  }

  @MainActor
  static func render(
    source: String, result: String, language: Language, scale: CGFloat = ShareCard.scale
  ) -> Swift.Result<Rendering, Failure> {
    guard source.utf16.count + result.utf16.count <= maximumUTF16Length else {
      return .failure(.tooLong)
    }

    let textWidth = CidaDesign.ShareCard.width - CidaDesign.Spacing.windowHorizontal * 2
    let sourceText = TypesetText(
      NSAttributedString(string: source, attributes: sourceAttributes), width: textWidth)
    let resultText = TypesetText(
      NSAttributedString(string: result, attributes: ResultTextStyle.attributes(for: language)),
      width: textWidth)
    let padding = CidaDesign.Spacing.resultVertical
    let sourceHeight = sourceText.height + padding * 2
    let resultHeight = resultText.height + padding * 2
    let hairline: CGFloat = 1
    let cardHeight = ceil(sourceHeight + hairline + resultHeight)
    guard cardHeight <= maximumCardHeight else { return .failure(.tooLong) }

    let margin = CidaDesign.ShareCard.margin
    let card = CGRect(x: margin, y: margin, width: CidaDesign.ShareCard.width, height: cardHeight)
    let size = CGSize(width: card.width + margin * 2, height: card.height + margin * 2)
    // sRGB, so the image carries the tokens' exact values instead of the
    // display's conversion of them.
    guard
      let context = CGContext(
        data: nil,
        width: Int(size.width * scale),
        height: Int(size.height * scale),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return .failure(.cannotRender) }

    // Points, top-left origin, as the board and TextKit lay the card out.
    context.translateBy(x: 0, y: CGFloat(context.height))
    context.scaleBy(x: scale, y: -scale)
    let flipped = NSGraphicsContext(cgContext: context, flipped: true)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = flipped
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
      let radius = CidaDesign.Radius.panel
      let outline = CGPath(
        roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)

      // The panel shadow's contact layer only: its ambient layer lifts the
      // panel off the desktop, and an image has no desktop under it.
      // Shadow offsets and blur are in device pixels and y up, whatever the CTM.
      context.saveGState()
      context.setShadow(
        offset: CGSize(width: 0, height: -2 * scale),
        blur: 6 * scale,
        color: CidaDesign.Palette.contactShadow.appKit(dark: false).cgColor
      )
      context.addPath(outline)
      context.setFillColor(CidaDesign.Palette.surface.appKit(dark: false).cgColor)
      context.fillPath()
      context.restoreGState()

      context.saveGState()
      context.addPath(outline)
      context.clip()
      let resultTop = card.minY + sourceHeight + hairline
      context.setFillColor(CidaDesign.Palette.border.appKit(dark: false).cgColor)
      context.fill(CGRect(x: card.minX, y: resultTop - hairline, width: card.width, height: hairline))
      context.setFillColor(CidaDesign.Palette.surfacePaper.appKit(dark: false).cgColor)
      context.fill(CGRect(x: card.minX, y: resultTop, width: card.width, height: card.maxY - resultTop))
      let textX = card.minX + CidaDesign.Spacing.windowHorizontal
      sourceText.draw(at: CGPoint(x: textX, y: card.minY + padding))
      resultText.draw(at: CGPoint(x: textX, y: resultTop + padding))
      context.restoreGState()

      // `panel-edge` hugs the card from outside, as the board's 1px spread does.
      let edge = card.insetBy(dx: -0.5, dy: -0.5)
      context.addPath(
        CGPath(
          roundedRect: edge, cornerWidth: radius + 0.5, cornerHeight: radius + 0.5, transform: nil))
      context.setStrokeColor(CidaDesign.Palette.panelEdge.appKit(dark: false).cgColor)
      context.setLineWidth(1)
      context.strokePath()
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let image = context.makeImage() else { return .failure(.cannotRender) }
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = size
    guard
      let png = bitmap.representation(using: .png, properties: [:]),
      let tiff = bitmap.tiffRepresentation
    else { return .failure(.cannotRender) }
    return .success(Rendering(size: size, png: png, tiff: tiff))
  }

  /// The source pane's typography (`ComposerTextEditor`), with its glyphs
  /// centred in their line the way the result's are.
  @MainActor
  private static var sourceAttributes: [NSAttributedString.Key: Any] {
    var attributes = ComposerTextEditor.textAttributes
    let font = attributes[.font] as! NSFont
    attributes[.baselineOffset] = CidaDesign.halfLeading(
      of: font, lineHeight: CidaDesign.Panel.composerLineHeight)
    return attributes
  }
}

/// Text laid out at a fixed width with TextKit, the way the panes lay it out.
@MainActor
private struct TypesetText {
  private let layoutManager = NSLayoutManager()
  private let container: NSTextContainer
  private let storage: NSTextStorage
  let height: CGFloat

  init(_ text: NSAttributedString, width: CGFloat) {
    storage = NSTextStorage(attributedString: text)
    container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)
    layoutManager.ensureLayout(for: container)
    height = ceil(layoutManager.usedRect(for: container).height)
  }

  func draw(at origin: CGPoint) {
    let glyphs = layoutManager.glyphRange(for: container)
    layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
  }
}
