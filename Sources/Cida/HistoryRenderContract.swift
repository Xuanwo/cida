enum HistoryEntryActionPolicy {
  static func presentationState(
    isHovering: Bool,
    state: HistoryEntryState,
    copiedAction: RecordAction? = nil
  ) -> RecordActionPresentationState {
    if let copiedAction {
      return .copied(copiedAction)
    }
    return isHovering && state != .streaming ? .visible : .hidden
  }

  static func showsActions(isHovering: Bool, state: HistoryEntryState) -> Bool {
    presentationState(isHovering: isHovering, state: state) == .visible
  }
}

enum HistoryPresentation: Equatable, Sendable {
  case folded
  case current
  case manuallyExpanded

  var isExpanded: Bool {
    self != .folded
  }
}

enum HistoryContentPresentation: Equatable, Sendable {
  case foldedPreview
  case sourceAndResult
}

enum HistoryDisclosureAction: Equatable, Sendable {
  case expand
  case collapse
  case none
}

struct HistoryRenderContract: Equatable, Sendable {
  let presentation: HistoryPresentation
  let content: HistoryContentPresentation
  let disclosureAction: HistoryDisclosureAction
  let accessibilityLabelPrefix: String
  let accessibilityValue: String

  init(presentation: HistoryPresentation) {
    self.presentation = presentation
    switch presentation {
    case .folded:
      content = .foldedPreview
      disclosureAction = .expand
      accessibilityLabelPrefix = "历史记录"
      accessibilityValue = "collapsed"
    case .current:
      content = .sourceAndResult
      disclosureAction = .none
      accessibilityLabelPrefix = "当前历史记录"
      accessibilityValue = "expanded"
    case .manuallyExpanded:
      content = .sourceAndResult
      disclosureAction = .collapse
      accessibilityLabelPrefix = "展开的历史记录"
      accessibilityValue = "expanded"
    }
  }

  var showsSourceAndResult: Bool {
    content == .sourceAndResult
  }
}
