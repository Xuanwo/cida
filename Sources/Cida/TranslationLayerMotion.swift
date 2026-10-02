import CoreGraphics
import Foundation

/// Source-window pixels only. Coordinates use the pane's top-left origin at one pixel per point.
struct LayerMotionImage: Sendable {
  let width: Int
  let height: Int
  let pixels: [UInt8]

  init?(image: CGImage) {
    width = image.width
    height = image.height
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height)
    let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
      guard let context = CGContext(
        data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else { return nil }
    // A half-point compositor translation changes glyph antialiasing. A small vertical
    // low-pass filter keeps that variation from looking like a different paragraph.
    var filtered = bytes
    if height > 2 {
      for index in width..<(width * (height - 1)) {
        filtered[index] = UInt8((Int(bytes[index - width]) + 2 * Int(bytes[index]) + Int(bytes[index + width])) / 4)
      }
    }
    pixels = filtered
  }

  init(width: Int, height: Int, pixels: [UInt8]) {
    self.width = width
    self.height = height
    self.pixels = pixels
  }
}

/// Matches a paragraph against its original pixels, never against an accumulated displacement.
/// A second plausible match (for example repeated chat messages) invalidates the position.
struct LayerImageAnchor: Sendable {
  private let x: Int
  private let originalY: Int
  private let offsets: [(x: Int, y: Int)]
  private let values: [Double]
  private let energy: Double
  private let patchHeight: Int
  private let imageWidth: Int
  private let imageHeight: Int

  init?(image: LayerMotionImage, frame: CGRect) {
    let visible = frame.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard visible.width >= 32, visible.height >= 12, visible == frame else { return nil }
    let width = min(192, Int(visible.width))
    patchHeight = min(32, Int(visible.height))
    x = Int(visible.midX) - width / 2
    originalY = Int(visible.minY)
    imageWidth = image.width
    imageHeight = image.height
    var points: [(x: Int, y: Int)] = []
    for row in 0..<min(patchHeight, 16) {
      for column in 0..<32 {
        points.append((column * (width - 1) / 31, row * (patchHeight - 1) / (min(patchHeight, 16) - 1)))
      }
    }
    offsets = points
    let originalY = originalY, x = x
    let samples = points.map { Double(image.pixels[(originalY + $0.y) * image.width + x + $0.x]) }
    let mean = samples.reduce(0, +) / Double(samples.count)
    values = samples.map { $0 - mean }
    energy = values.reduce(0) { $0 + $1 * $1 }
    guard energy / Double(samples.count) > 100 else { return nil }
  }

  /// Vertical scrolling only. Reflow, horizontal motion and ambiguous imagery fall back to AX.
  func displacement(in image: LayerMotionImage) -> CGFloat? {
    guard image.width == imageWidth, image.height == imageHeight else { return nil }
    var scores = [Double](repeating: -1, count: image.height - patchHeight + 1)
    for y in scores.indices {
      var sum = 0.0, squared = 0.0, product = 0.0
      for i in offsets.indices {
        let point = offsets[i]
        let value = Double(image.pixels[(y + point.y) * image.width + x + point.x])
        sum += value
        squared += value * value
        product += value * values[i]
      }
      let variance = squared - sum * sum / Double(offsets.count)
      if variance > 1 { scores[y] = product / sqrt(energy * variance) }
    }
    guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] >= 0.94 else { return nil }
    let alternate = scores.indices.filter { abs($0 - best) > 3 }.map { scores[$0] }.max() ?? -1
    guard scores[best] - alternate >= 0.06 else { return nil }
    return CGFloat(best - originalY)
  }
}

/// A lost paragraph is not reclaimed from pixels alone: a duplicate may have replaced it.
/// Only a new AX read can establish its identity again.
struct LayerMotionReference: Sendable {
  private let anchors: [LayerImageAnchor?]
  private(set) var offsets: [CGFloat?]
  private var time: TimeInterval

  init(image: LayerMotionImage, frames: [CGRect], time: TimeInterval) {
    anchors = frames.map { frame in
      guard let anchor = LayerImageAnchor(image: image, frame: frame),
        anchor.displacement(in: image) == 0 else { return nil }
      return anchor
    }
    offsets = anchors.map { $0 == nil ? nil : 0 }
    self.time = time
  }

  /// ScreenCaptureKit's idle status explicitly confirms that no new pixels were generated.
  mutating func confirmUnchanged(at time: TimeInterval) {
    self.time = max(self.time, time)
  }

  mutating func update(image: LayerMotionImage, time: TimeInterval, unchanged: Bool) {
    defer { self.time = time }
    guard time >= self.time, time - self.time < 0.1 else {
      offsets = offsets.map { _ in nil }
      return
    }
    guard !unchanged else { return }
    for index in anchors.indices {
      guard let previous = offsets[index] else { continue }
      guard let dy = anchors[index]?.displacement(in: image), abs(dy - previous) <= 80 else {
        offsets[index] = nil
        continue
      }
      offsets[index] = dy
    }
  }
}
