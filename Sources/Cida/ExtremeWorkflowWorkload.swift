import AppKit
import QuartzCore

struct ExtremeWorkflowConfiguration: Equatable, Sendable {
  let expectedInitialHistoryEntryCount: Int
  let inputCharacterCount: Int
  let outputCharacterCount: Int
  let minimumNormalScrollDistancePoints: CGFloat
  let minimumHyperScrollDistancePoints: CGFloat

  init(
    expectedInitialHistoryEntryCount: Int,
    inputCharacterCount: Int,
    outputCharacterCount: Int,
    minimumNormalScrollDistancePoints: CGFloat = 6_000,
    minimumHyperScrollDistancePoints: CGFloat = 120_000
  ) {
    self.expectedInitialHistoryEntryCount = max(0, expectedInitialHistoryEntryCount)
    self.inputCharacterCount = max(1, inputCharacterCount)
    self.outputCharacterCount = max(1, outputCharacterCount)
    self.minimumNormalScrollDistancePoints = max(1, minimumNormalScrollDistancePoints)
    self.minimumHyperScrollDistancePoints = max(1, minimumHyperScrollDistancePoints)
  }
}

@MainActor
final class LaunchPerformanceDiagnostics {
  private let startedAt = CACurrentMediaTime()
  private(set) var historyLoadDurationMilliseconds: Double?
  private(set) var initialRenderDurationMilliseconds: Double?
  private(set) var databaseBytes: Int64?

  func recordHistoryLoad(durationMilliseconds: Double, databaseURL: URL?) {
    historyLoadDurationMilliseconds = durationMilliseconds
    databaseBytes = databaseURL.map(Self.databaseFootprint)
  }

  func recordInitialRenderIfNeeded() {
    guard initialRenderDurationMilliseconds == nil else { return }
    initialRenderDurationMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
  }

  private static func databaseFootprint(at databaseURL: URL) -> Int64 {
    let fileManager = FileManager.default
    return [
      databaseURL.path,
      databaseURL.path + "-wal",
      databaseURL.path + "-shm",
    ].reduce(into: 0) { total, path in
      guard
        let attributes = try? fileManager.attributesOfItem(atPath: path),
        let size = attributes[.size] as? NSNumber
      else {
        return
      }
      total += size.int64Value
    }
  }
}

@MainActor
final class ExtremeWorkflowWorkload {
  private enum Phase: String {
    case ready
    case translating
    case normalScroll = "normal-scroll"
    case hyperScroll = "hyper-scroll"
    case completed
    case failed
  }

  private let model: AppModel
  private weak var rootView: NSView?
  private let configuration: ExtremeWorkflowConfiguration
  private let diagnostics: LaunchPerformanceDiagnostics
  private let document: String
  private let initialLoadedHistoryEntryCount: Int
  private weak var historyScrollView: NSScrollView?
  private var phase = Phase.ready
  private var submissionStartedAt: CFTimeInterval?
  private var translationDurationMilliseconds: Double?
  private var normalScrollDistancePoints: CGFloat = 0
  private var hyperScrollDistancePoints: CGFloat = 0
  private var maximumScrollStepPoints: CGFloat = 0
  private var observedOutputCharacterCount: Int?
  private var submitted = false
  private var completionSettlingFramesRemaining = 48
  private var scrollTransitionFramesRemaining = 0
  private var event = "ready"

  init(
    model: AppModel,
    rootView: NSView,
    configuration: ExtremeWorkflowConfiguration,
    diagnostics: LaunchPerformanceDiagnostics
  ) {
    self.model = model
    self.rootView = rootView
    self.configuration = configuration
    self.diagnostics = diagnostics
    initialLoadedHistoryEntryCount = model.entries.count
    document = Self.makeDocument(characterCount: configuration.inputCharacterCount)
  }

  @discardableResult
  func exercise() -> Bool {
    switch phase {
    case .ready:
      event = "submit"
      guard model.totalHistoryEntryCount == configuration.expectedInitialHistoryEntryCount else {
        phase = .failed
        return false
      }
      model.stageInputDocument(
        document,
        utf16Count: configuration.inputCharacterCount,
        hasNonWhitespace: true
      )
      submissionStartedAt = CACurrentMediaTime()
      submitted = model.submit()
      phase = submitted ? .translating : .failed
      return true

    case .translating:
      guard submitted else {
        phase = .failed
        return false
      }
      guard !model.isProcessing else {
        event =
          model.entries.count > initialLoadedHistoryEntryCount
          ? "streaming-entry-visible"
          : "submission-preflight"
        return false
      }
      guard let latest = model.entries.last, latest.state == .completed else {
        phase = .failed
        return false
      }
      if observedOutputCharacterCount == nil {
        event = "completion-observed"
        observedOutputCharacterCount = latest.resultUTF16Length
        if let submissionStartedAt {
          translationDurationMilliseconds =
            (CACurrentMediaTime() - submissionStartedAt) * 1_000
        }
        guard latest.resultUTF16Length == configuration.outputCharacterCount else {
          phase = .failed
          return false
        }
        return false
      }
      guard completionSettlingFramesRemaining == 0 else {
        event = "completion-settling"
        completionSettlingFramesRemaining -= 1
        return false
      }
      event = "prepare-normal-scroll"
      prepareForScrolling()
      scrollTransitionFramesRemaining = 8
      phase = .normalScroll
      return false

    case .normalScroll:
      guard scrollTransitionFramesRemaining == 0 else {
        event = "normal-scroll-settling"
        scrollTransitionFramesRemaining -= 1
        return false
      }
      event = "normal-scroll"
      let distance = scroll(upwardBy: 32)
      normalScrollDistancePoints += distance
      maximumScrollStepPoints = max(maximumScrollStepPoints, distance)
      if normalScrollDistancePoints >= configuration.minimumNormalScrollDistancePoints {
        scrollTransitionFramesRemaining = 8
        phase = .hyperScroll
      } else if distance < 0.5 {
        prepareForScrolling()
      }
      return distance > 0.5

    case .hyperScroll:
      guard scrollTransitionFramesRemaining == 0 else {
        event = "hyper-scroll-settling"
        scrollTransitionFramesRemaining -= 1
        return false
      }
      event = "hyper-scroll"
      guard let scrollView = resolveHistoryScrollView() else { return false }
      let distance = scroll(upwardBy: max(512, scrollView.contentView.bounds.height))
      hyperScrollDistancePoints += distance
      maximumScrollStepPoints = max(maximumScrollStepPoints, distance)
      if hyperScrollDistancePoints >= configuration.minimumHyperScrollDistancePoints {
        phase = .completed
      } else if distance < 0.5 {
        prepareForScrolling()
      }
      return distance > 0.5

    case .completed, .failed:
      event = phase.rawValue
      return false
    }
  }

  func metrics() -> FramePacingWorkloadMetrics {
    let expectedFinalHistoryCount = configuration.expectedInitialHistoryEntryCount + 1
    return FramePacingWorkloadMetrics(
      completed: phase == .completed
        && submitted
        && model.totalHistoryEntryCount == expectedFinalHistoryCount
        && model.entries.count >= initialLoadedHistoryEntryCount + 1
        && observedOutputCharacterCount == configuration.outputCharacterCount
        && normalScrollDistancePoints >= configuration.minimumNormalScrollDistancePoints
        && hyperScrollDistancePoints >= configuration.minimumHyperScrollDistancePoints,
      inputCharacterCount: configuration.inputCharacterCount,
      operationDurationMilliseconds: translationDurationMilliseconds,
      streamPresentationUpdateCount: model.streamPresentationUpdateCount,
      maximumStreamPresentationBatchCharacterCount:
        model.maximumStreamPresentationCharacterCount,
      historyEntryCount: model.entries.count,
      totalHistoryEntryCount: model.totalHistoryEntryCount,
      scrollDistancePoints: Double(normalScrollDistancePoints + hyperScrollDistancePoints),
      outputCharacterCount: observedOutputCharacterCount,
      normalScrollDistancePoints: Double(normalScrollDistancePoints),
      hyperScrollDistancePoints: Double(hyperScrollDistancePoints),
      maximumScrollStepPoints: Double(maximumScrollStepPoints),
      historyLoadDurationMilliseconds: diagnostics.historyLoadDurationMilliseconds,
      initialRenderDurationMilliseconds: diagnostics.initialRenderDurationMilliseconds,
      databaseBytes: diagnostics.databaseBytes,
      workflowPhase: phase.rawValue,
      workflowEvent: event
    )
  }

  private func prepareForScrolling() {
    guard let scrollView = resolveHistoryScrollView(), let documentView = scrollView.documentView
    else {
      return
    }
    let clipView = scrollView.contentView
    let visibleRect = clipView.documentVisibleRect
    let bottomOriginY =
      documentView.isFlipped
      ? max(documentView.bounds.minY, documentView.bounds.maxY - visibleRect.height)
      : documentView.bounds.minY
    clipView.scroll(to: NSPoint(x: visibleRect.minX, y: bottomOriginY))
    scrollView.reflectScrolledClipView(clipView)
  }

  private func scroll(upwardBy requestedDistance: CGFloat) -> CGFloat {
    guard let scrollView = resolveHistoryScrollView(), let documentView = scrollView.documentView
    else {
      return 0
    }
    let clipView = scrollView.contentView
    let visibleRect = clipView.documentVisibleRect
    let maximumOriginY = max(
      documentView.bounds.minY,
      documentView.bounds.maxY - visibleRect.height
    )
    let delta = documentView.isFlipped ? -requestedDistance : requestedDistance
    let nextOriginY = min(
      maximumOriginY,
      max(documentView.bounds.minY, visibleRect.minY + delta)
    )
    let distance = abs(nextOriginY - visibleRect.minY)
    guard distance > 0.5 else { return 0 }

    clipView.scroll(to: NSPoint(x: visibleRect.minX, y: nextOriginY))
    scrollView.reflectScrolledClipView(clipView)
    NotificationCenter.default.post(
      name: NSScrollView.didLiveScrollNotification,
      object: scrollView
    )
    rootView?.layoutSubtreeIfNeeded()
    rootView?.displayIfNeeded()
    return distance
  }

  private func resolveHistoryScrollView() -> NSScrollView? {
    if let historyScrollView { return historyScrollView }
    guard let rootView, let resolved = findHistoryScrollView(in: rootView) else { return nil }
    historyScrollView = resolved
    return resolved
  }

  private func findHistoryScrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView,
      scrollView.accessibilityIdentifier() == "history-scroll-view"
    {
      return scrollView
    }
    for child in view.subviews {
      if let result = findHistoryScrollView(in: child) {
        return result
      }
    }
    return nil
  }

  private static func makeDocument(characterCount: Int) -> String {
    let line = String(repeating: "A", count: 99) + "\n"
    let fullLines = characterCount / line.count
    let remainder = characterCount % line.count
    return String(repeating: line, count: fullLines)
      + String(repeating: "B", count: remainder)
  }
}
