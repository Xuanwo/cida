#!/usr/bin/env swift
// Regenerates the brand mark's vector files from the bundled Noto Serif SC and the geometry in
// Design/spec/brand.md: 辞 (weight 700) followed by the streaming caret.
//
//   swift scripts/generate-brand-marks.swift
//
// Writes the two layers of the app icon (Resources/AppIcon.icon/Assets) and the two layers of
// the menu bar template image (Sources/Cida/Resources/Brand). Resources/AppIcon.icon/icon.json
// (fills, dark appearance, glass) is edited by hand.

import CoreText
import Foundation

let projectURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()

let glyphCharacter = "辞"
let glyphWeight = 700.0
/// Space between the glyph and the caret, in em.
let caretGap = 0.06
/// Caret height relative to the glyph's ink height.
let caretHeightRatio = 0.86
/// How far the caret's centre sits below the glyph's centre, relative to the ink height.
let caretDrop = 0.07

struct Outline {
  let path: String
  /// Ink bounds in em units, y down.
  let bounds: CGRect
}

func loadOutline() throws -> Outline {
  let fontURL = projectURL.appendingPathComponent(
    "Sources/Cida/Resources/Fonts/NotoSerifSC[wght].ttf")
  guard
    let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL)
      as? [CTFontDescriptor])?.first
  else {
    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: fontURL.path])
  }
  let weightAxis = 0x7767_6874  // 'wght'
  let variation = [NSNumber(value: weightAxis): NSNumber(value: glyphWeight)]
  let font = CTFontCreateWithFontDescriptor(
    CTFontDescriptorCreateCopyWithAttributes(
      descriptor, [kCTFontVariationAttribute: variation] as CFDictionary),
    1, nil)
  var characters = Array(glyphCharacter.utf16)
  var glyphs = [CGGlyph](repeating: 0, count: characters.count)
  guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count),
    let path = CTFontCreatePathForGlyph(font, glyphs[0], nil)
  else {
    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: fontURL.path])
  }

  // Font space is y up in em units; SVG is y down. Keep five decimals of an em.
  func point(_ p: CGPoint) -> String { "\(format(p.x, 5)) \(format(-p.y, 5))" }
  var commands = ""
  path.applyWithBlock { element in
    let p = element.pointee.points
    switch element.pointee.type {
    case .moveToPoint: commands += "M\(point(p[0]))"
    case .addLineToPoint: commands += "L\(point(p[0]))"
    case .addQuadCurveToPoint: commands += "Q\(point(p[0])) \(point(p[1]))"
    case .addCurveToPoint: commands += "C\(point(p[0])) \(point(p[1])) \(point(p[2]))"
    case .closeSubpath: commands += "Z"
    @unknown default: break
    }
  }
  let box = path.boundingBoxOfPath
  return Outline(
    path: commands,
    bounds: CGRect(x: box.minX, y: -box.maxY, width: box.width, height: box.height))
}

func format(_ value: Double, _ digits: Int) -> String {
  String(format: "%.\(digits)f", value)
}

struct Layout {
  let glyphTransform: String
  let caret: CGRect
}

/// Places the glyph with `inkHeight` and its caret, centred as one group on the canvas.
func layout(
  _ outline: Outline, inkHeight: Double, canvas: CGSize, minimumCaretWidth: Double = 0
) -> Layout {
  let scale = inkHeight / outline.bounds.height
  let caretHeight = inkHeight * caretHeightRatio
  let caretWidth = max(caretHeight / 10, minimumCaretWidth)
  let gap = caretGap * scale
  let groupWidth = outline.bounds.width * scale + gap + caretWidth
  let originX = (canvas.width - groupWidth) / 2
  let originY = (canvas.height - inkHeight) / 2
  let caret = CGRect(
    x: originX + outline.bounds.width * scale + gap,
    y: originY + (inkHeight - caretHeight) / 2 + caretDrop * inkHeight,
    width: caretWidth,
    height: caretHeight)
  let translateX = originX - outline.bounds.minX * scale
  let translateY = originY - outline.bounds.minY * scale
  return Layout(
    glyphTransform:
      "translate(\(format(translateX, 3)) \(format(translateY, 3))) scale(\(format(scale, 4)))",
    caret: caret)
}

func svg(size: CGSize, _ body: String) -> String {
  let w = format(size.width, 0)
  let h = format(size.height, 0)
  return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">
    \(body)
    </svg>

    """
}

func rect(_ r: CGRect, fill: String) -> String {
  "<rect x=\"\(format(r.minX, 3))\" y=\"\(format(r.minY, 3))\" width=\"\(format(r.width, 3))\" "
    + "height=\"\(format(r.height, 3))\" fill=\"\(fill)\"/>"
}

func write(_ contents: String, to relativePath: String) throws {
  let url = projectURL.appendingPathComponent(relativePath)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try contents.write(to: url, atomically: true, encoding: .utf8)
  print(relativePath)
}

let outline = try loadOutline()

// App icon: 1024 canvas, the system supplies the tile shape and the paper fill (icon.json).
let iconCanvas = CGSize(width: 1024, height: 1024)
let icon = layout(outline, inkHeight: 560, canvas: iconCanvas)
try write(
  svg(
    size: iconCanvas,
    "<path transform=\"\(icon.glyphTransform)\" fill=\"#161614\" d=\"\(outline.path)\"/>"),
  to: "Resources/AppIcon.icon/Assets/glyph.svg")
try write(
  svg(size: iconCanvas, rect(icon.caret, fill: "#2E6B4F")),
  to: "Resources/AppIcon.icon/Assets/caret.svg")

// Menu bar: an 18 pt template image in one colour, which AppKit tints for the menu bar. The
// glyph and the caret are separate files so the caret can breathe on its own.
let statusCanvas = CGSize(width: 18, height: 18)
let status = layout(outline, inkHeight: 14, canvas: statusCanvas, minimumCaretWidth: 1.5)
try write(
  svg(
    size: statusCanvas,
    "<path transform=\"\(status.glyphTransform)\" fill=\"#000000\" d=\"\(outline.path)\"/>"),
  to: "Sources/Cida/Resources/Brand/status-item-glyph.svg")
try write(
  svg(size: statusCanvas, rect(status.caret, fill: "#000000")),
  to: "Sources/Cida/Resources/Brand/status-item-caret.svg")
