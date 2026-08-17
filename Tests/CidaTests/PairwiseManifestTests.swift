import Foundation
import XCTest

final class PairwiseManifestTests: XCTestCase {
  func testEnvironmentManifestCoversEveryPairWithAStableSeed() throws {
    let manifest = try loadManifest()
    XCTAssertEqual(manifest.version, 1)
    XCTAssertEqual(manifest.seed, 1_786_953_600)
    XCTAssertEqual(Set(manifest.cases.map(\.id)).count, manifest.cases.count)

    let dimensionNames = manifest.dimensions.keys.sorted()
    XCTAssertGreaterThanOrEqual(dimensionNames.count, 2)
    for caseDefinition in manifest.cases {
      XCTAssertEqual(Set(caseDefinition.values.keys), Set(dimensionNames))
      for dimension in dimensionNames {
        XCTAssertTrue(
          manifest.dimensions[dimension, default: []]
            .contains(try XCTUnwrap(caseDefinition.values[dimension]))
        )
      }
    }

    for firstIndex in dimensionNames.indices {
      for secondIndex in dimensionNames.indices where secondIndex > firstIndex {
        let first = dimensionNames[firstIndex]
        let second = dimensionNames[secondIndex]
        let expected = Set(
          manifest.dimensions[first, default: []].flatMap { firstValue in
            manifest.dimensions[second, default: []].map { secondValue in
              ValuePair(first: firstValue, second: secondValue)
            }
          }
        )
        let observed = Set(
          manifest.cases.compactMap { caseDefinition -> ValuePair? in
            guard
              let firstValue = caseDefinition.values[first],
              let secondValue = caseDefinition.values[second]
            else { return nil }
            return ValuePair(first: firstValue, second: secondValue)
          }
        )
        XCTAssertEqual(observed, expected, "Missing pairwise coverage for \(first) × \(second)")
      }
    }
  }

  func testPRGateIncludesEveryReleaseUITestSuite() throws {
    let repositoryRoot = repositoryRoot()
    let suiteDirectory = repositoryRoot.appendingPathComponent("UITests/CidaUITests")
    let suiteNames = try FileManager.default.contentsOfDirectory(
      at: suiteDirectory,
      includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasSuffix("Tests.swift") }
    .map { $0.deletingPathExtension().lastPathComponent }
    .sorted()
    let gateSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/e2e/run-gate.py"),
      encoding: .utf8
    )

    XCTAssertFalse(suiteNames.isEmpty)
    for suiteName in suiteNames {
      XCTAssertTrue(
        gateSource.contains("CidaUITests/\(suiteName)"),
        "The PR gate does not execute \(suiteName)"
      )
    }
  }

  private func loadManifest() throws -> PairwiseManifest {
    let url =
      repositoryRoot()
      .appendingPathComponent("UITests/Resources/Scenarios/pairwise-environment-v1.json")
    return try JSONDecoder().decode(PairwiseManifest.self, from: Data(contentsOf: url))
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

private struct PairwiseManifest: Decodable {
  let version: Int
  let seed: Int
  let dimensions: [String: [String]]
  let cases: [PairwiseCase]
}

private struct PairwiseCase: Decodable {
  let id: String
  let values: [String: String]

  private enum CodingKeys: String, CodingKey {
    case id
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    id = try container.decode(String.self, forKey: AnyCodingKey("id"))
    values = try container.allKeys.reduce(into: [:]) { result, key in
      guard key.stringValue != "id" else { return }
      result[key.stringValue] = try container.decode(String.self, forKey: key)
    }
  }
}

private struct AnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init(_ stringValue: String) {
    self.stringValue = stringValue
  }

  init?(stringValue: String) {
    self.init(stringValue)
  }

  init?(intValue: Int) {
    return nil
  }
}

private struct ValuePair: Hashable {
  let first: String
  let second: String
}
