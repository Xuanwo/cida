import AppKit
import SwiftUI
import Carbon.HIToolbox
import XCTest

@testable import Cida

/// A hand-built accessibility tree for the layer rules.
final class FakeLayerNode: LayerNode {
  let role: String
  let subrole: String?
  let frame: CGRect?
  let textValue: String?
  let domClasses: [String]
  let identifier: String?
  let url: URL?
  private(set) var children: [FakeLayerNode] = []
  weak var parent: FakeLayerNode?
  var characterBounds: (NSRange) -> CGRect? = { _ in nil }

  init(
    _ role: String, _ frame: CGRect? = nil, text: String? = nil, classes: [String] = [],
    subrole: String? = nil, identifier: String? = nil, url: URL? = nil,
    children: [FakeLayerNode] = []
  ) {
    self.role = role
    self.frame = frame
    textValue = text
    domClasses = classes
    self.subrole = subrole
    self.identifier = identifier
    self.url = url
    self.children = children
    for child in children { child.parent = self }
  }

  func bounds(ofCharacters range: NSRange) -> CGRect? { characterBounds(range) }
  func isSameElement(as other: FakeLayerNode) -> Bool { self === other }

  static func text(_ value: String, _ frame: CGRect) -> FakeLayerNode {
    FakeLayerNode(LayerRole.staticText, frame, text: value)
  }

  static func link(_ value: String, _ frame: CGRect) -> FakeLayerNode {
    FakeLayerNode(LayerRole.link, frame, children: [text(value, frame)])
  }
}

private typealias Node = FakeLayerNode

@MainActor
final class TranslationLayerTests: XCTestCase {
  /// The shape of Slack's window as measured on 2026-09-27: a plain group for the message
  /// area, a scroll container inside it, messages whose body is a rich-text section split by
  /// mentions and links, and sender, time and reply bar in buttons and links.
  private func slackWindow() -> (window: Node, messages: Node, scroller: Node, composer: Node) {
    let body = Node(
      "AXGroup", CGRect(x: 751, y: 640, width: 900, height: 44), classes: ["p-rich_text_section"],
      children: [
        .text("Thanks to ", CGRect(x: 751, y: 640, width: 80, height: 22)),
        .link("@maya", CGRect(x: 831, y: 640, width: 50, height: 22)),
        .text(" for testing the compaction job before Friday.", CGRect(x: 881, y: 640, width: 400, height: 22)),
      ])
    let sender = Node("AXButton", CGRect(x: 751, y: 615, width: 116, height: 22), children: [
      .text("Maya Chen", CGRect(x: 751, y: 615, width: 116, height: 22))
    ])
    let time = Node.link("10:02", CGRect(x: 880, y: 615, width: 40, height: 18))
    let reply = Node("AXGroup", CGRect(x: 751, y: 700, width: 300, height: 20), classes: ["c-message__reply_bar"], children: [
      .link("3 replies", CGRect(x: 751, y: 700, width: 80, height: 20))
    ])
    let message = Node(
      "AXGroup", CGRect(x: 687, y: 611, width: 1869, height: 120), classes: ["c-message_kit__hover"],
      subrole: "AXDocument", children: [sender, time, body, reply])
    // A row Chromium parks outside the view, one point tall.
    let parked = Node("AXGroup", CGRect(x: 687, y: 149, width: 1869, height: 1), children: [
      Node("AXGroup", CGRect(x: 751, y: 149, width: 900, height: 1), classes: ["p-rich_text_section"], children: [
        .text("An older message scrolled away", CGRect(x: 751, y: 149, width: 300, height: 1))
      ])
    ])
    let earlier = Node(
      "AXGroup", CGRect(x: 687, y: 480, width: 1869, height: 84), classes: ["c-message_kit__hover"],
      subrole: "AXDocument", children: [
        Node("AXGroup", CGRect(x: 751, y: 510, width: 900, height: 22), classes: ["p-rich_text_section"], children: [
          .text("Morning! The job finished overnight.", CGRect(x: 751, y: 510, width: 300, height: 22))
        ])
      ])
    let scroller = Node(
      "AXGroup", CGRect(x: 687, y: 149, width: 1869, height: 1191), classes: ["c-scrollbar__hider"],
      children: [parked, earlier, message])
    let messages = Node(
      "AXGroup", CGRect(x: 687, y: 149, width: 1869, height: 1191),
      classes: ["p-message_pane", "p-message_pane--classic-nav"], children: [scroller])
    let composer = Node(
      LayerRole.textArea, CGRect(x: 707, y: 1332, width: 1829, height: 80), text: "Draft",
      classes: ["ql-editor"])
    let footer = Node("AXGroup", CGRect(x: 687, y: 1332, width: 1869, height: 104), children: [composer])
    let webArea = Node(
      LayerRole.webArea, CGRect(x: 244, y: 30, width: 2316, height: 1410),
      url: URL(string: "https://app.slack.com/client/T0/C0"),
      children: [Node("AXGroup", CGRect(x: 244, y: 30, width: 2316, height: 1410), children: [messages, footer])])
    let window = Node(LayerRole.window, CGRect(x: 244, y: 30, width: 2316, height: 1410), children: [webArea])
    return (window, messages, scroller, composer)
  }

  // MARK: - Pane

  func testThePaneIsTheFirstLargeContainerWithTextNotAList() {
    let slack = slackWindow()
    // AX answers a point inside a message with the scroll container itself.
    XCTAssertTrue(LayerPaneRule.pane(from: slack.scroller) === slack.scroller)
    // A deeper hit climbs past text, links and small groups.
    // A deeper hit climbs past text, links and a single large message to the list of them.
    let deepText = slack.scroller.children[2].children[2].children[0]
    XCTAssertTrue(LayerPaneRule.pane(from: deepText) === slack.scroller)
  }

  func testANativeStackScrolledInAScrollAreaIsSeenThroughTheScrollArea() {
    let texts = (0..<12).map { index in
      Node.text("Paragraph \(index) of a long native article.", CGRect(x: 40, y: 100 + index * 60, width: 600, height: 44))
    }
    let stack = Node("AXGroup", CGRect(x: 40, y: 100, width: 600, height: 720), children: texts)
    let scroll = Node("AXScrollArea", CGRect(x: 20, y: 80, width: 680, height: 300), children: [stack])
    _ = Node(LayerRole.window, CGRect(x: 0, y: 0, width: 760, height: 460), children: [scroll])
    XCTAssertTrue(LayerPaneRule.pane(from: texts[1]) === scroll)
    XCTAssertEqual(LayerBlockExtractor.blocks(in: scroll, visible: scroll.frame).count, 5, "Rows inside the view only")
  }

  func testAComposerOrAFieldIsNeverAPaneButALargeDocumentIs() {
    let slack = slackWindow()
    XCTAssertNil(LayerPaneRule.pane(from: slack.composer))
    XCTAssertNil(LayerPaneRule.pane(from: Node("AXTextField", CGRect(x: 0, y: 0, width: 400, height: 300), text: "search")))
    let document = Node(LayerRole.textArea, CGRect(x: 0, y: 0, width: 656, height: 384), text: "Meeting notes")
    XCTAssertTrue(LayerPaneRule.pane(from: document) === document)
  }

  func testAPaneWithoutTextIsNotOffered() {
    let canvas = Node("AXGroup", CGRect(x: 0, y: 0, width: 800, height: 600), children: [
      Node(LayerRole.image, CGRect(x: 0, y: 0, width: 800, height: 600))
    ])
    XCTAssertNil(LayerPaneRule.pane(from: canvas))
  }

  // MARK: - Blocks

  /// Slack's current client, measured on 2026-09-27: messages are rows of a list that is a
  /// one-point screen-reader node, and an alert is one rich-text element whose lines are broken
  /// by hand, with bold labels, code values and emoji wrapped in plain groups.
  private func slackAlertPane() -> (pane: Node, alert: Node, label: Node) {
    func code(_ value: String, _ frame: CGRect) -> Node {
      Node("AXGroup", frame, classes: ["c-mrkdwn__code"], subrole: LayerRole.codeStyleGroup, children: [
        .text(value, frame.insetBy(dx: 4, dy: 0))
      ])
    }
    let label = Node.text("Service:", CGRect(x: 716, y: 279, width: 53, height: 19))
    let alert = Node("AXGroup", CGRect(x: 716, y: 255, width: 1785, height: 110), classes: ["p-mrkdwn_element"], children: [
      .text("service-pods-failing | ", CGRect(x: 716, y: 255, width: 396, height: 19)),
      Node("AXGroup", CGRect(x: 1112, y: 255, width: 22, height: 22), classes: ["c-emoji"], children: [
        Node(LayerRole.image, CGRect(x: 1112, y: 255, width: 22, height: 22))
      ]),
      .text(" Firing 1", CGRect(x: 1134, y: 255, width: 66, height: 19)),
      label,
      .text(" ", CGRect(x: 769, y: 279, width: 4, height: 19)),
      code("SaaS", CGRect(x: 772, y: 279, width: 38, height: 21)),
      .text("Urgency:", CGRect(x: 716, y: 301, width: 60, height: 19)),
      .text(" ", CGRect(x: 776, y: 301, width: 4, height: 19)),
      code("high", CGRect(x: 780, y: 301, width: 37, height: 21)),
      .link("View the incident in PagerDuty", CGRect(x: 716, y: 345, width: 424, height: 19)),
    ])
    let bold = Node("AXGroup", CGRect(x: 716, y: 420, width: 1785, height: 21), children: [
      .text("Please ", CGRect(x: 716, y: 420, width: 50, height: 21)),
      Node("AXGroup", CGRect(x: 766, y: 420, width: 90, height: 21), subrole: "AXStrongStyleGroup", children: [
        .text("do not restart", CGRect(x: 766, y: 420, width: 90, height: 21))
      ]),
      .text(" the pods yet.", CGRect(x: 856, y: 420, width: 100, height: 21)),
    ])
    func row(_ y: CGFloat, _ height: CGFloat, _ body: Node) -> Node {
      Node("AXGroup", CGRect(x: 652, y: y, width: 1869, height: height), classes: ["c-virtual_list__item"], children: [
        Node("AXGroup", CGRect(x: 652, y: y, width: 1869, height: height), classes: ["c-message_kit__hover"], subrole: "AXDocument", children: [
          Node("AXGroup", CGRect(x: 669, y: y, width: 1832, height: height), classes: ["c-message_kit__actions"], children: [
            Node("AXButton", CGRect(x: 716, y: y, width: 90, height: 20), children: [.text("LanceDuty", CGRect(x: 716, y: y, width: 90, height: 20))]),
            body,
          ])
        ])
      ])
    }
    let list = Node("AXList", CGRect(x: 652, y: 1339, width: 1, height: 1), classes: ["sr-only"], subrole: "AXContentList", children: [
      row(230, 150, alert), row(400, 60, bold),
    ])
    let pane = Node("AXGroup", CGRect(x: 652, y: 149, width: 1869, height: 1191), classes: ["p-message_pane"], children: [list])
    _ = Node(LayerRole.window, CGRect(x: 209, y: 30, width: 2316, height: 1410), children: [pane])
    return (pane, alert, label)
  }

  func testTheWholeMessageListIsThePaneEvenFromInsideALongMessage() {
    let slack = slackAlertPane()
    // The alert alone is large and holds several paragraphs, but it is a row of the list.
    XCTAssertTrue(LayerPaneRule.pane(from: slack.label) === slack.pane)
    XCTAssertTrue(LayerPaneRule.pane(from: slack.alert) === slack.pane)
  }

  func testAClickAnywhereAlongALinePicksThatLine() {
    let blocks = LayerBlockExtractor.blocks(in: slackAlertPane().pane)
    // Right of "Service: SaaS", where the line's text stops, still picks it.
    XCTAssertEqual(LayerBlockExtractor.paragraph(at: CGPoint(x: 1500, y: 289), in: blocks)?.maskedText, "Service: ⟦0⟧")
    XCTAssertEqual(LayerBlockExtractor.paragraph(at: CGPoint(x: 720, y: 310), in: blocks)?.maskedText, "Urgency: ⟦0⟧")
    XCTAssertNil(LayerBlockExtractor.paragraph(at: CGPoint(x: 900, y: 390), in: blocks), "Between lines, nothing")
  }

  func testLinesBrokenByHandAreSeparateBlocksWithCodeKeptAndStyledRunsJoined() {
    let blocks = LayerBlockExtractor.blocks(in: slackAlertPane().pane)
    // The emoji belongs to its line; a line that is only a link is not content.
    XCTAssertEqual(
      blocks.map(\.maskedText),
      ["service-pods-failing |  Firing 1", "Service: ⟦0⟧", "Urgency: ⟦0⟧", "Please do not restart the pods yet."])
    XCTAssertEqual(blocks[1].restoringVerbatim(in: "服务：⟦0⟧"), "服务：SaaS")
    XCTAssertEqual(blocks[1].frame, CGRect(x: 716, y: 279, width: 94, height: 21), "Only its own line is covered")
  }


  func testAMessageBodyIsOneBlockWithItsMentionKeptOutOfTheTranslation() throws {
    let slack = slackWindow()
    let blocks = LayerBlockExtractor.blocks(in: slack.scroller)
    // Sender, time, reply count and the parked row are not content.
    XCTAssertEqual(
      blocks.map(\.text),
      ["Morning! The job finished overnight.", "Thanks to @maya for testing the compaction job before Friday."])
    let block = try XCTUnwrap(blocks.last)
    XCTAssertEqual(block.maskedText, "Thanks to ⟦0⟧ for testing the compaction job before Friday.")
    XCTAssertEqual(block.restoringVerbatim(in: "感谢 ⟦0⟧ 在周五前测试压缩任务。"), "感谢 @maya 在周五前测试压缩任务。")
    XCTAssertEqual(block.lineHeight, 22)
  }

  func testWebParagraphsListItemsAndCellsAreBlocksAndNavigationIsNot() {
    let page = Node(LayerRole.webArea, CGRect(x: 0, y: 0, width: 1000, height: 800), url: URL(string: "https://example.dev/blog"), children: [
      Node("AXGroup", CGRect(x: 0, y: 0, width: 150, height: 90), children: [
        .link("Home", CGRect(x: 0, y: 0, width: 50, height: 20)),
        .link("Docs", CGRect(x: 0, y: 30, width: 50, height: 20)),
      ]),
      Node("AXHeading", CGRect(x: 200, y: 0, width: 600, height: 40), children: [
        .text("Release notes", CGRect(x: 200, y: 0, width: 300, height: 40))
      ]),
      Node("AXGroup", CGRect(x: 200, y: 60, width: 600, height: 24), children: [
        Node(LayerRole.listMarker, CGRect(x: 190, y: 60, width: 8, height: 20)),
        .text("Compaction no longer blocks writers.", CGRect(x: 200, y: 60, width: 400, height: 24)),
      ]),
      Node("AXCell", CGRect(x: 200, y: 120, width: 100, height: 24), children: [
        .text("Point lookup", CGRect(x: 200, y: 120, width: 100, height: 24))
      ]),
      Node("AXGroup", CGRect(x: 200, y: 160, width: 600, height: 24), children: [
        .link("https://example.dev/releases/2.4", CGRect(x: 200, y: 160, width: 300, height: 24))
      ]),
    ])
    XCTAssertEqual(
      LayerBlockExtractor.blocks(in: page).map(\.text),
      ["Release notes", "Compaction no longer blocks writers.", "Point lookup"])
    XCTAssertEqual(LayerScope.of(page.children[1]), .site("example.dev"))
  }

  /// A bridged Discord message in Slack, as measured on 2026-09-28: each run of one line
  /// sits in a container of its own, the link in another. Read container by container, the
  /// link was left out and the shorter translation of the rest left a gap before it. Runs that
  /// continue one line are one paragraph, the link travelling as a placeholder; separate lines
  /// and table cells stay apart.
  func testRunsContinuingOneLineAreOneParagraphWithTheirLink() throws {
    func box(_ child: Node) -> Node { Node("AXGroup", child.frame, children: [child]) }
    let message = Node("AXGroup", CGRect(x: 652, y: 440, width: 1869, height: 126), children: [
      box(.text("LanceDB / # ", CGRect(x: 716, y: 468, width: 84, height: 18))),
      box(Node(LayerRole.image, CGRect(x: 802, y: 468, width: 18, height: 18))),
      box(.text("questions", CGRect(x: 821, y: 468, width: 65, height: 18))),
      box(.link("Open in Discord", CGRect(x: 898, y: 468, width: 107, height: 18))),
      box(.text("Zhuang Keju: ", CGRect(x: 716, y: 490, width: 88, height: 18))),
      box(.text("Hi all, I reported the issue below: ", CGRect(x: 803, y: 490, width: 322, height: 18))),
      box(.link("https://github.com/lancedb/lancedb/issues/3669", CGRect(x: 1124, y: 490, width: 324, height: 18))),
      box(.text("It is closed now, but I can still reproduce it after the fix, and the script never reaches the path the fix handles.", CGRect(x: 716, y: 520, width: 1691, height: 40))),
    ])
    let blocks = LayerBlockExtractor.blocks(in: message)
    XCTAssertEqual(blocks.map(\.maskedText), [
      "LanceDB / # questions⟦0⟧",
      "Zhuang Keju: Hi all, I reported the issue below: ⟦0⟧",
      "It is closed now, but I can still reproduce it after the fix, and the script never reaches the path the fix handles.",
    ])
    let issue = try XCTUnwrap(blocks.dropFirst().first)
    XCTAssertEqual(issue.frame, CGRect(x: 716, y: 490, width: 732, height: 18))

    let row = Node("AXRow", CGRect(x: 0, y: 0, width: 400, height: 24), children: [
      Node("AXCell", CGRect(x: 0, y: 0, width: 120, height: 24), children: [.text("Point lookup", CGRect(x: 0, y: 0, width: 110, height: 24))]),
      Node("AXCell", CGRect(x: 120, y: 0, width: 120, height: 24), children: [.text("Full scan", CGRect(x: 124, y: 0, width: 80, height: 24))]),
    ])
    XCTAssertEqual(LayerBlockExtractor.blocks(in: row).map(\.text), ["Point lookup", "Full scan"])
  }

  /// A paragraph that wraps, with a link and more text after it on its last line, each in a
  /// container of its own (the issue post in Slack, 2026-09-28): the link and the text after it
  /// continue the paragraph rather than starting a new one part way along the line.
  func testALinkOnTheLastLineOfAWrappedParagraphContinuesIt() {
    func box(_ child: Node) -> Node { Node("AXGroup", child.frame, children: [child]) }
    let message = Node("AXGroup", CGRect(x: 687, y: 494, width: 1869, height: 120), children: [
      box(.text("I proposed gating the read and write paths so new types can land before they are complete; I opened an issue and would like feedback on whether this is the right direction:", CGRect(x: 751, y: 552, width: 1780, height: 40))),
      box(.link("github.com/apache/iceberg-rust/issues/3258", CGRect(x: 1227, y: 574, width: 301, height: 18))),
      box(.text(" (I'm hoping to put up a draft PR this week.)", CGRect(x: 1529, y: 574, width: 257, height: 18))),
    ])
    let blocks = LayerBlockExtractor.blocks(in: message)
    XCTAssertEqual(blocks.count, 1)
    XCTAssertEqual(blocks.first?.frame, CGRect(x: 751, y: 552, width: 1780, height: 40))
    XCTAssertEqual(blocks.first?.verbatimTexts, ["github.com/apache/iceberg-rust/issues/3258"])
  }

  func testADocumentInOneTextAreaSplitsIntoPlacedParagraphs() {
    let text = "Meeting notes.\n\nWe moved the review to Thursday.\nAction items follow.\n"
    let document = Node(LayerRole.textArea, CGRect(x: 0, y: 0, width: 600, height: 400), text: text)
    document.characterBounds = { range in
      let line = (text as NSString).substring(to: range.location).components(separatedBy: "\n").count - 1
      return CGRect(x: 10, y: CGFloat(line) * 20, width: 500, height: 18)
    }
    let blocks = LayerBlockExtractor.blocks(in: document)
    XCTAssertEqual(blocks.map(\.text), ["Meeting notes.", "We moved the review to Thursday.", "Action items follow."])
    XCTAssertEqual(blocks.map(\.frame.minY), [0, 40, 60])
  }

  func testStackedNativeTextsAreSeparateParagraphsButWrappedPiecesAreOne() {
    let stack = Node("AXGroup", CGRect(x: 0, y: 0, width: 600, height: 200), children: [
      .text("First paragraph of the article.", CGRect(x: 0, y: 0, width: 600, height: 40)),
      .text("Second paragraph follows below.", CGRect(x: 0, y: 56, width: 600, height: 40)),
    ])
    XCTAssertEqual(LayerBlockExtractor.blocks(in: stack).map(\.text), ["First paragraph of the article.", "Second paragraph follows below."])
    // Web pieces of one wrapped paragraph share lines.
    let wrapped = Node("AXGroup", CGRect(x: 0, y: 0, width: 600, height: 44), children: [
      .text("A sentence that wraps onto ", CGRect(x: 0, y: 0, width: 600, height: 44)),
      .text("a second line.", CGRect(x: 0, y: 22, width: 200, height: 22)),
    ])
    XCTAssertEqual(LayerBlockExtractor.blocks(in: wrapped).map(\.text), ["A sentence that wraps onto a second line."])
  }

  func testOnlyParagraphsInsideTheVisibleFrameAreRead() {
    let pane = Node("AXGroup", CGRect(x: 0, y: 0, width: 400, height: 300), children: [
      Node("AXGroup", CGRect(x: 0, y: 20, width: 400, height: 20), children: [.text("Visible line", CGRect(x: 0, y: 20, width: 200, height: 20))]),
      Node("AXGroup", CGRect(x: 0, y: 900, width: 400, height: 20), children: [.text("Far below", CGRect(x: 0, y: 900, width: 200, height: 20))]),
    ])
    XCTAssertEqual(LayerBlockExtractor.blocks(in: pane).map(\.text), ["Visible line"])
  }

  // MARK: - Scope and locating again

  func testASlackPaneIsRememberedForItsFixedSiteAndANativePaneForTheApp() {
    let slack = slackWindow()
    XCTAssertEqual(LayerScope.of(slack.scroller), .site("app.slack.com"))
    let native = Node("AXScrollArea", CGRect(x: 0, y: 0, width: 400, height: 400))
    XCTAssertEqual(LayerScope.of(native), .application)
    XCTAssertEqual(LayerScope.site("example.dev").label(applicationName: "Google Chrome"), "example.dev")
    XCTAssertEqual(LayerScope.application.label(applicationName: "Slack"), "Slack")
  }

  func testAWindowRuleAppliesToItsAppAndSiteOnlyAndIsKept() {
    let site = LayerWindowRule(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", scope: .site("example.dev"))
    XCTAssertTrue(site.applies(to: "com.google.Chrome", site: "example.dev"))
    XCTAssertFalse(site.applies(to: "com.google.Chrome", site: "news.ycombinator.com"))
    XCTAssertFalse(site.applies(to: "com.apple.Safari", site: "example.dev"))
    let app = LayerWindowRule(bundleIdentifier: "com.tinyspeck.slackmacgap", applicationName: "Slack", scope: .application)
    XCTAssertTrue(app.applies(to: "com.tinyspeck.slackmacgap", site: "app.slack.com"))

    let namespace = SettingsStore.automationNamespacePrefix + "layer-\(UUID().uuidString)"
    defer { UserDefaults(suiteName: namespace)?.removePersistentDomain(forName: namespace) }
    SettingsStore.saveLayerWindowRules([site, app], namespace: namespace)
    XCTAssertEqual(SettingsStore.loadLayerWindowRules(namespace: namespace), [site, app])
  }

  /// Slack's window as measured on 2026-09-27: a channel sidebar that is a navigation tree,
  /// a channel header, the message list, and a thread panel beside it.
  private func slackWholeWindow() -> (window: Node, messages: Node, thread: Node) {
    let sidebar = Node(LayerRole.outline, CGRect(x: 339, y: 151, width: 313, height: 1285), children: [
      Node("AXRow", CGRect(x: 339, y: 160, width: 313, height: 28), children: [.text("storage-eng", CGRect(x: 360, y: 164, width: 120, height: 20))]),
      Node("AXRow", CGRect(x: 339, y: 190, width: 313, height: 28), children: [.text("Direct messages", CGRect(x: 360, y: 194, width: 140, height: 20))]),
    ])
    let header = Node("AXGroup", CGRect(x: 652, y: 70, width: 1148, height: 60), children: [
      Node(LayerRole.staticText, CGRect(x: 672, y: 90, width: 120, height: 22), text: "storage-eng")
    ])
    func message(_ y: CGFloat, _ text: String) -> Node {
      Node("AXGroup", CGRect(x: 652, y: y, width: 1148, height: 60), classes: ["c-virtual_list__item"], children: [
        Node("AXGroup", CGRect(x: 716, y: y + 24, width: 900, height: 22), children: [.text(text, CGRect(x: 716, y: y + 24, width: 600, height: 22))])
      ])
    }
    let list = Node("AXList", CGRect(x: 652, y: 1339, width: 1, height: 1), subrole: "AXContentList", children: [
      message(200, "The compaction job finished overnight."), message(270, "LGTM"), message(340, "好的"), message(410, "好的，我今晚再看一下这个问题"),
    ])
    let messages = Node("AXGroup", CGRect(x: 652, y: 149, width: 1148, height: 1191), classes: ["p-message_pane"], children: [list])
    let replies = Node("AXList", CGRect(x: 1800, y: 250, width: 1, height: 1), subrole: "AXContentList", children: [
      Node("AXGroup", CGRect(x: 1800, y: 260, width: 721, height: 60), children: [
        Node("AXGroup", CGRect(x: 1820, y: 280, width: 600, height: 22), children: [.text("Can someone review the retention change?", CGRect(x: 1820, y: 280, width: 400, height: 22))])
      ]),
      Node("AXGroup", CGRect(x: 1800, y: 330, width: 721, height: 60), children: [
        Node("AXGroup", CGRect(x: 1820, y: 350, width: 600, height: 22), children: [.text("I will take a look after lunch.", CGRect(x: 1820, y: 350, width: 400, height: 22))])
      ]),
    ])
    let thread = Node("AXGroup", CGRect(x: 1800, y: 250, width: 721, height: 1117), children: [replies])
    let content = Node("AXGroup", CGRect(x: 652, y: 70, width: 1869, height: 1366), children: [header, messages, thread])
    let window = Node(LayerRole.window, CGRect(x: 209, y: 30, width: 2316, height: 1410), children: [sidebar, content])
    return (window, messages, thread)
  }

  func testWholeWindowTranslationLeavesNavigationAndOneWordLabelsAlone() {
    let slack = slackWholeWindow()
    let texts = LayerBlockExtractor.blocks(in: slack.window, visible: slack.window.frame).map(\.text)
    XCTAssertTrue(texts.contains("storage-eng") && texts.contains("LGTM"), "⌥D can still point at them")
    let automatic = LayerBlockExtractor.located(in: slack.window, visible: slack.window.frame, automatic: true).map(\.block.text)
    XCTAssertEqual(
      automatic,
      ["The compaction job finished overnight.", "好的，我今晚再看一下这个问题",
       "Can someone review the retention change?", "I will take a look after lunch."],
      "No sidebar, no channel name, no one-word or two-character message")
  }

  func testAWindowSplitsIntoTheParagraphsOwnPanesSmallerFirst() {
    let slack = slackWholeWindow()
    let panes = LayerPaneRule.panes(in: slack.window)
    XCTAssertEqual(panes.count, 2)
    XCTAssertTrue(panes.contains { $0 === slack.messages }, "The message list scrolls on its own")
    XCTAssertTrue(panes.contains { $0 === slack.thread }, "So does the thread beside it")
  }

  // MARK: - Language

  func testOnlyTextOutsideMyLanguageIsSent() {
    let chinese = LayerLanguageFilter(myLanguage: "简体中文")
    XCTAssertEqual(chinese.myLanguage, .simplifiedChinese)
    XCTAssertTrue(chinese.needsTranslation("Could it be the new prefetch default?"))
    XCTAssertFalse(chinese.needsTranslation("会不会是新的预取默认值导致的？"))
    XCTAssertFalse(chinese.needsTranslation("會不會是新的預取預設值導致的？"), "Either Chinese script reads")
    XCTAssertFalse(chinese.needsTranslation("12:04 · 3"), "No letters, nothing to translate")

    XCTAssertEqual(LayerLanguageFilter(myLanguage: "English").myLanguage, .english)
    XCTAssertEqual(LayerLanguageFilter(myLanguage: "英式英语").myLanguage, .english)
    XCTAssertEqual(LayerLanguageFilter(myLanguage: "繁體中文（台灣）").myLanguage, .traditionalChinese)
    XCTAssertEqual(LayerLanguageFilter(myLanguage: "日本語").myLanguage, .japanese)
    // Unknown wording: send everything and let the model return unchanged text.
    XCTAssertTrue(LayerLanguageFilter(myLanguage: "克林贡语").needsTranslation("你好 world"))
  }

  // MARK: - Request

  func testTheRequestIsNumberedJSONIntoMyLanguageWithPlaceholdersKept() throws {
    var settings = CidaSettings()
    settings.myLanguage = "简体中文"
    let request = try LayerTranslationRequest.request(texts: ["Hi ⟦0⟧", "Bye"], settings: settings)
    XCTAssertTrue(request.translatesLayerBlocks)
    XCTAssertEqual(
      try JSONDecoder().decode([LayerTranslationRequest.Item].self, from: Data(request.text.utf8)),
      [.init(id: 0, text: "Hi ⟦0⟧"), .init(id: 1, text: "Bye")])
    let prompt = try ModelPromptBuilder.build(request: request, settings: settings)
    XCTAssertEqual(prompt.parameters.languageBehavior, .translateInto)
    XCTAssertNil(prompt.parameters.foreignLanguage)
    XCTAssertTrue(prompt.systemMessage.contains("Keep every ⟦n⟧ placeholder exactly as written"))
    XCTAssertFalse(prompt.systemMessage.contains("Hi ⟦0⟧"), "Source text stays out of the instructions")

    let panel = try ModelPromptBuilder.build(
      request: ProcessingRequest(text: "Hi", mode: .translate, myLanguage: "简体中文", foreignLanguage: "English"),
      settings: settings)
    XCTAssertEqual(panel.parameters.languageBehavior, .translateBetween)
    XCTAssertFalse(panel.systemMessage.contains("translate_into"), "The panel's contract is unchanged")
  }

  func testRepliesDecodeInOrderFencedOrNotAndMismatchesFail() throws {
    XCTAssertEqual(
      try LayerTranslationRequest.decode(#"[{"id":1,"text":"乙"},{"id":0,"text":"甲"}]"#, count: 2), ["甲", "乙"])
    XCTAssertEqual(
      try LayerTranslationRequest.decode("```json\n[{\"id\":0,\"text\":\"甲\"}]\n```", count: 1), ["甲"])
    for reply in [#"[{"id":0,"text":"甲"}]"#, #"[{"id":0,"text":" "},{"id":1,"text":"乙"}]"#, "no json"] {
      XCTAssertThrowsError(try LayerTranslationRequest.decode(reply, count: 2))
    }
  }

  func testBatchesStayWithinTheItemAndCharacterLimits() {
    let many = Array(repeating: "short", count: 95)
    XCTAssertEqual(LayerTranslationRequest.batches(of: many).map(\.count), [40, 40, 15])
    let long = Array(repeating: String(repeating: "x", count: 5_000), count: 5)
    XCTAssertEqual(LayerTranslationRequest.batches(of: long).map(\.count), [2, 2, 1])
  }

  func testTranslationRunsThroughTheServiceAndRefusesWithoutOne() async throws {
    struct Echo: TextProcessingService {
      let configured: Bool
      func isConfigured(by settings: CidaSettings) -> Bool { configured }
      func stream(_ request: ProcessingRequest, settings: CidaSettings) -> AsyncThrowingStream<String, Error> {
        let items = try! JSONDecoder().decode([LayerTranslationRequest.Item].self, from: Data(request.text.utf8))
        let reply = String(decoding: try! JSONEncoder().encode(items.map { LayerTranslationRequest.Item(id: $0.id, text: "译:" + $0.text) }), as: UTF8.self)
        return AsyncThrowingStream { continuation in
          continuation.yield(String(reply.prefix(10)))
          continuation.yield(String(reply.dropFirst(10)))
          continuation.finish()
        }
      }
    }
    let result = try await LayerTranslationRequest.translate(["a", "b"], settings: CidaSettings(), service: Echo(configured: true))
    XCTAssertEqual(result, ["译:a", "译:b"])
    do {
      _ = try await LayerTranslationRequest.translate(["a"], settings: CidaSettings(), service: Echo(configured: false))
      XCTFail("A service without configuration must not be asked")
    } catch {
      XCTAssertEqual(error as? LayerTranslationError, .notConfigured)
    }
  }

  // MARK: - Drawing

  /// Translations are set in Cida's result serif (§五): at the original's size where they fit,
  /// smaller where they do not, never clipped, with Cida's caret just after the last character.
  func testTranslationsAreSetInTheResultSerifEndingWithCidasCaret() throws {
    FontRegistrar.registerBundledFonts()
    XCTAssertEqual(LayerTypeset.fontSize(forLineHeight: 18), 15)
    let short = try XCTUnwrap(LayerTypeset.fitting("同意，我来核对保留策略。", in: CGSize(width: 600, height: 18), lineHeight: 18))
    XCTAssertEqual(short.font.pointSize, 15)
    XCTAssertEqual(short.font.familyName, "Noto Serif SC")
    XCTAssertEqual(short.lines.count, 1)
    let lineEnd = CGFloat(CTLineGetTypographicBounds(short.lines[0].line, nil, nil, nil))
    XCTAssertEqual(short.caret.minX, lineEnd + 3, accuracy: 0.5)
    XCTAssertEqual(short.caret.width, 2)
    XCTAssertTrue(short.caret.minY >= -LayerTypeset.bleed && short.caret.maxY <= 18 + LayerTypeset.bleed)

    let long = String(repeating: "压缩任务昨晚跑完了，但生产表的清单数涨了三倍。", count: 3)
    let shrunk = try XCTUnwrap(LayerTypeset.fitting(long, in: CGSize(width: 300, height: 40), lineHeight: 18))
    XCTAssertLessThan(shrunk.font.pointSize, 15)
    XCTAssertGreaterThanOrEqual(shrunk.font.pointSize, 8)
    XCTAssertNil(LayerTypeset.fitting(String(repeating: long, count: 10), in: CGSize(width: 60, height: 12), lineHeight: 12))
  }

  /// Links come back where the model kept their placeholders, and the drawing knows where they
  /// are to set them in accent.
  func testLinksComeBackIntoTheTranslationWhereTheModelKeptThem() {
    let block = LayerBlock(
      pieces: [
        .init(text: "I reported ", isVerbatim: false),
        .init(text: "lancedb#3669", isVerbatim: true, isLink: true),
        .init(text: " and ", isVerbatim: false),
        .init(text: "compact()", isVerbatim: true),
      ],
      frame: .zero, lineHeight: 18)
    let (text, links) = block.restoring(in: "我在 ⟦1⟧ 之后报告了 ⟦0⟧")
    XCTAssertEqual(text, "我在 compact() 之后报告了 lancedb#3669")
    XCTAssertEqual(links.map { (text as NSString).substring(with: $0) }, ["lancedb#3669"])
  }

  /// One caret a run of translated paragraphs, not one a paragraph: an unfurled issue in Slack
  /// set a caret after each of its short paragraphs.
  func testOnlyTheLastOfParagraphsSetOneUnderAnotherKeepsItsCaret() {
    let style = LayerTextStyle.paper(darkAppearance: false)
    func drawing(_ y: CGFloat, _ height: CGFloat = 18, x: CGFloat = 80) -> LayerDrawing {
      LayerDrawing(frame: CGRect(x: x, y: y, width: 600, height: height), text: "译文", lineHeight: 18, style: style)
    }
    let carets = [drawing(100), drawing(128, 40), drawing(180), drawing(260), drawing(290, x: 900)]
      .caretsOnLastOfEachRun().map(\.showsCaret)
    // 100 → 128 and 168 → 180 are paragraph gaps; 198 → 260 starts another message; the last
    // one sits beside, not under.
    XCTAssertEqual(carets, [false, false, true, true, true])
  }

  // MARK: - The third shortcut

  func testTheLayerShortcutDefaultsToOptionDAndNoTwoShortcutsShareACombination() {
    var applied: [GlobalShortcutAction] = []
    let model = AppModel(saveSettings: { _ in }, applyGlobalShortcut: { _, action in
      applied.append(action)
      return true
    })
    XCTAssertEqual(model.settings.layerShortcut, GlobalShortcut(keyCode: UInt16(kVK_ANSI_D), modifiers: .option))
    XCTAssertEqual(GlobalShortcutAction.translationLayer.defaultShortcut, .optionD)
    XCTAssertFalse(model.setShortcut(.optionS, for: .translationLayer))
    XCTAssertFalse(model.setShortcut(.optionD, for: .captureText))
    XCTAssertTrue(applied.isEmpty)
    let recorded = GlobalShortcut(keyCode: UInt16(kVK_ANSI_L), modifiers: [.control, .option])
    XCTAssertTrue(model.setShortcut(recorded, for: .translationLayer))
    XCTAssertEqual(model.settings.layerShortcut, recorded)
    XCTAssertEqual(applied, [.translationLayer])
  }

  func testTheLayerShortcutLeavesShiftToTheWholeWindow() throws {
    let model = AppModel(saveSettings: { _ in }, applyGlobalShortcut: { _, _ in true })
    XCTAssertEqual(model.settings.layerShortcut.addingShift.displayText, "⌥ ⇧ D")
    XCTAssertFalse(model.setShortcut(GlobalShortcut(keyCode: UInt16(kVK_ANSI_L), modifiers: [.option, .shift]), for: .translationLayer))
    XCTAssertFalse(model.setShortcut(.optionD.addingShift, for: .captureText), "⌥⇧D is the whole window")

    var configuration = EditableConfiguration(settings: CidaSettings(), automaticUpdates: true, launchAtLogin: false)
    try ConfigurationField.layerShortcut.apply("option+shift+l", to: &configuration)
    XCTAssertThrowsError(try ConfigurationField.validate(configuration))
    ConfigurationField.layerShortcut.reset(in: &configuration)
    try ConfigurationField.captureShortcut.apply("option+shift+d", to: &configuration)
    XCTAssertThrowsError(try ConfigurationField.validate(configuration))
  }

  func testOlderSettingsDecodeWithOptionDAndACustomLayerShortcutRoundTrips() throws {
    let legacy = try JSONDecoder().decode(CidaSettings.self, from: Data(#"{"captureShortcut":{"keyCode":1,"modifiers":2}}"#.utf8))
    XCTAssertEqual(legacy.layerShortcut, .optionD)
    var settings = CidaSettings()
    settings.layerShortcut = GlobalShortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command, .shift])
    XCTAssertEqual(try JSONDecoder().decode(CidaSettings.self, from: JSONEncoder().encode(settings)).layerShortcut, settings.layerShortcut)
  }

  func testTheCommandLineSetsTheLayerShortcutAndRefusesADuplicate() throws {
    var configuration = EditableConfiguration(settings: CidaSettings(), automaticUpdates: true, launchAtLogin: false)
    XCTAssertEqual(ConfigurationField.layerShortcut.jsonValue(in: configuration, hasAPIKey: false), .string("option+d"))
    try ConfigurationField.layerShortcut.apply("control+option+l", to: &configuration)
    XCTAssertEqual(configuration.settings.layerShortcut.configurationText, "control+option+l")
    XCTAssertNoThrow(try ConfigurationField.validate(configuration))
    try ConfigurationField.layerShortcut.apply("option+s", to: &configuration)
    XCTAssertThrowsError(try ConfigurationField.validate(configuration))
    ConfigurationField.layerShortcut.reset(in: &configuration)
    XCTAssertEqual(configuration.settings.layerShortcut, GlobalShortcut.optionD)
  }

  /// Cida says everything in one place (§五 提示胶囊): centred on the screen under the
  /// pointer, the pill's top edge on the panel's, which leaves out the menu bar and the Dock.
  func testTheLayerAndCaptureHintsSitOnThePanelsTopEdge() throws {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    // A 37 pt menu bar and a 70 pt Dock on the left.
    let visible = CGRect(x: 70, y: 0, width: 1442, height: 945)
    let panelTop = CidaDesign.Panel.topEdge(in: visible)
    XCTAssertEqual(panelTop, 945 - 189)

    let size = CGSize(width: 380, height: 112)
    let layerPill = LayerHintPanel.frame(fitting: size, in: visible)
      .insetBy(dx: CidaHintPill.shadowMargin, dy: CidaHintPill.shadowMargin)
    XCTAssertEqual(layerPill.maxY, panelTop, accuracy: 1)
    XCTAssertEqual(layerPill.midX, visible.midX, accuracy: 1)

    let image = try XCTUnwrap(
      CGContext(
        data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )?.makeImage())
    let overlay = CaptureOverlayView(frame: CGRect(origin: .zero, size: screen.size), image: image, veil: .paper)
    overlay.hintAnchor = CidaDesign.Panel.topCenter(in: visible)
    overlay.layoutSubtreeIfNeeded()
    let hosting = try XCTUnwrap(overlay.subviews.first { $0 is NSHostingView<CaptureHint> })
    let capturePill = hosting.frame.insetBy(dx: CidaHintPill.shadowMargin, dy: CidaHintPill.shadowMargin)
    XCTAssertEqual(capturePill.maxY, panelTop, accuracy: 1)
    XCTAssertEqual(capturePill.midX, visible.midX, accuracy: 1)
  }

  /// Stage Manager keeps a window in the window list while it shows it as a thumbnail in the
  /// strip; its tree still reports the full frame, so its translations would float where the
  /// window no longer is (2026-09-28, Slack behind Claude on the user's Mac).
  func testAWindowShownElsewhereThanItsTreeSaysIsNotInPlace() {
    let slack = CGRect(x: 209, y: 30, width: 2316, height: 1410)
    let front = LayerWindowInfo(number: 1, ownerPID: 900, bounds: slack, layer: 0)
    let inTheStrip = LayerWindowInfo(
      number: 1, ownerPID: 900, bounds: CGRect(x: -323, y: 578, width: 189, height: 161), layer: 0)
    XCTAssertTrue(LayerWindowInfo.isInPlace(front, windowFrame: slack))
    XCTAssertTrue(LayerWindowInfo.isInPlace(front, windowFrame: slack.offsetBy(dx: 1, dy: -1)))
    XCTAssertFalse(LayerWindowInfo.isInPlace(inTheStrip, windowFrame: slack))
  }

  /// While Stage Manager animates a window, its WindowManager process holds a copy of it just
  /// above, at the same frame; that copy masked the translations until the window landed.
  func testStageManagersCopyOfTheWindowDoesNotCoverIt() {
    let bounds = CGRect(x: 191, y: 110, width: 614, height: 416)
    let windows = [
      LayerWindowInfo(number: 5, ownerPID: 80, bounds: bounds, layer: 0, ownerName: "WindowManager"),
      LayerWindowInfo(number: 6, ownerPID: 81, bounds: CGRect(x: 0, y: 0, width: 300, height: 300), layer: 0, ownerName: "Notes"),
      LayerWindowInfo(number: 7, ownerPID: 900, bounds: bounds, layer: 0, ownerName: "TextEdit"),
    ]
    let covering = LayerWindowInfo.occluders(of: 7, in: windows, displays: [])
    XCTAssertEqual(covering.map(\.number), [6])
  }

  func testOnlyWindowsInFrontCoverAPaneAndWholeDisplayOverlaysDoNot() {
    let own = ProcessInfo.processInfo.processIdentifier
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let windows = [
      LayerWindowInfo(number: 1, ownerPID: 900, bounds: display, layer: 0),
      LayerWindowInfo(number: 2, ownerPID: own, bounds: CGRect(x: 0, y: 0, width: 400, height: 300), layer: 3),
      LayerWindowInfo(number: 3, ownerPID: 901, bounds: CGRect(x: 100, y: 100, width: 300, height: 200), layer: 0),
      LayerWindowInfo(number: 4, ownerPID: 902, bounds: CGRect(x: 50, y: 50, width: 800, height: 600), layer: 0),
      LayerWindowInfo(number: 5, ownerPID: 903, bounds: CGRect(x: 0, y: 500, width: 200, height: 200), layer: 0),
    ]
    XCTAssertEqual(
      LayerWindowInfo.occluders(of: 4, in: windows, displays: [display]).map(\.number), [3],
      "Only other apps' windows in front, not a full-display overlay or Cida itself")
    XCTAssertEqual(
      LayerWindowInfo.applicationWindow(at: CGPoint(x: 120, y: 120), in: windows, displays: [display])?.number, 3,
      "The pointer is over the app window, not the overlay above everything")
  }

  func testALineIsOneCharacterBoxTallOrJudgedFromHowMuchTextFillsTheFrame() {
    let wrapped = Node("AXGroup", CGRect(x: 0, y: 0, width: 600, height: 60), children: [
      .text(String(repeating: "storage engine ", count: 8), CGRect(x: 0, y: 0, width: 600, height: 60))
    ])
    let estimated = try! XCTUnwrap(LayerBlockExtractor.blocks(in: wrapped).first).lineHeight
    XCTAssertEqual(estimated, 25, accuracy: 6, "A two-line text is not one 60 pt line")

    let measured = Node.text("CIDA LAYER PARAGRAPH 2. A long paragraph.", CGRect(x: 0, y: 0, width: 600, height: 44))
    measured.characterBounds = { _ in CGRect(x: 0, y: 0, width: 9, height: 18) }
    let pane = Node("AXGroup", CGRect(x: 0, y: 0, width: 600, height: 60), children: [measured, .link("x", .zero)])
    XCTAssertEqual(LayerBlockExtractor.blocks(in: pane).first?.lineHeight, 18)
  }
}
