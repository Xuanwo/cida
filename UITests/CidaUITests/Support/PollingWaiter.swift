import Foundation

struct PollingObservation: Equatable {
  let elapsed: TimeInterval
  let value: String
}

struct PollingWaitResult: Equatable {
  let matched: Bool
  let elapsed: TimeInterval
  let observations: [PollingObservation]

  var diagnosticDescription: String {
    observations
      .map { String(format: "+%.3fs %@", $0.elapsed, $0.value) }
      .joined(separator: "\n")
  }
}

@MainActor
struct PollingWaiter {
  static let defaultInterval: TimeInterval = 0.02

  let pollInterval: TimeInterval
  private let now: () -> TimeInterval
  private let pump: (TimeInterval) -> Void

  init(
    pollInterval: TimeInterval = defaultInterval,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    pump: @escaping (TimeInterval) -> Void = {
      RunLoop.current.run(until: Date().addingTimeInterval($0))
    }
  ) {
    precondition(pollInterval > 0)
    self.pollInterval = pollInterval
    self.now = now
    self.pump = pump
  }

  func wait<Value>(
    timeout: TimeInterval,
    sample: () -> Value,
    matches: (Value) -> Bool,
    describe: (Value) -> String
  ) -> PollingWaitResult {
    let started = now()
    let deadline = started + max(0, timeout)
    var observations: [PollingObservation] = []
    var lastDescription: String?

    while true {
      let value = sample()
      let elapsed = max(0, now() - started)
      let description = describe(value)
      if description != lastDescription {
        observations.append(PollingObservation(elapsed: elapsed, value: description))
        lastDescription = description
      }
      if matches(value) {
        return PollingWaitResult(
          matched: true,
          elapsed: elapsed,
          observations: observations
        )
      }
      if now() >= deadline {
        return PollingWaitResult(
          matched: false,
          elapsed: max(0, now() - started),
          observations: observations
        )
      }
      pump(min(pollInterval, max(0, deadline - now())))
    }
  }
}
