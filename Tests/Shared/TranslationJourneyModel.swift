import Foundation

enum TranslationJourneyCommand: Codable, Equatable, Sendable {
  case type(String)
  case paste(String)
  case deleteAll
  case submit
  case releaseChunk(String)
  case pauseStream
  case complete
  case cancel
  case fail
  case scrollUp
  case scrollBottom
  case expand(Int)
  case collapse(Int)
  case resize(width: Int, height: Int)
  case closeSettings
  case relaunch
}

extension TranslationJourneyCommand: CustomStringConvertible {
  var description: String {
    switch self {
    case .type(let value): "type(\(value.debugDescription))"
    case .paste(let value): "paste(\(value.debugDescription))"
    case .deleteAll: "deleteAll"
    case .submit: "submit"
    case .releaseChunk(let value): "releaseChunk(\(value.debugDescription))"
    case .pauseStream: "pauseStream"
    case .complete: "complete"
    case .cancel: "cancel"
    case .fail: "fail"
    case .scrollUp: "scrollUp"
    case .scrollBottom: "scrollBottom"
    case .expand(let ordinal): "expand(\(ordinal))"
    case .collapse(let ordinal): "collapse(\(ordinal))"
    case .resize(let width, let height): "resize(\(width)x\(height))"
    case .closeSettings: "closeSettings"
    case .relaunch: "relaunch"
    }
  }
}

struct TranslationJourneyModel: Equatable, Sendable {
  enum EntryState: String, Codable, Equatable, Sendable {
    case streaming
    case completed
    case cancelled
    case failed
  }

  enum ComposerPresentation: String, Equatable, Sendable {
    case compact
    case multiline
    case document
  }

  struct Entry: Codable, Equatable, Sendable {
    let ordinal: Int
    let source: String
    var result: String
    var state: EntryState
    var isCurrent: Bool
  }

  private(set) var composerText = ""
  private(set) var entries: [Entry] = []
  private(set) var activeEntryOrdinal: Int?
  private(set) var isPinnedToBottom = true
  private(set) var detachedAnchorOrdinal: Int?
  private(set) var expandedEntryOrdinals: Set<Int> = []
  private(set) var windowWidth = 860
  private(set) var windowHeight = 640
  private(set) var isSettingsOpen = true
  private(set) var relaunchCount = 0
  private var durableEntries: [Entry] = []
  private var sealedEntries: [Int: Entry] = [:]

  var currentEntry: Entry? {
    entries.last
  }

  var composerPresentation: ComposerPresentation {
    let count = composerText.utf16.count
    if count >= 800 { return .document }
    if count > 120 || composerText.contains(where: \Character.isNewline) {
      return .multiline
    }
    return .compact
  }

  var durableProjection: [Entry] {
    durableEntries.map { entry in
      var recovered = entry
      if recovered.state == .streaming {
        recovered.state = .cancelled
      }
      return recovered
    }
  }

  @discardableResult
  mutating func apply(_ command: TranslationJourneyCommand) -> Bool {
    switch command {
    case .type(let value):
      composerText.append(value)
    case .paste(let value):
      composerText = value
    case .deleteAll:
      composerText = ""
    case .submit:
      guard activeEntryOrdinal == nil, containsNonWhitespace(composerText) else {
        return false
      }
      if !entries.isEmpty {
        entries[entries.count - 1].isCurrent = false
        sealedEntries[entries[entries.count - 1].ordinal] = entries[entries.count - 1]
      }
      let ordinal = (entries.last?.ordinal ?? -1) + 1
      entries.append(
        Entry(
          ordinal: ordinal,
          source: composerText,
          result: "",
          state: .streaming,
          isCurrent: true
        )
      )
      activeEntryOrdinal = ordinal
      composerText = ""
      isPinnedToBottom = true
      detachedAnchorOrdinal = nil
      synchronizeDurableProjection()
    case .releaseChunk(let chunk):
      guard let index = activeEntryIndex, !chunk.isEmpty else { return false }
      entries[index].result.append(chunk)
      synchronizeDurableProjection()
    case .pauseStream:
      guard activeEntryOrdinal != nil else { return false }
    case .complete:
      guard let index = activeEntryIndex else { return false }
      entries[index].state = entries[index].result.isEmpty ? .failed : .completed
      activeEntryOrdinal = nil
      synchronizeDurableProjection()
    case .cancel:
      guard let index = activeEntryIndex else { return false }
      entries[index].state = .cancelled
      activeEntryOrdinal = nil
      synchronizeDurableProjection()
    case .fail:
      guard let index = activeEntryIndex else { return false }
      entries[index].state = .failed
      activeEntryOrdinal = nil
      synchronizeDurableProjection()
    case .scrollUp:
      guard let currentEntry else { return false }
      isPinnedToBottom = false
      detachedAnchorOrdinal = currentEntry.ordinal
    case .scrollBottom:
      isPinnedToBottom = true
      detachedAnchorOrdinal = nil
    case .expand(let ordinal):
      guard entries.contains(where: { $0.ordinal == ordinal }), ordinal != currentEntry?.ordinal
      else { return false }
      expandedEntryOrdinals.insert(ordinal)
    case .collapse(let ordinal):
      guard ordinal != currentEntry?.ordinal else { return false }
      expandedEntryOrdinals.remove(ordinal)
    case .resize(let width, let height):
      windowWidth = max(640, width)
      windowHeight = max(520, height)
    case .closeSettings:
      isSettingsOpen = false
    case .relaunch:
      entries = durableProjection
      activeEntryOrdinal = nil
      composerText = ""
      isPinnedToBottom = true
      detachedAnchorOrdinal = nil
      isSettingsOpen = false
      relaunchCount += 1
      for index in entries.indices {
        entries[index].isCurrent = index == entries.indices.last
      }
      expandedEntryOrdinals.formIntersection(entries.dropLast().map(\.ordinal))
      rebuildSealedEntries()
      synchronizeDurableProjection()
    }
    return true
  }

  func invariantViolations() -> [String] {
    var violations: [String] = []
    let currentEntries = entries.filter(\.isCurrent)
    if entries.isEmpty {
      if !currentEntries.isEmpty { violations.append("empty history exposes a current entry") }
    } else if currentEntries.count != 1 || currentEntries.first?.ordinal != entries.last?.ordinal {
      violations.append("current entry is not the latest accepted submission")
    }
    if let activeEntryOrdinal {
      if currentEntry?.ordinal != activeEntryOrdinal || currentEntry?.state != .streaming {
        violations.append("active stream is not attached to the current entry")
      }
    } else if currentEntry?.state == .streaming {
      violations.append("streaming entry exists without an active request")
    }
    for (ordinal, sealed) in sealedEntries {
      if entries.first(where: { $0.ordinal == ordinal }) != sealed {
        violations.append("sealed entry \(ordinal) changed after a later submission")
      }
    }
    if isPinnedToBottom {
      if detachedAnchorOrdinal != nil {
        violations.append("bottom-pinned history retained a detached anchor")
      }
    } else if detachedAnchorOrdinal == nil {
      violations.append("detached history lost its reading anchor")
    }
    if expandedEntryOrdinals.contains(where: { ordinal in
      !entries.contains(where: { $0.ordinal == ordinal }) || ordinal == currentEntry?.ordinal
    }) {
      violations.append("manual expansion contains an invalid or current entry")
    }
    if composerPresentation == .compact,
      composerText.utf16.count > 120 || composerText.contains(where: \Character.isNewline)
    {
      violations.append("composer presentation is inconsistent with its document")
    }
    if durableEntries.count != entries.count {
      violations.append("durable projection lost an accepted submission")
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
        .scrollUp,
        .scrollBottom,
        .resize(
          width: 640 + Int(generator.next() % 600), height: 520 + Int(generator.next() % 360)),
        .closeSettings,
      ]
      if model.activeEntryOrdinal == nil {
        candidates.append(.submit)
        candidates.append(.relaunch)
      } else {
        candidates += [
          .submit,
          .releaseChunk("chunk-\(step)-\(generator.next() % 97) "),
          .pauseStream,
          .complete,
          .cancel,
          .fail,
        ]
      }
      if let first = model.entries.first, model.entries.count > 1 {
        candidates.append(.expand(first.ordinal))
        candidates.append(.collapse(first.ordinal))
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
    .scrollUp,
    .scrollBottom,
    .paste("CIDA_E2E_POOL_STATE_MACHINE_B"),
    .submit,
    .releaseChunk("Pool response for CIDA_E2E_POOL_STATE_MACHINE_B.\n"),
    .releaseChunk("CIDA_E2E_POOL_STATE_MACHINE_B_COMPLETE"),
    .complete,
    .relaunch,
  ]

  private var activeEntryIndex: Int? {
    guard let activeEntryOrdinal else { return nil }
    return entries.firstIndex(where: { $0.ordinal == activeEntryOrdinal })
  }

  private mutating func synchronizeDurableProjection() {
    durableEntries = entries
  }

  private mutating func rebuildSealedEntries() {
    sealedEntries = Dictionary(
      uniqueKeysWithValues: entries.dropLast().map { ($0.ordinal, $0) }
    )
  }

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
