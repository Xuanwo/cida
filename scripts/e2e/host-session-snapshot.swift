#!/usr/bin/swift

import AppKit
import Foundation

struct RunningApplication: Codable {
  let bundleIdentifier: String?
  let executablePath: String?
  let processIdentifier: Int32
}

struct HostSessionSnapshot: Codable {
  let capturedAt: String
  let frontmostApplication: RunningApplication?
  let pasteboardChangeCount: Int
  let productionCidaApplications: [RunningApplication]
}

func record(_ application: NSRunningApplication) -> RunningApplication {
  RunningApplication(
    bundleIdentifier: application.bundleIdentifier,
    executablePath: application.executableURL?.path,
    processIdentifier: application.processIdentifier
  )
}

let snapshot = HostSessionSnapshot(
  capturedAt: ISO8601DateFormatter().string(from: Date()),
  frontmostApplication: NSWorkspace.shared.frontmostApplication.map(record),
  pasteboardChangeCount: NSPasteboard.general.changeCount,
  productionCidaApplications: NSRunningApplication
    .runningApplications(withBundleIdentifier: "com.xuanwo.Cida")
    .map(record)
    .sorted { $0.processIdentifier < $1.processIdentifier }
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(snapshot))
FileHandle.standardOutput.write(Data("\n".utf8))
