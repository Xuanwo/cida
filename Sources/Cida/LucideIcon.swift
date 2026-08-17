import AppKit
import SwiftUI

enum LucideIconName: String, CaseIterable {
  case languages
  case sparkles
  case scanText = "scan-text"
  case arrowLeftRight = "arrow-left-right"
  case arrowUp = "arrow-up"
  case rotateCounterclockwise = "rotate-ccw"
  case copy
  case check
}

@MainActor
enum LucideIconAsset {
  private static var cache: [LucideIconName: NSImage] = [:]

  static func image(for name: LucideIconName) -> NSImage? {
    if let cached = cache[name] { return cached }
    guard
      let url = CidaResourceBundle.bundle.url(
        forResource: name.rawValue,
        withExtension: "svg",
        subdirectory: "Icons"
      ) ?? CidaResourceBundle.bundle.url(forResource: name.rawValue, withExtension: "svg"),
      let image = NSImage(contentsOf: url)
    else {
      return nil
    }
    image.isTemplate = true
    cache[name] = image
    return image
  }
}

struct LucideIcon: View {
  let name: LucideIconName
  let size: CGFloat

  init(_ name: LucideIconName, size: CGFloat) {
    self.name = name
    self.size = size
  }

  var body: some View {
    Group {
      if let image = LucideIconAsset.image(for: name) {
        Image(nsImage: image)
          .resizable()
          .renderingMode(.template)
          .scaledToFit()
      }
    }
    .frame(width: size, height: size)
  }
}
