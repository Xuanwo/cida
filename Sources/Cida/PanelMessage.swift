import Foundation

/// What Cida says to the user in the panel itself (`Design/spec/lifecycle.md` §一): a statement
/// in the source pane, the choices in the control bar's segmented control, and the reason or the
/// notes on the paper pane. The panel's own keys drive it: Tab moves the choice, Return performs
/// it, Escape and every other way of hiding the panel answer 稍后 (`dismiss`).
struct PanelMessage: Equatable, Sendable {
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
  var choices: [String]
  var selectedChoice = 0
  var body: Body = .none
  /// Work is in progress: the choices dim and the paper ends in the streaming caret.
  var isWorking = false
  var slot: Slot = .none
  /// One line under the body, as a failure note.
  var note: String?

  var hasPaper: Bool {
    body != .none || isWorking || note != nil
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
