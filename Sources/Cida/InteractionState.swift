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

  var showsDocumentChrome: Bool {
    self == .document
  }
}

enum HistoryFollowState: String, Equatable, Sendable {
  case followingBottom
  case detached
}

enum RecordAction: Equatable, Sendable {
  case redo
  case copySource
  case copyResult
}

enum RecordActionPresentationState: Equatable, Sendable {
  case hidden
  case visible
  case copied(RecordAction)
}
