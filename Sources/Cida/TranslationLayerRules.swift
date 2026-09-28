import Foundation

/// What the translation layer reads from an application's accessibility tree
/// (`Design/spec/translation-layer.md`). The rules below only use these general
/// attributes, never an application's own names, so they apply to every app
/// without adaptation. `AccessibilityLayerNode` reads them from AX; tests build trees
/// by hand.
protocol LayerNode {
  var role: String { get }
  var subrole: String? { get }
  /// In screen points, origin at the top-left of the primary display, as AX reports it.
  var frame: CGRect? { get }
  /// `AXValue` when it is text.
  var textValue: String? { get }
  var children: [Self] { get }
  var parent: Self? { get }
  /// Chromium and WebKit expose the DOM classes; native elements have none.
  var domClasses: [String] { get }
  /// `AXIdentifier`, or `AXDOMIdentifier` in web content.
  var identifier: String? { get }
  /// `AXURL`, set on a web area.
  var url: URL? { get }
  /// The bounds of a character range in a text area, for documents held in one element.
  func bounds(ofCharacters range: NSRange) -> CGRect?
  /// The point size of the text's first character, where the app tells it.
  var fontSize: CGFloat? { get }
  /// Whether two reads refer to the same element of the application.
  func isSameElement(as other: Self) -> Bool
}

enum LayerRole {
  static let staticText = "AXStaticText"
  static let link = "AXLink"
  static let image = "AXImage"
  static let listMarker = "AXListMarker"
  static let textArea = "AXTextArea"
  static let webArea = "AXWebArea"
  /// A navigation tree: Slack's channel list, Finder's sidebar, Mail's mailboxes.
  static let outline = "AXOutline"
  /// A table cell: cells beside each other are separate paragraphs.
  static let cell = "AXCell"
  static let window = "AXWindow"
  static let application = "AXApplication"

  /// What a paragraph may hold besides its text (§三 分块), with the style runs below.
  static let inline: Set<String> = [staticText, link, image, listMarker]
  /// Chromium and WebKit wrap a bold, italic, code or similar run in an `AXGroup` whose
  /// subrole ends in `StyleGroup`; the run belongs to the paragraph around it.
  static let codeStyleGroup = "AXCodeStyleGroup"
  /// Rows of these are items: nothing inside one row is a pane (§二), however large.
  static let lists: Set<String> = ["AXList", "AXOutline", "AXTable"]

  static func isStyleGroup<Node: LayerNode>(_ node: Node) -> Bool {
    node.role == "AXGroup" && node.subrole?.hasSuffix("StyleGroup") == true
  }

  /// Inline elements, style runs, and plain groups that only wrap images (Slack's emoji).
  static func isInline<Node: LayerNode>(_ node: Node) -> Bool {
    if inline.contains(node.role) || isStyleGroup(node) { return true }
    guard node.role == "AXGroup" else { return false }
    let children = node.children
    return !children.isEmpty && children.allSatisfy { $0.role == image }
  }

  /// Children that make one paragraph: only inline elements, some of them text.
  static func formParagraph<Node: LayerNode>(_ children: [Node]) -> Bool {
    !children.isEmpty && children.allSatisfy { isInline($0) }
      && children.contains { $0.role == staticText || isStyleGroup($0) }
  }
  /// Text entirely inside these is interface, not content.
  static let controls: Set<String> = [
    "AXButton", link, "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXTab",
    "AXMenuItem", "AXMenuBarItem",
  ]
  /// A pointer on these never previews a pane (§二).
  static let fields: Set<String> = [
    "AXTextField", "AXSearchField", "AXComboBox", "AXSecureTextField", "AXMenu", "AXMenuBar",
    "AXMenuItem", "AXMenuBarItem",
  ]
  /// Small elements the pane rule climbs past.
  static let small: Set<String> = [
    staticText, link, image, listMarker, "AXButton", "AXCheckBox", "AXRadioButton",
    "AXPopUpButton", "AXValueIndicator", "AXScrollBar",
  ]
}

// MARK: - Pane

/// The pane under the pointer (§二): from the element AX hits, climb past small elements to
/// the first container that is at least 200 × 120 pt and holds text. Not by role: Slack's
/// message area is a plain group, neither a list nor a scroll area.
enum LayerPaneRule {
  static let minimumSize = CGSize(width: 200, height: 120)
  /// How much of a pane is read to see whether it holds text.
  static let textProbeLimit = 3_000

  static func pane<Node: LayerNode>(from hit: Node) -> Node? {
    if LayerRole.fields.contains(hit.role) { return nil }
    // A small editable area is an input field (a chat composer); a large one is a document.
    if hit.role == LayerRole.textArea, !isLargeEnough(hit.frame) { return nil }
    // A pane holds several paragraphs; one large message alone is not what a reader means by
    // the area to translate. Without such a container, the first large one with text will do.
    var firstLarge: Node?
    // Nothing inside a list's row is the pane, however long the row (a Slack message): the
    // search starts at the list. Slack's list itself may be a one-point screen-reader node.
    var cursor: Node? = enclosingList(of: hit) ?? hit
    var steps = 0
    while let node = cursor, steps < 64 {
      steps += 1
      if node.role == LayerRole.window || node.role == LayerRole.application { break }
      let parent = node.parent
      if !LayerRole.small.contains(node.role), isLargeEnough(node.frame), holdsText(node) {
        if node.role == LayerRole.textArea || holdsParagraphs(node, atLeast: 2) { return viewport(of: node) }
        if firstLarge == nil { firstLarge = node }
      }
      cursor = parent
    }
    guard let firstLarge else { return nil }
    return viewport(of: firstLarge)
  }

  /// A window's panes, for whole-window translation (§三): the pane of each paragraph, the
  /// smaller one where two overlap, `preferred` panes (those ⌥D already uses) first.
  /// Paragraphs outside every pane stay untranslated.
  static func panes<Node: LayerNode>(in window: Node, preferred: [Node] = []) -> [Node] {
    guard let windowFrame = window.frame else { return preferred }
    var candidates: [(node: Node, frame: CGRect)] = preferred.compactMap { node in node.frame.map { (node, $0) } }
    let windowArea = windowFrame.width * windowFrame.height
    for (block, node) in LayerBlockExtractor.located(in: window, visible: windowFrame, automatic: true) {
      let center = CGPoint(x: block.frame.midX, y: block.frame.midY)
      // A paragraph already inside a pane of reasonable size has its pane; one inside only a
      // pane that spans most of the window may still sit in a smaller one of its own.
      if candidates.contains(where: { $0.frame.contains(center) && $0.frame.width * $0.frame.height < windowArea / 2 }) {
        continue
      }
      guard let pane = pane(from: node), let frame = pane.frame, pane.role != LayerRole.outline,
        !candidates.contains(where: { $0.node.isSameElement(as: pane) })
      else {
        continue
      }
      candidates.append((pane, frame))
    }
    // Where two overlap the smaller one scrolls on its own; the larger adds only its margins.
    var chosen: [(node: Node, frame: CGRect)] = []
    let preferredCount = min(preferred.count, candidates.count)
    let ordered = Array(candidates[..<preferredCount])
      + candidates[preferredCount...].sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    for candidate in ordered {
      let overlaps = chosen.contains { existing in
        let shared = existing.frame.intersection(candidate.frame)
        let smaller = min(existing.frame.width * existing.frame.height, candidate.frame.width * candidate.frame.height)
        return !shared.isNull && shared.width * shared.height > smaller * 0.1
      }
      if !overlaps { chosen.append(candidate) }
    }
    return chosen.map(\.node)
  }

  static func enclosingList<Node: LayerNode>(of node: Node) -> Node? {
    var cursor: Node? = node
    var steps = 0
    while let current = cursor, steps < 64 {
      steps += 1
      if current.role == LayerRole.window || current.role == LayerRole.application { return nil }
      if LayerRole.lists.contains(current.role) { return current }
      cursor = current.parent
    }
    return nil
  }

  /// Content taller than its scroll area is seen through the scroll area; that is the pane.
  static func viewport<Node: LayerNode>(of node: Node) -> Node {
    guard let frame = node.frame else { return node }
    var cursor = node.parent
    var steps = 0
    while let ancestor = cursor, steps < 4 {
      steps += 1
      if ancestor.role == "AXScrollArea", let visible = ancestor.frame, !visible.contains(frame) {
        return ancestor
      }
      cursor = ancestor.parent
    }
    return node
  }

  static func holdsParagraphs<Node: LayerNode>(_ node: Node, atLeast count: Int) -> Bool {
    var found = 0
    var stack = [node]
    var visited = 0
    while let current = stack.popLast(), visited < textProbeLimit {
      visited += 1
      // A sender's name or a time is a control, not a paragraph.
      if LayerRole.controls.contains(current.role) { continue }
      let children = current.children
      if LayerRole.formParagraph(children), (current.frame?.height ?? 0) >= 6 {
        found += LayerBlockExtractor.isStack(children) ? children.count : 1
        if found >= count { return true }
        continue
      }
      stack.append(contentsOf: children)
    }
    return false
  }

  static func isLargeEnough(_ frame: CGRect?) -> Bool {
    guard let frame else { return false }
    return frame.width >= minimumSize.width && frame.height >= minimumSize.height
  }

  static func holdsText<Node: LayerNode>(_ node: Node) -> Bool {
    var stack = [node]
    var visited = 0
    while let current = stack.popLast(), visited < textProbeLimit {
      visited += 1
      if current.role == LayerRole.staticText || current.role == LayerRole.textArea,
        let text = current.textValue, text.contains(where: { $0.isLetter })
      {
        return true
      }
      stack.append(contentsOf: current.children)
    }
    return false
  }
}

// MARK: - Scope

/// Where a pane applies (§二 适用范围): per site when it sits in web content, per app otherwise.
enum LayerScope: Hashable, Codable, Sendable {
  case application
  case site(String)

  static func of<Node: LayerNode>(_ node: Node) -> LayerScope {
    var cursor: Node? = node
    var steps = 0
    while let current = cursor, steps < 128 {
      steps += 1
      if current.role == LayerRole.webArea {
        if let host = current.url?.host(percentEncoded: false)?.lowercased(), !host.isEmpty {
          return .site(host)
        }
        return .application
      }
      cursor = current.parent
    }
    return .application
  }

  /// The name the hint pill starts with: the site, or the app.
  func label(applicationName: String) -> String {
    switch self {
    case .application: applicationName
    case .site(let host): host
    }
  }
}

// MARK: - Blocks

/// One paragraph to translate (§三 分块). Link text (mentions, URLs, channel names) stays as
/// it is: it travels to the model as a numbered placeholder.
struct LayerBlock: Equatable, Sendable {
  struct Piece: Equatable, Sendable {
    let text: String
    /// Link or code text: sent to the model as ⟦n⟧ and put back unchanged.
    let isVerbatim: Bool
    /// Where it is on screen: runs continuing a line are joined by it, and the caret that
    /// breathes while the translation is on the way sits after the last one.
    var frame: CGRect? = nil
    /// A link, drawn in accent in the translation (§五).
    var isLink: Bool = false
  }

  let pieces: [Piece]
  /// Screen points, top-left origin.
  let frame: CGRect
  /// The height of one line of text, from the smallest text piece; it sizes the translation's
  /// font (§五).
  let lineHeight: CGFloat

  /// Some of it is prose rather than link or code text (§三): names, times, navigation and
  /// identifiers are left alone.
  var hasProse: Bool {
    pieces.contains { !$0.isVerbatim && $0.text.contains(where: \.isLetter) }
  }

  /// What the reader sees, links included.
  var text: String { pieces.map(\.text).joined() }

  /// What the model gets: link and code text replaced by ⟦n⟧.
  var maskedText: String {
    var index = 0
    return pieces.map { piece in
      guard piece.isVerbatim else { return piece.text }
      defer { index += 1 }
      return "⟦\(index)⟧"
    }.joined()
  }

  var verbatimTexts: [String] { pieces.filter(\.isVerbatim).map(\.text) }

  /// A one-word label (a channel, file or branch name) rather than prose: fewer than two words
  /// in scripts that separate words with spaces, fewer than four characters in those that do
  /// not (§四). Whole-window translation leaves it alone.
  var isLabel: Bool {
    let prose = pieces.filter { !$0.isVerbatim }.map(\.text).joined()
    let letters = prose.unicodeScalars.filter(CharacterSet.letters.contains)
    let unspaced = letters.filter { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }
    if unspaced.count * 2 >= letters.count, !letters.isEmpty { return unspaced.count < 4 }
    let words = prose.split(whereSeparator: { $0.isWhitespace })
      .filter { $0.unicodeScalars.contains(where: CharacterSet.letters.contains) }
    return words.count < 2
  }

  /// Prose that reads as code: most of its lines are commands, statements, JSON or stack
  /// frames (§四). Whole-window translation leaves it alone; ⌥D still translates it, so a
  /// paragraph misjudged here is one key away.
  var looksLikeCode: Bool {
    let prose = pieces.filter { !$0.isVerbatim }.map(\.text).joined()
    let lines = prose.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !lines.isEmpty else { return false }
    return lines.filter(LayerCodeText.isCodeLine).count * 3 >= lines.count * 2
  }

  /// Puts link and code text back where the model kept the placeholders.
  func restoringVerbatim(in translation: String) -> String {
    restoring(in: translation).text
  }

  /// The translation with link and code text put back, and where the links landed in it.
  func restoring(in translation: String) -> (text: String, links: [NSRange]) {
    let verbatim = pieces.filter(\.isVerbatim)
    var text = ""
    var links: [NSRange] = []
    var rest = Substring(translation)
    while let match = rest.firstMatch(of: /⟦(\d+)⟧/) {
      text += rest[..<match.range.lowerBound]
      if let index = Int(match.1), verbatim.indices.contains(index) {
        let piece = verbatim[index]
        if piece.isLink { links.append(NSRange(location: (text as NSString).length, length: (piece.text as NSString).length)) }
        text += piece.text
      } else {
        text += match.0
      }
      rest = rest[match.range.upperBound...]
    }
    return (text + rest, links)
  }

  /// Where the original's last line ends: the top-left of the caret that breathes after it while
  /// its translation is on the way (§二 等待).
  var endOfText: CGPoint {
    guard let last = pieces.last(where: { $0.frame != nil })?.frame else {
      return CGPoint(x: frame.maxX, y: frame.maxY - lineHeight)
    }
    // A piece taller than a line wraps; its last line ends at the paragraph's right edge.
    return last.height <= lineHeight * 1.5
      ? CGPoint(x: last.maxX, y: last.minY)
      : CGPoint(x: frame.maxX, y: frame.maxY - lineHeight)
  }
}

/// Code set in a monospaced face without a code element around it, like the ``` blocks of
/// Slack, which Chromium exposes as a plain group of text (§四). Every character of a
/// monospaced face is equally wide; in a proportional face a narrow character (`i`, `l`, `.`)
/// is at least a fifth of the size narrower than the rest. Chromium rounds each character's box
/// to whole points, so monospaced advances read as 7 and 8 alike.
enum LayerMonospace {
  static let narrow = Set("ijltfrI!|.,:;'`()[]{}")
  static let wide = Set("mwMW@%")

  static func isMonospaced(_ text: String, bounds: (NSRange) -> CGRect?, fontSize: () -> CGFloat? = { nil }) -> Bool {
    var widths: [(isOdd: Bool, width: CGFloat)] = []
    var span: (left: CGFloat, right: CGFloat)?
    var hasNarrow = false, hasWide = false, hasMiddle = false
    var firstLine: CGFloat?
    var lastLeft = -CGFloat.greatestFiniteMagnitude
    var offset = 0
    for character in text {
      let length = character.utf16.count
      defer { offset += length }
      if character.isNewline || widths.count >= 24 { break }
      guard character.isASCII, !character.isWhitespace else { continue }
      guard let box = bounds(NSRange(location: offset, length: length)), box.width > 0 else { return false }
      // Only the first line: a wrapped line starts again at the left.
      if let top = firstLine, abs(box.midY - top) > box.height / 2 { break }
      // Some apps answer every range with the element's own box; those say nothing.
      guard box.minX > lastLeft, box.width < box.height * 1.2 else { return false }
      lastLeft = box.minX
      span = (span?.left ?? box.minX, box.maxX)
      firstLine = firstLine ?? box.midY
      let isNarrow = narrow.contains(character), isWide = wide.contains(character)
      hasNarrow = hasNarrow || isNarrow
      hasWide = hasWide || isWide
      hasMiddle = hasMiddle || (!isNarrow && !isWide)
      widths.append((isNarrow || isWide, box.width))
      let all = widths.map(\.width)
      // Proportional as soon as characters differ by more than rounding.
      if all.max()! - all.min()! > 1.5 { return false }
    }
    // Equal widths only mean something when the sample holds characters a proportional face
    // sets differently.
    let telling = (hasNarrow && (hasMiddle || hasWide)) || (hasWide && hasMiddle)
    if widths.count >= 6, telling { return true }
    // Letters of middling width alone (a Slack block of plain words): a monospaced face
    // advances about 0.6 of its size for every character, a proportional one about half its
    // size for these letters (Slack's 12 pt code advanced 7.3 pt a character).
    guard widths.count >= 5, let span, let size = fontSize(), size > 0 else { return false }
    let advance = (span.right - span.left) / CGFloat(widths.count) / size
    return (0.57...0.63).contains(advance)
  }
}

/// Lines of prose that read as code (§四): a shell prompt, a statement, an operator, JSON, a
/// stack frame, or words that are mostly identifiers, paths and flags.
enum LayerCodeText {
  static func isCodeLine(_ line: String) -> Bool {
    // Chat prose uses `->` for "becomes" and starts lines with `[WIP]`, so neither counts.
    let starts = ["$ ", "#!", "//", "/*", "{", "}"]
    let operators = ["=>", "::", "==", "!=", "&&", "||", ":=", "();", "</", "/>", "+=", "${"]
    if line.hasPrefix("at "), line.contains(":"), line.contains("(") { return true }
    // A JSON or YAML member: `"key": value`.
    if line.hasPrefix("\""), line.contains("\":") { return true }
    if starts.contains(where: line.hasPrefix) { return true }
    if line.hasSuffix(";") || line.hasSuffix("{") || operators.contains(where: line.contains) { return true }
    let words = line.split(whereSeparator: \.isWhitespace)
    guard words.count >= 2 else { return words.first.map(isIdentifier) ?? false }
    // "Fix parse_args() in cli.rs" is a sentence about code, not code.
    return words.filter(isIdentifier).count * 3 >= words.count * 2
  }

  /// `snake_case`, `camelCase`, `a.b.c`, `/a/b`, `--flag`, `key=value`, `call(x)`.
  static func isIdentifier(_ word: Substring) -> Bool {
    let word = word.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"'"))
    guard word.contains(where: \.isLetter) else { return false }
    if word.contains("_") || word.contains("=") || word.contains("(") || word.contains("/") { return true }
    if word.hasPrefix("-"), word.count > 1 { return true }
    let parts = word.split(separator: ".")
    if parts.count > 1, parts.allSatisfy({ !$0.isEmpty }) { return true }
    // An upper-case letter after a lower-case one: camelCase.
    return zip(word, word.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
  }
}

enum LayerBlockExtractor {
  static let nodeLimit = 20_000

  /// The paragraphs of a pane that are on screen inside `visible` (the pane's frame, usually).
  static func blocks<Node: LayerNode>(in pane: Node, visible: CGRect? = nil) -> [LayerBlock] {
    located(in: pane, visible: visible).map(\.block)
  }

  /// The paragraphs with the element each came from, so their positions can be read again
  /// without walking the pane.
  ///
  /// `automatic` is for whole-window translation (§四): navigation trees and one-word labels
  /// are left alone there. Text the user is writing is never read.
  static func located<Node: LayerNode>(
    in pane: Node, visible: CGRect? = nil, automatic: Bool = false
  ) -> [(block: LayerBlock, node: Node)] {
    let clip = visible ?? pane.frame ?? .infinite
    var blocks: [(block: LayerBlock, node: Node)] = []
    var stack = [pane]
    var visited = 0
    while let node = stack.popLast(), visited < nodeLimit {
      visited += 1
      if let frame = node.frame, frame.height > 0, !frame.intersects(clip) { continue }
      if automatic, node.role == LayerRole.outline { continue }
      // A small editable area is an input field (a chat composer), as for panes.
      if node.role == LayerRole.textArea, !LayerPaneRule.isLargeEnough(node.frame) { continue }
      if node.role == LayerRole.textArea {
        blocks.append(contentsOf: documentBlocks(of: node, visible: clip).map { ($0, node) })
        continue
      }
      // A link on its own is left alone, unless it continues a line of prose (`continuingLines`).
      if node.role == LayerRole.link {
        let text = plainText(node)
        if !text.isEmpty, let frame = node.frame, frame.height >= 6, frame.intersects(clip) {
          let piece = LayerBlock.Piece(text: text, isVerbatim: true, frame: frame, isLink: true)
          blocks.append((LayerBlock(pieces: [piece], frame: frame, lineHeight: frame.height), node))
        }
        continue
      }
      let children = node.children
      if LayerRole.formParagraph(children) {
        if isStack(children) {
          // Lines of text stacked in one native container are separate paragraphs.
          for child in children where child.role == LayerRole.staticText {
            for block in paragraphs(child, children: [child], visible: clip) { blocks.append((block, child)) }
          }
        } else {
          for block in paragraphs(node, children: children, visible: clip) { blocks.append((block, node)) }
        }
        continue
      }
      // Lone text under a container that is not a paragraph (a label beside a control).
      if node.role == LayerRole.staticText {
        for block in paragraphs(node, children: [node], visible: clip) { blocks.append((block, node)) }
        continue
      }
      // Walk children in reading order.
      stack.append(contentsOf: children.reversed())
    }
    let paragraphs = continuingLines(blocks).filter(\.block.hasProse)
    return automatic ? paragraphs.filter { !$0.block.isLabel && !$0.block.looksLikeCode } : paragraphs
  }

  /// Joins runs that continue one line into one paragraph (§三). Apps put pieces of a line in
  /// containers of their own (a bridged chat message, a styled span); translated one by one,
  /// a link between them was left out and the shorter translation of the rest left a gap
  /// before it. Two runs continue a line when they sit on it together and the second starts
  /// where the first ends, give or take an emoji. Table cells beside each other stay apart.
  private static func continuingLines<Node: LayerNode>(
    _ blocks: [(block: LayerBlock, node: Node)]
  ) -> [(block: LayerBlock, node: Node)] {
    func isCell(_ node: Node) -> Bool {
      node.role == LayerRole.cell || node.parent?.role == LayerRole.cell
    }
    var joined: [(block: LayerBlock, node: Node)] = []
    for next in blocks {
      guard let current = joined.last, !isCell(current.node), !isCell(next.node),
        let end = current.block.pieces.last(where: { $0.frame != nil })?.frame,
        let start = next.block.pieces.first(where: { $0.frame != nil })?.frame
      else {
        joined.append(next)
        continue
      }
      let line = min(current.block.lineHeight, next.block.lineHeight)
      // A run that wraps ends on its last line, somewhere short of its frame's right edge.
      let wraps = end.height > line * 1.5
      let lastLine = wraps ? CGRect(x: end.minX, y: end.maxY - line, width: end.width, height: line) : end
      let gap = start.minX - end.maxX
      let continues = wraps ? start.minX >= end.minX - 4 && start.minX < end.maxX : gap > -4 && gap < line * 1.5
      guard abs(lastLine.midY - start.midY) < line * 0.6, continues else {
        joined.append(next)
        continue
      }
      joined[joined.count - 1] = (
        LayerBlock(
          pieces: current.block.pieces + next.block.pieces, frame: current.block.frame.union(next.block.frame),
          lineHeight: line),
        current.node
      )
    }
    return joined
  }

  /// Two or more texts, no links, one below the other without sharing a line: a native
  /// stack of labels or paragraphs, not the pieces of one wrapped paragraph.
  static func isStack<Node: LayerNode>(_ children: [Node]) -> Bool {
    let texts = children.filter { $0.role == LayerRole.staticText }
    guard texts.count >= 2,
      !children.contains(where: { $0.role == LayerRole.link || LayerRole.isStyleGroup($0) })
    else {
      return false
    }
    let frames = texts.compactMap(\.frame).sorted { $0.minY < $1.minY }
    guard frames.count == texts.count else { return false }
    return zip(frames, frames.dropFirst()).allSatisfy { $1.minY >= $0.maxY - 1 }
  }

  /// One piece of a paragraph as laid out: its text (none for an image) and where it is.
  private struct Run<Node: LayerNode> {
    let piece: LayerBlock.Piece?
    let frame: CGRect?
    /// The static text it came from, for measuring a line.
    let text: Node?
  }

  /// The paragraphs in one container. It is usually one; a container whose lines are broken
  /// by hand (a Slack alert's "Service: …", "Urgency: …" lines) holds one per line group.
  private static func paragraphs<Node: LayerNode>(
    _ node: Node, children: [Node], visible: CGRect
  ) -> [LayerBlock] {
    if LayerRole.controls.contains(node.role) { return [] }
    if let parent = node.parent, LayerRole.controls.contains(parent.role),
      node.role == LayerRole.staticText
    {
      return []
    }
    guard let container = node.frame else { return [] }
    var runs: [Run<Node>] = []
    func append(_ child: Node) {
      switch child.role {
      case LayerRole.staticText:
        if let text = child.textValue, !text.isEmpty {
          // Text set in a monospaced face is code, as if it were in a code element.
          let isCode = LayerMonospace.isMonospaced(
            text, bounds: child.bounds(ofCharacters:), fontSize: { child.fontSize })
          runs.append(Run(piece: .init(text: text, isVerbatim: isCode, frame: child.frame), frame: child.frame, text: child))
        }
      case LayerRole.link:
        let text = plainText(child)
        if !text.isEmpty {
          runs.append(
            Run(piece: .init(text: text, isVerbatim: true, frame: child.frame, isLink: true), frame: child.frame, text: nil))
        }
      default:
        if child.subrole == LayerRole.codeStyleGroup {
          let text = plainText(child)
          if !text.isEmpty {
            runs.append(Run(piece: .init(text: text, isVerbatim: true, frame: child.frame), frame: child.frame, text: nil))
          }
        } else if LayerRole.isStyleGroup(child) {
          child.children.forEach(append)
        } else {
          runs.append(Run(piece: nil, frame: child.frame, text: nil))
        }
      }
    }
    children.forEach(append)
    return lineGroups(runs, in: container).compactMap { block(from: $0, visible: visible) }
  }

  /// Splits runs where a line was broken by hand: the text ends in a line break, or the next
  /// run starts a new line at the left edge while the line before stopped short of the right
  /// edge. A paragraph that merely wraps fills its lines, so it stays whole.
  private static func lineGroups<Node: LayerNode>(_ runs: [Run<Node>], in container: CGRect) -> [[Run<Node>]] {
    var groups: [[Run<Node>]] = [[]]
    var previous: CGRect?
    for run in runs {
      if let frame = run.frame, let last = previous, frame.minY >= last.maxY - 2,
        frame.minX <= container.minX + 4, last.maxX < container.maxX - container.width * 0.4
      {
        groups.append([])
      }
      groups[groups.count - 1].append(run)
      if let frame = run.frame, frame.width > 0, frame.height > 0 { previous = frame }
      if run.piece?.text.hasSuffix("\n") == true {
        groups.append([])
        previous = nil
      }
    }
    return groups.filter { !$0.isEmpty }
  }

  private static func block<Node: LayerNode>(from runs: [Run<Node>], visible: CGRect) -> LayerBlock? {
    let pieces = runs.compactMap(\.piece)
    // Link-only runs are kept until the runs continuing their line are joined (`continuingLines`).
    guard !pieces.isEmpty else { return nil }
    let frames = runs.compactMap(\.frame).filter { $0.width > 0 && $0.height > 0 }
    guard let first = frames.first else { return nil }
    let frame = frames.dropFirst().reduce(first) { $0.union($1) }
    // Chromium parks virtualized rows just outside the view with a height of one point.
    guard frame.height >= 6, frame.intersects(visible) else { return nil }
    var smallestPiece = CGFloat.greatestFiniteMagnitude
    var measuredLine: CGFloat?
    for run in runs {
      guard let text = run.text else { continue }
      if let height = run.frame?.height, height > 4 { smallestPiece = min(smallestPiece, height) }
      // The first character's box is one line tall, however many lines the text wraps to.
      if measuredLine == nil, let height = text.bounds(ofCharacters: NSRange(location: 0, length: 1))?.height,
        height > 4
      {
        measuredLine = height
      }
    }
    return LayerBlock(
      pieces: pieces, frame: frame,
      lineHeight: measuredLine ?? estimatedLineHeight(
        text: pieces.map(\.text).joined(), frame: frame, smallestPiece: smallestPiece))
  }

  /// The paragraph on the pointer's line (§二): the one under it, or the nearest beside it,
  /// so a press anywhere along a line picks that line even where its text stops short.
  static func paragraph(at point: CGPoint, in blocks: [LayerBlock]) -> LayerBlock? {
    paragraphIndex(at: point, in: blocks).map { blocks[$0] }
  }

  static func paragraphIndex(at point: CGPoint, in blocks: [LayerBlock]) -> Int? {
    if let under = blocks.firstIndex(where: { $0.frame.contains(point) }) { return under }
    func distance(_ frame: CGRect) -> CGFloat {
      point.x < frame.minX ? frame.minX - point.x : max(0, point.x - frame.maxX)
    }
    return blocks.indices
      .filter { blocks[$0].frame.minY - 2 <= point.y && point.y <= blocks[$0].frame.maxY + 2 }
      .min { distance(blocks[$0].frame) < distance(blocks[$1].frame) }
  }

  /// Without a character box, a line is judged from how much text fills the frame: at font
  /// size f a line is about 1.3 f tall and holds width / (0.52 f) characters, so the frame
  /// holds width × height / (0.68 f²). A piece shorter than two such lines is one line itself.
  static func estimatedLineHeight(text: String, frame: CGRect, smallestPiece: CGFloat) -> CGFloat {
    let characters = CGFloat(max(text.count, 1))
    let fontSize = min(max((frame.width * frame.height / (0.68 * characters)).squareRoot(), 9), 28)
    let estimate = fontSize * 1.3
    if smallestPiece < estimate * 1.6 { return smallestPiece }
    return estimate
  }

  private static func plainText<Node: LayerNode>(_ node: Node) -> String {
    var parts: [String] = []
    var stack = [node]
    while let node = stack.popLast() {
      if node.role == LayerRole.staticText, let text = node.textValue { parts.append(text) }
      stack.append(contentsOf: node.children.reversed())
    }
    return parts.joined()
  }

  /// A whole document in one text area: paragraphs by line breaks, placed by character range.
  private static func documentBlocks<Node: LayerNode>(of node: Node, visible: CGRect) -> [LayerBlock] {
    guard let value = node.textValue, !value.isEmpty else { return [] }
    let text = value as NSString
    var blocks: [LayerBlock] = []
    var location = 0
    while location < text.length {
      let range = text.paragraphRange(for: NSRange(location: location, length: 0))
      location = NSMaxRange(range)
      let paragraph = text.substring(with: range).trimmingCharacters(in: .newlines)
      guard paragraph.contains(where: { $0.isLetter }) else { continue }
      let trimmed = NSRange(location: range.location, length: (paragraph as NSString).length)
      guard let frame = node.bounds(ofCharacters: trimmed), frame.height > 0,
        frame.intersects(visible)
      else {
        continue
      }
      let lineHeight = node.bounds(ofCharacters: NSRange(location: trimmed.location, length: 1))?
        .height ?? min(frame.height, 20)
      blocks.append(
        LayerBlock(pieces: [.init(text: paragraph, isVerbatim: false)], frame: frame, lineHeight: lineHeight))
    }
    return blocks
  }
}

// MARK: - Whole windows

/// An app, or a site in a browser, whose windows are translated whole (§三). Kept across
/// relaunches.
struct LayerWindowRule: Codable, Equatable, Hashable, Sendable {
  var bundleIdentifier: String
  var applicationName: String
  var scope: LayerScope

  /// Whether a window of `bundleIdentifier` showing `site` is translated.
  func applies(to bundleIdentifier: String, site: String?) -> Bool {
    guard bundleIdentifier == self.bundleIdentifier else { return false }
    switch scope {
    case .application: return true
    case .site(let host): return host == site
    }
  }
}
