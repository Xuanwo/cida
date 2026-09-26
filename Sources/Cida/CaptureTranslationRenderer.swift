import AppKit

struct CaptureTextStyle {
  let background: NSColor
  let foreground: NSColor
}

struct CaptureTextDrawing {
  let text: String
  let frame: CGRect
  let font: NSFont
  let style: CaptureTextStyle
}

/// Samples the dominant paper and ink in each block. Raster screenshots do not carry font metadata.
@MainActor
enum CaptureTranslationRenderer {
  /// Creates a cropped export at the capture's exact pixel dimensions, without overlay controls.
  static func renderedImage(
    original: CGImage, drawings: [CaptureTextDrawing], pointSize: CGSize
  ) throws -> CGImage {
    guard pointSize.width > 0, pointSize.height > 0,
      let context = CGContext(
        data: nil, width: original.width, height: original.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CaptureImageError.encodingFailed }
    context.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
    context.translateBy(x: 0, y: CGFloat(original.height))
    context.scaleBy(
      x: CGFloat(original.width) / pointSize.width,
      y: -CGFloat(original.height) / pointSize.height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw(drawings, at: .zero)
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else { throw CaptureImageError.encodingFailed }
    return image
  }

  static func drawings(
    blocks: [CaptureTextBlock], translations: [Int: String], image: CGImage,
    size: CGSize
  ) throws -> [CaptureTextDrawing] {
    try blocks.map { block in
      guard let text = translations[block.id] else { throw CaptureTranslationError.invalidBlocks }
      let frame = CGRect(
        x: block.frame.minX * size.width, y: block.frame.minY * size.height,
        width: block.frame.width * size.width, height: block.frame.height * size.height
      )
      .insetBy(dx: -1, dy: -1).intersection(CGRect(origin: .zero, size: size))
      let style = sampleStyle(image: image, frame: block.frame)
      let maximum = max(8, block.lineHeight * size.height * 1.1)
      guard let font = fittedFont(text: text, size: frame.size, maximum: maximum) else {
        throw CaptureTranslationError.doesNotFit
      }
      return CaptureTextDrawing(text: text, frame: frame, font: font, style: style)
    }
  }

  static func fittedFont(text: String, size: CGSize, maximum: CGFloat) -> NSFont? {
    let minimum = min(8, maximum)
    func fits(_ pointSize: CGFloat) -> Bool {
      let measured = (text as NSString).boundingRect(
        with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: attributes(font: .systemFont(ofSize: pointSize), color: .black))
      return ceil(measured.height) <= size.height && ceil(measured.width) <= size.width
    }
    guard size.width > 0, size.height > 0, fits(minimum) else { return nil }
    var low = minimum
    var high = maximum
    for _ in 0..<12 {
      let middle = (low + high) / 2
      if fits(middle) { low = middle } else { high = middle }
    }
    return .systemFont(ofSize: low)
  }

  static func attributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
  }

  static func draw(_ drawings: [CaptureTextDrawing], at origin: CGPoint) {
    for drawing in drawings {
      let frame = drawing.frame.offsetBy(dx: origin.x, dy: origin.y)
      drawing.style.background.setFill()
      frame.fill()
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(rect: frame).addClip()
      (drawing.text as NSString).draw(
        with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: attributes(font: drawing.font, color: drawing.style.foreground))
      NSGraphicsContext.restoreGraphicsState()
    }
  }

  static func sampleStyle(image: CGImage, frame: CGRect) -> CaptureTextStyle {
    let pixels = CGRect(
      x: frame.minX * CGFloat(image.width), y: frame.minY * CGFloat(image.height),
      width: frame.width * CGFloat(image.width), height: frame.height * CGFloat(image.height)
    )
    .insetBy(dx: -2, dy: -2).integral
    let fallback = CaptureTextStyle(background: .white, foreground: .black)
    guard let crop = image.cropping(to: pixels) else { return fallback }
    let scale = min(1, 768 / CGFloat(max(crop.width, crop.height)))
    let width = max(1, Int(CGFloat(crop.width) * scale))
    let height = max(1, Int(CGFloat(crop.height) * scale))
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return fallback }
    var bins: [Int: (count: Int, r: Double, g: Double, b: Double)] = [:]
    for i in stride(from: 0, to: bytes.count, by: 4) {
      let r = Int(bytes[i])
      let g = Int(bytes[i + 1])
      let b = Int(bytes[i + 2])
      let key = (r / 24) * 121 + (g / 24) * 11 + b / 24
      let previous = bins[key] ?? (0, 0, 0, 0)
      bins[key] = (
        previous.count + 1, previous.r + Double(r), previous.g + Double(g), previous.b + Double(b)
      )
    }
    let colors = bins.values.map { bin in
      (
        count: bin.count,
        color: NSColor(
          srgbRed: bin.r / Double(bin.count) / 255, green: bin.g / Double(bin.count) / 255,
          blue: bin.b / Double(bin.count) / 255, alpha: 1)
      )
    }.sorted { $0.count > $1.count }
    guard let background = colors.first?.color else { return fallback }
    func luminance(_ color: NSColor) -> CGFloat {
      0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }
    let backgroundLuminance = luminance(background)
    // Edge antialiasing is often more common than solid ink. Keep a populated contrasting
    // bin, then prefer its contrast instead of mistaking the grey edges for the text color.
    let foreground =
      colors.filter {
        $0.count >= max(2, width * height / 1_000)
          && abs(luminance($0.color) - backgroundLuminance) > 0.3
      }.max {
        abs(luminance($0.color) - backgroundLuminance)
          < abs(luminance($1.color) - backgroundLuminance)
      }?.color
      ?? (backgroundLuminance > 0.5 ? NSColor.black : NSColor.white)
    return CaptureTextStyle(background: background, foreground: foreground)
  }
}
