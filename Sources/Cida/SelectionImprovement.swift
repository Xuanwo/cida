import Foundation

struct ImprovementFeedback: Equatable {
  let text: String
  var action: String? = nil
  var dismissAfter: Double? = nil
}

/// A background improvement has its own captured editor and request lifetime. It does not
/// borrow the panel's current source, action or streamed presentation state.
@MainActor
final class SelectionImprovement {
  private let service: any TextProcessingService
  private let capture: @MainActor () -> (any SelectionReplacementTarget)?
  var onFeedback: (ImprovementFeedback?) -> Void = { _ in }
  var onResult: (ResultRecord) -> Void = { _ in }
  var recordEvent: (String) -> Void = { _ in }
  private(set) var result: ResultRecord?
  private(set) var isApplying = false
  var isRunning: Bool { task != nil }
  private var task: Task<Void, Never>?
  private var requestID: UUID?
  private var target: (any SelectionReplacementTarget)?
  private var showsFeedback = true

  init(
    service: any TextProcessingService,
    capture: @escaping @MainActor () -> (any SelectionReplacementTarget)? = AccessibilitySelectionTarget.capture
  ) {
    self.service = service
    self.capture = capture
  }

  func trigger(settings: CidaSettings) {
    if isRunning { cancel(); return }
    result = nil
    showsFeedback = true
    guard let target = capture() else {
      onFeedback(ImprovementFeedback(text: "请先选中要改进的文字", dismissAfter: 2.5))
      recordEvent("improvement-no-selection")
      return
    }
    self.target = target
    let id = UUID()
    requestID = id
    onFeedback(ImprovementFeedback(text: "正在改进…", action: "取消"))
    recordEvent("improvement-started")
    task = Task { [weak self] in
      await self?.generate(target: target, settings: settings, id: id)
    }
  }

  func cancel() {
    // A dispatched paste cannot be recalled. Its confirmation owns the clipboard until
    // it finishes; do not claim that already-dispatched work has been cancelled.
    guard isRunning, !isApplying else { return }
    requestID = nil
    task?.cancel()
    task = nil
    target?.stopObserving()
    target = nil
    result = nil
    onFeedback(ImprovementFeedback(text: "已取消", dismissAfter: 1.5))
    recordEvent("improvement-cancelled")
  }

  /// Another Cida entry point takes over. Confirmation may finish without showing a hint
  /// over that entry point, but it still settles clipboard ownership.
  func dismiss() {
    cancel()
    showsFeedback = false
    onFeedback(nil)
  }

  func performFeedbackAction() {
    if isRunning { cancel(); return }
    guard let result else { return }
    onFeedback(nil)
    onResult(result)
  }

  private func generate(
    target: any SelectionReplacementTarget, settings: CidaSettings, id: UUID
  ) async {
    defer {
      target.stopObserving()
      if requestID == id {
        self.target = nil
        task = nil
        isApplying = false
      }
    }
    let languages = settings.requestLanguages
    let request = ProcessingRequest(
      text: target.text, mode: .improve, myLanguage: languages.my, foreignLanguage: languages.foreign)
    var output = ""
    do {
      for try await chunk in service.stream(request, settings: settings) {
        try Task.checkCancellation()
        guard requestID == id else { return }
        output += chunk
      }
      try Task.checkCancellation()
      guard requestID == id else { return }
      guard SelectedText.normalized(output) != nil else { throw ModelServiceError.emptyResult }
      output = Self.preservingWhitespace(of: target.text, around: output)
      isApplying = true
      onFeedback(ImprovementFeedback(text: "正在确认替换…"))
      let outcome = await target.replace(with: output)
      guard requestID == id else { return }
      let record = makeResult(source: target.text, output: output, phase: .completed)
      record.replacementNote = outcome.note
      result = record
      recordEvent("improvement-\(outcome)")
      guard showsFeedback else { return }
      switch outcome {
      case .replaced, .unchanged:
        onFeedback(ImprovementFeedback(text: outcome.note, dismissAfter: 1.5))
      case .unavailable:
        onFeedback(ImprovementFeedback(text: "已改进 · 原文未替换", action: "查看结果"))
      case .unconfirmed:
        onFeedback(ImprovementFeedback(text: "请检查原文 · 替换结果未确认", action: "查看结果"))
      }
    } catch {
      guard requestID == id, !Task.isCancelled else { return }
      result = makeResult(
        source: target.text, output: output, phase: .failed(message: error.localizedDescription))
      recordEvent("improvement-failed")
      if showsFeedback {
        onFeedback(ImprovementFeedback(text: "改进失败 · 原文未变", action: "查看结果"))
      }
    }
  }

  private func makeResult(source: String, output: String, phase: ResultPhase) -> ResultRecord {
    ResultRecord(
      mode: .improve, source: source,
      outputLanguage: TextLanguageDetector.typography(of: output) ?? .english,
      result: output, phase: phase)
  }

  static func preservingWhitespace(of source: String, around output: String) -> String {
    let prefix = source.prefix(while: { $0.isWhitespace })
    let suffix = source.reversed().prefix(while: { $0.isWhitespace }).reversed()
    return String(prefix) + output.trimmingCharacters(in: .whitespacesAndNewlines) + String(suffix)
  }
}
