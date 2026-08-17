import AppKit
import CDisplayClock
import Darwin
import QuartzCore

struct PerformanceProbeConfiguration: Sendable {
  let outputURL: URL
  let sampleCount: Int
  let warmupFrameCount: Int
  let workload: FramePacingWorkload
  let requiredFramesPerSecond: Int?
  let requiresZeroMissedFrameBudgets: Bool
}

enum FramePacingWorkload: String, Sendable {
  case streaming
  case millionCharacterPaste = "million-character-paste"
  case largeHistoryScroll = "large-history-scroll"
  case extremeWorkflow = "extreme-workflow"

  var description: String {
    switch self {
    case .streaming:
      "Adaptive burst-smoothed streaming with Core Animation rendering"
    case .millionCharacterPaste:
      "Pasting a 1,000,000-character document into the native composer"
    case .largeHistoryScroll:
      "Continuously scrolling upward through 1,000 persisted history records"
    case .extremeWorkflow:
      "Submit, stream, persist, scroll, and hyper-scroll an extreme persisted history"
    }
  }
}

struct FramePacingWorkloadMetrics: Equatable, Sendable {
  var completed = true
  var inputCharacterCount: Int?
  var operationDurationMilliseconds: Double?
  var streamPresentationUpdateCount: Int?
  var maximumStreamPresentationBatchCharacterCount: Int?
  var historyEntryCount: Int?
  var totalHistoryEntryCount: Int?
  var scrollDistancePoints: Double?
  var outputCharacterCount: Int?
  var normalScrollDistancePoints: Double?
  var hyperScrollDistancePoints: Double?
  var maximumScrollStepPoints: Double?
  var historyLoadDurationMilliseconds: Double?
  var initialRenderDurationMilliseconds: Double?
  var databaseBytes: Int64?
  var workflowPhase: String?
  var workflowEvent: String?
}

struct PhaseFramePacingReport: Codable, Equatable, Sendable {
  let sampleCount: Int
  let meanFrameTimeMilliseconds: Double
  let p95FrameTimeMilliseconds: Double
  let p99FrameTimeMilliseconds: Double
  let maximumFrameTimeMilliseconds: Double
  let missedFrameBudgetCount: Int
}

struct FramePacingReport: Codable, Equatable, Sendable {
  let artifactAppTreeSHA256: String?
  let artifactSourceCommit: String?
  let hardwareModel: String
  let operatingSystemVersion: String
  let thermalState: String
  let lowPowerModeEnabled: Bool
  let powerSource: String?
  let displayName: String?
  let displayBackingScaleFactor: Double
  let displayPixelWidth: Int
  let displayPixelHeight: Int
  let workload: String
  let frameClock: String
  let applicationActivationObserved: Bool
  let probeWindowBecameKey: Bool
  let displayMaximumFramesPerSecond: Int
  let requiredFramesPerSecond: Int
  let displayRequirementSatisfied: Bool
  let workloadCompleted: Bool
  let inputCharacterCount: Int?
  let operationDurationMilliseconds: Double?
  let streamPresentationUpdateCount: Int?
  let maximumStreamPresentationBatchCharacterCount: Int?
  let historyEntryCount: Int?
  let totalHistoryEntryCount: Int?
  let scrollDistancePoints: Double?
  let outputCharacterCount: Int?
  let normalScrollDistancePoints: Double?
  let hyperScrollDistancePoints: Double?
  let maximumScrollStepPoints: Double?
  let historyLoadDurationMilliseconds: Double?
  let initialRenderDurationMilliseconds: Double?
  let databaseBytes: Int64?
  let currentResidentMemoryBytes: Int64
  let peakResidentMemoryBytes: Int64
  let workflowPhase: String?
  let phaseFramePacing: [String: PhaseFramePacingReport]
  let minimumMeasuredFramesPerSecond: Double
  let sampleCount: Int
  let interactionCount: Int
  let measuredFramesPerSecond: Double
  let meanFrameTimeMilliseconds: Double
  let p95FrameTimeMilliseconds: Double
  let p99FrameTimeMilliseconds: Double
  let maximumFrameTimeMilliseconds: Double
  let maximumFrameSampleIndex: Int?
  let maximumFrameEvent: String?
  let workloadCompletionSampleIndex: Int?
  let missedFrameSampleIndices: [Int]
  let missedFrameEvents: [String]
  let missedFrameSampleIndicesTruncated: Bool
  let missedFrameBudgetCount: Int
  let passed: Bool
}

private final class PerformanceDisplayClockBridge: @unchecked Sendable {
  let onTick: @Sendable () -> Void

  init(onTick: @escaping @Sendable () -> Void) {
    self.onTick = onTick
  }
}

private func performanceDisplayClockCallback(_ context: UnsafeMutableRawPointer?) {
  guard let context else { return }
  Unmanaged<PerformanceDisplayClockBridge>.fromOpaque(context).takeUnretainedValue().onTick()
}

@MainActor
final class FramePacingProbeNSView: NSView {
  private let configuration: PerformanceProbeConfiguration
  private let exerciseInteraction: @MainActor (Int) -> Bool
  private let workloadMetrics: @MainActor () -> FramePacingWorkloadMetrics
  private let markerLayer = CALayer()
  private var displayClock: OpaquePointer?
  private var displayClockBridge: PerformanceDisplayClockBridge?
  private var watchdog: Timer?
  private var frameTimestamps: [CFTimeInterval] = []
  private var framePhaseLabels: [String] = []
  private var frameEventLabels: [String] = []
  private var phase: CGFloat = 0
  private var didFinish = false
  private var displayLinkTicks = 0
  private var interactionCount = 0
  private var workloadCompletionSampleIndex: Int?
  private var latencyActivity: NSObjectProtocol?
  private var applicationActivationObserved = false
  private var probeWindowBecameKey = false
  private var maximumObservedResidentMemoryBytes = ProcessMemory.currentResidentBytes()

  init(
    configuration: PerformanceProbeConfiguration,
    exerciseInteraction: @escaping @MainActor (Int) -> Bool,
    workloadMetrics: @escaping @MainActor () -> FramePacingWorkloadMetrics = {
      FramePacingWorkloadMetrics()
    }
  ) {
    self.configuration = configuration
    self.exerciseInteraction = exerciseInteraction
    self.workloadMetrics = workloadMetrics
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    markerLayer.backgroundColor =
      NSColor(
        red: 46 / 255,
        green: 107 / 255,
        blue: 79 / 255,
        alpha: 1
      ).cgColor
    layer?.addSublayer(markerLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override var isOpaque: Bool { false }

  override func layout() {
    super.layout()
    updateMarkerFrame()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    NotificationCenter.default.removeObserver(self)

    stopDisplayClock()
    watchdog?.invalidate()
    watchdog = nil
    if let latencyActivity {
      ProcessInfo.processInfo.endActivity(latencyActivity)
      self.latencyActivity = nil
    }

    guard let window else { return }

    applicationActivationObserved = applicationActivationObserved || NSApp.isActive
    probeWindowBecameKey = probeWindowBecameKey || window.isKeyWindow
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidActivate(_:)),
      name: NSApplication.didBecomeActiveNotification,
      object: NSApp
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(probeWindowDidBecomeKey(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: window
    )

    let screen = window.screen ?? NSScreen.main
    guard let screen else { return }
    latencyActivity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .latencyCritical],
      reason: "Measuring interactive frame pacing"
    )
    let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
    let displayID =
      (screen.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value
      ?? CGMainDisplayID()
    let bridge = PerformanceDisplayClockBridge { [weak self] in
      Task { @MainActor [weak self] in
        self?.recordFrameTick(at: CACurrentMediaTime())
      }
    }
    guard
      let createdDisplayClock = cida_display_clock_create(
        displayID,
        performanceDisplayClockCallback,
        Unmanaged.passUnretained(bridge).toOpaque()
      )
    else {
      finish()
      return
    }
    displayClock = createdDisplayClock
    displayClockBridge = bridge
    guard cida_display_clock_start(createdDisplayClock) else {
      finish()
      return
    }
    let clockFramesPerSecond = max(
      1,
      configuration.requiredFramesPerSecond ?? screen.maximumFramesPerSecond
    )
    let expectedDuration =
      Double(configuration.sampleCount + configuration.warmupFrameCount)
      / Double(clockFramesPerSecond)
    watchdog = Timer.scheduledTimer(
      withTimeInterval: max(12, expectedDuration + 5),
      repeats: false
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.finish()
      }
    }
  }

  @objc
  private func applicationDidActivate(_ notification: Notification) {
    applicationActivationObserved = true
  }

  @objc
  private func probeWindowDidBecomeKey(_ notification: Notification) {
    probeWindowBecameKey = true
  }

  private func recordFrameTick(at timestamp: CFTimeInterval) {
    guard !didFinish else { return }

    displayLinkTicks += 1
    phase += 0.025
    if phase > 1 { phase = 0 }
    updateMarkerFrame()

    guard displayLinkTicks > configuration.warmupFrameCount else {
      _ = exerciseInteraction(displayLinkTicks - configuration.warmupFrameCount)
      return
    }
    let sampleIndex = displayLinkTicks - configuration.warmupFrameCount
    frameTimestamps.append(timestamp)
    if exerciseInteraction(sampleIndex) {
      interactionCount += 1
    }
    let metrics = workloadMetrics()
    framePhaseLabels.append(metrics.workflowPhase ?? "unspecified")
    frameEventLabels.append(metrics.workflowEvent ?? "unspecified")
    if interactionCount > 0,
      workloadCompletionSampleIndex == nil,
      metrics.completed
    {
      workloadCompletionSampleIndex = sampleIndex
    }

    if frameTimestamps.count >= configuration.sampleCount {
      finish()
    }
  }

  private func updateMarkerFrame() {
    let markerWidth: CGFloat = 18
    let travel = max(1, bounds.width - markerWidth)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    markerLayer.frame = CGRect(
      x: travel * phase,
      y: 0,
      width: markerWidth,
      height: bounds.height
    )
    CATransaction.commit()
  }

  private func finish() {
    guard !didFinish else { return }
    didFinish = true
    stopDisplayClock()
    watchdog?.invalidate()
    watchdog = nil
    if let latencyActivity {
      ProcessInfo.processInfo.endActivity(latencyActivity)
      self.latencyActivity = nil
    }

    applicationActivationObserved = applicationActivationObserved || NSApp.isActive
    probeWindowBecameKey = probeWindowBecameKey || window?.isKeyWindow == true

    let screen = window?.screen ?? NSScreen.main
    let maximumFPS = screen?.maximumFramesPerSecond ?? 60
    let backingFrame = screen.map { $0.convertRectToBacking($0.frame) } ?? .zero
    let metrics = workloadMetrics()
    let report = Self.makeReport(
      timestamps: frameTimestamps,
      maximumFramesPerSecond: maximumFPS,
      artifactAppTreeSHA256: ProcessInfo.processInfo.environment[
        "CIDA_ARTIFACT_APP_TREE_SHA256"
      ],
      artifactSourceCommit: ProcessInfo.processInfo.environment[
        "CIDA_ARTIFACT_SOURCE_COMMIT"
      ],
      hardwareModel: Self.hardwareModel(),
      operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      thermalState: Self.thermalStateDescription(ProcessInfo.processInfo.thermalState),
      lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
      powerSource: ProcessInfo.processInfo.environment["CIDA_PERFORMANCE_POWER_SOURCE"],
      displayName: screen?.localizedName,
      displayBackingScaleFactor: Double(screen?.backingScaleFactor ?? 1),
      displayPixelWidth: Int(backingFrame.width.rounded()),
      displayPixelHeight: Int(backingFrame.height.rounded()),
      interactionCount: interactionCount,
      requiredSampleCount: configuration.sampleCount,
      workload: configuration.workload.description,
      frameClock: "core-video-display-link",
      requiredFramesPerSecond: configuration.requiredFramesPerSecond,
      requiresZeroMissedFrameBudgets: configuration.requiresZeroMissedFrameBudgets,
      workloadCompleted: metrics.completed,
      inputCharacterCount: metrics.inputCharacterCount,
      operationDurationMilliseconds: metrics.operationDurationMilliseconds,
      streamPresentationUpdateCount: metrics.streamPresentationUpdateCount,
      maximumStreamPresentationBatchCharacterCount:
        metrics.maximumStreamPresentationBatchCharacterCount,
      historyEntryCount: metrics.historyEntryCount,
      totalHistoryEntryCount: metrics.totalHistoryEntryCount,
      scrollDistancePoints: metrics.scrollDistancePoints,
      outputCharacterCount: metrics.outputCharacterCount,
      normalScrollDistancePoints: metrics.normalScrollDistancePoints,
      hyperScrollDistancePoints: metrics.hyperScrollDistancePoints,
      maximumScrollStepPoints: metrics.maximumScrollStepPoints,
      historyLoadDurationMilliseconds: metrics.historyLoadDurationMilliseconds,
      initialRenderDurationMilliseconds: metrics.initialRenderDurationMilliseconds,
      databaseBytes: metrics.databaseBytes,
      currentResidentMemoryBytes: ProcessMemory.currentResidentBytes(),
      peakResidentMemoryBytes: max(
        maximumObservedResidentMemoryBytes,
        ProcessMemory.peakResidentBytes()
      ),
      workflowPhase: metrics.workflowPhase,
      phaseLabels: framePhaseLabels,
      eventLabels: frameEventLabels,
      workloadCompletionSampleIndex: workloadCompletionSampleIndex,
      applicationActivationObserved: applicationActivationObserved,
      probeWindowBecameKey: probeWindowBecameKey
    )

    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(report)
      try data.write(to: configuration.outputURL, options: Data.WritingOptions.atomic)
    } catch {
      fputs("Failed to write frame pacing report: \(error)\n", stderr)
    }

    DispatchQueue.main.async {
      NSApp.terminate(nil)
    }
  }

  private func stopDisplayClock() {
    guard let displayClock else { return }
    cida_display_clock_destroy(displayClock)
    self.displayClock = nil
    displayClockBridge = nil
  }

  static func makeReport(
    timestamps: [CFTimeInterval],
    maximumFramesPerSecond: Int,
    artifactAppTreeSHA256: String? = nil,
    artifactSourceCommit: String? = nil,
    hardwareModel: String = "unknown",
    operatingSystemVersion: String = "unknown",
    thermalState: String = "unknown",
    lowPowerModeEnabled: Bool = false,
    powerSource: String? = nil,
    displayName: String? = nil,
    displayBackingScaleFactor: Double = 1,
    displayPixelWidth: Int = 0,
    displayPixelHeight: Int = 0,
    interactionCount: Int = 0,
    requiredSampleCount: Int? = nil,
    workload: String = FramePacingWorkload.streaming.description,
    frameClock: String = "display-link",
    requiredFramesPerSecond: Int? = nil,
    requiresZeroMissedFrameBudgets: Bool = false,
    workloadCompleted: Bool = true,
    inputCharacterCount: Int? = nil,
    operationDurationMilliseconds: Double? = nil,
    streamPresentationUpdateCount: Int? = nil,
    maximumStreamPresentationBatchCharacterCount: Int? = nil,
    historyEntryCount: Int? = nil,
    totalHistoryEntryCount: Int? = nil,
    scrollDistancePoints: Double? = nil,
    outputCharacterCount: Int? = nil,
    normalScrollDistancePoints: Double? = nil,
    hyperScrollDistancePoints: Double? = nil,
    maximumScrollStepPoints: Double? = nil,
    historyLoadDurationMilliseconds: Double? = nil,
    initialRenderDurationMilliseconds: Double? = nil,
    databaseBytes: Int64? = nil,
    currentResidentMemoryBytes: Int64 = 0,
    peakResidentMemoryBytes: Int64 = 0,
    workflowPhase: String? = nil,
    phaseLabels: [String] = [],
    eventLabels: [String] = [],
    workloadCompletionSampleIndex: Int? = nil,
    applicationActivationObserved: Bool = false,
    probeWindowBecameKey: Bool = false
  ) -> FramePacingReport {
    let intervals = zip(timestamps.dropFirst(), timestamps).map(-)
    let targetFramesPerSecond = requiredFramesPerSecond ?? maximumFramesPerSecond
    let minimumMeasuredFramesPerSecond =
      Double(targetFramesPerSecond) * (requiresZeroMissedFrameBudgets ? 0.99 : 0.95)
    let displayRequirementSatisfied = maximumFramesPerSecond >= targetFramesPerSecond
    let phaseFramePacing = makePhaseReports(
      timestamps: timestamps,
      phaseLabels: phaseLabels,
      expectedInterval: 1 / Double(targetFramesPerSecond)
    )
    guard
      let first = timestamps.first,
      let last = timestamps.last,
      timestamps.count > 1,
      last > first,
      !intervals.isEmpty
    else {
      return FramePacingReport(
        artifactAppTreeSHA256: artifactAppTreeSHA256,
        artifactSourceCommit: artifactSourceCommit,
        hardwareModel: hardwareModel,
        operatingSystemVersion: operatingSystemVersion,
        thermalState: thermalState,
        lowPowerModeEnabled: lowPowerModeEnabled,
        powerSource: powerSource,
        displayName: displayName,
        displayBackingScaleFactor: displayBackingScaleFactor,
        displayPixelWidth: displayPixelWidth,
        displayPixelHeight: displayPixelHeight,
        workload: workload,
        frameClock: frameClock,
        applicationActivationObserved: applicationActivationObserved,
        probeWindowBecameKey: probeWindowBecameKey,
        displayMaximumFramesPerSecond: maximumFramesPerSecond,
        requiredFramesPerSecond: targetFramesPerSecond,
        displayRequirementSatisfied: displayRequirementSatisfied,
        workloadCompleted: workloadCompleted,
        inputCharacterCount: inputCharacterCount,
        operationDurationMilliseconds: operationDurationMilliseconds,
        streamPresentationUpdateCount: streamPresentationUpdateCount,
        maximumStreamPresentationBatchCharacterCount:
          maximumStreamPresentationBatchCharacterCount,
        historyEntryCount: historyEntryCount,
        totalHistoryEntryCount: totalHistoryEntryCount,
        scrollDistancePoints: scrollDistancePoints,
        outputCharacterCount: outputCharacterCount,
        normalScrollDistancePoints: normalScrollDistancePoints,
        hyperScrollDistancePoints: hyperScrollDistancePoints,
        maximumScrollStepPoints: maximumScrollStepPoints,
        historyLoadDurationMilliseconds: historyLoadDurationMilliseconds,
        initialRenderDurationMilliseconds: initialRenderDurationMilliseconds,
        databaseBytes: databaseBytes,
        currentResidentMemoryBytes: currentResidentMemoryBytes,
        peakResidentMemoryBytes: peakResidentMemoryBytes,
        workflowPhase: workflowPhase,
        phaseFramePacing: phaseFramePacing,
        minimumMeasuredFramesPerSecond: minimumMeasuredFramesPerSecond,
        sampleCount: timestamps.count,
        interactionCount: interactionCount,
        measuredFramesPerSecond: 0,
        meanFrameTimeMilliseconds: 0,
        p95FrameTimeMilliseconds: 0,
        p99FrameTimeMilliseconds: 0,
        maximumFrameTimeMilliseconds: 0,
        maximumFrameSampleIndex: nil,
        maximumFrameEvent: nil,
        workloadCompletionSampleIndex: workloadCompletionSampleIndex,
        missedFrameSampleIndices: [],
        missedFrameEvents: [],
        missedFrameSampleIndicesTruncated: false,
        missedFrameBudgetCount: timestamps.count,
        passed: false
      )
    }

    let sorted = intervals.sorted()
    let mean = intervals.reduce(0, +) / Double(intervals.count)
    let measuredFPS = Double(timestamps.count - 1) / (last - first)
    let expectedInterval = 1 / Double(targetFramesPerSecond)
    let missedFrameSampleIndices = intervals.enumerated().compactMap { index, interval in
      interval > expectedInterval * 1.5 ? index + 1 : nil
    }
    let missedFrameEvents = missedFrameSampleIndices.map { sampleIndex in
      eventLabels.indices.contains(sampleIndex - 1)
        ? eventLabels[sampleIndex - 1]
        : "unspecified"
    }
    let missedBudgets = missedFrameSampleIndices.count
    let p95 = percentile(sorted, 0.95)
    let p99 = percentile(sorted, 0.99)
    let reachedSampleTarget = requiredSampleCount.map { timestamps.count >= $0 } ?? true
    let missedFrameRequirementSatisfied =
      !requiresZeroMissedFrameBudgets || missedBudgets == 0
    let passed =
      reachedSampleTarget && displayRequirementSatisfied && workloadCompleted
      && measuredFPS >= minimumMeasuredFramesPerSecond
      && p99 <= expectedInterval * 1.5 && missedFrameRequirementSatisfied
      && !applicationActivationObserved && !probeWindowBecameKey

    return FramePacingReport(
      artifactAppTreeSHA256: artifactAppTreeSHA256,
      artifactSourceCommit: artifactSourceCommit,
      hardwareModel: hardwareModel,
      operatingSystemVersion: operatingSystemVersion,
      thermalState: thermalState,
      lowPowerModeEnabled: lowPowerModeEnabled,
      powerSource: powerSource,
      displayName: displayName,
      displayBackingScaleFactor: displayBackingScaleFactor,
      displayPixelWidth: displayPixelWidth,
      displayPixelHeight: displayPixelHeight,
      workload: workload,
      frameClock: frameClock,
      applicationActivationObserved: applicationActivationObserved,
      probeWindowBecameKey: probeWindowBecameKey,
      displayMaximumFramesPerSecond: maximumFramesPerSecond,
      requiredFramesPerSecond: targetFramesPerSecond,
      displayRequirementSatisfied: displayRequirementSatisfied,
      workloadCompleted: workloadCompleted,
      inputCharacterCount: inputCharacterCount,
      operationDurationMilliseconds: operationDurationMilliseconds,
      streamPresentationUpdateCount: streamPresentationUpdateCount,
      maximumStreamPresentationBatchCharacterCount:
        maximumStreamPresentationBatchCharacterCount,
      historyEntryCount: historyEntryCount,
      totalHistoryEntryCount: totalHistoryEntryCount,
      scrollDistancePoints: scrollDistancePoints,
      outputCharacterCount: outputCharacterCount,
      normalScrollDistancePoints: normalScrollDistancePoints,
      hyperScrollDistancePoints: hyperScrollDistancePoints,
      maximumScrollStepPoints: maximumScrollStepPoints,
      historyLoadDurationMilliseconds: historyLoadDurationMilliseconds,
      initialRenderDurationMilliseconds: initialRenderDurationMilliseconds,
      databaseBytes: databaseBytes,
      currentResidentMemoryBytes: currentResidentMemoryBytes,
      peakResidentMemoryBytes: peakResidentMemoryBytes,
      workflowPhase: workflowPhase,
      phaseFramePacing: phaseFramePacing,
      minimumMeasuredFramesPerSecond: minimumMeasuredFramesPerSecond,
      sampleCount: timestamps.count,
      interactionCount: interactionCount,
      measuredFramesPerSecond: measuredFPS,
      meanFrameTimeMilliseconds: mean * 1_000,
      p95FrameTimeMilliseconds: p95 * 1_000,
      p99FrameTimeMilliseconds: p99 * 1_000,
      maximumFrameTimeMilliseconds: (sorted.last ?? 0) * 1_000,
      maximumFrameSampleIndex: intervals.enumerated().max(by: { $0.element < $1.element })
        .map { $0.offset + 1 },
      maximumFrameEvent: intervals.enumerated().max(by: { $0.element < $1.element })
        .flatMap { maximum in
          eventLabels.indices.contains(maximum.offset) ? eventLabels[maximum.offset] : nil
        },
      workloadCompletionSampleIndex: workloadCompletionSampleIndex,
      missedFrameSampleIndices: Array(missedFrameSampleIndices.prefix(64)),
      missedFrameEvents: Array(missedFrameEvents.prefix(64)),
      missedFrameSampleIndicesTruncated: missedFrameSampleIndices.count > 64,
      missedFrameBudgetCount: missedBudgets,
      passed: passed
    )
  }

  private static func percentile(_ sortedValues: [Double], _ percentile: Double) -> Double {
    guard !sortedValues.isEmpty else { return .infinity }
    let index = Int((Double(sortedValues.count - 1) * percentile).rounded(.up))
    return sortedValues[min(index, sortedValues.count - 1)]
  }

  private static func makePhaseReports(
    timestamps: [CFTimeInterval],
    phaseLabels: [String],
    expectedInterval: Double
  ) -> [String: PhaseFramePacingReport] {
    guard timestamps.count > 1, phaseLabels.count == timestamps.count else { return [:] }
    var intervalsByPhase: [String: [Double]] = [:]
    for index in 1..<timestamps.count {
      intervalsByPhase[phaseLabels[index], default: []].append(
        timestamps[index] - timestamps[index - 1]
      )
    }
    return intervalsByPhase.mapValues { intervals in
      let sorted = intervals.sorted()
      let mean = intervals.reduce(0, +) / Double(intervals.count)
      return PhaseFramePacingReport(
        sampleCount: intervals.count,
        meanFrameTimeMilliseconds: mean * 1_000,
        p95FrameTimeMilliseconds: percentile(sorted, 0.95) * 1_000,
        p99FrameTimeMilliseconds: percentile(sorted, 0.99) * 1_000,
        maximumFrameTimeMilliseconds: (sorted.last ?? 0) * 1_000,
        missedFrameBudgetCount: intervals.count(where: { $0 > expectedInterval * 1.5 })
      )
    }
  }

  private static func hardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
      return "unknown"
    }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else {
      return "unknown"
    }
    let bytes = value.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }

  private static func thermalStateDescription(
    _ state: ProcessInfo.ThermalState
  ) -> String {
    switch state {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }
}

private enum ProcessMemory {
  static func currentResidentBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(
          mach_task_self_,
          task_flavor_t(MACH_TASK_BASIC_INFO),
          rebound,
          &count
        )
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Int64(clamping: info.resident_size)
  }

  static func peakResidentBytes() -> Int64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Int64(usage.ru_maxrss)
  }
}
