import Foundation
import XCTest

@testable import Cida

@MainActor
final class TranslationJourneyPropertyTests: XCTestCase {
  private static let seeds: [UInt64] = [
    0x0000_0000_0000_0001,
    0x0000_0000_6A84_9F2B,
    0x0000_0000_DEAD_BEEF,
    0x0123_4567_89AB_CDEF,
    0x0F0F_F0F0_AA55_55AA,
    0x1357_9BDF_2468_ACE0,
    0x3141_5926_5358_9793,
    0x5555_AAAA_5555_AAAA,
    0x8000_0000_0000_0001,
    0xA5A5_5A5A_C3C3_3C3C,
    0xCAFE_BABE_F00D_FACE,
    0xFFFF_FFFF_FFFF_FFFE,
  ]

  func testDeterministicCommandSequencesPreserveProductAndDurabilityInvariants() async throws {
    for seed in Self.seeds {
      let commands = TranslationJourneyModel.generatedCommands(seed: seed, length: 72)
      do {
        try await execute(commands, seed: seed)
      } catch {
        let prefix = try await shortestFailingPrefix(in: commands, seed: seed)
        XCTFail(
          failureMessage(
            seed: seed, commands: commands, shortestFailingPrefix: prefix, error: error)
        )
        return
      }
    }
  }

  func testSharedJourneyModelCoversEveryCommandAndMaintainsItsOwnInvariants() {
    var model = TranslationJourneyModel()
    let commands: [TranslationJourneyCommand] = [
      .type("draft"), .deleteAll, .paste("first\nrequest"), .submit,
      .releaseChunk("partial"), .pauseStream, .scrollUp, .releaseChunk(" result"),
      .scrollBottom, .complete, .expand(0), .collapse(0),
      .resize(width: 1_120, height: 780), .closeSettings, .relaunch,
      .paste("cancelled"), .submit, .cancel,
      .paste("failed"), .submit, .fail,
    ]

    for command in commands {
      _ = model.apply(command)
      XCTAssertTrue(
        model.invariantViolations().isEmpty,
        "command=\(command) violations=\(model.invariantViolations())"
      )
    }
  }

  private func execute(_ commands: [TranslationJourneyCommand], seed: UInt64) async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appending(path: "cida-property-\(seed)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    do {
      try await execute(commands, seed: seed, temporaryRoot: temporaryRoot)
      try FileManager.default.removeItem(at: temporaryRoot)
    } catch {
      try? FileManager.default.removeItem(at: temporaryRoot)
      throw error
    }
  }

  private func execute(
    _ commands: [TranslationJourneyCommand],
    seed: UInt64,
    temporaryRoot: URL
  ) async throws {
    let store = try HistoryStore(
      databaseURL: temporaryRoot.appending(path: "History.sqlite3"),
      deltaFlushDelay: .milliseconds(1)
    )
    let service = CommandStreamingService()
    var oracle = TranslationJourneyModel()
    var model = makeModel(entries: [], service: service, store: store)

    for (index, command) in commands.enumerated() {
      let oracleAccepted = oracle.apply(command)
      switch command {
      case .type(let value):
        model.inputText.append(value)
      case .paste(let value):
        model.stageInputDocument(nil)
        model.inputText = value
      case .deleteAll:
        model.stageInputDocument(nil)
        model.inputText = ""
      case .submit:
        let count = model.entries.count
        let accepted = model.submit()
        guard accepted == oracleAccepted else {
          throw PropertyFailure(
            "submit acceptance differs: product=\(accepted) oracle=\(oracleAccepted)")
        }
        if accepted {
          let submittedModel = model
          try await waitUntil {
            submittedModel.entries.count == count + 1 && service.hasActiveStream
          }
        }
      case .releaseChunk(let chunk):
        if oracleAccepted {
          try service.yield(chunk)
          let streamingModel = model
          let expectedResult = oracle.currentEntry?.result
          try await waitUntil { streamingModel.entries.last?.result == expectedResult }
        }
      case .pauseStream:
        if oracleAccepted {
          let value = model.entries.last?.result
          let revision = model.entries.last?.presentationRevision
          try await Task.sleep(for: .milliseconds(12))
          guard model.entries.last?.result == value,
            model.entries.last?.presentationRevision == revision
          else { throw PropertyFailure("backend pause changed the visible result") }
        }
      case .complete:
        if oracleAccepted {
          try service.finish()
          let completingModel = model
          try await waitUntil { !completingModel.isProcessing }
        }
      case .cancel:
        if oracleAccepted {
          model.cancelProcessing()
          let cancellingModel = model
          try await waitUntil { !cancellingModel.isProcessing }
        }
      case .fail:
        if oracleAccepted {
          try service.fail()
          let failingModel = model
          try await waitUntil { !failingModel.isProcessing }
        }
      case .scrollUp, .scrollBottom, .resize, .closeSettings:
        break
      case .expand(let ordinal):
        if let entry = model.entries.first(where: { actualOrdinal($0, in: model) == ordinal }) {
          model.expandHistoryEntry(entry.id)
        }
      case .collapse(let ordinal):
        if let entry = model.entries.first(where: { actualOrdinal($0, in: model) == ordinal }) {
          model.collapseHistoryEntry(entry.id)
        }
      case .relaunch:
        guard oracleAccepted else { break }
        model.flushHistoryPersistence()
        let loadedEntries = try store.load()
        model = makeModel(entries: loadedEntries, service: service, store: store)
      }

      try assertProduct(model, matches: oracle, commandIndex: index, command: command)
    }
    if model.isProcessing {
      model.cancelProcessing()
      let cancellingModel = model
      try await waitUntil { !cancellingModel.isProcessing }
    }
    model.flushHistoryPersistence()
  }

  private func makeModel(
    entries: [HistoryEntry],
    service: CommandStreamingService,
    store: HistoryStore
  ) -> AppModel {
    AppModel(
      entries: entries,
      service: service,
      streamPresentationPolicy: .fastTests,
      historyPersistence: store,
      saveSettings: { _ in },
      clearPersistedAPIKey: {}
    )
  }

  private func assertProduct(
    _ model: AppModel,
    matches oracle: TranslationJourneyModel,
    commandIndex: Int,
    command: TranslationJourneyCommand
  ) throws {
    let context = "index=\(commandIndex) command=\(command)"
    let violations = oracle.invariantViolations()
    guard violations.isEmpty else {
      throw PropertyFailure("oracle violations \(violations); \(context)")
    }
    guard model.inputText == oracle.composerText else {
      throw PropertyFailure("composer differs; \(context)")
    }
    guard model.inputDocumentUTF16Count == oracle.composerText.utf16.count else {
      throw PropertyFailure("composer document length differs; \(context)")
    }
    guard model.entries.count == oracle.entries.count else {
      throw PropertyFailure(
        "entry count differs: product=\(model.entries.count) oracle=\(oracle.entries.count); \(context)"
      )
    }
    for (actual, expected) in zip(model.entries, oracle.entries) {
      guard actual.source == expected.source else {
        throw PropertyFailure("source changed for entry \(expected.ordinal); \(context)")
      }
      guard actual.result == expected.result else {
        throw PropertyFailure(
          "result is not the released stream prefix for entry \(expected.ordinal); \(context)"
        )
      }
      guard actual.state.rawValue == expected.state.rawValue else {
        throw PropertyFailure("state differs for entry \(expected.ordinal); \(context)")
      }
      guard actual.isLatestInHistory == expected.isCurrent else {
        throw PropertyFailure("current entry differs for entry \(expected.ordinal); \(context)")
      }
      guard
        model.isHistoryEntryExpanded(actual) == expected.isCurrent
          || model.isHistoryEntryManuallyExpanded(actual.id)
      else {
        throw PropertyFailure("current entry is not expanded; \(context)")
      }
    }
  }

  private func shortestFailingPrefix(
    in commands: [TranslationJourneyCommand],
    seed: UInt64
  ) async throws -> [TranslationJourneyCommand] {
    for length in 1...commands.count {
      do {
        try await execute(Array(commands.prefix(length)), seed: seed ^ UInt64(length))
      } catch {
        return Array(commands.prefix(length))
      }
    }
    return commands
  }

  private func failureMessage(
    seed: UInt64,
    commands: [TranslationJourneyCommand],
    shortestFailingPrefix: [TranslationJourneyCommand],
    error: Error
  ) -> String {
    let timeline = commands.enumerated().map { "\($0.offset): \($0.element)" }.joined(
      separator: "\n")
    let prefix = shortestFailingPrefix.enumerated()
      .map { "\($0.offset): \($0.element)" }
      .joined(separator: "\n")
    return """
      Translation journey property failed.
      seed: 0x\(String(seed, radix: 16, uppercase: true))
      error: \(error)
      shortest failing prefix:
      \(prefix)
      full timeline:
      \(timeline)
      """
  }

  private func actualOrdinal(_ entry: HistoryEntry, in model: AppModel) -> Int? {
    model.entries.firstIndex(where: { $0 === entry })
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(2))
    }
    throw PropertyFailure("timed out waiting for product state")
  }
}

private struct PropertyFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

private final class CommandStreamingService: TextProcessingService, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<String, Error>.Continuation?

  var hasActiveStream: Bool {
    lock.withLock { continuation != nil }
  }

  func stream(
    _ request: ProcessingRequest,
    settings: CidaSettings
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      lock.withLock {
        precondition(self.continuation == nil, "Property runner permits one active stream")
        self.continuation = continuation
      }
      continuation.onTermination = { [weak self] _ in
        self?.lock.withLock { self?.continuation = nil }
      }
    }
  }

  func yield(_ chunk: String) throws {
    guard let continuation = lock.withLock({ continuation }) else {
      throw PropertyFailure("no active stream can receive a chunk")
    }
    continuation.yield(chunk)
  }

  func finish() throws {
    guard let continuation = takeContinuation() else {
      throw PropertyFailure("no active stream can complete")
    }
    continuation.finish()
  }

  func fail() throws {
    guard let continuation = takeContinuation() else {
      throw PropertyFailure("no active stream can fail")
    }
    continuation.finish(throwing: PropertyFailure("controlled property failure"))
  }

  private func takeContinuation() -> AsyncThrowingStream<String, Error>.Continuation? {
    lock.withLock {
      defer { continuation = nil }
      return continuation
    }
  }
}
