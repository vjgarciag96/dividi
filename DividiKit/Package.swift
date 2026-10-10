// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "DividiKit",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "DividiKit", targets: ["DividiKit"])
  ],
  targets: [
    .target(name: "DividiKit"),
    .testTarget(name: "DividiKitTests", dependencies: ["DividiKit"]),
  ]
)
