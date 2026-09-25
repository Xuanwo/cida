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

/// What the right-hand slot of the control bar shows. One slot, one button,
/// three phases (`Design/spec/panel.md` §二).
enum BarActionPresentation: Equatable, Sendable {
  case none
  case stop
  case copy
  case copied
  /// 打开设置 ⌘, while the panel welcomes a user without a model service
  /// (`Design/spec/lifecycle.md` §三).
  case openSettings

  static func resolve(
    isProcessing: Bool,
    canCopyResult: Bool,
    showsCopiedFeedback: Bool,
    showsWelcome: Bool = false
  ) -> BarActionPresentation {
    if isProcessing { return .stop }
    if showsCopiedFeedback { return .copied }
    if canCopyResult { return .copy }
    if showsWelcome { return .openSettings }
    return .none
  }
}
