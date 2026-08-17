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
    .target(
      name: "CDisplayClock",
      path: "Sources/CDisplayClock",
      linkerSettings: [
        .linkedFramework("CoreVideo")
      ]
    ),
    .executableTarget(
      name: "Cida",
      dependencies: ["CSQLite", "CDisplayClock"],
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
