import CoreGraphics

/// Pencil geometry shared by every history renderer. Values mirror the `Entry`
/// component and the `Spec — 历史折叠 v2` rules in `Design/cida.pen`.
enum HistoryEntryPencilLayout {
  static let actionIconSize: CGFloat = 12
  static let actionGap: CGFloat = 12
  static let actionColumnWidth = actionIconSize + actionGap

  /// The window keeps 28 pt beside the content column; wider windows centre a
  /// column of at most `readingWidth` (`reading-width`).
  static let windowHorizontalPadding: CGFloat = 28
  static let readingWidth: CGFloat = 804

  /// Hovering a historical record tints the whole row; the tint extends past
  /// the text column on both sides (`space-hover-bleed`) with the card radius.
  static let hoverBleed: CGFloat = 10
  static let hoverCornerRadius: CGFloat = 8

  static let verticalPadding: CGFloat = 16
  static let headerHeight: CGFloat = 16
  static let contentSpacing: CGFloat = 8
  static let separatorHeight: CGFloat = 1

  /// `font-size-body` × `line-height-body` (16 × 1.6, rounded to whole points).
  static let resultLineHeight: CGFloat = 26
  /// A historical record shows at most two result lines at rest; a longer
  /// result is clipped there under the fade and expands on click.
  static let foldedPreviewLineLimit = 2
  static let foldedPreviewHeight = resultLineHeight * CGFloat(foldedPreviewLineLimit)
  static let foldedPreviewFadeHeight: CGFloat = 25

  static let latestSourceLineLimit = 2
  static let latestSourceLineHeight: CGFloat = 13 * 1.55
  static let latestSourcePreviewHeight = ceil(
    latestSourceLineHeight * CGFloat(latestSourceLineLimit)
  )
  static let latestSourceFadeHeight: CGFloat = 20

  /// Height of a historical record at rest, excluding its separator: the meta
  /// row plus one or two result lines (Pencil 82 / 108).
  static func historyRowHeight(previewLineCount: Int) -> CGFloat {
    let visibleLines = min(foldedPreviewLineLimit, max(1, previewLineCount))
    return verticalPadding * 2 + headerHeight + contentSpacing
      + resultLineHeight * CGFloat(visibleLines)
  }

  static let foldedHeight = historyRowHeight(previewLineCount: foldedPreviewLineLimit)
  /// Unloaded history rows are drawn as folded placeholders with a separator.
  static let placeholderRowStride = foldedHeight + separatorHeight

  /// The preview height that fits inside a row of `rowHeight` (separator
  /// excluded), clamped to the one-to-two-line range.
  static func previewHeight(forRowHeight rowHeight: CGFloat) -> CGFloat {
    let available = rowHeight - verticalPadding * 2 - headerHeight - contentSpacing
    return min(foldedPreviewHeight, max(resultLineHeight, available))
  }
}
