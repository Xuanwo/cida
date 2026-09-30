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

/// What the slot says right after a copy, and for how long.
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

/// What the right-hand slot of the control bar shows. One slot, one button,
/// three phases (`Design/spec/panel.md` §二); ⇧ held alone turns 复制结果 into
/// 复制图片 (§八).
enum BarActionPresentation: Equatable, Sendable {
  case none
  case stop
  case copy
  case copyImage
  case copied(CopyFeedback)
  /// 打开设置 ⌘, while the panel welcomes a user without a model service
  /// (`Design/spec/lifecycle.md` §三).
  case openSettings

  static func resolve(
    isProcessing: Bool,
    canCopyResult: Bool,
    copyFeedback: CopyFeedback? = nil,
    offersImageCopy: Bool = false,
    showsWelcome: Bool = false
  ) -> BarActionPresentation {
    if isProcessing { return .stop }
    if let copyFeedback { return .copied(copyFeedback) }
    if canCopyResult { return offersImageCopy ? .copyImage : .copy }
    if showsWelcome { return .openSettings }
    return .none
  }
}
