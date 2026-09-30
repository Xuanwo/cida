import CoreGraphics
import CoreText
import Foundation
import Vision

/// Recognizes the text in a captured part of the screen, on this Mac
/// (`Design/spec/panel.md` §一 截图翻译). Nothing is uploaded; only the text goes on
/// to the model.
enum TextRecognizer {
  /// The first recognition in a process loads the models (about 13 seconds
  /// on an M-series Mac); later ones take a fraction of a second. Warming up
  /// once after launch keeps that wait away from the first capture.
  static func warmUp() async {
    guard let image = warmUpImage() else { return }
    _ = try? await recognizeLines(in: image)
  }

  /// The recognized text as paragraphs, or nil when the image holds none.
  static func recognizeText(in image: CGImage) async throws -> String? {
    let lines = try await recognizeLines(in: image)
    return RecognizedTextLayout.text(from: lines)
  }

  private static func recognizeLines(in image: CGImage) async throws -> [RecognizedLine] {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = [
      Locale.Language(identifier: "zh-Hans"),
      Locale.Language(identifier: "en-US"),
    ]
    request.usesLanguageCorrection = true
    // With a fixed zh-Hans-first order, English lines come back with
    // full-width punctuation and misread words ("（job", "iob"); detecting
    // the language per line reads both scripts as they are.
    request.automaticallyDetectsLanguage = true
    let observations = try await request.perform(on: image)
    return observations.compactMap { observation in
      guard let text = observation.topCandidates(1).first?.string else { return nil }
      let box = observation.boundingBox.cgRect
      // Vision measures from the bottom-left; the layout reads top-down.
      return RecognizedLine(
        text: text,
        frame: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
    }
  }

  /// A line of Chinese and English, so both recognizers load.
  private static func warmUpImage() -> CGImage? {
    let width = 480
    let height = 64
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else {
      return nil
    }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateUIFontForLanguage(.system, 28, "zh-Hans" as CFString)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font as Any,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
        gray: 0, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: "辞达而已矣 Cida", attributes: attributes))
    context.textPosition = CGPoint(x: 16, y: 20)
    CTLineDraw(line, context)
    return context.makeImage()
  }
}

/// One line of recognized text, framed in the image's unit square with the
/// origin at the top-left.
struct RecognizedLine: Equatable, Sendable {
  let text: String
  let frame: CGRect
}

/// Rebuilds reading order and line breaks from recognized lines: lines that
/// share a row join with a space, and consecutive rows join as one wrapped
/// paragraph, the way the language wraps, unless the text broke the line
/// itself. A row ends a line when the gap below it is clearly wider than the
/// text's line spacing, when the next row starts a list item, or when the
/// next row's first word would still have fit on it.
enum RecognizedTextLayout {
  static func text(from lines: [RecognizedLine]) -> String? {
    let lines = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    guard !lines.isEmpty else { return nil }

    let rows = rows(of: lines)
    let typicalHeight = median(rows.map(\.frame.height))
    let rightEdge = rows.map(\.frame.maxX).max() ?? 0
    var text = rows[0].text
    for (previous, row) in zip(rows, rows.dropFirst()) {
      let gap = row.frame.minY - previous.frame.maxY
      if gap > typicalHeight * 0.8 || startsListItem(row.text)
        || hasRoom(for: row, after: previous, rightEdge: rightEdge)
      {
        text += "\n" + row.text
      } else {
        text = joinWrapped(text, row.text)
      }
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  private struct Row {
    var text: String
    var frame: CGRect
  }

  /// Lines whose vertical centres fall within half a line of each other are
  /// one row, read left to right.
  private static func rows(of lines: [RecognizedLine]) -> [Row] {
    let sorted = lines.sorted { $0.frame.midY < $1.frame.midY }
    var rows: [[RecognizedLine]] = []
    for line in sorted {
      if let last = rows.last?.last,
        abs(line.frame.midY - last.frame.midY) < min(line.frame.height, last.frame.height) / 2
      {
        rows[rows.count - 1].append(line)
      } else {
        rows.append([line])
      }
    }
    return rows.map { row in
      let ordered = row.sorted { $0.frame.minX < $1.frame.minX }
      let text = ordered.map { $0.text.trimmingCharacters(in: .whitespaces) }
        .joined(separator: " ")
      let frame = ordered.dropFirst().reduce(ordered[0].frame) { $0.union($1.frame) }
      return Row(text: text, frame: frame)
    }
  }

  /// A wrapped line only ends early when the next word does not fit, so room
  /// for that word plus some slack means the line was broken on purpose. Widths
  /// are estimated from the row's average character width.
  private static func hasRoom(for row: Row, after previous: Row, rightEdge: CGFloat) -> Bool {
    let characterWidth = previous.frame.width / CGFloat(previous.text.count)
    let room = rightEdge - previous.frame.maxX
    let firstWord: Int
    if let first = row.text.first, first.isCJK {
      firstWord = 1
    } else {
      firstWord = row.text.prefix { !$0.isWhitespace }.count
    }
    return room > characterWidth * (CGFloat(firstWord) * 1.4 + 1)
  }

  /// Bullets, dashes and numbers that open a list item, such as "• ", "- ",
  /// "2. " and "3、".
  private static func startsListItem(_ text: String) -> Bool {
    guard let first = text.first else { return false }
    if "•◦▪▫‣∙·●○■□▸►".contains(first) {
      return true
    }
    let rest = text.dropFirst()
    if "-*+".contains(first) {
      return rest.first == " "
    }
    let digits = text.prefix { $0.isASCII && $0.isNumber }
    guard (1...3).contains(digits.count) else { return false }
    let marker = text.dropFirst(digits.count)
    if marker.first == "、" {
      return true
    }
    return (marker.first == "." || marker.first == ")") && marker.dropFirst().first == " "
  }

  /// Chinese and Japanese wrap without spaces; Latin text wraps at a space,
  /// or inside a word after a hyphen.
  static func joinWrapped(_ head: String, _ tail: String) -> String {
    guard let last = head.last, let first = tail.first else { return head + tail }
    if last.isCJK || first.isCJK {
      return head + tail
    }
    if last == "-", head.dropLast().last?.isLetter == true, first.isLowercase {
      return String(head.dropLast()) + tail
    }
    return head + " " + tail
  }

  private static func median(_ values: [CGFloat]) -> CGFloat {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
  }
}

extension Character {
  /// Han ideographs, kana, and CJK punctuation or full-width forms.
  fileprivate var isCJK: Bool {
    unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
        true
      default:
        false
      }
    }
  }
}
