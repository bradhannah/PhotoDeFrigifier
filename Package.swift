// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "PhotoDeFrigifier",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .library(name: "PhotoCatalogCore", targets: ["PhotoCatalogCore"]),
    .library(name: "ProviderAccessCore", targets: ["ProviderAccessCore"]),
    .executable(name: "PhotoDeFrigifierApp", targets: ["PhotoDeFrigifierApp"]),
    .executable(name: "ProviderAccessLab", targets: ["ProviderAccessLab"]),
  ],
  targets: [
    .target(
      name: "PhotoCatalogCore"
    ),
    .target(
      name: "ProviderAccessCore",
      linkerSettings: [
        .linkedFramework("Photos")
      ]
    ),
    .executableTarget(
      name: "PhotoDeFrigifierApp",
      dependencies: ["PhotoCatalogCore"]
    ),
    .executableTarget(
      name: "ProviderAccessLab",
      dependencies: ["PhotoCatalogCore", "ProviderAccessCore"]
    ),
    .testTarget(
      name: "PhotoCatalogCoreTests",
      dependencies: ["PhotoCatalogCore"]
    ),
    .testTarget(
      name: "ProviderAccessCoreTests",
      dependencies: ["ProviderAccessCore"]
    ),
  ]
)
