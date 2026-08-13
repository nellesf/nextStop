// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "NextStopCore",
  defaultLocalization: "de",
  platforms: [
    .iOS(.v18),
    .macOS(.v14),
  ],
  products: [
    .library(name: "NextStopCore", targets: ["NextStopCore"])
  ],
  targets: [
    .target(name: "NextStopCore"),
    .testTarget(
      name: "NextStopCoreTests",
      dependencies: ["NextStopCore"]
    ),
  ]
)
