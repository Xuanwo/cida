import AppKit
import CryptoKit
import Foundation
import XCTest

struct VisualBaselineManifest: Decodable {
  let namespace: String
  let baselines: [VisualBaseline]

  static func load(from sourceRoot: String) throws -> VisualBaselineManifest {
    let url = URL(fileURLWithPath: sourceRoot)
      .appendingPathComponent("UITests/Resources/VisualBaselines/manifest.json")
    return try JSONDecoder().decode(
      VisualBaselineManifest.self,
      from: Data(contentsOf: url)
    )
  }

  func baseline(named name: String) throws -> VisualBaseline {
    guard let baseline = baselines.first(where: { $0.name == name }) else {
      throw VisualBaselineError.missingBaseline(name)
    }
    return baseline
  }
}

struct VisualBaseline: Decodable {
  let name: String
  let approvedImage: String
  let approvedImageSHA256: String
  let designReference: String
  let designReferenceSHA256: String
  let designDocument: String
  let designDocumentSHA256: String
  let logicalWidth: Int
  let logicalHeight: Int
  let blockSize: Int
  let channelTolerance: Double
  let maximumChangedBlockRatio: Double
  let maximumMeanChannelDelta: Double
  let masks: [VisualMask]
}

struct VisualMask: Decodable {
  let x: Int
  let y: Int
  let width: Int
  let height: Int

  var rect: CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }
}

enum VisualBaselineError: Error, CustomStringConvertible {
  case missingBaseline(String)
  case invalidImage(String)
  case digestMismatch(path: String, expected: String, actual: String)

  var description: String {
    switch self {
    case .missingBaseline(let name):
      "Visual baseline is not declared: \(name)"
    case .invalidImage(let path):
      "Visual baseline image could not be decoded: \(path)"
    case .digestMismatch(let path, let expected, let actual):
      "Visual baseline digest mismatch for \(path): expected \(expected), got \(actual)"
    }
  }
}

enum PixelDiff {
  @MainActor
  static func assertScreenshot(
    _ screenshot: XCUIScreenshot,
    matches baseline: VisualBaseline,
    sourceRoot: String,
    activity: XCTActivity,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let sourceURL = URL(fileURLWithPath: sourceRoot)
    let approvedURL = sourceURL.appendingPathComponent(baseline.approvedImage)
    let designURL = sourceURL.appendingPathComponent(baseline.designReference)
    let designDocumentURL = sourceURL.appendingPathComponent(baseline.designDocument)
    let approvedData = try verifiedData(
      at: approvedURL,
      expectedSHA256: baseline.approvedImageSHA256
    )
    let designData = try verifiedData(
      at: designURL,
      expectedSHA256: baseline.designReferenceSHA256
    )
    _ = try verifiedData(
      at: designDocumentURL,
      expectedSHA256: baseline.designDocumentSHA256
    )

    let size = CGSize(width: baseline.logicalWidth, height: baseline.logicalHeight)
    guard
      let approved = normalizedBitmap(from: approvedData, size: size),
      let current = normalizedBitmap(from: screenshot.pngRepresentation, size: size)
    else {
      throw VisualBaselineError.invalidImage(baseline.approvedImage)
    }

    let result = compare(
      current: current,
      approved: approved,
      blockSize: baseline.blockSize,
      channelTolerance: baseline.channelTolerance,
      masks: baseline.masks.map(\.rect)
    )

    attach(
      approvedData,
      name: "\(baseline.name) reference approved",
      to: activity
    )
    attach(
      designData,
      name: "\(baseline.name) Pencil reference",
      to: activity
    )
    let currentAttachment = XCTAttachment(screenshot: screenshot)
    currentAttachment.name = "\(baseline.name) current"
    currentAttachment.lifetime = .keepAlways
    activity.add(currentAttachment)
    attach(
      result.diffPNG,
      name: "\(baseline.name) diff changed blocks",
      to: activity
    )

    XCTAssertLessThanOrEqual(
      result.changedBlockRatio,
      baseline.maximumChangedBlockRatio,
      "Visual baseline \(baseline.name) changed \(percentage(result.changedBlockRatio)) "
        + "of unmasked blocks in namespace \(baseline.name)",
      file: file,
      line: line
    )
    XCTAssertLessThanOrEqual(
      result.meanChannelDelta,
      baseline.maximumMeanChannelDelta,
      "Visual baseline \(baseline.name) mean channel delta was "
        + String(format: "%.4f", result.meanChannelDelta),
      file: file,
      line: line
    )
  }

  private static func verifiedData(
    at url: URL,
    expectedSHA256: String
  ) throws -> Data {
    let data = try Data(contentsOf: url)
    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard actual == expectedSHA256 else {
      throw VisualBaselineError.digestMismatch(
        path: url.path,
        expected: expectedSHA256,
        actual: actual
      )
    }
    return data
  }

  private static func normalizedBitmap(
    from data: Data,
    size: CGSize
  ) -> NSBitmapImageRep? {
    guard let image = NSImage(data: data) else { return nil }
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
    image.draw(
      in: CGRect(origin: .zero, size: size),
      from: CGRect(origin: .zero, size: image.size),
      operation: .copy,
      fraction: 1,
      respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high]
    )
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
  }

  private static func compare(
    current: NSBitmapImageRep,
    approved: NSBitmapImageRep,
    blockSize: Int,
    channelTolerance: Double,
    masks: [CGRect]
  ) -> PixelDiffResult {
    let width = min(current.pixelsWide, approved.pixelsWide)
    let height = min(current.pixelsHigh, approved.pixelsHigh)
    let safeBlockSize = max(1, blockSize)
    var comparedBlocks = 0
    var changedBlocks = 0
    var totalMeanDelta = 0.0
    var changedRects: [CGRect] = []

    for y in stride(from: 0, to: height, by: safeBlockSize) {
      for x in stride(from: 0, to: width, by: safeBlockSize) {
        let blockWidth = min(safeBlockSize, width - x)
        let blockHeight = min(safeBlockSize, height - y)
        let rect = CGRect(x: x, y: y, width: blockWidth, height: blockHeight)
        if masks.contains(where: { $0.intersects(rect) }) { continue }
        guard
          let currentAverage = averageColor(in: rect, bitmap: current),
          let approvedAverage = averageColor(in: rect, bitmap: approved)
        else { continue }

        let deltas = zip(currentAverage, approvedAverage).map { abs($0.0 - $0.1) }
        let meanDelta = deltas.reduce(0, +) / Double(deltas.count)
        totalMeanDelta += meanDelta
        comparedBlocks += 1
        if deltas.max() ?? 0 > channelTolerance {
          changedBlocks += 1
          changedRects.append(rect)
        }
      }
    }

    let denominator = Double(max(1, comparedBlocks))
    return PixelDiffResult(
      changedBlockRatio: Double(changedBlocks) / denominator,
      meanChannelDelta: totalMeanDelta / denominator,
      diffPNG: makeDiffPNG(size: CGSize(width: width, height: height), changedRects: changedRects)
    )
  }

  private static func averageColor(
    in rect: CGRect,
    bitmap: NSBitmapImageRep
  ) -> [Double]? {
    var red = 0.0
    var green = 0.0
    var blue = 0.0
    var count = 0.0
    for y in Int(rect.minY)..<Int(rect.maxY) {
      for x in Int(rect.minX)..<Int(rect.maxX) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }
        red += color.redComponent
        green += color.greenComponent
        blue += color.blueComponent
        count += 1
      }
    }
    guard count > 0 else { return nil }
    return [red / count, green / count, blue / count]
  }

  private static func makeDiffPNG(size: CGSize, changedRects: [CGRect]) -> Data {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return Data() }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
    NSColor.systemRed.withAlphaComponent(0.8).setFill()
    for rect in changedRects {
      NSBezierPath(rect: rect).fill()
    }
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:]) ?? Data()
  }

  private static func attach(_ data: Data, name: String, to activity: XCTActivity) {
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    activity.add(attachment)
  }

  private static func percentage(_ value: Double) -> String {
    String(format: "%.2f%%", value * 100)
  }
}

private struct PixelDiffResult {
  let changedBlockRatio: Double
  let meanChannelDelta: Double
  let diffPNG: Data
}
