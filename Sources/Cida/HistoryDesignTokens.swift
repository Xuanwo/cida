import CoreGraphics

/// Pencil geometry shared by every history renderer. Values mirror the `Entry`
/// component, the `States — 记录操作` folded card, and the `Motion — 历史折叠`
/// board in `Design/cida.pen`.
enum HistoryEntryPencilLayout {
  static let actionIconSize: CGFloat = 12
  static let actionGap: CGFloat = 12
  static let actionColumnWidth = actionIconSize + actionGap

  /// Folded cards use a 10 pt inset on every side and an 8 pt radius.
  static let foldedInset: CGFloat = 10
  static let foldedCornerRadius: CGFloat = 8
  /// The Stream frame stacks entries without a gap; consecutive folded cards
  /// keep one `Entry` gap between them so their fills do not merge.
  static let foldedCardGap: CGFloat = 8
  static let foldedHeaderHeight: CGFloat = 16
  static let foldedContentSpacing: CGFloat = 8
  static let expandedVerticalPadding: CGFloat = 16

  /// `font-size-body` × `line-height-body` (16 × 1.6, rounded to whole points).
  static let resultLineHeight: CGFloat = 26
  static let foldedPreviewLineLimit = 2
  static let foldedPreviewHeight = resultLineHeight * CGFloat(foldedPreviewLineLimit)
  static let foldedPreviewFadeHeight: CGFloat = 25

  static let latestSourceLineLimit = 2
  static let latestSourceLineHeight: CGFloat = 13 * 1.55
  static let latestSourcePreviewHeight = ceil(
    latestSourceLineHeight * CGFloat(latestSourceLineLimit)
  )
  static let latestSourceFadeHeight: CGFloat = 20

  static let foldedHeight =
    foldedInset * 2 + foldedHeaderHeight + foldedContentSpacing + foldedPreviewHeight
  static let foldedRowStride = foldedHeight + foldedCardGap

  static func foldedListHeight(rowCount: Int) -> CGFloat {
    guard rowCount > 0 else { return 0 }
    return CGFloat(rowCount) * foldedRowStride - foldedCardGap
  }
}
