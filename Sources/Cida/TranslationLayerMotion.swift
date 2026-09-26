import AppKit
import CoreMedia
import ScreenCaptureKit

/// How far content moved between two frames of the same pane (`Design/spec/translation-layer.md`
/// §五). Scrolled content moves whole rows of pixels unchanged, so each vertical tile votes
/// for the shift that maps its non-blank rows onto identical ones; static tiles (a sidebar, an
/// overlay scroller, a sticky header) vote for no shift. Measured on 2026-09-26: exact on six
/// scroll gestures, 3–6 ms a frame, and it declines only when a frame moves more than a screen.
enum LayerMotionEstimator {
  struct Rows: Sendable {
    var hashes: [[UInt64]]
    var informative: [[Bool]]
  }

  static let tiles = 8

  static func rows(of buffer: CVPixelBuffer, crop: CGRect) -> Rows {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
      return Rows(hashes: [], informative: [])
    }
    return rows(
      base: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), crop: crop)
  }

  /// Row hashes per tile of a 32-bit pixel buffer.
  static func rows(
    base: UnsafePointer<UInt8>, bytesPerRow: Int, width: Int, height: Int, crop: CGRect
  ) -> Rows {
    let x0 = max(0, Int(crop.minX)), x1 = min(width, Int(crop.maxX))
    let y0 = max(0, Int(crop.minY)), y1 = min(height, Int(crop.maxY))
    guard x1 - x0 >= tiles, y1 > y0 else { return Rows(hashes: [], informative: []) }
    var hashes = [[UInt64]](repeating: [], count: tiles)
    var informative = [[Bool]](repeating: [], count: tiles)
    for tile in 0..<tiles {
      let tx0 = x0 + tile * (x1 - x0) / tiles
      let tx1 = x0 + (tile + 1) * (x1 - x0) / tiles
      hashes[tile].reserveCapacity(y1 - y0)
      informative[tile].reserveCapacity(y1 - y0)
      for y in y0..<y1 {
        let row = UnsafeRawPointer(base + y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let first = row[tx0]
        var uniform = true
        for x in tx0..<tx1 {
          let value = row[x]
          if value != first { uniform = false }
          hash = (hash ^ UInt64(value)) &* 0x100_0000_01b3
        }
        hashes[tile].append(hash)
        informative[tile].append(!uniform)
      }
    }
    return Rows(hashes: hashes, informative: informative)
  }

  /// The shift in pixels (positive: content moved up), 0 for no motion, nil when the frames
  /// do not agree on one (the content was replaced, or moved too far to match).
  static func shift(from a: Rows, to b: Rows, minimumOverlap: Int = 80) -> Int? {
    guard a.hashes.count == b.hashes.count, !a.hashes.isEmpty else { return nil }
    var shifts: [Int: Int] = [:]
    // Tiles with text that match no shift at all: the content there was replaced.
    var changed = 0
    for tile in 0..<a.hashes.count {
      let ha = a.hashes[tile], hb = b.hashes[tile], ia = a.informative[tile], ib = b.informative[tile]
      let height = min(ha.count, hb.count)
      var positions: [UInt64: [Int]] = [:]
      for y in 0..<height where ia[y] { positions[ha[y], default: []].append(y) }
      var votes: [Int: Int] = [0: 0]
      var rows = 0
      for y in 0..<height where ib[y] {
        rows += 1
        // Rows that repeat many times (blank lines of a table) say nothing about motion.
        guard let ys = positions[hb[y]], ys.count <= 8 else { continue }
        for ya in ys { votes[ya - y, default: 0] += 1 }
      }
      guard rows >= 20 else { continue }
      var best: (shift: Int, ratio: Double)?
      for candidate in votes.sorted(by: { $0.value > $1.value }).prefix(5).map(\.key) {
        guard height - abs(candidate) >= minimumOverlap else { continue }
        var informativeRows = 0, matched = 0, staticRows = 0
        for y in max(0, -candidate)..<min(height, height - candidate) where ib[y] {
          informativeRows += 1
          if hb[y] == ha[y + candidate] { matched += 1 } else if hb[y] == ha[y] { staticRows += 1 }
        }
        guard candidate == 0 || Double(matched) >= Double(informativeRows) * 0.3 else { continue }
        let ratio = informativeRows == 0 ? 0 : Double(matched + staticRows) / Double(informativeRows)
        if best == nil || ratio > best!.ratio + 1e-9
          || (abs(ratio - best!.ratio) < 1e-9 && abs(candidate) < abs(best!.shift))
        {
          best = (candidate, ratio)
        }
      }
      guard let best, best.ratio >= 0.9 else {
        changed += 1
        continue
      }
      shifts[best.shift, default: 0] += 1
    }
    let moving = shifts.filter { $0.key != 0 }
    guard let winner = moving.max(by: { $0.value < $1.value }) else {
      // A caret or a hover highlight changes one tile; a new channel changes most of them.
      if changed >= 2 { return nil }
      return shifts[0] != nil ? 0 : nil
    }
    let movingTiles = moving.values.reduce(0, +)
    guard winner.value >= 2, Double(winner.value) >= Double(movingTiles) * 0.75 else { return nil }
    return winner.key
  }
}

/// Captures one application window while its pane shows translations, and reports how far
/// the pane's content has moved since the last read of the tree. Runs only with the Screen
/// Recording permission; macOS shows its recording indicator meanwhile.
final class LayerMotionStream: NSObject, SCStreamOutput, @unchecked Sendable {
  private let lock = NSLock()
  private var stream: SCStream?
  private var crop: CGRect = .zero
  private var scale: CGFloat = 2
  private var previous: LayerMotionEstimator.Rows?
  private var cumulativePixels = 0
  private let queue = DispatchQueue(label: "cida.layer.motion", qos: .userInteractive)
  /// Points the content moved (positive: down the screen), or nil when it could not be followed.
  var onMotion: (@MainActor (CGFloat?) -> Void)?

  /// Starts capturing `windowNumber`; `pane` is the pane's frame inside the window, in points.
  func start(windowNumber: CGWindowID, pane: CGRect) async {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
      let window = content.windows.first(where: { $0.windowID == windowNumber })
    else {
      return
    }
    let displayScale =
      NSScreen.screens.first {
        $0.frame.intersects(LayerScreenGeometry.appKitRect(fromTopLeft: window.frame))
      }?.backingScaleFactor ?? 2
    let configuration = SCStreamConfiguration()
    configuration.width = Int(window.frame.width * displayScale)
    configuration.height = Int(window.frame.height * displayScale)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = false
    configuration.queueDepth = 5
    let stream = SCStream(
      filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration,
      delegate: nil)
    lock.withLock {
      scale = displayScale
      crop = CGRect(
        x: pane.minX * displayScale, y: pane.minY * displayScale, width: pane.width * displayScale,
        height: pane.height * displayScale)
      self.stream = stream
    }
    do {
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
      try await stream.startCapture()
    } catch {
      lock.withLock { self.stream = nil }
    }
  }

  func stop() {
    let stream = lock.withLock { () -> SCStream? in
      defer { self.stream = nil }
      return self.stream
    }
    stream?.stopCapture { _ in }
  }

  /// The paragraphs were just read where the content is now: motion counts from here.
  func resetBaseline(pane: CGRect) {
    lock.withLock {
      cumulativePixels = 0
      crop = CGRect(
        x: pane.minX * scale, y: pane.minY * scale, width: pane.width * scale, height: pane.height * scale)
      previous = nil
    }
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
      let buffer = sample.imageBuffer
    else {
      return
    }
    let (crop, scale) = lock.withLock { (self.crop, self.scale) }
    let rows = LayerMotionEstimator.rows(of: buffer, crop: crop)
    let report: CGFloat?? = lock.withLock {
      defer { previous = rows }
      guard let previous else { return .none }
      guard let shift = LayerMotionEstimator.shift(from: previous, to: rows) else { return .some(nil) }
      guard shift != 0 else { return .none }
      cumulativePixels += shift
      return .some(-CGFloat(cumulativePixels) / scale)
    }
    guard let report, let onMotion else { return }
    Task { @MainActor in onMotion(report) }
  }
}
