import AppKit
import XCTest

@testable import Cida

/// The share card ⇧⌘C copies (`Design/spec/panel.md` §八).
@MainActor
final class ShareCardTests: XCTestCase {
  private let source = ResultRecord.designTranslateSource
  private let result = ResultRecord.designTranslateResult

  func testTheCardIsTheBoardsWidthAtThreePixelsAPointInsideItsShadowMargin() throws {
    let card = try ShareCard.render(source: source, result: result, language: .english).get()
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: card.png))

    XCTAssertEqual(card.size.width, CidaDesign.ShareCard.width + CidaDesign.ShareCard.margin * 2)
    XCTAssertEqual(bitmap.pixelsWide, 1_500)
    XCTAssertEqual(CGFloat(bitmap.pixelsHigh), card.size.height * ShareCard.scale)
    XCTAssertNotNil(NSBitmapImageRep(data: card.tiff))

    XCTAssertEqual(alpha(bitmap, x: 0, y: 0), 0, "The margin is transparent")
    XCTAssertLessThan(alpha(bitmap, x: 12, y: 12), 64, "The rounded corner shows only the shadow")
    XCTAssertEqual(alpha(bitmap, x: 20, y: 20), 255)
    XCTAssertEqual(color(bitmap, x: 20, y: 60), 0xFFFFFF, "The source sits on surface")
    let bottom = Int(card.size.height - CidaDesign.ShareCard.margin - 6)
    XCTAssertEqual(color(bitmap, x: 20, y: bottom), 0xF7F6F1, "The result sits on paper")
  }

  func testTheCardIsLightWhateverTheAppearance() throws {
    var dark: ShareCard.Rendering?
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
      dark = try? ShareCard.render(source: source, result: result, language: .english).get()
    }
    let light = try ShareCard.render(source: source, result: result, language: .english).get()
    XCTAssertEqual(try XCTUnwrap(dark).png, light.png)
  }

  func testALongerSourceMakesATallerCard() throws {
    let short = try ShareCard.render(source: source, result: result, language: .english).get()
    let longer = try ShareCard.render(
      source: source + "\n" + source, result: result, language: .english
    ).get()
    XCTAssertEqual(longer.size.height - short.size.height, 26 * 2, accuracy: 1, "Two more 26 pt source lines")
  }

  func testATooLongCardIsRefused() {
    let paragraph = String(repeating: "辞达而已矣。", count: 600)
    XCTAssertEqual(
      failure(ShareCard.render(source: paragraph, result: paragraph, language: .chinese)), .tooLong,
      "Taller than 6,000 pt")
    let document = String(repeating: "a", count: ShareCard.maximumUTF16Length)
    XCTAssertEqual(
      failure(ShareCard.render(source: document, result: "b", language: .english)), .tooLong,
      "Refused before layout")
  }

  // MARK: - Copying from the panel

  func testCommandShiftCPutsOnlyTheCardOfTheGeneratingSourceOnThePasteboard() throws {
    let pasteboard = NSPasteboard(name: .init("io.xuanwo.cida.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let model = AppModel(
      inputText: source, result: ResultRecord.designCompleted(mode: .translate), pasteboard: pasteboard)
    model.inputText = "The source edited after the result"

    XCTAssertTrue(model.copyResultImage())

    let expected = try ShareCard.render(source: source, result: result, language: .english).get()
    XCTAssertEqual(
      pasteboard.data(forType: .png), expected.png, "The card pairs the result with its own source")
    XCTAssertNotNil(pasteboard.data(forType: .tiff))
    XCTAssertNil(pasteboard.string(forType: .string), "No text, or apps paste the text")
    XCTAssertEqual(model.copyFeedback, .image)
  }

  func testATooLongCardLeavesThePasteboardAndSaysSo() {
    let pasteboard = NSPasteboard(name: .init("io.xuanwo.cida.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("kept", forType: .string)
    let paragraph = String(repeating: "辞达而已矣。", count: 600)
    let record = ResultRecord(
      mode: .translate, source: paragraph, outputLanguage: .chinese, result: paragraph, phase: .completed)
    let model = AppModel(inputText: paragraph, result: record, pasteboard: pasteboard)
    let revision = model.copyFeedbackRevision

    XCTAssertTrue(model.copyResultImage())

    XCTAssertEqual(pasteboard.string(forType: .string), "kept")
    XCTAssertEqual(model.copyFeedback, .imageTooLong)
    XCTAssertEqual(model.copyFeedbackRevision, revision &+ 1)
  }

  func testNothingIsCopiedWhileTheResultIsStillWriting() {
    let pasteboard = NSPasteboard(name: .init("io.xuanwo.cida.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let record = ResultRecord(
      mode: .translate, source: source, outputLanguage: .english, result: "Our", phase: .streaming)
    let model = AppModel(inputText: source, result: record, pasteboard: pasteboard)
    let changeCount = pasteboard.changeCount

    XCTAssertFalse(model.copyResultImage())
    XCTAssertEqual(pasteboard.changeCount, changeCount)
  }

  func testTheCopyFeedbackSaysWhatWasCopiedForItsOwnTime() {
    XCTAssertEqual(BarActionPresentation.resolve(isProcessing: false, canCopyResult: true), .copy)
    XCTAssertEqual(
      BarActionPresentation.resolve(isProcessing: false, canCopyResult: true, copyFeedback: .image),
      .copied(.image))
    XCTAssertEqual(
      BarActionPresentation.resolve(isProcessing: true, canCopyResult: false, copyFeedback: .image),
      .stop)
    XCTAssertEqual(CopyFeedback.imageTooLong.holdMilliseconds, 1_500)
    XCTAssertEqual(CopyFeedback.image.holdMilliseconds, CidaMotion.copiedHoldMilliseconds)
  }

  /// The copy menu closes once either copy runs or a new request starts.
  func testCopyingOrSubmittingClosesTheCopyMenu() {
    let pasteboard = NSPasteboard(name: .init("io.xuanwo.cida.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let model = AppModel(
      inputText: source, result: ResultRecord.designCompleted(mode: .translate), pasteboard: pasteboard)

    model.isCopyMenuOpen = true
    XCTAssertTrue(model.copyResultImage())
    XCTAssertFalse(model.isCopyMenuOpen)

    model.isCopyMenuOpen = true
    XCTAssertTrue(model.copyResult())
    XCTAssertFalse(model.isCopyMenuOpen)

    model.isCopyMenuOpen = true
    XCTAssertTrue(model.submit())
    XCTAssertFalse(model.isCopyMenuOpen)
    model.cancelProcessing()
  }

  // MARK: - Pixels

  private func failure(_ rendering: Result<ShareCard.Rendering, ShareCard.Failure>) -> ShareCard.Failure? {
    if case .failure(let failure) = rendering { return failure }
    return nil
  }

  /// The stored RGBA bytes at (x, y) points from the image's top left: the
  /// image is sRGB, so these are the tokens' own values.
  private func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> [Int] {
    let scale = Int(ShareCard.scale)
    var bytes = [Int](repeating: 0, count: 4)
    bitmap.getPixel(&bytes, atX: x * scale + 1, y: y * scale + 1)
    return bytes
  }

  private func alpha(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Int {
    pixel(bitmap, x: x, y: y)[3]
  }

  private func color(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> UInt32 {
    let bytes = pixel(bitmap, x: x, y: y)
    return UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
  }
}
