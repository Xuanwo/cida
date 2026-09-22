import Foundation

/// The commands a person can issue to the panel. The unit property test drives
/// `AppModel` with them and the Release XCUI journey drives the real panel.
enum TranslationJourneyCommand: Codable, Equatable, Sendable {
  case type(String)
  case paste(String)
  case deleteAll
  case toggleAction
  case submit
  case releaseChunk(String)
  case pauseStream
  case complete
  case cancel
  case fail
  case hide
  case show
}

extension TranslationJourneyCommand: CustomStringConvertible {
  var description: String {
    switch self {
    case .type(let value): "type(\(value.debugDescription))"
    case .paste(let value): "paste(\(value.debugDescription))"
    case .deleteAll: "deleteAll"
    case .toggleAction: "toggleAction"
    case .submit: "submit"
    case .releaseChunk(let value): "releaseChunk(\(value.debugDescription))"
    case .pauseStream: "pauseStream"
    case .complete: "complete"
    case .cancel: "cancel"
    case .fail: "fail"
    case .hide: "hide"
    case .show: "show"
    }
  }
}

/// The oracle for the single-result panel (Pencil `Spec — 面板模型`): one
/// source, one action, at most one result, and the rules that tie them.
struct TranslationJourneyModel: Equatable, Sendable {
  enum Action: String, Codable, Equatable, Sendable {
    case translate
    case improve
  }

  enum ResultPhase: String, Codable, Equatable, Sendable {
    case streaming
    case completed
    case stopped
    case failed
  }

  enum ComposerPresentation: String, Equatable, Sendable {
    case compact
    case multiline
    case document
  }

  struct Result: Codable, Equatable, Sendable {
    let source: String
    let action: Action
    var text: String
    var phase: ResultPhase
  }

  private(set) var sourceText = ""
  private(set) var action = Action.translate
  private(set) var result: Result?
  private(set) var isPanelVisible = true
  private(set) var showCount = 0

  var isStreaming: Bool {
    result?.phase == .streaming
  }

  /// A terminal result whose source or action no longer matches the panel.
  var isResultStale: Bool {
    guard let result, result.phase != .streaming else { return false }
    return result.source != sourceText || result.action != action
  }

  var canCopyResult: Bool {
    guard let result else { return false }
    return result.phase != .streaming && !result.text.isEmpty
  }

  var composerPresentation: ComposerPresentation {
    let count = sourceText.utf16.count
    if count >= 800 { return .document }
    if count > 120 || sourceText.contains(where: \Character.isNewline) {
      return .multiline
    }
    return .compact
  }

  @discardableResult
  mutating func apply(_ command: TranslationJourneyCommand) -> Bool {
    switch command {
    case .type(let value):
      sourceText.append(value)
    case .paste(let value):
      sourceText = value
    case .deleteAll:
      sourceText = ""
    case .toggleAction:
      guard !isStreaming else { return false }
      action = action == .translate ? .improve : .translate
    case .submit:
      guard !isStreaming, containsNonWhitespace(sourceText) else { return false }
      result = Result(source: sourceText, action: action, text: "", phase: .streaming)
    case .releaseChunk(let chunk):
      guard isStreaming, !chunk.isEmpty else { return false }
      result?.text.append(chunk)
    case .pauseStream:
      guard isStreaming else { return false }
    case .complete:
      guard isStreaming, var completed = result else { return false }
      completed.phase = completed.text.isEmpty ? .failed : .completed
      result = completed
    case .cancel:
      guard isStreaming else { return false }
      result?.phase = .stopped
    case .fail:
      guard isStreaming else { return false }
      result?.phase = .failed
    case .hide:
      guard isPanelVisible else { return false }
      isPanelVisible = false
    case .show:
      guard !isPanelVisible else { return false }
      isPanelVisible = true
      showCount += 1
      action = .translate
    }
    return true
  }

  func invariantViolations() -> [String] {
    var violations: [String] = []
    if let result {
      if result.phase == .streaming, result.source != sourceText, isResultStale {
        violations.append("a running request reported itself stale")
      }
      if result.phase == .failed, result.text.isEmpty, canCopyResult {
        violations.append("an empty failed result is copyable")
      }
    } else if canCopyResult || isResultStale {
      violations.append("no result but copy or stale state is set")
    }
    if composerPresentation == .compact,
      sourceText.utf16.count > 120 || sourceText.contains(where: \Character.isNewline)
    {
      violations.append("composer presentation is inconsistent with its document")
    }
    if !isPanelVisible, showCount < 0 {
      violations.append("hidden panel lost its show count")
    }
    return violations
  }

  static func generatedCommands(seed: UInt64, length: Int) -> [TranslationJourneyCommand] {
    var generator = SplitMix64(seed: seed)
    var model = TranslationJourneyModel()
    var commands: [TranslationJourneyCommand] = []
    commands.reserveCapacity(max(0, length))

    for step in 0..<max(0, length) {
      var candidates: [TranslationJourneyCommand] = [
        .type("t\(step) "),
        .paste(step.isMultiple(of: 5) ? "line \(step)\nsecond line" : "paste \(step)"),
        .deleteAll,
        .toggleAction,
        .submit,
        model.isPanelVisible ? .hide : .show,
      ]
      if model.isStreaming {
        candidates += [
          .releaseChunk("chunk-\(step)-\(generator.next() % 97) "),
          .pauseStream,
          .complete,
          .cancel,
          .fail,
        ]
      }

      let command = candidates[Int(generator.next() % UInt64(candidates.count))]
      commands.append(command)
      _ = model.apply(command)
    }
    return commands
  }

  static let releaseUISmokeCommands: [TranslationJourneyCommand] = [
    .paste("CIDA_E2E_POOL_STATE_MACHINE_A"),
    .submit,
    .releaseChunk("Pool response for CIDA_E2E_POOL_STATE_MACHINE_A.\n"),
    .releaseChunk("CIDA_E2E_POOL_STATE_MACHINE_A_COMPLETE"),
    .complete,
    .hide,
    .show,
    .paste("CIDA_E2E_POOL_STATE_MACHINE_B"),
    .submit,
    .releaseChunk("Pool response for CIDA_E2E_POOL_STATE_MACHINE_B.\n"),
    .releaseChunk("CIDA_E2E_POOL_STATE_MACHINE_B_COMPLETE"),
    .complete,
  ]

  private func containsNonWhitespace(_ value: String) -> Bool {
    value.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
  }
}

private struct SplitMix64 {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}
