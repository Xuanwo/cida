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
}

enum LayerRole {
  static let staticText = "AXStaticText"
  static let link = "AXLink"
  static let image = "AXImage"
  static let listMarker = "AXListMarker"
  static let textArea = "AXTextArea"
  static let webArea = "AXWebArea"
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

// MARK: - Locating a pane again

/// How a chosen pane is found again after relaunches, channel switches and resizes: what it
/// is (role, DOM classes, identifier) and where it sits in its window, relative to the window.
struct LayerPaneLocator: Codable, Equatable, Sendable {
  var role: String
  var subrole: String?
  var domClasses: [String]
  var identifier: String?
  /// The pane's frame as fractions of its window's frame.
  var relativeFrame: CGRect

  init<Node: LayerNode>(pane: Node, window: CGRect) {
    role = pane.role
    subrole = pane.subrole
    domClasses = pane.domClasses
    identifier = pane.identifier
    relativeFrame = Self.relative(pane.frame ?? .zero, in: window)
  }

  init(
    role: String, subrole: String? = nil, domClasses: [String] = [], identifier: String? = nil,
    relativeFrame: CGRect
  ) {
    self.role = role
    self.subrole = subrole
    self.domClasses = domClasses
    self.identifier = identifier
    self.relativeFrame = relativeFrame
  }

  static func relative(_ frame: CGRect, in window: CGRect) -> CGRect {
    guard window.width > 0, window.height > 0 else { return .zero }
    return CGRect(
      x: (frame.minX - window.minX) / window.width, y: (frame.minY - window.minY) / window.height,
      width: frame.width / window.width, height: frame.height / window.height)
  }

  /// Whether `node` is the same kind of element: same role, and the same identifier or
  /// DOM classes when the pane had them.
  func matches<Node: LayerNode>(_ node: Node) -> Bool {
    guard node.role == role, node.subrole == subrole else { return false }
    if let identifier, !identifier.isEmpty { return node.identifier == identifier }
    // State classes (hovered, selected, focus) come and go; the first class names the component.
    if let first = domClasses.first { return node.domClasses.first == first }
    return true
  }

  /// The matching element in `window` whose relative frame is closest to the remembered one.
  func resolve<Node: LayerNode>(in window: Node, limit: Int = 20_000) -> Node? {
    guard let windowFrame = window.frame else { return nil }
    var best: (node: Node, distance: CGFloat)?
    var stack = [window]
    var visited = 0
    while let node = stack.popLast(), visited < limit {
      visited += 1
      if matches(node), let frame = node.frame, LayerPaneRule.isLargeEnough(frame) {
        let candidate = Self.relative(frame, in: windowFrame)
        let distance =
          abs(candidate.minX - relativeFrame.minX) + abs(candidate.minY - relativeFrame.minY)
          + abs(candidate.width - relativeFrame.width) + abs(candidate.height - relativeFrame.height)
        if best == nil || distance < best!.distance { best = (node, distance) }
      }
      stack.append(contentsOf: node.children)
    }
    // Far off means the layout changed beyond recognition; better nothing than the wrong pane.
    guard let best, best.distance < 0.8 else { return nil }
    return best.node
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
  }

  let pieces: [Piece]
  /// Screen points, top-left origin.
  let frame: CGRect
  /// The height of one line, from the smallest text piece; it sizes the translation's font.
  let lineHeight: CGFloat

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

  /// Puts link and code text back where the model kept the placeholders.
  func restoringVerbatim(in translation: String) -> String {
    var restored = translation
    for (index, text) in verbatimTexts.enumerated() {
      restored = restored.replacingOccurrences(of: "⟦\(index)⟧", with: text)
    }
    return restored
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
  static func located<Node: LayerNode>(
    in pane: Node, visible: CGRect? = nil
  ) -> [(block: LayerBlock, node: Node)] {
    let clip = visible ?? pane.frame ?? .infinite
    var blocks: [(block: LayerBlock, node: Node)] = []
    var stack = [pane]
    var visited = 0
    while let node = stack.popLast(), visited < nodeLimit {
      visited += 1
      if let frame = node.frame, frame.height > 0, !frame.intersects(clip) { continue }
      if node.role == LayerRole.textArea {
        blocks.append(contentsOf: documentBlocks(of: node, visible: clip).map { ($0, node) })
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
    return blocks
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
          runs.append(Run(piece: .init(text: text, isVerbatim: false), frame: child.frame, text: child))
        }
      case LayerRole.link:
        let text = plainText(child)
        if !text.isEmpty { runs.append(Run(piece: .init(text: text, isVerbatim: true), frame: child.frame, text: nil)) }
      default:
        if child.subrole == LayerRole.codeStyleGroup {
          let text = plainText(child)
          if !text.isEmpty { runs.append(Run(piece: .init(text: text, isVerbatim: true), frame: child.frame, text: nil)) }
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
    // All the text sits in links or code: names, times, navigation, identifiers (§三).
    guard pieces.contains(where: { !$0.isVerbatim && $0.text.contains(where: { $0.isLetter }) }) else {
      return nil
    }
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

// MARK: - Selections

/// A pane the user chose: in which app, for which site when it sits in web content, and how
/// to find it again.
struct LayerSelection: Codable, Equatable, Identifiable, Sendable {
  var id = UUID()
  var bundleIdentifier: String
  var applicationName: String
  var scope: LayerScope
  var locator: LayerPaneLocator

  /// Whether this selection applies to a window of `bundleIdentifier` showing `site`.
  func applies(to bundleIdentifier: String, site: String?) -> Bool {
    guard bundleIdentifier == self.bundleIdentifier else { return false }
    switch scope {
    case .application: return true
    case .site(let host): return host == site
    }
  }
}
