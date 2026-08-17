import AppKit

enum SnapshotWriter {
  @MainActor
  static func write(window: NSWindow, to outputURL: URL) throws {
    guard let contentView = window.contentView else {
      throw SnapshotError.missingContentView
    }
    let view = contentView.superview ?? contentView

    window.displayIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()

    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw SnapshotError.cannotCreateBitmap
    }

    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw SnapshotError.cannotEncodePNG
    }

    try data.write(to: outputURL, options: .atomic)
  }
}

enum SnapshotError: LocalizedError {
  case missingContentView
  case cannotCreateBitmap
  case cannotEncodePNG

  var errorDescription: String? {
    switch self {
    case .missingContentView: "The window has no content view."
    case .cannotCreateBitmap: "The window content could not create a bitmap representation."
    case .cannotEncodePNG: "The window snapshot could not be encoded as PNG."
    }
  }
}
