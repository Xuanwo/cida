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

  func testFadeOracleRejectsAnIdenticalUnfadedSecondLine() throws {
    let line = [20.0, 80, 100, 95, 90, 70, 40, 10]
    let metrics = try XCTUnwrap(
      VisualOracle.repeatedLineFadeMetrics(
        rowContrasts: [0, 0] + line + [0, 0, 0] + line + [0, 0]
      )
    )

    XCTAssertEqual(metrics.overallRatio, 1, accuracy: 0.0001)
    XCTAssertEqual(metrics.tailRatio, 1, accuracy: 0.0001)
  }

  func testFadeOracleMeasuresTheSecondLinesLowerContrastTail() throws {
    let firstLine = [20.0, 80, 100, 95, 90, 70, 40, 10]
    let secondLine = [20.0, 78, 94, 84, 70, 48, 22, 6]
    let metrics = try XCTUnwrap(
      VisualOracle.repeatedLineFadeMetrics(
        rowContrasts: [0, 0] + firstLine + [0, 0, 0] + secondLine + [0, 0]
      )
    )

    XCTAssertLessThan(metrics.overallRatio, 0.94)
    XCTAssertLessThan(metrics.tailRatio, 0.90)
  }
}

@MainActor
private final class TestPollingClock {
  var time: TimeInterval = 0
}
