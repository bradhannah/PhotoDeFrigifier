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
  body: (URL) throws -> Void
) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("amazon-inventory.jsonl")
  let digest = "0123456789abcdef0123456789abcdef"
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
      "contentType": "image/jpeg",
      "size": 1_024,
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
      "contentType": "image/jpeg",
      "size": 1_024,
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
