import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Keeps only the selected region. Export always uses the translated PNG at its native resolution.
@MainActor
@Observable
final class CaptureImageDocument {
  let original: NSImage
  let translated: NSImage
  let pngData: Data
  let pointSize: CGSize
  let translationText: String
  var showsOriginal = false
  var message = ""

  init(original: CGImage, translated: CGImage, pointSize: CGSize, translationText: String) throws {
    self.original = NSImage(cgImage: original, size: pointSize)
    self.translated = NSImage(cgImage: translated, size: pointSize)
    self.pointSize = pointSize
    self.translationText = translationText
    guard
      let data = NSBitmapImageRep(cgImage: translated).representation(using: .png, properties: [:])
    else { throw CaptureImageError.encodingFailed }
    pngData = data
  }

  func copy(to pasteboard: NSPasteboard) -> Bool {
    pasteboard.clearContents()
    return pasteboard.setData(pngData, forType: .png)
  }

  func save(to url: URL) throws {
    try pngData.write(to: url, options: .atomic)
  }
}

enum CaptureImageError: LocalizedError {
  case encodingFailed
  var errorDescription: String? { "无法生成翻译图片，请重新截图。" }
}

@MainActor
final class CaptureImageWindowController: NSWindowController, NSWindowDelegate {
  let id = UUID()
  let imageDocument: CaptureImageDocument
  var onClose: ((UUID) -> Void)?

  init(document: CaptureImageDocument) {
    self.imageDocument = document
    let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1000, height: 800)
    let size = CGSize(
      width: min(max(document.pointSize.width + 48, 520), available.width * 0.85),
      height: min(max(document.pointSize.height + 100, 300), available.height * 0.85))
    let window = CaptureImageWindow(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "截图翻译"
    window.setAccessibilityIdentifier("capture-image-window")
    window.isReleasedWhenClosed = false
    window.contentMinSize = CGSize(width: 440, height: 220)
    super.init(window: window)
    window.delegate = self
    let hosting = NSHostingController(
      rootView: CaptureImageWindowView(
        document: document,
        copy: { [weak self] in self?.copyImage() },
        save: { [weak self] in self?.saveImage() }))
    window.contentViewController = hosting
    window.setContentSize(size)
    window.center()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func present() {
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) { onClose?(id) }

  private func copyImage() {
    imageDocument.message = imageDocument.copy(to: .general) ? "已复制译图" : "复制失败，请重试。"
  }

  private func saveImage() {
    guard let window else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "截图翻译.png"
    panel.canCreateDirectories = true
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .OK, let url = panel.url else { return }
      do {
        try imageDocument.save(to: url)
        imageDocument.message = "已保存译图"
      } catch {
        imageDocument.message = "保存失败：\(error.localizedDescription)"
      }
    }
  }
}

private final class CaptureImageWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

struct CaptureImageWindowView: View {
  @Bindable var document: CaptureImageDocument
  var copy: () -> Void
  var save: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Picker("图片对照", selection: $document.showsOriginal) {
          Text("原文").tag(true)
          Text("译文").tag(false)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 140)
        .accessibilityIdentifier("capture-image-comparison")
        Spacer()
        Button("复制译图", action: copy)
          .keyboardShortcut("c", modifiers: .command)
          .accessibilityIdentifier("capture-image-copy")
        Button("保存译图…", action: save)
          .keyboardShortcut("s", modifiers: .command)
          .accessibilityIdentifier("capture-image-save")
      }
      .buttonStyle(.bordered)
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      Divider()
      GeometryReader { geometry in
        Image(nsImage: document.showsOriginal ? document.original : document.translated)
          .resizable()
          .scaledToFit()
          .frame(
            width: min(document.pointSize.width, max(1, geometry.size.width - 48)),
            height: min(document.pointSize.height, max(1, geometry.size.height - 48))
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityLabel(document.showsOriginal ? "原始截图" : "翻译后的截图")
          .accessibilityValue(document.showsOriginal ? "" : document.translationText)
          .accessibilityIdentifier("capture-image-preview")
      }
      if !document.message.isEmpty {
        Text(document.message)
          .font(CidaDesign.ui(12))
          .foregroundStyle(CidaDesign.textSecondary)
          .padding(10)
          .accessibilityIdentifier("capture-image-status")
      }
    }
    .background(CidaDesign.background)
  }
}
