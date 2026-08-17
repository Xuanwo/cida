// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Cida",
  defaultLocalization: "zh-Hans",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "Cida", targets: ["Cida"])
  ],
  targets: [
    .systemLibrary(
      name: "CSQLite",
      path: "Sources/CSQLite"
    ),
    .executableTarget(
      name: "Cida",
      dependencies: ["CSQLite"],
      resources: [
        .process("Resources")
      ]
    ),
    .testTarget(
      name: "CidaTests",
      dependencies: ["Cida", "CSQLite"],
      path: "Tests",
      exclude: ["CidaTests/Fixtures"],
      sources: ["CidaTests", "Shared"]
    ),
  ]
)
