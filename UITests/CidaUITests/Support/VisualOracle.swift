import AppKit
import XCTest

enum VisualOracle {
  @MainActor
  static func assertSecondLineUsesPencilFade(
    _ element: XCUIElement,
    attachmentName: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let screenshot = element.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = attachmentName
    attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: attachmentName) { activity in
      activity.add(attachment)
    }

    guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation) else {
      XCTFail("Could not decode the text-fade screenshot", file: file, line: line)
      return
    }

    let backgroundSampleWidth = max(1, bitmap.pixelsWide / 12)
    var backgroundLuminance = 0.0
    var backgroundSamples = 0
    for y in 0..<bitmap.pixelsHigh {
      for x in (bitmap.pixelsWide - backgroundSampleWidth)..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }
        backgroundLuminance += luminance(of: color)
        backgroundSamples += 1
      }
    }
    guard backgroundSamples > 0 else {
      XCTFail("Could not sample the text-fade background", file: file, line: line)
      return
    }
    backgroundLuminance /= Double(backgroundSamples)

    let horizontalInset = max(1, bitmap.pixelsWide / 100)
    let rowContrasts = (0..<bitmap.pixelsHigh).map { y in
      totalInkContrast(
        in: bitmap,
        xRange: horizontalInset..<(bitmap.pixelsWide - horizontalInset),
        yRange: y..<(y + 1),
        backgroundLuminance: backgroundLuminance
      )
    }
    guard let fadeMetrics = repeatedLineFadeMetrics(rowContrasts: rowContrasts) else {
      XCTFail("Could not resolve two visible preview lines", file: file, line: line)
      return
    }

    XCTAssertGreaterThan(
      fadeMetrics.firstLineContrast,
      100,
      "The first preview line must remain legible and measurable",
      file: file,
      line: line
    )
    XCTAssertGreaterThan(
      fadeMetrics.secondLineContrast,
      50,
      "The second preview line must remain perceptible",
      file: file,
      line: line
    )
    XCTAssertLessThan(
      fadeMetrics.overallRatio,
      0.94,
      "The repeated second line must lose contrast across the Pencil fade",
      file: file,
      line: line
    )
    XCTAssertLessThan(
      fadeMetrics.tailRatio,
      0.90,
      "The lower half of the second line must fade more than matching first-line glyphs",
      file: file,
      line: line
    )
  }

  struct RepeatedLineFadeMetrics: Equatable {
    let firstLineContrast: Double
    let secondLineContrast: Double
    let overallRatio: Double
    let tailRatio: Double
  }

  static func repeatedLineFadeMetrics(
    rowContrasts: [Double],
    inkThreshold: Double = 5
  ) -> RepeatedLineFadeMetrics? {
    var runs: [Range<Int>] = []
    var runStart: Int?
    for (index, contrast) in rowContrasts.enumerated() {
      if contrast > inkThreshold {
        if runStart == nil { runStart = index }
      } else if let start = runStart {
        runs.append(start..<index)
        runStart = nil
      }
    }
    if let runStart {
      runs.append(runStart..<rowContrasts.count)
    }
    guard runs.count >= 2 else { return nil }

    let first = runs[0]
    let second = runs[1]
    let comparedCount = min(first.count, second.count)
    guard comparedCount >= 4 else { return nil }
    let firstRows = Array(
      rowContrasts[first.lowerBound..<(first.lowerBound + comparedCount)]
    )
    let secondRows = Array(
      rowContrasts[second.lowerBound..<(second.lowerBound + comparedCount)]
    )
    let firstLineContrast = firstRows.reduce(0, +)
    let secondLineContrast = secondRows.reduce(0, +)
    let tailStart = comparedCount / 2
    let firstTailContrast = firstRows[tailStart...].reduce(0, +)
    let secondTailContrast = secondRows[tailStart...].reduce(0, +)
    guard firstLineContrast > 0, firstTailContrast > 0 else { return nil }
    return RepeatedLineFadeMetrics(
      firstLineContrast: firstLineContrast,
      secondLineContrast: secondLineContrast,
      overallRatio: secondLineContrast / firstLineContrast,
      tailRatio: secondTailContrast / firstTailContrast
    )
  }

  @MainActor
  static func assertActionIconInkFitsPencilBounds(
    _ action: XCUIElement,
    in window: XCUIElement,
    screenshot: XCUIScreenshot,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation) else {
      XCTFail("Could not decode the record-action screenshot", file: file, line: line)
      return
    }

    let scale = CGFloat(bitmap.pixelsWide) / max(1, window.frame.width)
    let actionRect = action.frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    let searchRect = actionRect.insetBy(dx: -6, dy: -6)
    let minimumX = max(0, Int(floor(searchRect.minX * scale)))
    let maximumX = min(bitmap.pixelsWide - 1, Int(ceil(searchRect.maxX * scale)))
    let minimumY = max(0, Int(floor(searchRect.minY * scale)))
    let maximumY = min(bitmap.pixelsHigh - 1, Int(ceil(searchRect.maxY * scale)))
    var inkCount = 0
    var outsideActionCount = 0
    var inkBounds = CGRect.null

    for y in minimumY...maximumY {
      for x in minimumX...maximumX {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        let maximum = channels.max() ?? 1
        let minimum = channels.min() ?? 0
        guard
          color.alphaComponent > 0.5,
          maximum > 0.50,
          maximum < 0.84,
          maximum - minimum < 0.12
        else { continue }

        inkCount += 1
        let point = CGPoint(
          x: (CGFloat(x) + 0.5) / scale,
          y: (CGFloat(y) + 0.5) / scale
        )
        inkBounds = inkBounds.union(CGRect(origin: point, size: .zero))
        if !actionRect.insetBy(dx: -0.5, dy: -0.5).contains(point) {
          outsideActionCount += 1
        }
      }
    }

    XCTAssertGreaterThan(inkCount, 12, "The action must paint a visible Lucide icon")
    XCTAssertEqual(outsideActionCount, 0, "The icon ink escaped its 12 pt Pencil frame")
    guard !inkBounds.isNull else { return }
    XCTAssertLessThanOrEqual(inkBounds.width, 12, file: file, line: line)
    XCTAssertLessThanOrEqual(inkBounds.height, 12, file: file, line: line)
  }

  @MainActor
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
