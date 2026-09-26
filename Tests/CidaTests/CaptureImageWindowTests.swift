import AppKit
import XCTest

@testable import Cida

@MainActor
final class CaptureImageWindowTests: XCTestCase {
  func testLegacySettingsDefaultToOverlayAndBothModesRoundTrip() throws {
    XCTAssertEqual(
      try JSONDecoder().decode(CidaSettings.self, from: Data("{}".utf8)).capturePresentation,
      .overlay)
    for presentation in CapturePresentation.allCases {
      var settings = CidaSettings()
      settings.capturePresentation = presentation
      let decoded = try JSONDecoder().decode(
        CidaSettings.self, from: JSONEncoder().encode(settings))
      XCTAssertEqual(decoded.capturePresentation, presentation)
    }
  }

  func testSettingsSaveDoesNotLoseModeOrOverwriteServiceConfiguration() {
    let namespace = "com.xuanwo.Cida.Automation.capture-mode-\(UUID().uuidString)"
    defer { UserDefaults(suiteName: namespace)?.removePersistentDomain(forName: namespace) }
    var configured = CidaSettings()
    configured.modelService.endpoint = "http://localhost:1234/chat/completions"
    configured.modelService.model = "local-test"
    SettingsStore.save(configured, namespace: namespace)
    var edited = CidaSettings()
    edited.capturePresentation = .imageWindow
    SettingsStore.saveApplicationSettings(edited, namespace: namespace)
    let saved = SettingsStore.loadWithoutAPIKey(namespace: namespace)
    XCTAssertEqual(saved.capturePresentation, .imageWindow)
    XCTAssertEqual(saved.modelService, configured.modelService)
  }

  func testCommandLineModeValidationAndReset() throws {
    var configuration = EditableConfiguration(
      settings: CidaSettings(), automaticUpdates: false, launchAtLogin: false)
    try ConfigurationField.capturePresentation.apply("image-window", to: &configuration)
    XCTAssertEqual(configuration.settings.capturePresentation, .imageWindow)
    XCTAssertThrowsError(
      try ConfigurationField.capturePresentation.apply("invalid", to: &configuration))
    XCTAssertEqual(configuration.settings.capturePresentation, .imageWindow)
    ConfigurationField.capturePresentation.reset(in: &configuration)
    XCTAssertEqual(configuration.settings.capturePresentation, .overlay)
  }

  func testExportPreservesPixelSizeAndOrientationAndCopiesTheTranslatedImage() throws {
    let original = try image()
    let size = CGSize(width: 120, height: 60)
    let drawing = CaptureTextDrawing(
      text: "译文", frame: CGRect(x: 20, y: 10, width: 80, height: 25),
      font: .systemFont(ofSize: 12), style: CaptureTextStyle(background: .white, foreground: .black)
    )
    let translated = try CaptureTranslationRenderer.renderedImage(
      original: original, drawings: [drawing], pointSize: size)
    XCTAssertEqual(translated.width, 240)
    XCTAssertEqual(translated.height, 120)
    let before = NSBitmapImageRep(cgImage: original)
    let after = NSBitmapImageRep(cgImage: translated)
    XCTAssertEqual(try XCTUnwrap(after.colorAt(x: 42, y: 22)).redComponent, 1, accuracy: 0.02)
    for (x, y) in [(5, 5), (5, 110), (230, 30), (42, 100)] {
      let lhs = try XCTUnwrap(before.colorAt(x: x, y: y)).usingColorSpace(.sRGB)!
      let rhs = try XCTUnwrap(after.colorAt(x: x, y: y)).usingColorSpace(.sRGB)!
      XCTAssertEqual(lhs.redComponent, rhs.redComponent, accuracy: 0.01)
      XCTAssertEqual(lhs.greenComponent, rhs.greenComponent, accuracy: 0.01)
      XCTAssertEqual(lhs.blueComponent, rhs.blueComponent, accuracy: 0.01)
    }
    let document = try CaptureImageDocument(
      original: original, translated: translated, pointSize: size, translationText: "译文")
    document.showsOriginal = true
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    XCTAssertTrue(document.copy(to: pasteboard))
    XCTAssertEqual(pasteboard.data(forType: .png), document.pngData)
    let decoded = try XCTUnwrap(NSBitmapImageRep(data: document.pngData))
    XCTAssertEqual(decoded.pixelsWide, 240)
    XCTAssertEqual(decoded.pixelsHigh, 120)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("translation.png")
    try document.save(to: destination)
    XCTAssertEqual(try Data(contentsOf: destination), document.pngData)
    XCTAssertThrowsError(
      try document.save(to: directory.appendingPathComponent("missing/image.png")))
  }

  func testImageWindowModeFinishesCaptureAndPassesOnlyTheCroppedImage() async throws {
    let screen = try XCTUnwrap(NSScreen.main)
    var settings = CidaSettings()
    settings.capturePresentation = .imageWindow
    var result: CaptureImageDocument?
    let session = CaptureTranslationSession(
      image: try image(), screen: screen,
      service: DelayedStreamingService(
        chunks: [#"[{"id":0,"text":"译文"}]"#], delay: .milliseconds(5)),
      settings: settings, onImageReady: { result = $0 },
      recognize: { _ in
        [RecognizedLine(text: "Source", frame: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.4))]
      })
    session.beginTranslation(
      in: CGRect(x: 0, y: 0, width: screen.frame.width / 2, height: screen.frame.height / 2))
    for _ in 0..<100 where result == nil { try await Task.sleep(for: .milliseconds(10)) }
    let document = try XCTUnwrap(result)
    XCTAssertTrue(session.isClosed)
    XCTAssertNil(session.translationView)
    let decoded = try XCTUnwrap(NSBitmapImageRep(data: document.pngData))
    XCTAssertEqual(decoded.pixelsWide, 120)
    XCTAssertEqual(decoded.pixelsHigh, 60)
    XCTAssertEqual(document.translationText, "译文")
  }

  func testWindowControllerReleasesOnCloseAndCanRenderOffscreen() throws {
    let size = CGSize(width: 848, height: 180)
    let source = NSImage(size: size, flipped: true) { rect in
      NSColor.white.setFill()
      rect.fill()
      ("A lightweight translation tool. Select a region to translate while keeping its layout." as NSString)
        .draw(in: rect.insetBy(dx: 26, dy: 26), withAttributes: [
          .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black,
        ])
      return true
    }
    let original = try XCTUnwrap(source.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let translated = try CaptureTranslationRenderer.renderedImage(
      original: original,
      drawings: [CaptureTextDrawing(
        text: "轻巧的翻译工具。框选屏幕区域，在保留布局的同时阅读译文。",
        frame: CGRect(x: 24, y: 24, width: 800, height: 132),
        font: .systemFont(ofSize: 20),
        style: CaptureTextStyle(background: .white, foreground: .black))], pointSize: size)
    let document = try CaptureImageDocument(
      original: original, translated: translated,
      pointSize: size, translationText: "轻巧的翻译工具。")
    let controller = CaptureImageWindowController(document: document)
    let window = try XCTUnwrap(controller.window)
    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(window.isKeyWindow)
    if let path = ProcessInfo.processInfo.environment["CIDA_IMAGE_WINDOW_RENDER_DIR"] {
      let root = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let view = try XCTUnwrap(window.contentView)
      view.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try data.write(to: root.appendingPathComponent("capture-image-window.png"))
    }
    var closedID: UUID?
    controller.onClose = { closedID = $0 }
    window.close()
    XCTAssertEqual(closedID, controller.id)
  }

  private func image() throws -> CGImage {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 240, height: 120,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
    context.setFillColor(CGColor(red: 0.6, green: 0.1, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 240, height: 10))
    return try XCTUnwrap(context.makeImage())
  }
}
