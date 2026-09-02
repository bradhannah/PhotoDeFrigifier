import Foundation
import Testing

@testable import PhotoCatalogCore

@Test func filesystemImportHashesNestedMediaAndSkipsUnmanagedEntries() throws {
  try withTemporaryDirectory { directory in
    let nested = directory.appendingPathComponent("nested", isDirectory: true)
    let package = directory.appendingPathComponent("ignored.photoslibrary", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    let bytes = Data("identical-media-bytes".utf8)
    let first = directory.appendingPathComponent("first.jpg")
    let second = nested.appendingPathComponent("second.JPG")
    try bytes.write(to: first)
    try bytes.write(to: second)
    try Data("not media".utf8).write(to: directory.appendingPathComponent("notes.txt"))
    try bytes.write(to: directory.appendingPathComponent(".hidden.jpg"))
    try bytes.write(to: package.appendingPathComponent("inside.jpg"))
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("linked.jpg"),
      withDestinationURL: first
    )

    let snapshot = try FilesystemCatalogImporter().importCatalog(
      from: directory,
      importedAt: Date(timeIntervalSinceReferenceDate: 1_000)
    )

    #expect(snapshot.sourceLibraries.count == 1)
    #expect(snapshot.sourceLibraries[0].provider == .filesystem)
    #expect(snapshot.importRuns[0].sourceRecordCount == 2)
    #expect(snapshot.sourceItems.map(\.externalID) == ["first.jpg", "nested/second.JPG"])
    #expect(snapshot.assets.count == 2)
    #expect(snapshot.sourceResources.count == 2)
    #expect(snapshot.byteResources.count == 1)
    #expect(snapshot.assetResourceLinks.count == 2)
    #expect(snapshot.byteResources[0].sha256.count == 64)
    #expect(snapshot.byteResources[0].locallyMeasuredMD5?.count == 32)
    #expect(snapshot.byteResources[0].byteCount == Int64(bytes.count))
    #expect(snapshot.sourceResources.allSatisfy { $0.role == .original })
    #expect(snapshot.sourceResources.allSatisfy { $0.reportedDigests.isEmpty })
    #expect(CatalogIdentityIndex(snapshot: snapshot).automaticMatches.count == 1)
    #expect(snapshot.metadataClaims.contains { $0.field == "filesystem.relativePath" })
    try CatalogJSONLStore.validate(snapshot)
  }
}

@Test func filesystemImportMeasuresKnownMD5AndEnrichesEarlierByteEvidence() throws {
  try withTemporaryDirectory { directory in
    try Data("abc".utf8).write(to: directory.appendingPathComponent("known.jpg"))
    let measured = try FilesystemCatalogImporter().importCatalog(from: directory)

    #expect(measured.importRuns[0].adapterVersion == 2)
    #expect(measured.byteResources[0].locallyMeasuredMD5 == "900150983cd24fb0d6963f7d28e17f72")
    #expect(
      measured.sourceObservations[0].rawRecord["md5"]?.stringValue
        == "900150983cd24fb0d6963f7d28e17f72"
    )

    var earlier = measured
    let byteResource = measured.byteResources[0]
    earlier.byteResources[0] = ByteResource(
      id: byteResource.id,
      sha256: byteResource.sha256,
      byteCount: byteResource.byteCount,
      verificationMethod: byteResource.verificationMethod,
      measuredAt: byteResource.measuredAt
    )
    let enriched = try CatalogMerge.merging(measured, into: earlier)
    #expect(enriched.byteResources[0].locallyMeasuredMD5 == byteResource.locallyMeasuredMD5)
  }
}

@Test func filesystemImportRecognizesBroaderAndSignatureDetectedMedia() throws {
  try withTemporaryDirectory { directory in
    let png = try #require(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      ))
    try png.write(to: directory.appendingPathComponent("misnamed.efb"))
    try Data("quicktime".utf8).write(to: directory.appendingPathComponent("clip.qt"))
    try Data("windows-media".utf8).write(to: directory.appendingPathComponent("legacy.wmv"))
    try Data("<svg/>".utf8).write(to: directory.appendingPathComponent("vector.svg"))
    try Data("unknown".utf8).write(to: directory.appendingPathComponent("unknown.efb"))

    let snapshot = try FilesystemCatalogImporter().importCatalog(from: directory)

    #expect(snapshot.sourceItems.count == 4)
    #expect(snapshot.assets.filter { $0.kind == .photo }.count == 2)
    #expect(snapshot.assets.filter { $0.kind == .video }.count == 2)
    #expect(snapshot.sourceResources.contains { $0.mediaType == "image/png" })
    #expect(snapshot.sourceResources.contains { $0.mediaType == "video/quicktime" })
    #expect(snapshot.sourceResources.contains { $0.mediaType == "video/x-ms-wmv" })
  }
}

@Test func duplicateIndexSeparatesExactNamesFromMatchingStems() throws {
  try withTemporaryDirectory { directory in
    let firstDirectory = directory.appendingPathComponent("first", isDirectory: true)
    let secondDirectory = directory.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    try Data("first".utf8).write(to: firstDirectory.appendingPathComponent("Shared.JPG"))
    try Data("second".utf8).write(to: secondDirectory.appendingPathComponent("shared.jpg"))
    try Data("third".utf8).write(to: firstDirectory.appendingPathComponent("alternate.heic"))
    try Data("fourth".utf8).write(to: secondDirectory.appendingPathComponent("alternate.jpg"))

    let snapshot = try FilesystemCatalogImporter().importCatalog(from: directory)
    let groups = CatalogDuplicateIndex(snapshot: snapshot).groups

    #expect(
      groups.contains { group in
        group.evidence == [.exactFilename]
          && Set(group.occurrences.map(\.filename)) == ["Shared.JPG", "shared.jpg"]
      })
    #expect(
      groups.contains { group in
        group.evidence == [.matchingFilenameStem]
          && Set(group.occurrences.map(\.filename)) == ["alternate.heic", "alternate.jpg"]
      })
  }
}

@Test func duplicatePairDecisionIsStableAcrossOccurrenceOrder() {
  let date = Date(timeIntervalSinceReferenceDate: 1_000)
  let forward = DuplicatePairReviewDecision(
    firstSourceResourceID: "resource-a",
    firstSourceObservationID: "observation-a",
    secondSourceResourceID: "resource-b",
    secondSourceObservationID: "observation-b",
    disposition: .confirmedDuplicate,
    decidedAt: date
  )
  let reverse = DuplicatePairReviewDecision(
    firstSourceResourceID: "resource-b",
    firstSourceObservationID: "observation-b",
    secondSourceResourceID: "resource-a",
    secondSourceObservationID: "observation-a",
    disposition: .confirmedDuplicate,
    decidedAt: date
  )

  #expect(forward == reverse)
}

@Test func duplicatePairDecisionChangesWithCurrentObservation() {
  let date = Date(timeIntervalSinceReferenceDate: 1_000)
  let original = DuplicatePairReviewDecision(
    firstSourceResourceID: "resource-a",
    firstSourceObservationID: "observation-a-1",
    secondSourceResourceID: "resource-b",
    secondSourceObservationID: "observation-b",
    disposition: .confirmedDuplicate,
    decidedAt: date
  )
  let changed = DuplicatePairReviewDecision(
    firstSourceResourceID: "resource-a",
    firstSourceObservationID: "observation-a-2",
    secondSourceResourceID: "resource-b",
    secondSourceObservationID: "observation-b",
    disposition: .confirmedDuplicate,
    decidedAt: date
  )

  #expect(original.id != changed.id)
}

@Test func stalePairDecisionDoesNotResolveCurrentEvidence() throws {
  try withTemporaryDirectory { directory in
    let firstDirectory = directory.appendingPathComponent("first", isDirectory: true)
    let secondDirectory = directory.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    try Data("first".utf8).write(to: firstDirectory.appendingPathComponent("shared.jpg"))
    try Data("second".utf8).write(to: secondDirectory.appendingPathComponent("shared.jpg"))

    let duplicateIndex = CatalogDuplicateIndex(
      snapshot: try FilesystemCatalogImporter().importCatalog(from: directory)
    )
    let pair = try #require(duplicateIndex.pairs.first)
    let staleDecision = DuplicatePairReviewDecision(
      firstSourceResourceID: pair.first.sourceResourceID,
      firstSourceObservationID: "stale-observation",
      secondSourceResourceID: pair.second.sourceResourceID,
      secondSourceObservationID: pair.second.sourceObservationID,
      disposition: .confirmedDuplicate,
      decidedAt: Date()
    )
    let resolution = CatalogDuplicateResolutionIndex(
      duplicateIndex: duplicateIndex,
      reviewState: LibraryProjectReviewState(duplicatePairDecisions: [staleDecision])
    )

    #expect(resolution.resolution(for: pair) == .unresolved)
  }
}

@Test func exactBytesMakeAnOverlappingFilenamePairAutomatic() throws {
  try withTemporaryDirectory { directory in
    let firstDirectory = directory.appendingPathComponent("first", isDirectory: true)
    let secondDirectory = directory.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    try Data("same".utf8).write(to: firstDirectory.appendingPathComponent("shared.jpg"))
    try Data("same".utf8).write(to: secondDirectory.appendingPathComponent("shared.jpg"))

    let duplicateIndex = CatalogDuplicateIndex(
      snapshot: try FilesystemCatalogImporter().importCatalog(from: directory)
    )
    let pair = try #require(duplicateIndex.pairs.first)

    #expect(pair.isAutomatic)
    #expect(pair.evidence.contains(.exactSHA256))
    #expect(pair.evidence.contains(.exactFilename))
  }
}

@Test func filesystemImportIsDeterministicAndRemeasurementIsIdempotent() throws {
  try withTemporaryDirectory { directory in
    try Data("stable-photo".utf8).write(to: directory.appendingPathComponent("stable.heic"))
    let first = try FilesystemCatalogImporter().importCatalog(
      from: directory,
      importedAt: Date(timeIntervalSinceReferenceDate: 2_000)
    )
    let identical = try FilesystemCatalogImporter().importCatalog(
      from: directory,
      importedAt: Date(timeIntervalSinceReferenceDate: 2_000)
    )
    let remeasured = try FilesystemCatalogImporter().importCatalog(
      from: directory,
      importedAt: Date(timeIntervalSinceReferenceDate: 3_000)
    )

    #expect(first == identical)
    #expect(try CatalogMerge.merging(remeasured, into: first) == first)
  }
}

@Test func changedFilePreservesOccurrenceAndReplacesCurrentByteLink() throws {
  try withTemporaryDirectory { directory in
    let media = directory.appendingPathComponent("changing.png")
    try Data("first-version".utf8).write(to: media)
    let first = try FilesystemCatalogImporter().importCatalog(
      from: directory,
      importedAt: Date(timeIntervalSinceReferenceDate: 4_000)
    )
    try Data("second-version".utf8).write(to: media)
    let second = try FilesystemCatalogImporter().importCatalog(
      from: directory,
      importedAt: Date(timeIntervalSinceReferenceDate: 5_000)
    )

    #expect(first.sourceItems[0].id == second.sourceItems[0].id)
    #expect(first.sourceResources[0].id == second.sourceResources[0].id)
    #expect(first.byteResources[0].id != second.byteResources[0].id)
    let merged = try CatalogMerge.merging(second, into: first)
    #expect(merged.importRuns.count == 2)
    #expect(merged.sourceItems.count == 1)
    #expect(merged.byteResources.count == 2)
    #expect(merged.assetResourceLinks.count == 1)
    #expect(merged.assetResourceLinks[0].byteResourceID == second.byteResources[0].id)
    #expect(CatalogIdentityIndex(snapshot: merged).automaticMatches.isEmpty)
    try CatalogJSONLStore.validate(merged)
  }
}

@Test func filesystemImportReadsImageDimensionsWithoutRequiringMetadata() throws {
  try withTemporaryDirectory { directory in
    let encoded =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    let png = try #require(Data(base64Encoded: encoded))
    try png.write(to: directory.appendingPathComponent("pixel.png"))

    let snapshot = try FilesystemCatalogImporter().importCatalog(from: directory)

    #expect(snapshot.sourceResources[0].width == 1)
    #expect(snapshot.sourceResources[0].height == 1)
    #expect(snapshot.metadataClaims.contains { $0.field == "dimension.width" })
    #expect(snapshot.metadataClaims.contains { $0.field == "dimension.height" })
  }
}

@Test func filesystemImportAllowsAnEmptyMediaScope() throws {
  try withTemporaryDirectory { directory in
    try Data("nothing to import".utf8).write(to: directory.appendingPathComponent("readme.txt"))

    let snapshot = try FilesystemCatalogImporter().importCatalog(from: directory)

    #expect(snapshot.sourceLibraries.count == 1)
    #expect(snapshot.importRuns[0].sourceRecordCount == 0)
    #expect(snapshot.assets.isEmpty)
    #expect(snapshot.byteResources.isEmpty)
    try CatalogJSONLStore.validate(snapshot)
  }
}

@Test func filesystemImportRejectsAFileOrSymlinkRoot() throws {
  try withTemporaryDirectory { directory in
    let file = directory.appendingPathComponent("photo.jpg")
    let link = directory.appendingPathComponent("linked-directory")
    try Data("photo".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)

    #expect(throws: FilesystemCatalogImportError.invalidDirectory) {
      try FilesystemCatalogImporter().importCatalog(from: file)
    }
    #expect(throws: FilesystemCatalogImportError.invalidDirectory) {
      try FilesystemCatalogImporter().importCatalog(from: link)
    }
  }
}

@Test func removedFolderItemIsRetainedAsHistoryButExcludedFromMatching() throws {
  try withTemporaryDirectory { directory in
    let firstURL = directory.appendingPathComponent("first.jpg")
    let removedURL = directory.appendingPathComponent("removed.jpg")
    let bytes = Data("same-media".utf8)
    try bytes.write(to: firstURL)
    try bytes.write(to: removedURL)
    let first = try FilesystemCatalogImporter().importCatalog(
      from: directory,
      importedAt: Date(timeIntervalSinceReferenceDate: 6_000)
    )
    #expect(CatalogIdentityIndex(snapshot: first).automaticMatches.count == 1)

    try FileManager.default.removeItem(at: removedURL)
    let second = try FilesystemCatalogImporter().importCatalog(
      from: directory,
      importedAt: Date(timeIntervalSinceReferenceDate: 7_000)
    )
    let merged = try CatalogMerge.merging(second, into: first)

    #expect(merged.sourceItems.count == 2)
    #expect(
      merged.sourceItems.filter { $0.lastSeenImportRunID == second.importRuns[0].id }.count == 1)
    #expect(CatalogIdentityIndex(snapshot: merged).automaticMatches.isEmpty)
    try CatalogJSONLStore.validate(merged)
  }
}

@Test func movedFolderCanRetainItsPersistedSourceIdentity() throws {
  try withTemporaryDirectory { parent in
    let original = parent.appendingPathComponent("Original", isDirectory: true)
    let moved = parent.appendingPathComponent("Moved", isDirectory: true)
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
    try Data("photo".utf8).write(to: original.appendingPathComponent("photo.jpg"))
    let first = try FilesystemCatalogImporter().importCatalog(from: original)
    let library = first.sourceLibraries[0]
    let externalAccountID = try #require(library.externalAccountID)

    try FileManager.default.moveItem(at: original, to: moved)
    let second = try FilesystemCatalogImporter().importCatalog(
      from: moved,
      sourceIdentity: FilesystemSourceIdentity(
        sourceLibraryID: library.id,
        externalAccountID: externalAccountID
      )
    )

    #expect(second.sourceLibraries[0].id == library.id)
    #expect(second.sourceLibraries[0].externalAccountID == externalAccountID)
    #expect(second.sourceItems[0].id == first.sourceItems[0].id)
    #expect(try CatalogMerge.merging(second, into: first).sourceLibraries.count == 1)
  }
}

@Test func restoredEarlierFolderFingerprintBecomesCurrentAgain() throws {
  try withTemporaryDirectory { directory in
    let retainedURL = directory.appendingPathComponent("retained.jpg")
    let restoredURL = directory.appendingPathComponent("restored.jpg")
    let bytes = Data("same-media".utf8)
    let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
    try bytes.write(to: retainedURL)
    try bytes.write(to: restoredURL)
    try FileManager.default.setAttributes(
      [.modificationDate: modificationDate], ofItemAtPath: retainedURL.path)
    try FileManager.default.setAttributes(
      [.modificationDate: modificationDate], ofItemAtPath: restoredURL.path)
    let first = try FilesystemCatalogImporter().importCatalog(
      from: directory,
      importedAt: Date(timeIntervalSinceReferenceDate: 8_000)
    )

    try FileManager.default.removeItem(at: restoredURL)
    let second = try FilesystemCatalogImporter().importCatalog(
      from: directory,
      importedAt: Date(timeIntervalSinceReferenceDate: 9_000)
    )
    let withoutRestored = try CatalogMerge.merging(second, into: first)
    #expect(CatalogIdentityIndex(snapshot: withoutRestored).automaticMatches.isEmpty)

    try bytes.write(to: restoredURL)
    try FileManager.default.setAttributes(
      [.modificationDate: modificationDate], ofItemAtPath: restoredURL.path)
    let third = try FilesystemCatalogImporter().importCatalog(
      from: directory,
      importedAt: Date(timeIntervalSinceReferenceDate: 10_000)
    )
    #expect(third.importRuns[0].id == first.importRuns[0].id)
    let restored = try CatalogMerge.merging(third, into: withoutRestored)

    #expect(restored.sourceLibraries[0].latestImportRunID == first.importRuns[0].id)
    #expect(CatalogIdentityIndex(snapshot: restored).automaticMatches.count == 1)
    try CatalogJSONLStore.validate(restored)
  }
}

private func withTemporaryDirectory(body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}
