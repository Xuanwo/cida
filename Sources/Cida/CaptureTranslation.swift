import Foundation

/// A paragraph in crop-relative coordinates, measured from the top-left.
struct CaptureTextBlock: Equatable, Sendable {
  let id: Int
  var text: String
  var frame: CGRect
  var lineHeight: CGFloat
}

struct CaptureBlockText: Codable, Equatable, Sendable {
  let id: Int
  let text: String
}

enum CaptureTranslationError: LocalizedError {
  case invalidBlocks
  case tooMuchText
  case doesNotFit

  var errorDescription: String? {
    switch self {
    case .invalidBlocks: "翻译结果与截图文字无法对应，请重新框选。"
    case .tooMuchText: "选区文字过多，请缩小范围后重试。"
    case .doesNotFit: "译文放不进原来的文字区域，请尝试框选更完整的段落。"
    }
  }
}

/// Groups wrapped lines without joining neighbouring columns or differently sized headings.
enum CaptureBlockLayout {
  static func blocks(from lines: [RecognizedLine]) -> [CaptureTextBlock] {
    let sorted = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .sorted {
        $0.frame.minY == $1.frame.minY
          ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
      }
    var blocks: [CaptureTextBlock] = []
    for line in sorted {
      let candidate = blocks.indices.filter { index in
        let block = blocks[index]
        let gap = line.frame.minY - block.frame.maxY
        let heightRatio = line.frame.height / max(block.lineHeight, 0.0001)
        return gap >= -block.lineHeight * 0.15 && gap <= block.lineHeight * 0.8
          && (0.8...1.25).contains(heightRatio)
          && abs(line.frame.minX - block.frame.minX) < block.lineHeight * 0.8
          && line.frame.maxX <= block.frame.maxX + block.lineHeight * 2
      }.min { blocks[$0].frame.maxY > blocks[$1].frame.maxY }
      if let index = candidate {
        blocks[index].text = RecognizedTextLayout.joinWrapped(blocks[index].text, line.text)
        blocks[index].frame = blocks[index].frame.union(line.frame)
      } else {
        blocks.append(
          CaptureTextBlock(
            id: blocks.count, text: line.text, frame: line.frame, lineHeight: line.frame.height))
      }
    }
    return blocks
  }
}

enum CaptureTranslation {
  static func request(blocks: [CaptureTextBlock], settings: CidaSettings) throws
    -> ProcessingRequest
  {
    guard blocks.count <= 200 else { throw CaptureTranslationError.tooMuchText }
    let data = try JSONEncoder().encode(blocks.map { CaptureBlockText(id: $0.id, text: $0.text) })
    guard data.count <= 100_000 else { throw CaptureTranslationError.tooMuchText }
    let languages = settings.requestLanguages
    return ProcessingRequest(
      text: String(decoding: data, as: UTF8.self), mode: .translate,
      myLanguage: languages.my, foreignLanguage: languages.foreign, translatesCaptureBlocks: true)
  }

  static func decode(_ response: String, blocks: [CaptureTextBlock]) throws -> [Int: String] {
    guard let data = response.data(using: .utf8),
      let translated = try? JSONDecoder().decode([CaptureBlockText].self, from: data),
      translated.count == blocks.count,
      Set(translated.map(\.id)) == Set(blocks.map(\.id)),
      translated.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else { throw CaptureTranslationError.invalidBlocks }
    return Dictionary(uniqueKeysWithValues: translated.map { ($0.id, $0.text) })
  }

  static func translate(
    blocks: [CaptureTextBlock], settings: CidaSettings, service: any TextProcessingService
  ) async throws -> [Int: String] {
    let request = try request(blocks: blocks, settings: settings)
    var response = ""
    for try await chunk in service.stream(request, settings: settings) {
      try Task.checkCancellation()
      response += chunk
      guard response.utf8.count <= 1_000_000 else { throw CaptureTranslationError.tooMuchText }
    }
    try Task.checkCancellation()
    return try decode(response, blocks: blocks)
  }
}
