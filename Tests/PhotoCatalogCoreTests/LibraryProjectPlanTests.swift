import Foundation
import Testing

@testable import PhotoCatalogCore

@Test func emptyProjectProducesVisibleReviewBlocker() {
  let plan = LibraryProjectPlan(
    project: LibraryProject(),
    catalog: CatalogSnapshot(),
    reviewState: LibraryProjectReviewState()
  )

  #expect(plan.currentAssetIDs.isEmpty)
  #expect(plan.blockers.contains(.noCurrentAssets))
  #expect(
    plan.cleanupBlockers == [.destructiveOperationsNotSupported, .archiveProtectionUnverified])
}

@Test func assetsWithoutPeopleDefaultToVisibleIncludeAndBothArchives() throws {
  try withPlanFixture(files: ["photo.jpg": Data("photo".utf8)]) { project, catalog in
    let plan = LibraryProjectPlan(
      project: project,
      catalog: catalog,
      reviewState: LibraryProjectReviewState()
    )

    #expect(plan.currentAssetIDs.count == 1)
    #expect(plan.apple.visibleAssetIDs == plan.currentAssetIDs)
    #expect(plan.google.includedAssetIDs == plan.currentAssetIDs)
    #expect(plan.archives.assetIDs == plan.currentAssetIDs)
    #expect(plan.blockers.contains(.applePhotosNotConnected))
    #expect(plan.blockers.contains(.destinationNotConfigured(.googleReadyExport)))
    #expect(plan.blockers.contains(.destinationNotConfigured(.archiveOne)))
    #expect(plan.blockers.contains(.destinationNotConfigured(.archiveTwo)))
  }
}

@Test func filenameCandidateBlocksPlanUntilItsPairIsReviewed() throws {
  try withPlanFixture(
    files: [
      "first/shared.jpg": Data("first".utf8),
      "second/shared.jpg": Data("second".utf8),
    ]
  ) { project, catalog in
    let duplicateIndex = CatalogDuplicateIndex(snapshot: catalog)
    let group = try #require(
      duplicateIndex.groups.first { $0.evidence.contains(.exactFilename) }
    )
    let first = group.occurrences[0]
    let second = group.occurrences[1]
    let unresolved = LibraryProjectPlan(
      project: project,
      catalog: catalog,
      reviewState: LibraryProjectReviewState(),
      duplicateIndex: duplicateIndex
    )
    #expect(
      unresolved.blockers.contains { blocker in
        if case .unresolvedDuplicatePairs(let ids) = blocker { return ids.count == 1 }
        return false
      })

    var review = LibraryProjectReviewState()
    review.setDuplicatePairDisposition(
      .rejected,
      first: first,
      second: second
    )
    let resolved = LibraryProjectPlan(
      project: project,
      catalog: catalog,
      reviewState: review,
      duplicateIndex: duplicateIndex
    )
    #expect(
      !resolved.blockers.contains { blocker in
        if case .unresolvedDuplicatePairs = blocker { return true }
        return false
      })
    #expect(resolved.currentAssetIDs.count == 2)
  }
}

@Test func confirmedDuplicatesProduceOneRetainedLogicalAsset() throws {
  try withPlanFixture(
    files: [
      "first/shared.jpg": Data("first".utf8),
      "second/shared.jpg": Data("second".utf8),
    ]
  ) { project, catalog in
    let duplicateIndex = CatalogDuplicateIndex(snapshot: catalog)
    let pair = try #require(duplicateIndex.pairs.first)
    var review = LibraryProjectReviewState()
    review.setDuplicatePairDisposition(
      .confirmedDuplicate,
      first: pair.first,
      second: pair.second
    )

    let plan = LibraryProjectPlan(
      project: project,
      catalog: catalog,
      reviewState: review,
      duplicateIndex: duplicateIndex
    )

    #expect(plan.currentAssetIDs.count == 1)
    #expect(plan.archives.assetIDs == plan.currentAssetIDs)
  }
}

@Test func oneMatchingResourceDoesNotCollapseDistinctCompoundAssets() throws {
  func measuredResource(
    externalID: String,
    role: ResourceRole,
    filename: String,
    sha256: String,
    byteCount: Int64
  ) -> ProviderResourceObservation {
    ProviderResourceObservation(
      externalID: externalID,
      role: role,
      filename: filename,
      mediaType: role == .pairedVideo ? "video/quicktime" : "image/heic",
      localReadState: .measured,
      localMeasurement: LocalResourceMeasurement(
        sha256: sha256,
        md5: String(repeating: String(sha256.first ?? "0"), count: 32),
        byteCount: byteCount
      )
    )
  }
  let observations = [
    ApplePhotoObservation(
      localIdentifier: "compound-a",
      kind: .photo,
      resources: [
        measuredResource(
          externalID: "photo|0",
          role: .primary,
          filename: "a.heic",
          sha256: String(repeating: "a", count: 64),
          byteCount: 10
        ),
        measuredResource(
          externalID: "pairedVideo|0",
          role: .pairedVideo,
          filename: "a.mov",
          sha256: String(repeating: "b", count: 64),
          byteCount: 20
        ),
      ],
      metadata: [:]
    ),
    ApplePhotoObservation(
      localIdentifier: "compound-b",
      kind: .photo,
      resources: [
        measuredResource(
          externalID: "photo|0",
          role: .primary,
          filename: "b.heic",
          sha256: String(repeating: "a", count: 64),
          byteCount: 10
        ),
        measuredResource(
          externalID: "pairedVideo|0",
          role: .pairedVideo,
          filename: "b.mov",
          sha256: String(repeating: "c", count: 64),
          byteCount: 30
        ),
      ],
      metadata: [:]
    ),
  ]
  let importedAt = Date(timeIntervalSinceReferenceDate: 1_000)
  let catalog = try ApplePhotosCatalogBuilder.build(
    observations: observations,
    sourceIdentity: ApplePhotosSourceIdentity(
      sourceLibraryID: "apple-library",
      externalAccountID: "system-library:test"
    ),
    importedAt: importedAt
  )
  var project = LibraryProject(createdAt: importedAt)
  project.recordImport(
    LibraryProjectSource(
      id: "apple-library",
      provider: .applePhotos,
      kind: .applePhotos,
      externalAccountID: "system-library:test",
      displayName: "Apple Photos",
      addedAt: importedAt,
      lastImportedAt: importedAt,
      itemCount: 2
    ),
    at: importedAt
  )

  let plan = LibraryProjectPlan(
    project: project,
    catalog: catalog,
    reviewState: LibraryProjectReviewState()
  )

  #expect(plan.currentAssetIDs.count == 2)
}

@Test func everyPairInALargerFilenameGroupRequiresReview() throws {
  try withPlanFixture(
    files: [
      "first/shared.jpg": Data("first".utf8),
      "second/shared.jpg": Data("second".utf8),
      "third/shared.jpg": Data("third".utf8),
    ]
  ) { project, catalog in
    let duplicateIndex = CatalogDuplicateIndex(snapshot: catalog)
    let plan = LibraryProjectPlan(
      project: project,
      catalog: catalog,
      reviewState: LibraryProjectReviewState(),
      duplicateIndex: duplicateIndex
    )

    #expect(
      plan.blockers.contains { blocker in
        if case .unresolvedDuplicatePairs(let ids) = blocker { return ids.count == 3 }
        return false
      })
  }
}

@Test func contradictoryTransitiveDecisionsBlockAndDoNotCollapseAssets() throws {
  try withPlanFixture(
    files: [
      "first/shared.jpg": Data("first".utf8),
      "second/shared.jpg": Data("second".utf8),
      "third/shared.jpg": Data("third".utf8),
    ]
  ) { project, catalog in
    let duplicateIndex = CatalogDuplicateIndex(snapshot: catalog)
    let occurrences = try #require(
      duplicateIndex.groups.first { $0.occurrences.count == 3 }
    ).occurrences
    let firstSecond = try #require(
      duplicateIndex.pair(between: occurrences[0].id, and: occurrences[1].id)
    )
    let secondThird = try #require(
      duplicateIndex.pair(between: occurrences[1].id, and: occurrences[2].id)
    )
    let firstThird = try #require(
      duplicateIndex.pair(between: occurrences[0].id, and: occurrences[2].id)
    )
    var review = LibraryProjectReviewState()
    review.setDuplicatePairDisposition(
      .confirmedDuplicate,
      first: firstSecond.first,
      second: firstSecond.second
    )
    review.setDuplicatePairDisposition(
      .confirmedDuplicate,
      first: secondThird.first,
      second: secondThird.second
    )
    review.setDuplicatePairDisposition(
      .rejected,
      first: firstThird.first,
      second: firstThird.second
    )

    let plan = LibraryProjectPlan(
      project: project,
      catalog: catalog,
      reviewState: review,
      duplicateIndex: duplicateIndex
    )

    #expect(plan.currentAssetIDs.count == 3)
    #expect(
      plan.blockers.contains { blocker in
        if case .contradictoryDuplicatePairs(let ids) = blocker { return ids == [firstThird.id] }
        return false
      })
  }
}

@Test func oversizedFilenameGroupBlocksWithoutQuadraticPairMaterialization() throws {
  let files = Dictionary(
    uniqueKeysWithValues: (0..<101).map { index in
      ("\(index)/shared.jpg", Data("value-\(index)".utf8))
    }
  )
  try withPlanFixture(files: files) { project, catalog in
    let duplicateIndex = CatalogDuplicateIndex(snapshot: catalog)
    let oversizedGroupID = try #require(duplicateIndex.oversizedGroupIDs.first)
    let oversizedGroup = try #require(
      duplicateIndex.groups.first { $0.id == oversizedGroupID }
    )
    let occurrenceIDs = Set(oversizedGroup.occurrences.map(\.id))

    #expect(
      duplicateIndex.pairs.allSatisfy { pair in
        !occurrenceIDs.contains(pair.first.id) || !occurrenceIDs.contains(pair.second.id)
      })
    let plan = LibraryProjectPlan(
      project: project,
      catalog: catalog,
      reviewState: LibraryProjectReviewState(),
      duplicateIndex: duplicateIndex
    )
    #expect(plan.blockers.contains(.duplicateGroupsTooLarge([oversizedGroupID])))
  }
}

@Test func largeExactGroupUsesLinearAutomaticEdges() throws {
  let files = Dictionary(
    uniqueKeysWithValues: (0..<101).map { index in
      ("\(index)/copy-\(index).jpg", Data("identical".utf8))
    }
  )
  try withPlanFixture(files: files) { project, catalog in
    let duplicateIndex = CatalogDuplicateIndex(snapshot: catalog)

    #expect(duplicateIndex.pairs.count == 100)
    #expect(duplicateIndex.pairs.allSatisfy { $0.isAutomatic })
    #expect(duplicateIndex.oversizedGroupIDs.isEmpty)
    let plan = LibraryProjectPlan(
      project: project,
      catalog: catalog,
      reviewState: LibraryProjectReviewState(),
      duplicateIndex: duplicateIndex
    )
    #expect(plan.currentAssetIDs.count == 1)
  }
}

@Test func cumulativeExactGroupsDoNotConsumeTheReviewPairBudget() throws {
  var files: [String: Data] = [:]
  for group in 0..<3 {
    for index in 0..<101 {
      files["exact-\(group)/\(index)/copy-\(group)-\(index).jpg"] = Data(
        "identical-\(group)".utf8)
    }
  }
  files["review-a/shared.jpg"] = Data("review-a".utf8)
  files["review-b/shared.jpg"] = Data("review-b".utf8)

  try withPlanFixture(files: files) { _, catalog in
    let duplicateIndex = CatalogDuplicateIndex(snapshot: catalog)

    #expect(duplicateIndex.oversizedGroupIDs.isEmpty)
    #expect(duplicateIndex.pairs.count == 301)
    #expect(duplicateIndex.pairs.count { !$0.isAutomatic } == 1)
  }
}

@Test func largeEquivalentCompoundGroupProducesOneRetainedAsset() throws {
  let observations = (0..<101).map { index in
    ApplePhotoObservation(
      localIdentifier: "compound-\(index)",
      kind: .photo,
      resources: [
        ProviderResourceObservation(
          externalID: "photo|0",
          role: .primary,
          filename: "photo-\(index).heic",
          mediaType: "image/heic",
          localReadState: .measured,
          localMeasurement: LocalResourceMeasurement(
            sha256: String(repeating: "a", count: 64),
            md5: String(repeating: "a", count: 32),
            byteCount: 10
          )
        ),
        ProviderResourceObservation(
          externalID: "pairedVideo|0",
          role: .pairedVideo,
          filename: "video-\(index).mov",
          mediaType: "video/quicktime",
          localReadState: .measured,
          localMeasurement: LocalResourceMeasurement(
            sha256: String(repeating: "b", count: 64),
            md5: String(repeating: "b", count: 32),
            byteCount: 20
          )
        ),
      ],
      metadata: [:]
    )
  }
  let importedAt = Date(timeIntervalSinceReferenceDate: 1_000)
  let catalog = try ApplePhotosCatalogBuilder.build(
    observations: observations,
    sourceIdentity: ApplePhotosSourceIdentity(
      sourceLibraryID: "apple-library",
      externalAccountID: "system-library:test"
    ),
    importedAt: importedAt
  )
  var project = LibraryProject(createdAt: importedAt)
  project.recordImport(
    LibraryProjectSource(
      id: "apple-library",
      provider: .applePhotos,
      kind: .applePhotos,
      externalAccountID: "system-library:test",
      displayName: "Apple Photos",
      addedAt: importedAt,
      lastImportedAt: importedAt,
      itemCount: observations.count
    ),
    at: importedAt
  )

  let plan = LibraryProjectPlan(
    project: project,
    catalog: catalog,
    reviewState: LibraryProjectReviewState()
  )

  #expect(plan.currentAssetIDs.count == 1)
}

@Test func configuredDistinctDestinationsCompleteNonDestructiveRouting() throws {
  try withPlanFixture(files: ["photo.jpg": Data("photo".utf8)]) { initialProject, catalog in
    let date = Date(timeIntervalSinceReferenceDate: 1_000)
    var project = initialProject
    project.recordImport(
      LibraryProjectSource(
        id: "apple-library",
        provider: .applePhotos,
        kind: .applePhotos,
        externalAccountID: "system-library:test",
        displayName: "Apple Photos",
        addedAt: date,
        lastImportedAt: date,
        itemCount: 0
      ),
      at: date
    )
    project.setDestination(
      destination("Google", volume: "volume-google", date: date),
      for: .googleReadyExport,
      at: date
    )
    project.setDestination(
      destination("Archive One", volume: "volume-one", date: date),
      for: .archiveOne,
      at: date
    )
    project.setDestination(
      destination("Archive Two", volume: "volume-two", date: date),
      for: .archiveTwo,
      at: date
    )

    let plan = LibraryProjectPlan(
      project: project,
      catalog: catalog,
      reviewState: LibraryProjectReviewState()
    )

    #expect(plan.isConfigurationComplete)
    #expect(plan.archives.configuredSlots == [.archiveOne, .archiveTwo])
    #expect(plan.cleanupBlockers.contains(.archiveProtectionUnverified))
  }
}

private func withPlanFixture(
  files: [String: Data],
  body: (LibraryProject, CatalogSnapshot) throws -> Void
) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  for (relativePath, data) in files {
    let fileURL = directory.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL)
  }
  let date = Date(timeIntervalSinceReferenceDate: 1_000)
  let catalog = try FilesystemCatalogImporter().importCatalog(from: directory, importedAt: date)
  let library = catalog.sourceLibraries[0]
  var project = LibraryProject(createdAt: date)
  project.recordImport(
    LibraryProjectSource(
      id: library.id,
      provider: .filesystem,
      kind: .folder,
      externalAccountID: library.externalAccountID,
      displayName: "Fixture",
      bookmarkData: Data("bookmark".utf8),
      addedAt: date,
      lastImportedAt: date,
      itemCount: catalog.sourceItems.count
    ),
    at: date
  )
  try body(project, catalog)
}

private func destination(
  _ name: String,
  volume: String,
  date: Date
) -> ProjectDirectoryDestination {
  ProjectDirectoryDestination(
    displayName: name,
    directoryBookmarkData: Data("bookmark-\(name)".utf8),
    volumeUUID: volume,
    configuredAt: date
  )
}
