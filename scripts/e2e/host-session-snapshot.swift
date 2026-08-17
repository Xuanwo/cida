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
  let frontmostApplicationMatchesMonitoredArtifact: Bool
  let monitoredArtifactApplications: [RunningApplication]
  let pasteboardChangeCount: Int
  let productionCidaApplications: [RunningApplication]
}

let timestampFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()

func record(_ application: NSRunningApplication) -> RunningApplication {
  RunningApplication(
    bundleIdentifier: application.bundleIdentifier,
    executablePath: application.executableURL?.path,
    processIdentifier: application.processIdentifier
  )
}

func normalizedPath(_ path: String) -> String {
  URL(fileURLWithPath: path)
    .standardizedFileURL
    .resolvingSymlinksInPath()
    .path
}

func belongsToMonitoredArtifact(
  _ application: NSRunningApplication,
  roots: [String]
) -> Bool {
  guard let executablePath = application.executableURL?.path else { return false }
  let normalizedExecutablePath = normalizedPath(executablePath)
  return roots.contains { root in
    normalizedExecutablePath == root || normalizedExecutablePath.hasPrefix(root + "/")
  }
}

func makeSnapshot(monitoredArtifactRoots: [String] = []) -> HostSessionSnapshot {
  let normalizedRoots = monitoredArtifactRoots.map(normalizedPath)
  let runningApplications = NSWorkspace.shared.runningApplications
  let frontmostApplication = NSWorkspace.shared.frontmostApplication
  return HostSessionSnapshot(
    capturedAt: timestampFormatter.string(from: Date()),
    frontmostApplication: frontmostApplication.map(record),
    frontmostApplicationMatchesMonitoredArtifact: frontmostApplication.map {
      belongsToMonitoredArtifact($0, roots: normalizedRoots)
    } ?? false,
    monitoredArtifactApplications:
      runningApplications
      .filter { belongsToMonitoredArtifact($0, roots: normalizedRoots) }
      .map(record)
      .sorted { $0.processIdentifier < $1.processIdentifier },
    pasteboardChangeCount: NSPasteboard.general.changeCount,
    productionCidaApplications:
      runningApplications
      .filter { $0.bundleIdentifier == "com.xuanwo.Cida" }
      .map(record)
      .sorted { $0.processIdentifier < $1.processIdentifier }
  )
}

func emit(_ snapshot: HostSessionSnapshot, prettyPrinted: Bool) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
  FileHandle.standardOutput.write(try encoder.encode(snapshot))
  FileHandle.standardOutput.write(Data("\n".utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--monitor" {
  guard
    arguments.count >= 3,
    let intervalSeconds = Double(arguments[1]),
    intervalSeconds > 0
  else {
    FileHandle.standardError.write(
      Data(
        "Usage: host-session-snapshot.swift --monitor <interval-seconds> <artifact-app>...\n".utf8)
    )
    exit(64)
  }
  let monitoredArtifactRoots = Array(arguments.dropFirst(2))
  while true {
    try emit(
      makeSnapshot(monitoredArtifactRoots: monitoredArtifactRoots),
      prettyPrinted: false
    )
    Thread.sleep(forTimeInterval: intervalSeconds)
  }
}

guard arguments.isEmpty else {
  FileHandle.standardError.write(Data("Usage: host-session-snapshot.swift\n".utf8))
  exit(64)
}
try emit(makeSnapshot(), prettyPrinted: true)
