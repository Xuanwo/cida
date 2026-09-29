// Renders the design boards (Design/boards/*.html) to PNG with the system's
// WebKit, off screen: the whole board to Design/rendered/boards/<board>.png
// and every [data-state] element to Design/rendered/states/<state>.png, at
// 2x. The window stays transparent behind everything and never takes focus.
//
// usage: swift scripts/render-design.swift [board.html ...]

import AppKit
import WebKit

@MainActor
final class BoardRenderer: NSObject, WKNavigationDelegate {
  private let window: NSWindow
  private let webView: WKWebView
  private var navigation: CheckedContinuation<Void, Error>?

  override init() {
    let frame = NSRect(x: 0, y: 0, width: 1400, height: 1000)
    window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    webView = WKWebView(frame: frame)
    super.init()
    webView.navigationDelegate = self
    window.contentView = webView
    window.orderBack(nil)
  }

  struct Element: Decodable {
    let name: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
  }

  struct Layout: Decodable {
    let width: Double
    let height: Double
    let board: Element
    let states: [Element]
  }

  func render(board url: URL, root: URL, output: URL) async throws -> [String] {
    try await withCheckedThrowingContinuation { continuation in
      navigation = continuation
      webView.loadFileURL(url, allowingReadAccessTo: root)
    }
    log("loaded \(url.lastPathComponent)")
    let layout = try await measure()
    log("measured \(layout.states.count) states")
    webView.setFrameSize(NSSize(width: layout.width, height: layout.height))
    window.setContentSize(NSSize(width: layout.width, height: layout.height))
    try await Task.sleep(for: .milliseconds(300))

    var written: [String] = []
    let boardsDirectory = output.appendingPathComponent("boards")
    let statesDirectory = output.appendingPathComponent("states")
    try FileManager.default.createDirectory(at: boardsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: statesDirectory, withIntermediateDirectories: true)
    let targets =
      [(layout.board, boardsDirectory)] + layout.states.map { ($0, statesDirectory) }
    for (element, directory) in targets {
      let file = directory.appendingPathComponent("\(element.name).png")
      try await snapshot(element, to: file)
      log("wrote \(element.name)")
      written.append(file.path)
    }
    return written
  }

  private func measure() async throws -> Layout {
    let script = """
      await document.fonts.ready;
      await new Promise(r => setTimeout(r, 50));
      const rect = (el, name) => {
        const r = el.getBoundingClientRect();
        return { name, x: r.left + scrollX, y: r.top + scrollY, width: r.width, height: r.height };
      };
      const board = document.querySelector("[data-board]");
      return JSON.stringify({
        width: document.documentElement.scrollWidth,
        height: document.documentElement.scrollHeight,
        board: rect(board, board.dataset.board),
        states: [...document.querySelectorAll("[data-state]")].map(el => rect(el, el.dataset.state)),
      });
      """
    let result = try await webView.callAsyncJavaScript(script, contentWorld: .page)
    guard let json = result as? String else { throw RenderError.layout }
    return try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
  }

  private func snapshot(_ element: Element, to file: URL) async throws {
    let configuration = WKSnapshotConfiguration()
    configuration.rect = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
    configuration.afterScreenUpdates = true
    let image = try await webView.takeSnapshot(configuration: configuration)
    let pixelsWide = Int((element.width * 2).rounded())
    let pixelsHigh = Int((element.height * 2).rounded())
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else {
      throw RenderError.bitmap
    }
    bitmap.size = NSSize(width: element.width, height: element.height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: element.width, height: element.height))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw RenderError.bitmap
    }
    try png.write(to: file)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    self.navigation?.resume()
    self.navigation = nil
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    self.navigation?.resume(throwing: error)
    self.navigation = nil
  }

  enum RenderError: Error {
    case layout
    case bitmap
  }
}

func log(_ message: String) {
  if ProcessInfo.processInfo.environment["RENDER_DESIGN_VERBOSE"] != nil {
    fputs("render-design: \(message)\n", stderr)
  }
}

let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent()
let boardsDirectory = projectRoot.appendingPathComponent("Design/boards")
let outputDirectory = projectRoot.appendingPathComponent("Design/rendered")
let requested = CommandLine.arguments.dropFirst()
let boards: [URL] =
  requested.isEmpty
  ? try FileManager.default.contentsOfDirectory(at: boardsDirectory, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "html" }.sorted { $0.path < $1.path }
  : requested.map { boardsDirectory.appendingPathComponent($0) }

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
Task { @MainActor in
  do {
    let renderer = BoardRenderer()
    for board in boards {
      for path in try await renderer.render(board: board, root: projectRoot, output: outputDirectory) {
        print(path)
      }
    }
    exit(0)
  } catch {
    fputs("render-design: \(error)\n", stderr)
    exit(1)
  }
}
application.run()
