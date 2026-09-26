import AppKit

/// Owns the frozen screen until the user exits, including recognition and the network task.
@MainActor
final class CaptureTranslationSession {
  private let image: CGImage
  private let panel: CaptureOverlayPanel
  private let service: any TextProcessingService
  private let settings: CidaSettings
  private let onImageReady: (CaptureImageDocument) -> Void
  private let recognize: @Sendable (CGImage) async throws -> [RecognizedLine]
  private var processingTask: Task<Void, Never>?
  private var completion: CheckedContinuation<Void, Never>?
  private(set) var isClosed = false
  private(set) var translationView: CaptureTranslationView?

  init(
    image: CGImage, screen: NSScreen, service: any TextProcessingService, settings: CidaSettings,
    onImageReady: @escaping (CaptureImageDocument) -> Void = { _ in },
    recognize: @escaping @Sendable (CGImage) async throws -> [RecognizedLine] = TextRecognizer
      .recognizeLines
  ) {
    self.image = image
    panel = CaptureOverlayPanel(screen: screen)
    self.service = service
    self.settings = settings
    self.onImageReady = onImageReady
    self.recognize = recognize
  }

  func run() async {
    let view = CaptureOverlayView(
      frame: NSRect(origin: .zero, size: panel.frame.size), image: image,
      veil: CaptureVeil(forScreen: image))
    panel.contentView = view
    await withCheckedContinuation { continuation in
      completion = continuation
      view.onFinish = { [weak self, weak view] selection in
        view?.onFinish = nil
        guard let self else { return }
        guard let selection else {
          close()
          return
        }
        beginTranslation(in: selection)
      }
      panel.makeKeyAndOrderFront(nil)
      panel.makeFirstResponder(view)
      view.fadeInVeil()
    }
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    processingTask?.cancel()
    processingTask = nil
    panel.orderOut(nil)
    panel.contentView = nil
    translationView = nil
    completion?.resume()
    completion = nil
  }

  func beginTranslation(in selection: CGRect) {
    guard !isClosed else { return }
    let size = panel.frame.size
    let pixelRect = CaptureGeometry.pixelRect(
      for: selection, in: size, imageSize: CGSize(width: image.width, height: image.height))
    // Use the rounded crop's geometry when drawing back onto the full screenshot.
    let displayedRect = CGRect(
      x: pixelRect.minX * size.width / CGFloat(image.width),
      y: pixelRect.minY * size.height / CGFloat(image.height),
      width: pixelRect.width * size.width / CGFloat(image.width),
      height: pixelRect.height * size.height / CGFloat(image.height))
    let view = CaptureTranslationView(
      frame: CGRect(origin: .zero, size: size), image: image, selection: displayedRect)
    view.onClose = { [weak self] in self?.close() }
    translationView = view
    panel.contentView = view
    panel.makeFirstResponder(view)
    guard let crop = image.cropping(to: pixelRect) else {
      view.showStatus("无法读取截图选区，请重新框选。")
      return
    }
    processingTask = Task { [weak self] in
      guard let self else { return }
      do {
        let lines: [RecognizedLine]
        do { lines = try await recognize(crop) } catch {
          guard !isClosed else { return }
          view.showStatus("文字识别失败，请重新框选。")
          return
        }
        try Task.checkCancellation()
        let blocks = CaptureBlockLayout.blocks(from: lines)
        guard !blocks.isEmpty else {
          view.showStatus("截图里没有识别到文字")
          return
        }
        guard service.isConfigured(by: settings) else {
          view.showStatus("请先在辞达设置中配置模型服务。")
          return
        }
        view.showStatus("正在翻译…")
        let translations = try await CaptureTranslation.translate(
          blocks: blocks, settings: settings, service: service)
        try Task.checkCancellation()
        let drawings = try CaptureTranslationRenderer.drawings(
          blocks: blocks, translations: translations, image: crop, size: displayedRect.size)
        if settings.capturePresentation == .imageWindow {
          let translated = try CaptureTranslationRenderer.renderedImage(
            original: crop, drawings: drawings, pointSize: displayedRect.size)
          let document = try CaptureImageDocument(
            original: crop, translated: translated, pointSize: displayedRect.size,
            translationText: drawings.map(\.text).joined(separator: "\n"))
          close()
          onImageReady(document)
        } else {
          view.show(drawings)
        }
      } catch is CancellationError {
        // Exiting the overlay owns cancellation and must never reopen a window.
      } catch {
        guard !isClosed else { return }
        view.showStatus("翻译失败：\(error.localizedDescription)")
      }
    }
  }
}

/// Draws into the screenshot's original coordinate space; the rest of the screen stays frozen.
@MainActor
final class CaptureTranslationView: NSView {
  private let image: NSImage
  private let selection: CGRect
  private let status = NSTextField(wrappingLabelWithString: "")
  private let statusBackground = NSView()
  private var drawings: [CaptureTextDrawing] = []
  private var showsOriginal = false
  var onClose: (() -> Void)?

  init(frame: CGRect, image: CGImage, selection: CGRect) {
    self.image = NSImage(cgImage: image, size: frame.size)
    self.selection = selection
    super.init(frame: frame)
    status.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    status.textColor = CidaDesign.Palette.textControl.appKit
    status.alignment = .center
    status.isSelectable = false
    status.setAccessibilityIdentifier("capture-translation-status")
    statusBackground.wantsLayer = true
    statusBackground.layer?.backgroundColor = CidaDesign.Palette.surface.appKit.cgColor
    statusBackground.layer?.cornerRadius = CidaDesign.Radius.card
    addSubview(statusBackground)
    statusBackground.addSubview(status)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("capture-translation-result")
    setAccessibilityLabel("截图原位翻译")
    showStatus("正在识别文字…")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  func showStatus(_ message: String) {
    status.stringValue = "\(message) · Esc 退出"
    needsLayout = true
  }

  func show(_ drawings: [CaptureTextDrawing]) {
    self.drawings = drawings
    showStatus("翻译完成 · 按住空格查看原文")
    setAccessibilityValue(drawings.map(\.text).joined(separator: "\n"))
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    let width = min(640, bounds.width - 32)
    let labelHeight = status.sizeThatFits(CGSize(width: width - 16, height: 200)).height
    let height = labelHeight + 16
    let top = CGRect(x: (bounds.width - width) / 2, y: 24, width: width, height: height)
    statusBackground.frame =
      selection.intersects(top)
      ? CGRect(x: top.minX, y: bounds.height - height - 24, width: width, height: height) : top
    status.frame = CGRect(x: 8, y: 8, width: width - 16, height: labelHeight)
  }

  override func draw(_ dirtyRect: NSRect) {
    image.draw(
      in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    if !showsOriginal {
      CaptureTranslationRenderer.draw(drawings, at: selection.origin)
    }
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
  override func rightMouseDown(with event: NSEvent) { onClose?() }
  override func cancelOperation(_ sender: Any?) { onClose?() }
  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 53: onClose?()
    case 49:
      showsOriginal = true
      needsDisplay = true
    default: break
    }
  }

  override func keyUp(with event: NSEvent) {
    if event.keyCode == 49 {
      showsOriginal = false
      needsDisplay = true
    }
  }
}
