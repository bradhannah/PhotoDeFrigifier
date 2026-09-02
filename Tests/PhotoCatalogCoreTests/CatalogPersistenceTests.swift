import Foundation
import Testing

@testable import PhotoCatalogCore

@Test func catalogJSONLRoundTripsWithRestrictedPermissions() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("catalog.jsonl")
  let snapshot = fixtureCatalog()

  try CatalogJSONLStore.write(snapshot, to: destination)
  let decoded = try CatalogJSONLStore.read(from: destination)
  let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
  let permissions = try #require(attributes[.posixPermissions] as? NSNumber)

  #expect(decoded == snapshot)
  #expect(permissions.intValue & 0o777 == 0o600)
}

@Test func verifiedSHA256ProducesAutomaticMatch() throws {
  let snapshot = fixtureCatalog()
  let index = CatalogIdentityIndex(snapshot: snapshot)

  #expect(index.automaticMatches.count == 1)
  #expect(index.automaticMatches[0].sourceResourceIDs == ["resource-1", "resource-2"])
  #expect(index.reportedDigestCandidates.isEmpty)
}

@Test func incompatibleRolesDoNotProduceAutomaticMatch() {
  var snapshot = fixtureCatalog()
  snapshot.sourceResources[1] = SourceResource(
    id: "resource-2",
    sourceItemID: "item-2",
    role: .edited,
    byteCount: 12
  )

  #expect(CatalogIdentityIndex(snapshot: snapshot).automaticMatches.isEmpty)
}

@Test func newerSourceObservationInvalidatesOlderByteVerification() throws {
  var snapshot = fixtureCatalog()
  let run = snapshot.importRuns[0]
  snapshot.importRuns[0] = ImportRun(
    id: run.id,
    sourceLibraryID: run.sourceLibraryID,
    adapterID: run.adapterID,
    adapterVersion: run.adapterVersion,
    sourceFingerprintSHA256: run.sourceFingerprintSHA256,
    sourceSchemaVersion: run.sourceSchemaVersion,
    capturedAt: run.capturedAt,
    importedAt: run.importedAt,
    sourceRecordCount: 3
  )
  snapshot.sourceObservations.append(
    SourceObservation(
      id: "observation-3",
      importRunID: "run-1",
      sourceItemID: "item-1",
      lineNumber: 3,
      recordType: "fixture",
      rawRecord: .object(["private": .string("newer-fixture")])
    ))
  snapshot.sourceItems[0] = SourceItem(
    id: "item-1",
    sourceLibraryID: "library-1",
    externalID: "external-1",
    firstObservedImportRunID: "run-1",
    latestObservationID: "observation-3",
    lastSeenImportRunID: "run-1",
    kind: .photo
  )

  try CatalogJSONLStore.validate(snapshot)
  #expect(CatalogIdentityIndex(snapshot: snapshot).automaticMatches.isEmpty)
}

@Test func catalogValidationRejectsCrossWiredClaim() {
  var snapshot = fixtureCatalog()
  let claim = snapshot.metadataClaims[0]
  snapshot.metadataClaims[0] = MetadataClaim(
    id: claim.id,
    assetID: "asset-2",
    sourceItemID: claim.sourceItemID,
    importRunID: claim.importRunID,
    observationID: claim.observationID,
    field: claim.field,
    normalizedValue: claim.normalizedValue,
    rawValue: claim.rawValue,
    sourceJSONPath: claim.sourceJSONPath,
    authorship: claim.authorship,
    confidence: claim.confidence,
    observedAt: claim.observedAt
  )

  #expect(throws: CatalogStoreError.self) {
    try CatalogJSONLStore.validate(snapshot)
  }
}

@Test func catalogValidationRejectsDuplicateSourceNaturalKey() {
  var snapshot = fixtureCatalog()
  snapshot.sourceItems.append(
    SourceItem(
      id: "item-duplicate",
      sourceLibraryID: "library-1",
      externalID: "external-1",
      firstObservedImportRunID: "run-1",
      latestObservationID: "observation-1",
      lastSeenImportRunID: "run-1",
      kind: .photo
    ))

  #expect(throws: CatalogStoreError.duplicateEntity("source item natural key")) {
    try CatalogJSONLStore.validate(snapshot)
  }
}

@Test func catalogReplacementRestrictsPreviouslyPermissiveDestination() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("catalog.jsonl")
  try CatalogJSONLStore.write(fixtureCatalog(), to: destination)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o644],
    ofItemAtPath: destination.path
  )

  try CatalogJSONLStore.write(fixtureCatalog(), to: destination)

  let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
  let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
  #expect(permissions.intValue & 0o777 == 0o600)
}

@Test func catalogRejectsRecordsAfterCompletionSummary() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("catalog.jsonl")
  try CatalogJSONLStore.write(fixtureCatalog(), to: destination)
  let handle = try FileHandle(forWritingTo: destination)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data("{\"recordType\":\"asset\"}\n".utf8))
  try handle.close()

  #expect(throws: CatalogStoreError.missingSummary) {
    try CatalogJSONLStore.read(from: destination)
  }
}

@Test func catalogRejectsObsoleteSchemaBeforeDecodingRecords() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("schema-1-catalog.jsonl")
  try Data(
    "{\"containsPrivateMetadata\":true,\"recordType\":\"catalogManifest\",\"schemaVersion\":1}\n"
      .utf8
  ).write(to: source)

  #expect(throws: CatalogStoreError.unsupportedSchema(1)) {
    try CatalogJSONLStore.read(from: source)
  }
}

@Test func catalogMigratesSchemaTwoCurrentRunPointers() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("schema-2-catalog.jsonl")
  try CatalogJSONLStore.write(fixtureCatalog(), to: source)
  let currentContents = try String(contentsOf: source, encoding: .utf8)
  let legacyContents =
    currentContents
    .replacingOccurrences(
      of: "\"schemaVersion\":\(CatalogSchema.currentVersion)",
      with: "\"schemaVersion\":2"
    )
    .replacingOccurrences(of: "\"latestImportRunID\":\"run-1\",", with: "")
    .replacingOccurrences(of: "\"lastSeenImportRunID\":\"run-1\",", with: "")
  try Data(legacyContents.utf8).write(to: source)

  let migrated = try CatalogJSONLStore.read(from: source)

  #expect(migrated.schemaVersion == CatalogSchema.currentVersion)
  #expect(migrated.sourceLibraries[0].latestImportRunID == "run-1")
  #expect(migrated.sourceItems.allSatisfy { $0.lastSeenImportRunID == "run-1" })
  try CatalogJSONLStore.validate(migrated)
}

@Test func corruptSchemaTwoDuplicateObservationIsRejectedWithoutCrashing() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("corrupt-schema-2-catalog.jsonl")
  try CatalogJSONLStore.write(fixtureCatalog(), to: source)
  let currentContents = try String(contentsOf: source, encoding: .utf8)
  let corruptContents =
    currentContents
    .replacingOccurrences(
      of: "\"schemaVersion\":\(CatalogSchema.currentVersion)",
      with: "\"schemaVersion\":2"
    )
    .replacingOccurrences(of: "\"id\":\"observation-2\"", with: "\"id\":\"observation-1\"")
  try Data(corruptContents.utf8).write(to: source)

  #expect(throws: CatalogStoreError.duplicateEntity("source observation")) {
    try CatalogJSONLStore.read(from: source)
  }
}

@Test func catalogRejectsLastSeenRunThatDoesNotOwnLatestObservation() {
  var snapshot = fixtureCatalog()
  snapshot.importRuns.append(
    ImportRun(
      id: "run-2",
      sourceLibraryID: "library-1",
      adapterID: "fixture",
      adapterVersion: 1,
      sourceFingerprintSHA256: String(repeating: "c", count: 64),
      sourceSchemaVersion: 1,
      capturedAt: nil,
      importedAt: Date(timeIntervalSinceReferenceDate: 5_000),
      sourceRecordCount: 0
    ))
  let item = snapshot.sourceItems[0]
  snapshot.sourceItems[0] = SourceItem(
    id: item.id,
    sourceLibraryID: item.sourceLibraryID,
    externalID: item.externalID,
    firstObservedImportRunID: item.firstObservedImportRunID,
    latestObservationID: item.latestObservationID,
    lastSeenImportRunID: "run-2",
    kind: item.kind
  )

  #expect(throws: CatalogStoreError.invalidReference("source item")) {
    try CatalogJSONLStore.validate(snapshot)
  }
}

@Test func catalogRejectsLibraryWithRunsButNoCurrentRun() {
  var snapshot = fixtureCatalog()
  let library = snapshot.sourceLibraries[0]
  snapshot.sourceLibraries[0] = SourceLibrary(
    id: library.id,
    provider: library.provider,
    externalAccountID: library.externalAccountID,
    displayName: library.displayName
  )

  #expect(throws: CatalogStoreError.invalidReference("source library latest import")) {
    try CatalogJSONLStore.validate(snapshot)
  }
  #expect(CatalogIdentityIndex(snapshot: snapshot).automaticMatches.isEmpty)
}

@Test func jsonlReaderRejectsSourceChangedDuringRead() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("changing.jsonl")
  try Data("{\"line\":1}\n{\"line\":2}\n".utf8).write(to: source)

  #expect(throws: CatalogIOError.sourceChanged) {
    _ = try JSONLReader.forEachLine(at: source) { lineNumber, _ in
      guard lineNumber == 1 else { return }
      let handle = try FileHandle(forWritingTo: source)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("{\"line\":3}\n".utf8))
      try handle.close()
    }
  }
}

@Test func jsonlReaderRejectsNewlineTerminatedOverlongRecord() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("overlong.jsonl")
  var contents = Data(repeating: 0x61, count: 16 * 1_024 * 1_024 + 1)
  contents.append(0x0A)
  try contents.write(to: source)

  #expect(throws: CatalogIOError.lineTooLong(1)) {
    _ = try JSONLReader.forEachLine(at: source) { _, _ in }
  }
}

@Test func sameFingerprintWithNewAdapterVersionCreatesANewRun() throws {
  let existing = emptyImportCatalog(runID: "run-1", adapterVersion: 1)
  let incoming = emptyImportCatalog(runID: "run-2", adapterVersion: 2)

  let merged = try CatalogMerge.merging(incoming, into: existing)

  #expect(merged.importRuns.count == 2)
}

@Test func catalogMergeRejectsSameIDWithDifferentLibraryIdentity() {
  let existing = emptyImportCatalog(runID: "run-1", adapterVersion: 1)
  var incoming = emptyImportCatalog(runID: "run-2", adapterVersion: 2)
  incoming.sourceLibraries = [
    SourceLibrary(
      id: "library-1",
      provider: .amazon,
      externalAccountID: "different-account",
      latestImportRunID: "run-2"
    )
  ]

  #expect(throws: CatalogStoreError.conflictingEntity("source library")) {
    try CatalogMerge.merging(incoming, into: existing)
  }
}

@Test func concurrentCatalogUpdatesPreserveBothRuns() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("catalog.jsonl")
  try CatalogJSONLStore.write(
    CatalogSnapshot(sourceLibraries: [fixtureSourceLibrary()]),
    to: destination
  )
  let first = emptyImportCatalog(runID: "run-1", adapterVersion: 1)
  let second = emptyImportCatalog(runID: "run-2", adapterVersion: 2)

  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
      _ = try CatalogJSONLStore.update(at: destination, importing: first)
    }
    group.addTask {
      _ = try CatalogJSONLStore.update(at: destination, importing: second)
    }
    try await group.waitForAll()
  }

  let stored = try CatalogJSONLStore.read(from: destination)
  #expect(Set(stored.importRuns.map(\.id)) == ["run-1", "run-2"])
}

private func fixtureCatalog() -> CatalogSnapshot {
  let importedAt = Date(timeIntervalSinceReferenceDate: 4_000)
  let observation1 = SourceObservation(
    id: "observation-1",
    importRunID: "run-1",
    sourceItemID: "item-1",
    lineNumber: 1,
    recordType: "fixture",
    rawRecord: .object(["private": .string("fixture-1")])
  )
  let observation2 = SourceObservation(
    id: "observation-2",
    importRunID: "run-1",
    sourceItemID: "item-2",
    lineNumber: 2,
    recordType: "fixture",
    rawRecord: .object(["private": .string("fixture-2")])
  )
  let byteResource = ByteResource(
    id: "bytes-1",
    sha256: String(repeating: "a", count: 64),
    byteCount: 12,
    verificationMethod: .localSHA256,
    measuredAt: importedAt
  )
  return CatalogSnapshot(
    sourceLibraries: [
      SourceLibrary(
        id: "library-1",
        provider: .filesystem,
        latestImportRunID: "run-1"
      )
    ],
    importRuns: [
      ImportRun(
        id: "run-1",
        sourceLibraryID: "library-1",
        adapterID: "fixture",
        adapterVersion: 1,
        sourceFingerprintSHA256: String(repeating: "b", count: 64),
        sourceSchemaVersion: 1,
        capturedAt: nil,
        importedAt: importedAt,
        sourceRecordCount: 2
      )
    ],
    assets: [
      Asset(
        id: "asset-1",
        kind: .photo,
        resolutionState: .provisional,
        sourceItemIDs: ["item-1"],
        sourceResourceIDs: ["resource-1"]
      ),
      Asset(
        id: "asset-2",
        kind: .photo,
        resolutionState: .provisional,
        sourceItemIDs: ["item-2"],
        sourceResourceIDs: ["resource-2"]
      ),
    ],
    sourceItems: [
      SourceItem(
        id: "item-1",
        sourceLibraryID: "library-1",
        externalID: "external-1",
        firstObservedImportRunID: "run-1",
        latestObservationID: "observation-1",
        lastSeenImportRunID: "run-1",
        kind: .photo
      ),
      SourceItem(
        id: "item-2",
        sourceLibraryID: "library-1",
        externalID: "external-2",
        firstObservedImportRunID: "run-1",
        latestObservationID: "observation-2",
        lastSeenImportRunID: "run-1",
        kind: .photo
      ),
    ],
    sourceResources: [
      SourceResource(id: "resource-1", sourceItemID: "item-1", role: .original, byteCount: 12),
      SourceResource(id: "resource-2", sourceItemID: "item-2", role: .primary, byteCount: 12),
    ],
    byteResources: [byteResource],
    assetResourceLinks: [
      AssetResourceLink(
        id: "link-1",
        sourceResourceID: "resource-1",
        byteResourceID: "bytes-1",
        sourceObservationID: "observation-1",
        verifiedAt: importedAt
      ),
      AssetResourceLink(
        id: "link-2",
        sourceResourceID: "resource-2",
        byteResourceID: "bytes-1",
        sourceObservationID: "observation-2",
        verifiedAt: importedAt
      ),
    ],
    metadataClaims: [
      MetadataClaim(
        id: "claim-1",
        assetID: "asset-1",
        sourceItemID: "item-1",
        importRunID: "run-1",
        observationID: "observation-1",
        field: "fixture.field",
        normalizedValue: .string("fixture"),
        rawValue: .string("fixture"),
        sourceJSONPath: "fixture",
        authorship: .unknown,
        confidence: 1,
        observedAt: importedAt
      )
    ],
    sourceObservations: [observation1, observation2]
  )
}

private func fixtureSourceLibrary() -> SourceLibrary {
  SourceLibrary(
    id: "library-1",
    provider: .filesystem,
    externalAccountID: "fixture-account"
  )
}

private func emptyImportCatalog(runID: String, adapterVersion: Int) -> CatalogSnapshot {
  CatalogSnapshot(
    sourceLibraries: [
      SourceLibrary(
        id: "library-1",
        provider: .filesystem,
        externalAccountID: "fixture-account",
        latestImportRunID: runID
      )
    ],
    importRuns: [
      ImportRun(
        id: runID,
        sourceLibraryID: "library-1",
        adapterID: "fixture-adapter",
        adapterVersion: adapterVersion,
        sourceFingerprintSHA256: String(repeating: "c", count: 64),
        sourceSchemaVersion: 1,
        capturedAt: nil,
        importedAt: Date(timeIntervalSinceReferenceDate: 5_000),
        sourceRecordCount: 0
      )
    ]
  )
}
