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
  static func pencilScrollThumbCenterY(
    in scrollView: XCUIElement,
    activity: XCTActivity,
    attachmentName: String
  ) -> CGFloat {
    scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.5)).hover()
    scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    let screenshot = scrollView.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = attachmentName
    attachment.lifetime = .keepAlways
    activity.add(attachment)

    guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation) else {
      XCTFail("Could not decode the history screenshot")
      return 0
    }

    let scale = CGFloat(bitmap.pixelsWide) / max(1, scrollView.frame.width)
    let trailingWidth = min(bitmap.pixelsWide, Int(ceil(12 * scale)))
    let minimumThumbRun = max(1, Int(floor(2 * scale)))
    let edgeInset = min(bitmap.pixelsHigh / 2, Int(ceil(4 * scale)))
    var maximumWidthRun = 0
    var currentHeightRun = 0
    var currentStart = 0
    var maximumHeightRun = 0
    var maximumStart = 0
    var maximumEnd = 0

    for y in edgeInset..<(bitmap.pixelsHigh - edgeInset) {
      var horizontalRun = 0
      var rowMaximum = 0
      for x in (bitmap.pixelsWide - trailingWidth)..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          horizontalRun = 0
          continue
        }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        let maximum = channels.max() ?? 1
        let minimum = channels.min() ?? 0
        if color.alphaComponent > 0.5, maximum < 0.94, maximum - minimum < 0.08 {
          horizontalRun += 1
          rowMaximum = max(rowMaximum, horizontalRun)
        } else {
          horizontalRun = 0
        }
      }

      maximumWidthRun = max(maximumWidthRun, rowMaximum)
      if rowMaximum >= minimumThumbRun {
        if currentHeightRun == 0 { currentStart = y }
        currentHeightRun += 1
        if currentHeightRun > maximumHeightRun {
          maximumHeightRun = currentHeightRun
          maximumStart = currentStart
          maximumEnd = y
        }
      } else {
        currentHeightRun = 0
      }
    }

    let width = CGFloat(maximumWidthRun) / scale
    let height = CGFloat(maximumHeightRun) / scale
    XCTAssertGreaterThanOrEqual(width, 3)
    XCTAssertLessThanOrEqual(width, 6)
    XCTAssertGreaterThanOrEqual(height, 80)
    XCTAssertLessThanOrEqual(height, 100)
    return CGFloat(maximumStart + maximumEnd + 1) / (2 * scale)
  }
}
