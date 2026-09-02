import Darwin
import Foundation
import Testing

@testable import PhotoCatalogCore

@Test func libraryProjectCreatesPrivatePackageAndRoundTripsSource() throws {
  try withLibraryProjectParent { parent in
    let projectURL = parent.appendingPathComponent("Test.photodefrigifier", isDirectory: true)
    let createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
    var project = try LibraryProjectStore.create(at: projectURL, date: createdAt)
    let importedAt = Date(timeIntervalSinceReferenceDate: 2_000)
    project.recordImport(
      LibraryProjectSource(
        id: "source:folder",
        provider: .filesystem,
        kind: .folder,
        displayName: "Family Photos",
        bookmarkData: Data("bookmark".utf8),
        addedAt: importedAt,
        lastImportedAt: importedAt,
        itemCount: 42
      ),
      at: importedAt
    )
    try LibraryProjectStore.write(project, to: projectURL)

    #expect(try LibraryProjectStore.read(from: projectURL) == project)
    #expect(
      try CatalogJSONLStore.read(from: LibraryProjectStore.catalogURL(for: projectURL))
        == CatalogSnapshot())
    #expect(try fileMode(projectURL) == mode_t(S_IRWXU))
    #expect(
      try fileMode(LibraryProjectStore.manifestURL(for: projectURL))
        == mode_t(S_IRUSR | S_IWUSR)
    )
    #expect(
      try fileMode(LibraryProjectStore.catalogURL(for: projectURL))
        == mode_t(S_IRUSR | S_IWUSR)
    )
  }
}

@Test func libraryProjectRefreshPreservesOriginalAddedDate() throws {
  let createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
  let firstImport = Date(timeIntervalSinceReferenceDate: 2_000)
  let secondImport = Date(timeIntervalSinceReferenceDate: 3_000)
  var project = LibraryProject(createdAt: createdAt)
  project.recordImport(
    projectSource(addedAt: firstImport, importedAt: firstImport, count: 1),
    at: firstImport
  )
  project.recordImport(
    projectSource(addedAt: secondImport, importedAt: secondImport, count: 2),
    at: secondImport
  )

  #expect(project.sources.count == 1)
  #expect(project.sources[0].addedAt == firstImport)
  #expect(project.sources[0].lastImportedAt == secondImport)
  #expect(project.sources[0].itemCount == 2)
  #expect(project.updatedAt == secondImport)
}

@Test func libraryProjectRejectsExistingDestinationAndSymlink() throws {
  try withLibraryProjectParent { parent in
    let existing = parent.appendingPathComponent("Existing.photodefrigifier", isDirectory: true)
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
    #expect(throws: LibraryProjectStoreError.destinationExists) {
      try LibraryProjectStore.create(at: existing)
    }

    let link = parent.appendingPathComponent("Linked.photodefrigifier", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
    #expect(throws: LibraryProjectStoreError.invalidProject) {
      try LibraryProjectStore.read(from: link)
    }
  }
}

@Test func libraryProjectImportCommitsManifestAndCatalogTogether() throws {
  try withLibraryProjectParent { parent in
    let projectURL = parent.appendingPathComponent("Import.photodefrigifier", isDirectory: true)
    _ = try LibraryProjectStore.create(
      at: projectURL,
      date: Date(timeIntervalSinceReferenceDate: 1_000)
    )
    let sourceDirectory = parent.appendingPathComponent("Photos", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
    try Data("photo".utf8).write(to: sourceDirectory.appendingPathComponent("photo.jpg"))
    let importedAt = Date(timeIntervalSinceReferenceDate: 2_000)
    let incoming = try FilesystemCatalogImporter().importCatalog(
      from: sourceDirectory,
      importedAt: importedAt
    )
    let library = incoming.sourceLibraries[0]
    let source = LibraryProjectSource(
      id: library.id,
      provider: library.provider,
      kind: .folder,
      externalAccountID: library.externalAccountID,
      displayName: "Photos",
      bookmarkData: Data("bookmark".utf8),
      addedAt: importedAt,
      lastImportedAt: importedAt,
      itemCount: incoming.sourceItems.count
    )

    let result = try LibraryProjectStore.importCatalog(
      incoming,
      source: source,
      into: projectURL,
      importedAt: importedAt
    )

    #expect(result.project.sources == [source])
    #expect(result.catalog.sourceItems.count == 1)
    #expect(try LibraryProjectStore.read(from: projectURL) == result.project)
    #expect(
      try CatalogJSONLStore.read(from: LibraryProjectStore.catalogURL(for: projectURL))
        == result.catalog
    )
  }
}

@Test func invalidSourceMetadataCannotCommitCatalogOrJournal() throws {
  try withLibraryProjectParent { parent in
    let projectURL = parent.appendingPathComponent(
      "Invalid Import.photodefrigifier", isDirectory: true)
    let original = try LibraryProjectStore.create(
      at: projectURL,
      date: Date(timeIntervalSinceReferenceDate: 1_000)
    )
    let sourceDirectory = parent.appendingPathComponent("Photos", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
    try Data("photo".utf8).write(to: sourceDirectory.appendingPathComponent("photo.jpg"))
    let importedAt = Date(timeIntervalSinceReferenceDate: 2_000)
    let incoming = try FilesystemCatalogImporter().importCatalog(
      from: sourceDirectory,
      importedAt: importedAt
    )
    let library = incoming.sourceLibraries[0]
    let invalidSource = LibraryProjectSource(
      id: library.id,
      provider: library.provider,
      kind: .folder,
      externalAccountID: library.externalAccountID,
      displayName: "",
      bookmarkData: Data("bookmark".utf8),
      addedAt: importedAt,
      lastImportedAt: importedAt,
      itemCount: 1
    )

    #expect(throws: LibraryProjectStoreError.invalidProject) {
      try LibraryProjectStore.importCatalog(
        incoming,
        source: invalidSource,
        into: projectURL,
        importedAt: importedAt
      )
    }

    let contents = try LibraryProjectStore.load(from: projectURL)
    #expect(contents.project == original)
    #expect(contents.catalog == CatalogSnapshot())
  }
}

@Test func libraryProjectRecoversManifestAfterInterruptedImportCommit() throws {
  try withLibraryProjectParent { parent in
    let projectURL = parent.appendingPathComponent("Recovery.photodefrigifier", isDirectory: true)
    _ = try LibraryProjectStore.create(
      at: projectURL,
      date: Date(timeIntervalSinceReferenceDate: 1_000)
    )
    let sourceDirectory = parent.appendingPathComponent("Recovery Photos", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
    try Data("photo".utf8).write(to: sourceDirectory.appendingPathComponent("photo.jpg"))
    let importedAt = Date(timeIntervalSinceReferenceDate: 2_000)
    let incoming = try FilesystemCatalogImporter().importCatalog(
      from: sourceDirectory,
      importedAt: importedAt
    )
    let library = incoming.sourceLibraries[0]
    let source = LibraryProjectSource(
      id: library.id,
      provider: library.provider,
      kind: .folder,
      externalAccountID: library.externalAccountID,
      displayName: "Recovery Photos",
      bookmarkData: Data("bookmark".utf8),
      addedAt: importedAt,
      lastImportedAt: importedAt,
      itemCount: 1
    )
    _ = try CatalogJSONLStore.update(
      at: LibraryProjectStore.catalogURL(for: projectURL),
      importing: incoming
    )
    let pendingURL = projectURL.appendingPathComponent(".pending-import.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(
      PendingImportFixture(
        source: source,
        importRunIDs: incoming.importRuns.map(\.id),
        expectedLatestImportRunID: incoming.sourceLibraries[0].latestImportRunID,
        importedAt: importedAt
      )
    ).write(to: pendingURL)

    let recovered = try LibraryProjectStore.load(from: projectURL)

    #expect(recovered.project.sources == [source])
    #expect(recovered.catalog.sourceItems.count == 1)
    #expect(!FileManager.default.fileExists(atPath: pendingURL.path))
  }
}

@Test func libraryProjectDoesNotRecoverJournalForHistoricalRun() throws {
  try withLibraryProjectParent { parent in
    let projectURL = parent.appendingPathComponent("Historical.photodefrigifier", isDirectory: true)
    _ = try LibraryProjectStore.create(
      at: projectURL,
      date: Date(timeIntervalSinceReferenceDate: 1_000)
    )
    let sourceDirectory = parent.appendingPathComponent("Historical Photos", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
    let mediaURL = sourceDirectory.appendingPathComponent("photo.jpg")
    try Data("version-a".utf8).write(to: mediaURL)
    let firstImportDate = Date(timeIntervalSinceReferenceDate: 2_000)
    let first = try FilesystemCatalogImporter().importCatalog(
      from: sourceDirectory,
      importedAt: firstImportDate
    )
    let library = first.sourceLibraries[0]
    let firstSource = LibraryProjectSource(
      id: library.id,
      provider: library.provider,
      kind: .folder,
      externalAccountID: library.externalAccountID,
      displayName: "Historical Photos",
      bookmarkData: Data("bookmark".utf8),
      addedAt: firstImportDate,
      lastImportedAt: firstImportDate,
      itemCount: 1
    )
    _ = try LibraryProjectStore.importCatalog(
      first,
      source: firstSource,
      into: projectURL,
      importedAt: firstImportDate
    )

    try Data("version-b".utf8).write(to: mediaURL)
    let second = try FilesystemCatalogImporter().importCatalog(
      from: sourceDirectory,
      importedAt: Date(timeIntervalSinceReferenceDate: 3_000),
      sourceIdentity: FilesystemSourceIdentity(
        sourceLibraryID: library.id,
        externalAccountID: try #require(library.externalAccountID)
      )
    )
    _ = try CatalogJSONLStore.update(
      at: LibraryProjectStore.catalogURL(for: projectURL),
      importing: second
    )

    let attemptedRestoreDate = Date(timeIntervalSinceReferenceDate: 4_000)
    let pendingSource = LibraryProjectSource(
      id: firstSource.id,
      provider: firstSource.provider,
      kind: firstSource.kind,
      externalAccountID: firstSource.externalAccountID,
      displayName: firstSource.displayName,
      bookmarkData: firstSource.bookmarkData,
      addedAt: attemptedRestoreDate,
      lastImportedAt: attemptedRestoreDate,
      itemCount: firstSource.itemCount
    )
    let pendingURL = projectURL.appendingPathComponent(".pending-import.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(
      PendingImportFixture(
        source: pendingSource,
        importRunIDs: first.importRuns.map(\.id),
        expectedLatestImportRunID: first.sourceLibraries[0].latestImportRunID,
        importedAt: attemptedRestoreDate
      )
    ).write(to: pendingURL)

    let loaded = try LibraryProjectStore.load(from: projectURL)

    #expect(loaded.catalog.sourceLibraries[0].latestImportRunID == second.importRuns[0].id)
    #expect(loaded.project.sources[0].lastImportedAt == firstImportDate)
    #expect(!FileManager.default.fileExists(atPath: pendingURL.path))
  }
}

@Test func libraryProjectPersistsPrivateReviewStateWithoutChangingCatalog() throws {
  try withLibraryProjectParent { parent in
    let projectURL = parent.appendingPathComponent("Review.photodefrigifier", isDirectory: true)
    _ = try LibraryProjectStore.create(at: projectURL)
    let catalogBefore = try Data(contentsOf: LibraryProjectStore.catalogURL(for: projectURL))
    let empty = try LibraryProjectStore.load(from: projectURL)
    #expect(empty.reviewState == LibraryProjectReviewState())

    let updated = try LibraryProjectStore.updateReviewState(at: projectURL) { state in
      state.setDuplicateDisposition(
        .confirmedDuplicate,
        for: "candidate-1",
        at: Date(timeIntervalSinceReferenceDate: 1_000)
      )
      state.createCanonicalPerson(
        preferredName: "Fixture Person",
        sourcePersonID: "source-person-1",
        at: Date(timeIntervalSinceReferenceDate: 1_000)
      )
    }

    #expect(updated.duplicateDecisions.count == 1)
    #expect(updated.canonicalPeople.count == 1)
    #expect(try LibraryProjectStore.load(from: projectURL).reviewState == updated)
    #expect(try Data(contentsOf: LibraryProjectStore.catalogURL(for: projectURL)) == catalogBefore)
    #expect(
      try fileMode(LibraryProjectStore.reviewURL(for: projectURL))
        == mode_t(S_IRUSR | S_IWUSR)
    )
  }
}

@Test func libraryProjectRejectsOneSourcePersonAssignedTwice() throws {
  try withLibraryProjectParent { parent in
    let projectURL = parent.appendingPathComponent(
      "Invalid Review.photodefrigifier", isDirectory: true)
    _ = try LibraryProjectStore.create(at: projectURL)

    #expect(throws: LibraryProjectStoreError.invalidReviewState) {
      try LibraryProjectStore.updateReviewState(at: projectURL) { state in
        state.createCanonicalPerson(
          preferredName: "First",
          sourcePersonID: "source-person-1"
        )
        state.createCanonicalPerson(
          preferredName: "Second",
          sourcePersonID: "source-person-1"
        )
      }
    }
  }
}

private func projectSource(addedAt: Date, importedAt: Date, count: Int) -> LibraryProjectSource {
  LibraryProjectSource(
    id: "source:folder",
    provider: .filesystem,
    kind: .folder,
    displayName: "Family Photos",
    bookmarkData: Data("bookmark".utf8),
    addedAt: addedAt,
    lastImportedAt: importedAt,
    itemCount: count
  )
}

private func withLibraryProjectParent(body: (URL) throws -> Void) throws {
  let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: parent) }
  try body(parent)
}

private func fileMode(_ url: URL) throws -> mode_t {
  var information = stat()
  guard lstat(url.path, &information) == 0 else {
    throw LibraryProjectStoreError.invalidProject
  }
  return information.st_mode & mode_t(S_IRWXU | S_IRWXG | S_IRWXO)
}

private struct PendingImportFixture: Codable {
  let source: LibraryProjectSource
  let importRunIDs: [String]
  let expectedLatestImportRunID: String?
  let importedAt: Date
}
