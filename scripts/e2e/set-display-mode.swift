// Switches the main display to a Retina mode of the given size in points, for the Tart guest:
// macOS keeps the resolution the golden image was saved with, whatever `tart set --display`
// offers. Exits non-zero when the display has no such mode.
//
//   swift scripts/e2e/set-display-mode.swift <width> <height>
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3, let width = Int(arguments[1]), let height = Int(arguments[2]) else {
  FileHandle.standardError.write(Data("usage: set-display-mode.swift <width> <height>\n".utf8))
  exit(64)
}
let display = CGMainDisplayID()
let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
guard
  let mode = modes.first(where: {
    $0.width == width && $0.height == height && $0.pixelWidth == width * 2
      && $0.isUsableForDesktopGUI()
  })
else {
  FileHandle.standardError.write(Data("The display has no \(width)x\(height) Retina mode\n".utf8))
  exit(69)
}
var configuration: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&configuration) == .success,
  CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil) == .success,
  CGCompleteDisplayConfiguration(configuration, .permanently) == .success
else {
  FileHandle.standardError.write(Data("Switching to \(width)x\(height) failed\n".utf8))
  exit(70)
}
print("\(width)x\(height) pt")
