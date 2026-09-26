import AppKit
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

  func testAMessageBodyIsOneBlockWithItsMentionKeptOutOfTheTranslation() throws {
    let slack = slackWindow()
    let blocks = LayerBlockExtractor.blocks(in: slack.scroller)
    // Sender, time, reply count and the parked row are not content.
    XCTAssertEqual(
      blocks.map(\.text),
      ["Morning! The job finished overnight.", "Thanks to @maya for testing the compaction job before Friday."])
    let block = try XCTUnwrap(blocks.last)
    XCTAssertEqual(block.maskedText, "Thanks to ⟦0⟧ for testing the compaction job before Friday.")
    XCTAssertEqual(block.restoringLinks(in: "感谢 ⟦0⟧ 在周五前测试压缩任务。"), "感谢 @maya 在周五前测试压缩任务。")
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

  func testALocatorFindsTheSamePaneAfterTheWindowResizesButNotAStranger() throws {
    let slack = slackWindow()
    let locator = LayerPaneLocator(pane: slack.scroller, window: try XCTUnwrap(slack.window.frame))
    XCTAssertTrue(locator.resolve(in: slack.window) === slack.scroller)

    // Same classes, same place relative to a wider window.
    let wider = Node(LayerRole.window, CGRect(x: 0, y: 0, width: 3000, height: 1410), children: [
      Node("AXGroup", CGRect(x: 824, y: 119, width: 2420, height: 1191), classes: ["c-scrollbar__hider"], children: [
        Node("AXGroup", CGRect(x: 900, y: 200, width: 900, height: 22), children: [.text("hi", CGRect(x: 900, y: 200, width: 20, height: 22))])
      ])
    ])
    XCTAssertNotNil(locator.resolve(in: wider))

    let stranger = Node(LayerRole.window, CGRect(x: 0, y: 0, width: 800, height: 600), children: [
      Node("AXGroup", CGRect(x: 0, y: 0, width: 800, height: 600), classes: ["something-else"])
    ])
    XCTAssertNil(locator.resolve(in: stranger))
  }

  func testASelectionAppliesToItsAppAndSiteOnly() {
    let locator = LayerPaneLocator(role: "AXGroup", relativeFrame: .zero)
    let site = LayerSelection(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", scope: .site("example.dev"), locator: locator)
    XCTAssertTrue(site.applies(to: "com.google.Chrome", site: "example.dev"))
    XCTAssertFalse(site.applies(to: "com.google.Chrome", site: "news.ycombinator.com"))
    XCTAssertFalse(site.applies(to: "com.apple.Safari", site: "example.dev"))
    let app = LayerSelection(bundleIdentifier: "com.apple.TextEdit", applicationName: "TextEdit", scope: .application, locator: locator)
    XCTAssertTrue(app.applies(to: "com.apple.TextEdit", site: nil))
  }

  func testSelectionsRoundTripThroughStorage() throws {
    let namespace = SettingsStore.automationNamespacePrefix + "layer-\(UUID().uuidString)"
    defer { UserDefaults(suiteName: namespace)?.removePersistentDomain(forName: namespace) }
    let selection = LayerSelection(
      bundleIdentifier: "com.tinyspeck.slackmacgap", applicationName: "Slack", scope: .site("app.slack.com"),
      locator: LayerPaneLocator(role: "AXGroup", domClasses: ["c-scrollbar__hider"], relativeFrame: CGRect(x: 0.19, y: 0.08, width: 0.8, height: 0.84)))
    SettingsStore.saveLayerSelections([selection], namespace: namespace)
    XCTAssertEqual(SettingsStore.loadLayerSelections(namespace: namespace), [selection])
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

  func testTranslationsShrinkToFitButNeverClip() {
    let fitted = LayerTextFitting.fittedFont(
      text: "这是较长的一段译文，需要换行显示。", size: CGSize(width: 130, height: 44), maximum: 24)
    XCTAssertNotNil(fitted)
    XCTAssertLessThan(fitted!.pointSize, 24)
    XCTAssertGreaterThanOrEqual(fitted!.pointSize, 8)
    XCTAssertNil(LayerTextFitting.fittedFont(
      text: String(repeating: "很多文字", count: 100), size: CGSize(width: 30, height: 10), maximum: 20))
    XCTAssertEqual(LayerTextFitting.fontSize(forLineHeight: 22), 22 / 1.3, accuracy: 0.01)
  }

  func testPaperAndInkAreSampledFromTheWindow() throws {
    let width = 200, height = 40
    let context = try XCTUnwrap(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
    for x in stride(from: 10, to: 190, by: 6) { context.fill(CGRect(x: x, y: 12, width: 3, height: 16)) }
    let style = try XCTUnwrap(LayerColorSampler.style(
      in: try XCTUnwrap(context.makeImage()), pixelRect: CGRect(x: 0, y: 0, width: width, height: height)))
    XCTAssertLessThan(style.background.usingColorSpace(.sRGB)!.redComponent, 0.2)
    XCTAssertGreaterThan(style.foreground.usingColorSpace(.sRGB)!.redComponent, 0.8)
    XCTAssertFalse(style.isPaper)
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

  // MARK: - Following motion

  /// A tall "document" of pseudo-random text rows with blank gaps, viewed through a 400-row
  /// window at different offsets, plus a static sidebar in the left eighth.
  private func frame(offset: Int, width: Int = 320, height: Int = 400, replaced: Bool = false) -> [UInt32] {
    var pixels = [UInt32](repeating: 0xFFFF_FFFF, count: width * height)
    for y in 0..<height {
      let documentRow = y + offset
      for x in 0..<width {
        if x < width / 8 {
          pixels[y * width + x] = UInt32(truncatingIfNeeded: (y * 31 + x * 7) % 251) | 0xFF00_0000
        } else if documentRow % 24 < 16 {
          var seed = UInt64(documentRow &* 2_654_435_761 &+ (replaced ? 99 : 0)) &* UInt64(x + 1)
          seed ^= seed >> 13
          pixels[y * width + x] = seed % 5 == 0 ? 0xFF10_1010 : 0xFFFF_FFFF
        }
      }
    }
    return pixels
  }

  private func rows(_ pixels: [UInt32], width: Int = 320, height: Int = 400) -> LayerMotionEstimator.Rows {
    pixels.withUnsafeBytes { raw in
      LayerMotionEstimator.rows(
        base: raw.bindMemory(to: UInt8.self).baseAddress!, bytesPerRow: width * 4, width: width,
        height: height, crop: CGRect(x: 0, y: 0, width: width, height: height))
    }
  }

  func testScrolledContentShiftsByExactRowsPastAStaticSidebarAndReplacementDeclines() {
    let start = rows(frame(offset: 1_000))
    for delta in [2, 40, 120, -60] {
      XCTAssertEqual(LayerMotionEstimator.shift(from: start, to: rows(frame(offset: 1_000 + delta))), delta)
    }
    XCTAssertEqual(LayerMotionEstimator.shift(from: start, to: start), 0)
    XCTAssertNil(LayerMotionEstimator.shift(from: start, to: rows(frame(offset: 1_000, replaced: true))))
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
