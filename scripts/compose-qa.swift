import AppKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("usage: compose-qa.swift <source.png> <implementation.png> <output.png>\n", stderr)
    exit(2)
}

let sourcePath = CommandLine.arguments[1]
let implementationPath = CommandLine.arguments[2]
let outputPath = CommandLine.arguments[3]

guard
    let sourceData = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)),
    let implementationData = try? Data(contentsOf: URL(fileURLWithPath: implementationPath)),
    let sourceRepresentation = NSBitmapImageRep(data: sourceData),
    let implementationRepresentation = NSBitmapImageRep(data: implementationData)
else {
    fputs("failed to load a comparison image\n", stderr)
    exit(1)
}

let gap: CGFloat = 16
let sourceSize = NSSize(
    width: sourceRepresentation.pixelsWide,
    height: sourceRepresentation.pixelsHigh
)
let implementationSize = NSSize(
    width: implementationRepresentation.pixelsWide,
    height: implementationRepresentation.pixelsHigh
)
let source = NSImage(size: sourceSize)
source.addRepresentation(sourceRepresentation)
let implementation = NSImage(size: implementationSize)
implementation.addRepresentation(implementationRepresentation)
let width = sourceSize.width + gap + implementationSize.width
let height = max(sourceSize.height, implementationSize.height)
guard let outputRepresentation = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width),
    pixelsHigh: Int(height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("failed to create comparison bitmap\n", stderr)
    exit(1)
}
outputRepresentation.size = NSSize(width: width, height: height)
guard let context = NSGraphicsContext(bitmapImageRep: outputRepresentation) else {
    fputs("failed to create comparison context\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
source.draw(
    in: NSRect(x: 0, y: 0, width: sourceSize.width, height: sourceSize.height),
    from: NSRect.zero,
    operation: NSCompositingOperation.copy,
    fraction: 1
)
implementation.draw(
    in: NSRect(
        x: sourceSize.width + gap,
        y: 0,
        width: implementationSize.width,
        height: implementationSize.height
    ),
    from: NSRect.zero,
    operation: NSCompositingOperation.copy,
    fraction: 1
)
NSGraphicsContext.restoreGraphicsState()

guard
    let png = outputRepresentation.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
else {
    fputs("failed to encode comparison image\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath), options: Data.WritingOptions.atomic)
