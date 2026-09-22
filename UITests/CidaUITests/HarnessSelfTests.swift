import XCTest

@MainActor
final class HarnessSelfTests: XCTestCase {
  func testPollingWaiterObservesSupportedTransientDurations() {
    for duration in [0.1, 0.2, 0.8] {
      let clock = TestPollingClock()
      let activeStart = 0.04
      let activeEnd = activeStart + duration
      let waiter = PollingWaiter(
        pollInterval: 0.02,
        now: { clock.time },
        pump: { clock.time += $0 }
      )

      let result = waiter.wait(
        timeout: 1,
        sample: {
          activeStart...activeEnd ~= clock.time ? "transient" : "idle"
        },
        matches: { $0 == "transient" },
        describe: { $0 }
      )

      XCTAssertTrue(result.matched, "Missed a \(duration)s transient state")
      XCTAssertLessThanOrEqual(result.elapsed, activeStart + waiter.pollInterval)
      XCTAssertEqual(result.observations.last?.value, "transient")
    }
  }

  func testPollingWaiterSamplesImmediately() {
    let clock = TestPollingClock()
    let waiter = PollingWaiter(
      now: { clock.time },
      pump: { clock.time += $0 }
    )

    let result = waiter.wait(
      timeout: 1,
      sample: { "ready" },
      matches: { $0 == "ready" },
      describe: { $0 }
    )

    XCTAssertTrue(result.matched)
    XCTAssertEqual(result.elapsed, 0)
    XCTAssertEqual(result.observations, [PollingObservation(elapsed: 0, value: "ready")])
  }

  func testPollingWaiterReportsChangedValuesOnTimeout() {
    let clock = TestPollingClock()
    let waiter = PollingWaiter(
      pollInterval: 0.02,
      now: { clock.time },
      pump: { clock.time += $0 }
    )

    let result = waiter.wait(
      timeout: 0.08,
      sample: { clock.time < 0.04 ? "waiting" : "still-waiting" },
      matches: { $0 == "ready" },
      describe: { $0 }
    )

    XCTAssertFalse(result.matched)
    XCTAssertEqual(result.observations.map(\.value), ["waiting", "still-waiting"])
    XCTAssertTrue(result.diagnosticDescription.contains("still-waiting"))
  }
}

@MainActor
private final class TestPollingClock {
  var time: TimeInterval = 0
}
