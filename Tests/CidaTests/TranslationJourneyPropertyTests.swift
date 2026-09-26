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
      .type("draft"), .deleteAll, .paste("first\nrequest"), .toggleAction, .submit,
      .releaseChunk("partial"), .pauseStream, .releaseChunk(" result"), .complete,
      .hide, .show, .paste("cancelled"), .submit, .cancel,
      .paste("failed"), .submit, .fail, .type(" edited"),
    ]

    for command in commands {
      _ = model.apply(command)
      XCTAssertTrue(
        model.invariantViolations().isEmpty,
        "command=\(command) violations=\(model.invariantViolations())"
      )
    }
    XCTAssertEqual(model.action, .translate, "Showing the panel resets the action")
    XCTAssertTrue(model.isResultStale)
  }

  private func execute(_ commands: [TranslationJourneyCommand], seed: UInt64) async throws {
    let service = CommandStreamingService()
    var oracle = TranslationJourneyModel()
    let model = AppModel(
      service: service,
      streamPresentationPolicy: .fastTests,
      saveSettings: { _ in }
    )

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
      case .toggleAction:
        if !model.isProcessing {
          model.toggleMode()
        }
      case .submit:
        let previous = model.result
        let accepted = model.submit()
        guard accepted == oracleAccepted else {
          throw PropertyFailure(
            "submit acceptance differs: product=\(accepted) oracle=\(oracleAccepted); index=\(index)")
        }
        if accepted {
          guard model.result !== previous else {
            throw PropertyFailure("submit did not replace the result; index=\(index)")
          }
          try await waitUntil { service.hasActiveStream }
        }
      case .releaseChunk(let chunk):
        if oracleAccepted {
          try service.yield(chunk)
          let expectedResult = oracle.result?.text
          try await waitUntil { model.result?.result == expectedResult }
        }
      case .pauseStream:
        if oracleAccepted {
          let value = model.result?.result
          let revision = model.result?.presentationRevision
          try await Task.sleep(for: .milliseconds(12))
          guard model.result?.result == value, model.result?.presentationRevision == revision
          else { throw PropertyFailure("backend pause changed the visible result") }
        }
      case .complete:
        if oracleAccepted {
          try service.finish()
          try await waitUntil { !model.isProcessing }
        }
      case .cancel:
        if oracleAccepted {
          model.cancelProcessing()
          try await waitUntil { !model.isProcessing }
        }
      case .fail:
        if oracleAccepted {
          try service.fail()
          try await waitUntil { !model.isProcessing }
        }
      case .hide:
        break
      case .show:
        if oracleAccepted {
          model.resetModeToDefault()
        }
      }

      try assertProduct(model, matches: oracle, commandIndex: index, command: command)
    }
    if model.isProcessing {
      model.cancelProcessing()
      try await waitUntil { !model.isProcessing }
    }
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
    guard model.inputText == oracle.sourceText else {
      throw PropertyFailure("source differs; \(context)")
    }
    guard model.mode.rawValue == oracle.action.rawValue else {
      throw PropertyFailure("action differs; \(context)")
    }
    guard (model.result == nil) == (oracle.result == nil) else {
      throw PropertyFailure("result presence differs; \(context)")
    }
    if let actual = model.result, let expected = oracle.result {
      guard actual.source == expected.source else {
        throw PropertyFailure("result source differs; \(context)")
      }
      guard actual.mode.rawValue == expected.action.rawValue else {
        throw PropertyFailure("result action differs; \(context)")
      }
      guard actual.result == expected.text else {
        throw PropertyFailure("result is not the released stream prefix; \(context)")
      }
      guard phaseName(actual.phase) == expected.phase.rawValue else {
        throw PropertyFailure(
          "phase differs: product=\(phaseName(actual.phase)) oracle=\(expected.phase); \(context)")
      }
    }
    guard model.isResultStale == oracle.isResultStale else {
      throw PropertyFailure("stale flag differs; \(context)")
    }
    guard model.canCopyResult == oracle.canCopyResult else {
      throw PropertyFailure("copyability differs; \(context)")
    }
  }

  private func phaseName(_ phase: ResultPhase) -> String {
    switch phase {
    case .streaming: "streaming"
    case .completed: "completed"
    case .stopped: "stopped"
    case .failed: "failed"
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
