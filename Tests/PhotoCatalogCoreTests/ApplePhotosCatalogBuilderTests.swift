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

@Test func duplicateIndexDoesNotCompareResourcesFromTheSameSourceItem() throws {
  let observations = [
    ApplePhotoObservation(
      localIdentifier: "asset-1",
      kind: .photo,
      resources: [
        ProviderResourceObservation(
          externalID: "photo|0",
          role: .primary,
          filename: "shared.jpg",
          mediaType: "image/jpeg",
          localReadState: .requiresNetwork
        ),
        ProviderResourceObservation(
          externalID: "photo|1",
          role: .primary,
          filename: "shared.jpg",
          mediaType: "image/jpeg",
          localReadState: .requiresNetwork
        ),
      ],
      metadata: [:]
    ),
    ApplePhotoObservation(
      localIdentifier: "asset-2",
      kind: .photo,
      resources: [
        ProviderResourceObservation(
          externalID: "photo|0",
          role: .primary,
          filename: "shared.jpg",
          mediaType: "image/jpeg",
          localReadState: .requiresNetwork
        )
      ],
      metadata: [:]
    ),
  ]
  let snapshot = try ApplePhotosCatalogBuilder.build(
    observations: observations,
    sourceIdentity: ApplePhotosSourceIdentity(
      sourceLibraryID: "library:apple",
      externalAccountID: "system-library:test"
    )
  )
  let pairs = CatalogDuplicateIndex(snapshot: snapshot).pairs

  #expect(pairs.count == 2)
  #expect(pairs.allSatisfy { $0.first.sourceItemID != $0.second.sourceItemID })
}

@Test func removedAppleResourceRemainsHistoryButIsNotCurrentMatchEvidence() throws {
  func observation(_ localIdentifier: String, filenames: [String]) -> ApplePhotoObservation {
    ApplePhotoObservation(
      localIdentifier: localIdentifier,
      kind: .photo,
      resources: filenames.enumerated().map { index, filename in
        ProviderResourceObservation(
          externalID: "photo|\(index)",
          role: .primary,
          filename: filename,
          mediaType: "image/jpeg",
          localReadState: .requiresNetwork
        )
      },
      metadata: [:]
    )
  }
  let identity = ApplePhotosSourceIdentity(
    sourceLibraryID: "library:apple",
    externalAccountID: "system-library:test"
  )
  let first = try ApplePhotosCatalogBuilder.build(
    observations: [
      observation("asset-1", filenames: ["kept.jpg", "shared.jpg"]),
      observation("asset-2", filenames: ["shared.jpg"]),
    ],
    sourceIdentity: identity,
    importedAt: Date(timeIntervalSinceReferenceDate: 1_000)
  )
  let second = try ApplePhotosCatalogBuilder.build(
    observations: [
      observation("asset-1", filenames: ["kept.jpg"]),
      observation("asset-2", filenames: ["shared.jpg"]),
    ],
    sourceIdentity: identity,
    importedAt: Date(timeIntervalSinceReferenceDate: 2_000)
  )
  let merged = try CatalogMerge.merging(second, into: first)

  #expect(merged.sourceResources.count == 3)
  #expect(CatalogDuplicateIndex(snapshot: merged).pairs.isEmpty)
  let currentItems = Dictionary(uniqueKeysWithValues: merged.sourceItems.map { ($0.id, $0) })
  #expect(
    merged.sourceResources.count { resource in
      resource.latestObservationID == currentItems[resource.sourceItemID]?.latestObservationID
    } == 2)
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
