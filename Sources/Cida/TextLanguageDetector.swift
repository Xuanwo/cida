import Foundation
import NaturalLanguage

enum TextLanguageDetector {
  private static let sampleLimit = 2_048

  static func detect(in text: String) -> Language? {
    let sample = String(text.prefix(sampleLimit))
    guard sample.contains(where: { !$0.isWhitespace }) else { return nil }

    let recognizer = NLLanguageRecognizer()
    recognizer.processString(sample)
    switch recognizer.dominantLanguage {
    case .english:
      return .english
    case .simplifiedChinese, .traditionalChinese:
      return .chinese
    default:
      break
    }

    if sample.unicodeScalars.contains(where: Self.isCJKScalar) {
      return .chinese
    }
    if sample.unicodeScalars.contains(where: CharacterSet.letters.contains) {
      return .english
    }
    return nil
  }

  private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
      return true
    default:
      return false
    }
  }
}

enum ImprovementPresentation {
  static let profileTitle = "语气与语法"
  static let followsSourceTitle = "输出跟随原文"

  static func composerHint(for text: String) -> String {
    guard let language = TextLanguageDetector.detect(in: text) else {
      return followsSourceTitle
    }
    return "\(language.title) · \(followsSourceTitle)"
  }

  static func historyDetail(for source: String) -> String {
    let language = TextLanguageDetector.detect(in: source) ?? .chinese
    return "\(language.title) · \(profileTitle)"
  }
}
