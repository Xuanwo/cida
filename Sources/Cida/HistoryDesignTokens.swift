import CoreGraphics

enum HistoryEntryPencilLayout {
  static let actionIconSize: CGFloat = 12
  static let actionGap: CGFloat = 12
  static let actionColumnWidth = actionIconSize + actionGap
  static let foldedHorizontalInset: CGFloat = 0
  static let foldedVerticalInset: CGFloat = 10
  static let foldedHeaderHeight: CGFloat = 16
  static let foldedPreviewHeight: CGFloat = 52
  static let foldedContentSpacing: CGFloat = 8
  static let latestSourceLineLimit = 2
  static let latestSourceLineHeight: CGFloat = 13 * 1.55
  static let latestSourcePreviewHeight = ceil(
    latestSourceLineHeight * CGFloat(latestSourceLineLimit)
  )
  static let latestSourceFadeHeight: CGFloat = 20
  static let foldedHeight =
    foldedVerticalInset * 2 + foldedHeaderHeight + foldedContentSpacing + foldedPreviewHeight
  static let foldedRowStride = foldedHeight + 1
}
