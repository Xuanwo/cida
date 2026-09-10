import AppKit
import QuartzCore
import SwiftUI

struct NativeHistoryEntryView: NSViewRepresentable {
  let entry: HistoryEntry
  let presentation: HistoryPresentation
  let showsSeparator: Bool
  let animatesTransitions: Bool
  let onExpand: @MainActor () -> Void
  let onCollapse: @MainActor () -> Void
  let onRedo: @MainActor () -> Void
  let onCopySource: @MainActor () -> Void
  let onCopyResult: @MainActor () -> Void

  func makeNSView(context: Context) -> HistoryEntryNSView {
    let view = HistoryEntryNSView()
    configure(view, animated: false)
    return view
  }

  func updateNSView(_ view: HistoryEntryNSView, context: Context) {
    configure(view, animated: animatesTransitions && view.presentation != presentation)
  }

  static func dismantleNSView(_ view: HistoryEntryNSView, coordinator: Void) {
    view.detachStandalonePresentation()
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView view: HistoryEntryNSView,
    context _: Context
  ) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    return CGSize(width: width, height: view.preferredHeight(for: width))
  }

  private func configure(_ view: HistoryEntryNSView, animated: Bool) {
    switch presentation {
    case .folded:
      if animated, view.presentation.isExpanded {
        view.configureFolding(
          entryID: entry.id,
          mode: entry.mode,
          metadata: entry.metadata,
          source: entry.source,
          preview: entry.resultStorage.foldedPreview,
          resultStorage: entry.resultStorage,
          state: entry.state,
          isLongEntry: entry.isLongDocument,
          showsSeparator: showsSeparator,
          animated: true,
          onExpand: onExpand,
          onRedo: onRedo,
          onCopyResult: onCopyResult
        )
      } else {
        view.configure(
          entryID: entry.id,
          mode: entry.mode,
          metadata: entry.metadata,
          preview: entry.resultStorage.foldedPreview,
          state: entry.state,
          showsSeparator: showsSeparator,
          animated: animated,
          onExpand: onExpand,
          onRedo: onRedo,
          onCopyResult: onCopyResult
        )
      }
    case .current, .manuallyExpanded:
      view.configureExpanded(
        entryID: entry.id,
        mode: entry.mode,
        metadata: entry.metadata,
        source: entry.source,
        preview: entry.resultStorage.foldedPreview,
        resultStorage: entry.resultStorage,
        presentationRevision: entry.presentationRevision,
        latestPresentationDelta: entry.latestPresentationDelta,
        state: entry.state,
        presentation: presentation,
        isLongEntry: entry.isLongDocument,
        showsSeparator: showsSeparator,
        animated: animated,
        onCollapse: onCollapse,
        onRedo: onRedo,
        onCopySource: onCopySource,
        onCopyResult: onCopyResult
      )
    }
  }
}
