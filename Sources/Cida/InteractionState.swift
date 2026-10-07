import Foundation

enum GenerationPhase: String, Equatable, Sendable {
  case idle
  case waiting
  case revealing
}

struct GenerationPresentationState: Equatable, Sendable {
  var phase: GenerationPhase
  var entryID: UUID?

  static let idle = GenerationPresentationState(phase: .idle, entryID: nil)

  static func waiting(entryID: UUID) -> Self {
    Self(phase: .waiting, entryID: entryID)
  }

  static func revealing(entryID: UUID) -> Self {
    Self(phase: .revealing, entryID: entryID)
  }

  var isActive: Bool {
    phase != .idle
  }
}

enum ComposerPresentationState: Equatable, Sendable {
  case compact
  case multiline(visibleLineCount: Int)
  case document
}

/// Feedback shown beside the result after copying, and for how long.
enum CopyFeedback: Equatable, Sendable {
  /// ✓ 已复制 after the result's text went to the pasteboard.
  case text
  /// ✓ 已复制图片 after the share card did (`Design/spec/panel.md` §八).
  case image
  /// The share card would set taller than `ShareCard.maximumCardHeight`.
  case imageTooLong

  var holdMilliseconds: Int {
    switch self {
    case .text, .image: CidaMotion.copiedHoldMilliseconds
    case .imageTooLong: ShareCard.tooLongHoldMilliseconds
    }
  }
}

/// Execution stays in the control bar; copying belongs to the displayed result.
enum BarActionPresentation: Equatable, Sendable {
  case execute
  case reexecute
  case stop

  static func resolve(isProcessing: Bool, repeatsAction: Bool) -> BarActionPresentation {
    if isProcessing { return .stop }
    return repeatsAction ? .reexecute : .execute
  }
}
