import AppKit
import XCTest

enum VisualOracle {
  static func neutralDarkPixelCount(
    in screenshot: XCUIScreenshot,
    logicalWidth: CGFloat,
    topPoints: CGFloat,
    ignoringLeadingPoints: CGFloat = 8
  ) -> Int {
    guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation) else {
      XCTFail("Could not decode the screenshot")
      return .max
    }

    let scale = CGFloat(bitmap.pixelsWide) / max(1, logicalWidth)
    let maximumY = min(bitmap.pixelsHigh, max(1, Int(ceil(topPoints * scale))))
    let minimumX = min(bitmap.pixelsWide, max(0, Int(ceil(ignoringLeadingPoints * scale))))
    var count = 0
    for y in 0..<maximumY {
      for x in minimumX..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        let maximumChannel = channels.max() ?? 1
        let minimumChannel = channels.min() ?? 0
        if color.alphaComponent > 0.5,
          maximumChannel < 0.82,
          maximumChannel - minimumChannel < 0.08
        {
          count += 1
        }
      }
    }
    return count
  }

  @MainActor
  private static func totalInkContrast(
    in bitmap: NSBitmapImageRep,
    xRange: Range<Int>,
    yRange: Range<Int>,
    backgroundLuminance: Double
  ) -> Double {
    var contrast = 0.0
    for y in yRange {
      for x in xRange {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }
        contrast += max(0, backgroundLuminance - luminance(of: color))
      }
    }
    return contrast
  }

  private static func luminance(of color: NSColor) -> Double {
    0.2126 * Double(color.redComponent)
      + 0.7152 * Double(color.greenComponent)
      + 0.0722 * Double(color.blueComponent)
  }
}
