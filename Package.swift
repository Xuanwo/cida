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
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
  ],
  targets: [
    .executableTarget(
      name: "Cida",
      dependencies: [
        .product(name: "Sparkle", package: "Sparkle")
      ],
      resources: [
        .process("Resources")
      ],
      linkerSettings: [
        // The app bundle carries Sparkle.framework in Contents/Frameworks; `swift run` finds it
        // next to the executable in the build directory.
        .unsafeFlags([
          "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
          "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
        ])
      ]
    ),
    .testTarget(
      name: "CidaTests",
      dependencies: ["Cida"],
      path: "Tests",
      exclude: ["CidaTests/Fixtures"],
      sources: ["CidaTests", "Shared"]
    ),
  ]
)
