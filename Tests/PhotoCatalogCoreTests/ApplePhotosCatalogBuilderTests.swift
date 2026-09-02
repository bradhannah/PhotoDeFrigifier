import Foundation
import Testing

@testable import PhotoCatalogCore

@Test func appleBuilderCreatesMeasuredAndDeferredResources() throws {
  let identity = ApplePhotosSourceIdentity(
    sourceLibraryID: "library:apple",
    externalAccountID: "system-library:test"
  )
  let observation = ApplePhotoObservation(
    localIdentifier: "asset-1",
    kind: .photo,
    resources: [
      ProviderResourceObservation(
        externalID: "photo|0",
        role: .primary,
        filename: "photo.heic",
        mediaType: "image/heic",
        width: 4_032,
        height: 3_024,
        nativeResourceType: "photo",
        localReadState: .measured,
        localMeasurement: LocalResourceMeasurement(
          sha256: String(repeating: "a", count: 64),
          md5: String(repeating: "b", count: 32),
          byteCount: 1_024
        )
      ),
      ProviderResourceObservation(
        externalID: "pairedVideo|0",
        role: .pairedVideo,
        filename: "photo.mov",
        mediaType: "video/quicktime",
        nativeResourceType: "pairedVideo",
        localReadState: .requiresNetwork
      ),
    ],
    metadata: [
      "favorite": .boolean(true),
      "pixelWidth": .integer(4_032),
    ]
  )

  let snapshot = try ApplePhotosCatalogBuilder.build(
    observations: [observation],
    sourceIdentity: identity,
    importedAt: Date(timeIntervalSinceReferenceDate: 1_000)
  )

  #expect(snapshot.sourceLibraries[0].provider == .applePhotos)
  #expect(snapshot.assets.count == 1)
  #expect(snapshot.sourceResources.count == 2)
  #expect(snapshot.byteResources.count == 1)
  #expect(snapshot.byteResources[0].locallyMeasuredMD5 == String(repeating: "b", count: 32))
  #expect(snapshot.assetResourceLinks.count == 1)
  #expect(snapshot.metadataClaims.contains { $0.field == "apple.favorite" })
  try CatalogJSONLStore.validate(snapshot)
}

@Test func appleBuilderIsDeterministicAcrossObservationOrdering() throws {
  let identity = ApplePhotosSourceIdentity(
    sourceLibraryID: "library:apple",
    externalAccountID: "system-library:test"
  )
  let first = ApplePhotoObservation(
    localIdentifier: "asset-a",
    kind: .photo,
    resources: [],
    metadata: [:]
  )
  let second = ApplePhotoObservation(
    localIdentifier: "asset-b",
    kind: .video,
    resources: [],
    metadata: [:]
  )
  let importedAt = Date(timeIntervalSinceReferenceDate: 2_000)

  let forward = try ApplePhotosCatalogBuilder.build(
    observations: [first, second],
    sourceIdentity: identity,
    importedAt: importedAt
  )
  let reverse = try ApplePhotosCatalogBuilder.build(
    observations: [second, first],
    sourceIdentity: identity,
    importedAt: importedAt
  )

  #expect(forward == reverse)
}

@Test func appleBuilderRejectsIncompleteMeasurement() {
  let observation = ApplePhotoObservation(
    localIdentifier: "asset-1",
    kind: .photo,
    resources: [
      ProviderResourceObservation(
        externalID: "photo|0",
        role: .primary,
        localReadState: .measured
      )
    ],
    metadata: [:]
  )

  #expect(throws: ApplePhotosCatalogBuildError.invalidMeasurement) {
    try ApplePhotosCatalogBuilder.build(
      observations: [observation],
      sourceIdentity: ApplePhotosSourceIdentity(
        sourceLibraryID: "library:apple",
        externalAccountID: "system-library:test"
      )
    )
  }
}

@Test func appleIdentityAnchorsRejectAChangedSystemLibrary() throws {
  #expect(
    try ApplePhotosCatalogBuilder.updatedIdentityAnchors(
      previous: [],
      incoming: ["asset-c", "asset-a", "asset-b"],
      limit: 2
    ) == ["asset-a", "asset-b"]
  )
  #expect(
    try ApplePhotosCatalogBuilder.updatedIdentityAnchors(
      previous: ["asset-a", "asset-b"],
      incoming: ["asset-b", "asset-c"],
      limit: 2
    ) == ["asset-b", "asset-c"]
  )
  #expect(throws: ApplePhotosCatalogBuildError.sourceLibraryChanged) {
    try ApplePhotosCatalogBuilder.updatedIdentityAnchors(
      previous: ["asset-a", "asset-b"],
      incoming: ["asset-c", "asset-d"]
    )
  }
}
