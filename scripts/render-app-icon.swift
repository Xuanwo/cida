#!/usr/bin/env swift
// Renders the app icon the way macOS draws it in Finder and the Dock, with the system's icon
// grid, edge and shadow, for the READMEs' header:
//
//   swift scripts/render-app-icon.swift
//
// Writes docs/images/icon.png. Run it on macOS 26 or later after changing Resources/AppIcon.icon;
// an older system draws the flat macOS 15 fallback instead. The light icon is drawn whatever the
// appearance, because Icon Services follows the system's icon style setting, not the process.

import AppKit

let projectURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
let pixels = 256

// Icon Services draws an icon only for a bundle it can launch, so the compiled icon goes into a
// throwaway app whose executable is /usr/bin/true.
let bundleURL = FileManager.default.temporaryDirectory
  .appendingPathComponent("cida-icon-\(UUID().uuidString).app")
defer { try? FileManager.default.removeItem(at: bundleURL) }
let contentsURL = bundleURL.appendingPathComponent("Contents")
let resourcesURL = contentsURL.appendingPathComponent("Resources")
let executableURL = contentsURL.appendingPathComponent("MacOS/Icon")
try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(
  at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executableURL)
let info: [String: Any] = [
  "CFBundleIdentifier": "io.xuanwo.cida.icon-render.\(UUID().uuidString)",
  "CFBundleExecutable": "Icon",
  "CFBundlePackageType": "APPL",
  "CFBundleIconName": "AppIcon",
  "CFBundleIconFile": "AppIcon",
  "LSMinimumSystemVersion": "15.0",
]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
  .write(to: contentsURL.appendingPathComponent("Info.plist"))

let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/bin/zsh")
compile.arguments = [
  projectURL.appendingPathComponent("scripts/compile-app-icon.sh").path, resourcesURL.path,
]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }

let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
  bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!
  .write(to: projectURL.appendingPathComponent("docs/images/icon.png"))
