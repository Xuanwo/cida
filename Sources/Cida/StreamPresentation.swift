import AppKit
import QuartzCore

struct StreamPresentationPolicy: Equatable, Sendable {
  let initialBufferingDuration: Duration
  let updateInterval: Duration
  let targetCatchUpDurationSeconds: Double
  let minimumCharactersPerSecond: Double
  let maximumCharactersPerSecond: Double
  let smoothingAlphaPer120HzFrame: Double
  let minimumPresentationIntervalSeconds: Double
  let maximumGraphemeClustersPerUpdate: Int
  let synchronizesUpdatesToDisplay: Bool

  static let production = StreamPresentationPolicy(
    initialBufferingDuration: .milliseconds(84),
    updateInterval: .milliseconds(8),
    targetCatchUpDurationSeconds: Double(CidaMotion.catchUpMilliseconds) / 1_000,
    minimumCharactersPerSecond: CidaMotion.minimumCharactersPerSecond,
    maximumCharactersPerSecond: CidaMotion.maximumCharactersPerSecond,
    smoothingAlphaPer120HzFrame: CidaMotion.smoothingAlphaPer120HzFrame,
    minimumPresentationIntervalSeconds: 1 / 120,
    maximumGraphemeClustersPerUpdate: 8,
    synchronizesUpdatesToDisplay: true
  )

  static let fastTests = StreamPresentationPolicy(
    initialBufferingDuration: .milliseconds(8),
    updateInterval: .milliseconds(4),
    targetCatchUpDurationSeconds: 0.02,
    minimumCharactersPerSecond: 250,
    maximumCharactersPerSecond: 4_000,
    smoothingAlphaPer120HzFrame: 1,
    minimumPresentationIntervalSeconds: 0,
    maximumGraphemeClustersPerUpdate: 16,
    synchronizesUpdatesToDisplay: false
  )

  func targetCharactersPerSecond(forPendingCount pendingCount: Int) -> Double {
    guard pendingCount > 0 else { return 0 }
    let catchUpRate = Double(pendingCount) / max(0.001, targetCatchUpDurationSeconds)
    return min(
      maximumCharactersPerSecond,
      max(minimumCharactersPerSecond, catchUpRate)
    )
  }

  func smoothingAlpha(forElapsedSeconds elapsedSeconds: Double) -> Double {
    guard smoothingAlphaPer120HzFrame < 1 else { return 1 }
    let frameCount = max(0, elapsedSeconds) * 120
    return 1 - pow(1 - smoothingAlphaPer120HzFrame, frameCount)
  }
}

struct StreamVelocityController {
  let policy: StreamPresentationPolicy
  private(set) var smoothedCharactersPerSecond = 0.0
  private var characterAllowance = 0.0

  init(policy: StreamPresentationPolicy) {
    self.policy = policy
  }

  mutating func releaseLimit(
    pendingGraphemeClusterCount: Int,
    elapsedSeconds: Double
  ) -> Int {
    guard pendingGraphemeClusterCount > 0 else {
      smoothedCharactersPerSecond = 0
      characterAllowance = 0
      return 0
    }

    let target = policy.targetCharactersPerSecond(forPendingCount: pendingGraphemeClusterCount)
    if smoothedCharactersPerSecond == 0 {
      smoothedCharactersPerSecond = target
    } else {
      let alpha = policy.smoothingAlpha(forElapsedSeconds: elapsedSeconds)
      smoothedCharactersPerSecond += alpha * (target - smoothedCharactersPerSecond)
    }

    // A stalled callback must not turn into a visible burst when delivery resumes.
    let boundedElapsed = min(max(0, elapsedSeconds), 0.1)
    characterAllowance += smoothedCharactersPerSecond * boundedElapsed
    let availableCount = Int(characterAllowance.rounded(.down))
    let releaseCount = min(
      pendingGraphemeClusterCount,
      policy.maximumGraphemeClustersPerUpdate,
      availableCount
    )
    characterAllowance -= Double(releaseCount)
    return releaseCount
  }
}

struct StreamPresentationBuffer {
  private struct Segment {
    let text: String
    var cursor: String.Index

    init(_ text: String) {
      self.text = text
      cursor = text.startIndex
    }
  }

  private var segments: [Segment] = []
  private var headIndex = 0
  private var trailingGraphemeCluster = ""
  private(set) var pendingUTF8ByteCount = 0
  private(set) var pendingGraphemeClusterCount = 0
  private(set) var isInputFinished = false

  var isDrained: Bool {
    isInputFinished && pendingGraphemeClusterCount == 0 && trailingGraphemeCluster.isEmpty
  }

  mutating func append(_ chunk: String) {
    guard !isInputFinished, !chunk.isEmpty else { return }

    var combined = trailingGraphemeCluster
    combined.append(contentsOf: chunk)

    // Hold the newest cluster briefly because a later network delta may extend
    // it with a combining mark, skin tone, or zero-width-joiner sequence.
    let trailingStart = combined.index(before: combined.endIndex)
    enqueue(String(combined[..<trailingStart]))
    trailingGraphemeCluster = String(combined[trailingStart...])
  }

  mutating func finish() {
    guard !isInputFinished else { return }
    isInputFinished = true
    makeTrailingGraphemeClusterReady()
  }

  mutating func makeTrailingGraphemeClusterReady() {
    enqueue(trailingGraphemeCluster)
    trailingGraphemeCluster = ""
  }

  mutating func take(maximumGraphemeClusterCount limit: Int) -> String {
    guard limit > 0, pendingGraphemeClusterCount > 0 else { return "" }

    var result = ""
    var remaining = limit

    while remaining > 0, headIndex < segments.count {
      let text = segments[headIndex].text
      let start = segments[headIndex].cursor
      var end = start
      var consumedCount = 0

      while consumedCount < remaining, end < text.endIndex {
        end = text.index(after: end)
        consumedCount += 1
      }

      let slice = text[start..<end]
      result.append(contentsOf: slice)
      pendingUTF8ByteCount -= slice.utf8.count
      pendingGraphemeClusterCount -= consumedCount
      remaining -= consumedCount

      if end == text.endIndex {
        headIndex += 1
      } else {
        segments[headIndex].cursor = end
      }
    }

    compactConsumedSegmentsIfNeeded()
    return result
  }

  private mutating func enqueue(_ text: String) {
    guard !text.isEmpty else { return }
    pendingUTF8ByteCount += text.utf8.count
    pendingGraphemeClusterCount += text.count
    segments.append(Segment(text))
  }

  private mutating func compactConsumedSegmentsIfNeeded() {
    guard headIndex >= 64, headIndex * 2 >= segments.count else { return }
    segments.removeFirst(headIndex)
    headIndex = 0
  }
}

@MainActor
final class SmoothStreamPresenter {
  private let policy: StreamPresentationPolicy
  private let publish: @MainActor (String) -> Void
  private var buffer = StreamPresentationBuffer()
  private var velocityController: StreamVelocityController
  private var displayPulseContinuation: AsyncStream<CFTimeInterval>.Continuation?
  private weak var displayLinkView: NSView?
  private var displayClock: DisplayLinkClock?
  private var lastDisplayPulseUptime = 0.0
  private var elapsedSinceLastPresentation = 0.0
  private(set) var receivedContent = false

  init(
    policy: StreamPresentationPolicy,
    displayLinkView: NSView? = nil,
    publish: @escaping @MainActor (String) -> Void
  ) {
    self.policy = policy
    self.displayLinkView = displayLinkView
    velocityController = StreamVelocityController(policy: policy)
    self.publish = publish
  }

  func append(_ chunk: String) {
    guard !chunk.isEmpty else { return }
    receivedContent = true
    buffer.append(chunk)
  }

  func finishInput() {
    buffer.finish()
  }

  func presentForExternalDisplayPulse(elapsedSeconds: Double) {
    presentNextUpdate(elapsedSeconds: max(0, elapsedSeconds))
  }

  func run() async throws {
    let clock = ContinuousClock()
    try await clock.sleep(for: policy.initialBufferingDuration)

    if policy.synchronizesUpdatesToDisplay, displayLinkView?.window != nil {
      try await runSynchronizedToDisplay()
    } else {
      try await runOnTimer(clock: clock)
    }
  }

  private func runSynchronizedToDisplay() async throws {
    guard let displayLinkView else { return }
    let (pulses, continuation) = AsyncStream<CFTimeInterval>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    displayPulseContinuation = continuation

    let displayClock = DisplayLinkClock(
      sourceView: displayLinkView,
      handler: { pulse in
        _ = continuation.yield(pulse.timestamp)
      }
    )
    guard displayClock.start() else {
      continuation.finish()
      try await runOnTimer(clock: ContinuousClock())
      return
    }
    self.displayClock = displayClock
    lastDisplayPulseUptime = CACurrentMediaTime()
    let stalledDisplayFallback = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled, let self else { return }
        let now = CACurrentMediaTime()
        if now - self.lastDisplayPulseUptime >= 0.09 {
          self.displayPulseContinuation?.yield(now)
        }
      }
    }

    defer {
      stalledDisplayFallback.cancel()
      displayClock.invalidate()
      self.displayClock = nil
      continuation.finish()
      displayPulseContinuation = nil
    }

    var previousPulse = CACurrentMediaTime()
    for await pulse in pulses {
      try Task.checkCancellation()
      lastDisplayPulseUptime = pulse
      presentNextUpdate(elapsedSeconds: pulse - previousPulse)
      previousPulse = pulse
      if buffer.isDrained { return }
    }
  }

  private func runOnTimer(clock: ContinuousClock) async throws {
    var nextUpdate = clock.now
    var previousUptime = ProcessInfo.processInfo.systemUptime

    while !buffer.isDrained {
      try Task.checkCancellation()
      let nowUptime = ProcessInfo.processInfo.systemUptime
      presentNextUpdate(elapsedSeconds: nowUptime - previousUptime)
      previousUptime = nowUptime

      nextUpdate = nextUpdate.advanced(by: policy.updateInterval)
      let now = clock.now
      if nextUpdate < now {
        nextUpdate = now.advanced(by: policy.updateInterval)
      }
      try await clock.sleep(until: nextUpdate, tolerance: .milliseconds(1))
    }
  }

  private func presentNextUpdate(elapsedSeconds: Double) {
    if buffer.pendingGraphemeClusterCount == 0 {
      buffer.makeTrailingGraphemeClusterReady()
    }

    guard buffer.pendingGraphemeClusterCount > 0 else {
      _ = velocityController.releaseLimit(
        pendingGraphemeClusterCount: 0,
        elapsedSeconds: elapsedSeconds
      )
      elapsedSinceLastPresentation = 0
      return
    }

    elapsedSinceLastPresentation += min(max(0, elapsedSeconds), 0.1)
    guard
      elapsedSinceLastPresentation + 0.000_001
        >= policy.minimumPresentationIntervalSeconds
    else {
      return
    }
    let presentationElapsed = elapsedSinceLastPresentation
    elapsedSinceLastPresentation = 0

    let releaseLimit = velocityController.releaseLimit(
      pendingGraphemeClusterCount: buffer.pendingGraphemeClusterCount,
      elapsedSeconds: presentationElapsed
    )
    let delta = buffer.take(maximumGraphemeClusterCount: releaseLimit)
    if !delta.isEmpty {
      publish(delta)
    }
  }
}
