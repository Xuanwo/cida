import Foundation

/// A statement, trailing commands, and optional notes in the panel. The first command is
/// the Return action; Tab moves native button focus without changing that default.
struct PanelMessage: Equatable, Sendable {
  struct Choice: Equatable, Sendable, ExpressibleByStringLiteral {
    let title: String
    var isQuiet = false

    init(_ title: String, isQuiet: Bool = false) {
      self.title = title
      self.isQuiet = isQuiet
    }

    init(stringLiteral value: String) { self.init(value) }
  }

  enum Body: Equatable, Sendable {
    case none
    case text(String)
    /// One item per line, each drawn after a quiet bullet (update notes).
    case lines([String])
  }

  enum Slot: Equatable, Sendable {
    case none
    /// 停止 ⌘.: cancels the work in progress.
    case stop
  }

  /// Names the message for accessibility identifiers and tests, e.g. `update-found`.
  var kind: String
  var statement: String
  /// Quiet text after the statement, e.g. ` · 当前 1.0.0`.
  var statementDetail: String?
  var choices: [Choice]
  var body: Body = .none
  /// A caption above the body naming what it is, e.g. 更新内容 over release notes.
  var bodyCaption: String?
  /// Work is in progress: commands are unavailable and the paper ends in the streaming caret.
  var isWorking = false
  var slot: Slot = .none
  /// One line under the body, as a failure note.
  var note: String?

  var hasBar: Bool { !choices.isEmpty || slot != .none }

  var hasPaper: Bool {
    body != .none || isWorking || note != nil || bodyCaption != nil
  }
}

/// What the owner of a message does with the user's answer.
struct PanelMessageHandler {
  /// The user performed `choices[index]`.
  var choose: @MainActor (Int) -> Void
  /// 停止 ⌘. while the message is working.
  var stop: @MainActor () -> Void = {}
  /// The panel went away without an answer; the owner treats it as 稍后.
  var dismiss: @MainActor () -> Void
}
