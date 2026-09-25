#!/usr/bin/env swift
// Places the native captures from scripts/capture-design-states.sh on a paper backdrop with the
// panel's shadow, for the README:
//
//   scripts/capture-design-states.sh             # refresh Design/ImplementationCurrent first
//   swift scripts/render-readme-images.swift
//
// Writes docs/images/<name>.png at the captures' 2x scale.

import AppKit

let projectURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()

/// Capture in Design/ImplementationCurrent → image in docs/images.
let images = [
  ("translate", "translate"),
  ("improve", "improve"),
  ("settings", "settings"),
]

/// The board background (Design/boards/components.css `body`), a shade darker than the panel.
let backdrop = NSColor(srgbRed: 0xE9 / 255, green: 0xE9 / 255, blue: 0xE4 / 255, alpha: 1)
/// Room around the capture, in pixels at 2x; the bottom leaves space for the long shadow.
let margin = (top: 96.0, side: 112.0, bottom: 144.0)

/// `--panel-shadow` from Design/boards/tokens.css at 2x: 0 2px 6px #00000014, 0 28px 72px #1A1A1830.
let shadows: [(offset: CGFloat, blur: CGFloat, color: NSColor)] = [
  (4, 12, NSColor(white: 0, alpha: 0x14 / 255)),
  (56, 144, NSColor(srgbRed: 0x1A / 255, green: 0x1A / 255, blue: 0x18 / 255, alpha: 0x30 / 255)),
]

func render(capture: URL, to output: URL) throws {
  guard let source = NSBitmapImageRep(data: try Data(contentsOf: capture)),
    let panel = source.cgImage
  else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: capture.path]) }
  let width = Int(Double(panel.width) + 2 * margin.side)
  let height = Int(Double(panel.height) + margin.top + margin.bottom)
  guard
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { throw CocoaError(.featureUnsupported) }

  context.setFillColor(backdrop.cgColor)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  // Core Graphics is y-up: the panel sits `margin.bottom` above the bottom edge.
  let frame = CGRect(
    x: margin.side, y: margin.bottom, width: Double(panel.width), height: Double(panel.height))
  for shadow in shadows {
    context.saveGState()
    context.setShadow(
      offset: CGSize(width: 0, height: -shadow.offset), blur: shadow.blur,
      color: shadow.color.cgColor)
    context.draw(panel, in: frame)
    context.restoreGState()
  }
  context.draw(panel, in: frame)

  guard let image = context.makeImage(),
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  else { throw CocoaError(.fileWriteUnknown) }
  try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
  try png.write(to: output)
  print(output.path.replacingOccurrences(of: projectURL.path + "/", with: ""))
}

for (capture, name) in images {
  try render(
    capture: projectURL.appendingPathComponent("Design/ImplementationCurrent/\(capture).png"),
    to: projectURL.appendingPathComponent("docs/images/\(name).png"))
}
