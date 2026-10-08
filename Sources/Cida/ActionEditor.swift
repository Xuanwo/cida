import Foundation
import Observation

/// One Settings draft and its sample results, kept for the lifetime of the application.
/// Applied actions live only in CidaSettings; previews never replace the panel's result.
@MainActor
@Observable
final class ActionEditor {
  static let sample = """
    想跟你同步一下，原定周五的分享会要改到下周三下午三点，地点还是二楼会议室。主要是因为演示还没准备好，有几处细节想再确认一下。如果这个时间不方便，麻烦明天中午前告诉我，我们再一起看看怎么安排。
    """

  struct Draft: Equatable {
    var action: TextAction
    let original: TextAction?
    var isDirty: Bool { action != original }
  }

  struct Preview {
    let prompt: String
    let fingerprint: String
    let languages: (my: String, foreign: String)
    var text: String

    func matches(_ action: TextAction, settings: CidaSettings) -> Bool {
      prompt == action.prompt && fingerprint == settings.modelServiceFingerprint
        && languages == settings.requestLanguages
    }
  }

  struct Attempt {
    enum Phase { case running, stopped, failed(ProcessingFailure) }
    var preview: Preview
    var phase: Phase
    let saved: Bool

    var failure: ProcessingFailure? {
      if case .failed(let failure) = phase { return failure }
      return nil
    }
  }

  private enum Undo {
    case draft(Draft)
    case deletion(TextAction, Int)
  }

  var selected: ProcessingMode = .translate
  var draft: Draft?
  private(set) var previews: [ProcessingMode: Preview] = [:]
  private(set) var running: ProcessingMode?
  private(set) var error: String?
  private(set) var notice: String?
  private(set) var attempts: [ProcessingMode: Attempt] = [:]
  @ObservationIgnored private var undo: Undo?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var requestID = UUID()
  @ObservationIgnored private let service: any TextProcessingService

  init(service: any TextProcessingService) { self.service = service }
  var isDirty: Bool { draft?.isDirty == true }

  func select(_ id: ProcessingMode) {
    guard !isDirty, running == nil else { return }
    draft = nil
    selected = id
    error = nil
  }

  func begin(_ settings: CidaSettings) {
    guard draft == nil, let action = settings.actions.first(where: { $0.id == selected }) else {
      return
    }
    draft = Draft(action: action, original: action)
    error = nil
  }

  func create(_ settings: CidaSettings) {
    guard !isDirty, running == nil else { return }
    var number = 1
    while settings.actions.contains(where: { $0.name == "新动作 \(number)" }) { number += 1 }
    let action = TextAction(
      id: ProcessingMode(rawValue: UUID().uuidString), name: "新动作 \(number)", prompt: "")
    draft = Draft(action: action, original: nil)
    selected = action.id
    error = nil
  }

  func restoreDefault() {
    guard let id = draft?.action.id, id == .translate || id == .improve else { return }
    draft?.action.prompt = CidaSettings.defaultPrompt(for: id)
  }

  @discardableResult
  func apply(to settings: inout CidaSettings) -> Bool {
    guard var action = draft?.action else { return false }
    action.name = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
    action.prompt = action.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !action.name.isEmpty else {
      error = "给动作起一个名字"
      return false
    }
    guard !settings.actions.contains(where: { $0.id != action.id && $0.name == action.name }) else {
      error = "已经有同名的动作了"
      return false
    }
    guard !action.prompt.isEmpty else {
      error = "写下你希望这个动作做什么"
      return false
    }
    if let index = settings.actions.firstIndex(where: { $0.id == action.id }) {
      settings.actions[index] = action
    } else {
      settings.actions.append(action)
    }
    draft = nil
    error = nil
    notice = nil
    undo = nil
    if !needsConfiguration(settings: settings),
      previews[action.id]?.matches(action, settings: settings) != true || attempts[action.id] != nil {
      runPreview(action, settings: settings, saved: true)
    }

    return true
  }

  func discard(settings: CidaSettings) {
    guard let discarded = draft else { return }
    if discarded.isDirty {
      undo = .draft(discarded)
      notice = discarded.original == nil ? "已放弃新建「\(discarded.action.name)」" : "已放弃修改"
    }
    draft = nil
    error = nil
    if !settings.actions.contains(where: { $0.id == selected }) {
      selected = settings.actions.first?.id ?? .translate
    }
  }

  func delete(_ id: ProcessingMode, from settings: inout CidaSettings) {
    guard id != .translate else {
      error = "「翻译」用于截图翻译与原处翻译，不能删除"
      return
    }
    if draft?.action.id == id, draft?.original == nil {
      discard(settings: settings)
      return
    }
    guard let index = settings.actions.firstIndex(where: { $0.id == id }) else { return }
    let action = settings.actions.remove(at: index)
    undo = .deletion(action, index)
    notice = "已删除「\(action.name)」"
    if running == id { stopPreview() }
    draft = nil
    error = nil
    selected = settings.actions[min(index, settings.actions.count - 1)].id
  }

  func undoChange(settings: inout CidaSettings) {
    guard !isDirty, let undo else { return }
    switch undo {
    case .draft(let value):
      draft = value
      selected = value.action.id
    case .deletion(let action, let index):
      guard !settings.actions.contains(where: { $0.id == action.id }) else { return }
      settings.actions.insert(action, at: min(index, settings.actions.count))
      selected = action.id
    }
    self.undo = nil
    notice = nil
    error = nil
  }

  func move(_ id: ProcessingMode, to destination: Int, settings: inout CidaSettings) {
    guard !isDirty, running == nil, let source = settings.actions.firstIndex(where: { $0.id == id }) else { return }
    let action = settings.actions.remove(at: source)
    settings.actions.insert(action, at: max(0, min(destination, settings.actions.count)))
  }

  #if DEBUG
    func setPreviewForDesign(settings: CidaSettings, phase: Attempt.Phase? = nil,
      saved: Bool = false, reference: Bool = true, partial: String = "") {
      selected = .improve
      let snapshot = Preview(prompt: settings.improvementPrompt,
        fingerprint: settings.modelServiceFingerprint, languages: settings.requestLanguages,
        text: "原定周五的分享会调整至下周三下午三点，地点仍为二楼会议室。演示尚需完善，部分细节仍待确认。如时间不便，请于明天中午前告知，以便另行安排。")
      if reference {
        previews[selected] = Preview(prompt: saved ? "Previous policy" : snapshot.prompt,
          fingerprint: snapshot.fingerprint, languages: snapshot.languages, text: snapshot.text)
      }
      if let phase {
        var output = snapshot
        output.text = partial
        attempts[selected] = Attempt(preview: output, phase: phase, saved: saved)
        if case .running = phase { running = selected }
      }
    }
  #endif

  /// Browsing never requests a preview. Only an explicit run or applying a draft does.
  func trySavedAction(settings: CidaSettings) {
    guard draft == nil, running == nil, !needsConfiguration(settings: settings),
      let action = settings.actions.first(where: { $0.id == selected }) else { return }
    runPreview(action, settings: settings, saved: false)
  }

  func needsConfiguration(settings: CidaSettings) -> Bool {
    guard let attempt = attempts[selected], attempt.failure?.category == .configuration,
      let action = settings.actions.first(where: { $0.id == selected }) else { return false }
    return attempt.preview.matches(action, settings: settings)
  }

  func stopPreview() {
    task?.cancel()
    task = nil
    requestID = UUID()
    if let running { attempts[running]?.phase = .stopped }
    running = nil
  }

  private func runPreview(_ action: TextAction, settings: CidaSettings, saved: Bool) {
    stopPreview()
    let languages = settings.requestLanguages
    attempts[action.id] = Attempt(
      preview: Preview(prompt: action.prompt, fingerprint: settings.modelServiceFingerprint,
        languages: languages, text: ""), phase: .running, saved: saved)
    guard service.isConfigured(by: settings) else {
      attempts[action.id]?.phase = .failed(ProcessingFailure(category: .configuration, settings: settings))
      return
    }
    let id = UUID()
    requestID = id
    running = action.id
    let request = ProcessingRequest(
      text: Self.sample, mode: action.id,
      myLanguage: languages.my, foreignLanguage: languages.foreign)
    let service = service
    task = Task { [weak self] in
      do {
        for try await chunk in service.stream(request, settings: settings) {
          try Task.checkCancellation()
          guard let self, self.requestID == id else { return }
          self.attempts[action.id]?.preview.text += chunk
        }
        try Task.checkCancellation()
        guard let self, self.requestID == id else { return }
        guard let result = self.attempts[action.id]?.preview, !result.text.isEmpty else {
          throw ModelServiceError.emptyResult
        }
        self.previews[action.id] = result
        self.attempts[action.id] = nil
        self.running = nil
        self.task = nil
      } catch {
        guard let self, self.requestID == id else { return }
        self.attempts[action.id]?.phase = error is CancellationError ? .stopped
          : .failed(ProcessingFailure(error: error, settings: settings))
        self.running = nil
        self.task = nil
      }
    }
  }
}
