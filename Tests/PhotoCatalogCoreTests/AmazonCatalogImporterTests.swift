import Foundation
import Testing

@testable import PhotoCatalogCore

@Test func amazonImportBuildsProvisionalCatalogWithoutPromotingMD5() throws {
  try withFixtureInventory { source in
    let importedAt = Date(timeIntervalSinceReferenceDate: 1_000)
    let snapshot = try AmazonCatalogImporter().importCatalog(
      from: source,
      importedAt: importedAt
    )

    #expect(snapshot.sourceLibraries.count == 1)
    #expect(snapshot.importRuns.count == 1)
    #expect(snapshot.assets.count == 2)
    #expect(snapshot.assets.allSatisfy { $0.resolutionState == .provisional })
    #expect(snapshot.sourceItems.count == 2)
    #expect(snapshot.sourceResources.count == 2)
    #expect(snapshot.byteResources.isEmpty)
    #expect(snapshot.assetResourceLinks.isEmpty)
    #expect(snapshot.sourcePeople.count == 1)
    #expect(snapshot.personNameClaims.count == 1)
    #expect(snapshot.personMembershipClaims.count == 1)
    #expect(snapshot.sourceObservations.count == 8)
    #expect(snapshot.metadataClaims.contains { $0.field == "date.providerCreated" })
    #expect(snapshot.metadataClaims.contains { $0.field == "date.embeddedOriginal" })

    let identity = CatalogIdentityIndex(snapshot: snapshot)
    #expect(identity.automaticMatches.isEmpty)
    #expect(identity.reportedDigestCandidates.count == 1)
    #expect(identity.reportedDigestCandidates[0].algorithm == "md5")
    #expect(identity.reportedDigestCandidates[0].sourceResourceIDs.count == 2)
    try CatalogJSONLStore.validate(snapshot)
  }
}

@Test func amazonImportIsDeterministicForTheSameSource() throws {
  try withFixtureInventory { source in
    let importedAt = Date(timeIntervalSinceReferenceDate: 2_000)
    let first = try AmazonCatalogImporter().importCatalog(from: source, importedAt: importedAt)
    let second = try AmazonCatalogImporter().importCatalog(from: source, importedAt: importedAt)

    #expect(first == second)
    #expect(try CatalogMerge.merging(second, into: first) == first)
  }
}

@Test func amazonVideoUsesVideoRoleWithStableResourceIdentity() throws {
  try withFixtureInventory(contentType: "video/mp4") { source in
    let snapshot = try AmazonCatalogImporter().importCatalog(from: source)

    #expect(snapshot.sourceResources.allSatisfy { $0.role == .video })
    #expect(
      snapshot.sourceResources.allSatisfy { resource in
        resource.id
          == CatalogStableID.make(
            prefix: "source-resource",
            components: [resource.sourceItemID, "primary"]
          )
      }
    )
  }
}

@Test func locallyMeasuredMD5CreatesReviewOnlyAmazonBridge() throws {
  try withFixtureInventory(
    digest: "900150983cd24fb0d6963f7d28e17f72",
    byteSize: 3
  ) { amazonURL in
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("abc".utf8).write(to: directory.appendingPathComponent("local.jpg"))

    let amazon = try AmazonCatalogImporter().importCatalog(from: amazonURL)
    let local = try FilesystemCatalogImporter().importCatalog(from: directory)
    let merged = try CatalogMerge.merging(local, into: amazon)
    let identity = CatalogIdentityIndex(snapshot: merged)

    #expect(identity.automaticMatches.isEmpty)
    #expect(identity.amazonMD5ReviewCandidates.count == 1)
    #expect(identity.amazonMD5ReviewCandidates[0].localSourceResourceIDs.count == 1)
    #expect(identity.amazonMD5ReviewCandidates[0].amazonSourceResourceIDs.count == 2)
  }
}

@Test func amazonMD5BridgeRequiresCompatibleResourceRoles() throws {
  try withFixtureInventory(
    digest: "900150983cd24fb0d6963f7d28e17f72",
    byteSize: 3
  ) { amazonURL in
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("abc".utf8).write(to: directory.appendingPathComponent("local.mov"))

    let amazon = try AmazonCatalogImporter().importCatalog(from: amazonURL)
    let local = try FilesystemCatalogImporter().importCatalog(from: directory)
    let merged = try CatalogMerge.merging(local, into: amazon)

    #expect(CatalogIdentityIndex(snapshot: merged).amazonMD5ReviewCandidates.isEmpty)
  }
}

@Test func amazonMD5BridgeExcludesFilesMissingFromCurrentScan() throws {
  try withFixtureInventory(
    digest: "900150983cd24fb0d6963f7d28e17f72",
    byteSize: 3
  ) { amazonURL in
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("local.jpg")
    try Data("abc".utf8).write(to: fileURL)

    let importer = FilesystemCatalogImporter()
    let first = try importer.importCatalog(
      from: directory,
      importedAt: Date(timeIntervalSinceReferenceDate: 1_000)
    )
    try FileManager.default.removeItem(at: fileURL)
    let identity = FilesystemSourceIdentity(
      sourceLibraryID: first.sourceLibraries[0].id,
      externalAccountID: try #require(first.sourceLibraries[0].externalAccountID)
    )
    let second = try importer.importCatalog(
      from: directory,
      importedAt: Date(timeIntervalSinceReferenceDate: 2_000),
      sourceIdentity: identity
    )
    let localHistory = try CatalogMerge.merging(second, into: first)
    let amazon = try AmazonCatalogImporter().importCatalog(from: amazonURL)
    let merged = try CatalogMerge.merging(amazon, into: localHistory)

    #expect(CatalogIdentityIndex(snapshot: merged).amazonMD5ReviewCandidates.isEmpty)
  }
}

@Test func oneReportedMD5RejectsAmbiguousLocalSHA256Anchors() throws {
  try withFixtureInventory(
    digest: "900150983cd24fb0d6963f7d28e17f72",
    byteSize: 3
  ) { amazonURL in
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("abc".utf8).write(to: directory.appendingPathComponent("first.jpg"))
    try Data("def".utf8).write(to: directory.appendingPathComponent("second.jpg"))

    var local = try FilesystemCatalogImporter().importCatalog(from: directory)
    local.byteResources = local.byteResources.map { resource in
      ByteResource(
        id: resource.id,
        sha256: resource.sha256,
        locallyMeasuredMD5: "900150983cd24fb0d6963f7d28e17f72",
        byteCount: resource.byteCount,
        verificationMethod: resource.verificationMethod,
        measuredAt: resource.measuredAt
      )
    }
    let amazon = try AmazonCatalogImporter().importCatalog(from: amazonURL)
    let merged = try CatalogMerge.merging(local, into: amazon)
    let candidates = CatalogIdentityIndex(snapshot: merged).amazonMD5ReviewCandidates

    #expect(candidates.isEmpty)
  }
}

@Test func confirmedAmazonMD5BridgePropagatesCanonicalPersonMembership() throws {
  try withFixtureInventory(
    digest: "900150983cd24fb0d6963f7d28e17f72",
    byteSize: 3
  ) { amazonURL in
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("abc".utf8).write(to: directory.appendingPathComponent("local.jpg"))

    let amazon = try AmazonCatalogImporter().importCatalog(from: amazonURL)
    let local = try FilesystemCatalogImporter().importCatalog(from: directory)
    let merged = try CatalogMerge.merging(local, into: amazon)
    let candidate = try #require(
      CatalogIdentityIndex(snapshot: merged).amazonMD5ReviewCandidates.first
    )
    let sourcePersonID = try #require(amazon.sourcePeople.first?.id)
    var review = LibraryProjectReviewState()
    review.createCanonicalPerson(
      preferredName: "Fixture Person",
      sourcePersonID: sourcePersonID,
      at: Date(timeIntervalSinceReferenceDate: 1_000)
    )
    let canonicalPersonID = try #require(review.canonicalPeople.first?.id)
    review.setPrivacyCategory(
      .neverCloud,
      for: canonicalPersonID,
      at: Date(timeIntervalSinceReferenceDate: 1_500)
    )
    let beforeConfirmation = CatalogPeopleIndex(snapshot: merged, reviewState: review)
    review.setDuplicateDisposition(
      .confirmedDuplicate,
      for: candidate.id,
      at: Date(timeIntervalSinceReferenceDate: 2_000)
    )
    let afterConfirmation = CatalogPeopleIndex(snapshot: merged, reviewState: review)

    #expect(beforeConfirmation.memberships.count == 1)
    #expect(afterConfirmation.memberships.count == 3)
    #expect(afterConfirmation.memberships.count(where: \.isPropagated) == 2)
    #expect(afterConfirmation.effectivePrivacyByAssetID.values.allSatisfy { $0 == .neverCloud })
  }
}

@Test func directPersonEvidenceDominatesPropagationRegardlessOfClaimOrder() throws {
  try withFixtureInventory(
    digest: "900150983cd24fb0d6963f7d28e17f72",
    byteSize: 3
  ) { amazonURL in
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("abc".utf8).write(to: directory.appendingPathComponent("local.jpg"))

    let amazon = try AmazonCatalogImporter().importCatalog(from: amazonURL)
    let local = try FilesystemCatalogImporter().importCatalog(from: directory)
    var merged = try CatalogMerge.merging(local, into: amazon)
    let secondItem = try #require(merged.sourceItems.first { $0.externalID == "photo-2" })
    let secondAsset = try #require(merged.assets.first { $0.sourceItemIDs.contains(secondItem.id) })
    let secondObservation = try #require(
      merged.sourceObservations.first { $0.id == secondItem.latestObservationID }
    )
    let sourcePersonID = try #require(amazon.sourcePeople.first?.id)
    let directClaim = PersonMembershipClaim(
      id: "second-direct-membership",
      sourcePersonID: sourcePersonID,
      sourceItemID: secondItem.id,
      assetID: secondAsset.id,
      importRunID: secondObservation.importRunID,
      observationID: secondObservation.id,
      confidence: 1
    )
    let candidate = try #require(
      CatalogIdentityIndex(snapshot: merged).amazonMD5ReviewCandidates.first
    )
    var review = LibraryProjectReviewState()
    review.createCanonicalPerson(
      preferredName: "Fixture Person",
      sourcePersonID: sourcePersonID
    )
    review.setDuplicateDisposition(.confirmedDuplicate, for: candidate.id)

    for claims in [
      merged.personMembershipClaims + [directClaim],
      [directClaim] + merged.personMembershipClaims,
    ] {
      merged.personMembershipClaims = claims
      let membership = try #require(
        CatalogPeopleIndex(snapshot: merged, reviewState: review).memberships.first {
          $0.assetID == secondAsset.id
        })
      #expect(!membership.isPropagated)
      #expect(membership.originatingClaimIDs.contains(directClaim.id))
    }
  }
}

@Test func amazonImportRejectsAnIncompleteSummary() throws {
  try withFixtureInventory(expectedPhotoCount: 3) { source in
    #expect(throws: AmazonCatalogImportError.invalidSummary) {
      try AmazonCatalogImporter().importCatalog(from: source)
    }
  }
}

@Test func amazonImportRequiresRootAccountIdentity() throws {
  try withFixtureInventory(includeRootMetadata: false) { source in
    #expect(throws: AmazonCatalogImportError.missingAccountIdentity) {
      try AmazonCatalogImporter().importCatalog(from: source)
    }
  }
}

@Test func personNameClaimRequiresItsPersonObservation() throws {
  try withFixtureInventory { source in
    var snapshot = try AmazonCatalogImporter().importCatalog(from: source)
    let claim = snapshot.personNameClaims[0]
    let membershipObservation = try #require(
      snapshot.sourceObservations.first { $0.recordType == "personMembership" }
    )
    snapshot.personNameClaims[0] = PersonNameClaim(
      id: claim.id,
      sourcePersonID: claim.sourcePersonID,
      importRunID: claim.importRunID,
      observationID: membershipObservation.id,
      displayName: claim.displayName,
      authorship: claim.authorship,
      confidence: claim.confidence,
      observedAt: claim.observedAt
    )

    #expect(throws: CatalogStoreError.self) {
      try CatalogJSONLStore.validate(snapshot)
    }
  }
}

@Test func repeatedAmazonImportPreservesEarlierClaimsAndUpdatesObservation() throws {
  let importedAt = Date(timeIntervalSinceReferenceDate: 3_000)
  try withFixtureInventory(createdDate: "2025-01-01T00:00:00Z") { firstSource in
    let first = try AmazonCatalogImporter().importCatalog(
      from: firstSource,
      importedAt: importedAt
    )
    try withFixtureInventory(createdDate: "2025-02-01T00:00:00Z") { secondSource in
      let second = try AmazonCatalogImporter().importCatalog(
        from: secondSource,
        importedAt: importedAt.addingTimeInterval(100)
      )
      let merged = try CatalogMerge.merging(second, into: first)

      #expect(merged.importRuns.count == 2)
      #expect(merged.assets.count == 2)
      #expect(merged.sourceItems.count == 2)
      #expect(merged.sourceObservations.count == 16)
      #expect(
        merged.metadataClaims.count == first.metadataClaims.count + second.metadataClaims.count)
      #expect(merged.personNameClaims.count == 2)
      #expect(
        merged.sourceItems[0].firstObservedImportRunID
          == first.sourceItems[0].firstObservedImportRunID
      )
      #expect(
        merged.sourceItems[0].latestObservationID == second.sourceItems[0].latestObservationID)
    }
  }
}

@Test func optInPrivateAmazonInventoryImportsWithoutDisclosingValues() throws {
  guard let path = ProcessInfo.processInfo.environment["AMAZON_INVENTORY_FILE"] else { return }

  let snapshot = try AmazonCatalogImporter().importCatalog(from: URL(fileURLWithPath: path))
  try CatalogJSONLStore.validate(snapshot)
  let roundTripURL = FileManager.default.temporaryDirectory.appendingPathComponent(
    "private-catalog-round-trip-\(UUID().uuidString).jsonl"
  )
  defer { try? FileManager.default.removeItem(at: roundTripURL) }
  try CatalogJSONLStore.write(snapshot, to: roundTripURL)
  let roundTripped = try CatalogJSONLStore.read(from: roundTripURL)

  #expect(!snapshot.assets.isEmpty)
  #expect(snapshot.assets.count == snapshot.sourceItems.count)
  #expect(snapshot.sourceItems.count == snapshot.sourceResources.count)
  #expect(roundTripped == snapshot)
  print(
    "PRIVATE_AMAZON_CATALOG assets=\(snapshot.assets.count) claims=\(snapshot.metadataClaims.count) people=\(snapshot.sourcePeople.count) personNames=\(snapshot.personNameClaims.count) memberships=\(snapshot.personMembershipClaims.count) observations=\(snapshot.sourceObservations.count) md5CandidateGroups=\(CatalogIdentityIndex(snapshot: snapshot).reportedDigestCandidates.count)"
  )
}

private func withFixtureInventory(
  expectedPhotoCount: Int = 2,
  createdDate: String = "2025-01-01T00:00:00Z",
  includeRootMetadata: Bool = true,
  contentType: String = "image/jpeg",
  digest: String = "0123456789abcdef0123456789abcdef",
  byteSize: Int = 1_024,
  body: (URL) throws -> Void
) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("amazon-inventory.jsonl")
  let photo1: [String: Any] = [
    "id": "photo-1",
    "ownerId": "account-1",
    "name": "first.jpg",
    "createdDate": createdDate,
    "modifiedDate": "2025-01-02T00:00:00Z",
    "status": "AVAILABLE",
    "settings": ["favorite": true],
    "contentProperties": [
      "contentDate": "2024-12-31T18:00:00Z",
      "contentType": contentType,
      "size": byteSize,
      "md5": digest,
      "image": [
        "width": 1_200,
        "height": 800,
        "dateTimeOriginal": "2024:12:31 18:00:00",
        "make": "Fixture Camera",
        "model": "One",
        "location": "0,0",
      ],
    ],
  ]
  let photo2: [String: Any] = [
    "id": "photo-2",
    "ownerId": "account-1",
    "name": "second.jpg",
    "createdDate": createdDate,
    "modifiedDate": "2025-01-03T00:00:00Z",
    "status": "AVAILABLE",
    "contentProperties": [
      "contentDate": "2024-12-31T18:00:00Z",
      "contentType": contentType,
      "size": byteSize,
      "md5": digest,
      "image": ["width": 1_200, "height": 800],
    ],
  ]
  var lines: [[String: Any]] = [
    [
      "recordType": "manifest",
      "schemaVersion": 1,
      "provider": "amazon",
      "capturedAt": "2025-01-04T00:00:00Z",
      "scope": "customer photos",
      "containsPrivateMetadata": true,
    ],
    ["recordType": "photoNode", "value": photo1],
    ["recordType": "photoNode", "value": photo2],
    ["recordType": "person", "personKey": "person-1", "name": "Fixture Person"],
    ["recordType": "personMembership", "personKey": "person-1", "photoNodeId": "photo-1"],
    ["recordType": "aggregations", "value": ["people": []]],
    [
      "recordType": "summary",
      "expectedPhotoCount": expectedPhotoCount,
      "uniquePhotoCount": 2,
      "duplicatePhotoCount": 0,
      "photoPageCount": 1,
      "namedPersonCount": 1,
      "personMembershipCount": 1,
      "peoplePageCount": 1,
      "complete": true,
    ],
  ]
  if includeRootMetadata {
    lines.insert(
      [
        "recordType": "rootMetadata",
        "value": ["count": 1, "data": [["ownerId": "account-1", "id": "root-1"]]],
      ],
      at: 1
    )
  }
  var contents = Data()
  for line in lines {
    contents.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
    contents.append(0x0A)
  }
  try contents.write(to: source)
  try body(source)
}
