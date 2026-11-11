// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "PhotoDeFrigifier",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .library(name: "QuickFixCore", targets: ["QuickFixCore"]),
    .executable(name: "PhotoDeFrigifierApp", targets: ["PhotoDeFrigifierApp"]),
  ],
  targets: [
    // Review logic with no PhotoKit dependency: models, the JSON review store, queue ordering, date rules.
    .target(name: "QuickFixCore"),
    // The SwiftUI app: PhotoKit access, the review screen and the sheets.
    .executableTarget(
      name: "PhotoDeFrigifierApp",
      dependencies: ["QuickFixCore"],
      linkerSettings: [
        .linkedFramework("Photos"),
        .linkedFramework("AVKit"),
        .linkedFramework("CoreImage"),
      ]
    ),
    .testTarget(
      name: "QuickFixCoreTests",
      dependencies: ["QuickFixCore"]
    ),
  ]
)
