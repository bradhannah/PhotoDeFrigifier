import Darwin
import Foundation

public enum LibraryProjectSchema {
  public static let currentVersion = 1
}

public enum LibraryProjectSourceKind: String, Codable, Sendable {
  case amazonInventory
  case applePhotos
  case folder
}

public struct LibraryProjectSource: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let provider: CatalogProvider
  public let kind: LibraryProjectSourceKind
  public let externalAccountID: String?
  public let displayName: String
  public let bookmarkData: Data?
  public let addedAt: Date
  public let lastImportedAt: Date
  public let itemCount: Int
  public let measuredResourceCount: Int?
  public let networkRequiredResourceCount: Int?
  public let unavailableResourceCount: Int?
  public let identityAnchorExternalIDs: [String]?

  public init(
    id: String,
    provider: CatalogProvider,
    kind: LibraryProjectSourceKind,
    externalAccountID: String? = nil,
    displayName: String,
    bookmarkData: Data? = nil,
    addedAt: Date,
    lastImportedAt: Date,
    itemCount: Int,
    measuredResourceCount: Int? = nil,
    networkRequiredResourceCount: Int? = nil,
    unavailableResourceCount: Int? = nil,
    identityAnchorExternalIDs: [String]? = nil
  ) {
    self.id = id
    self.provider = provider
    self.kind = kind
    self.externalAccountID = externalAccountID
    self.displayName = displayName
    self.bookmarkData = bookmarkData
    self.addedAt = addedAt
    self.lastImportedAt = lastImportedAt
    self.itemCount = itemCount
    self.measuredResourceCount = measuredResourceCount
    self.networkRequiredResourceCount = networkRequiredResourceCount
    self.unavailableResourceCount = unavailableResourceCount
    self.identityAnchorExternalIDs = identityAnchorExternalIDs
  }
}

public struct LibraryProject: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let createdAt: Date
  public private(set) var updatedAt: Date
  public private(set) var sources: [LibraryProjectSource]

  public init(
    schemaVersion: Int = LibraryProjectSchema.currentVersion,
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    sources: [LibraryProjectSource] = []
  ) {
    self.schemaVersion = schemaVersion
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.sources = sources
  }

  public mutating func recordImport(_ source: LibraryProjectSource, at date: Date) {
    if let index = sources.firstIndex(where: { $0.id == source.id }) {
      let existing = sources[index]
      sources[index] = LibraryProjectSource(
        id: source.id,
        provider: source.provider,
        kind: source.kind,
        externalAccountID: source.externalAccountID,
        displayName: source.displayName,
        bookmarkData: source.bookmarkData,
        addedAt: existing.addedAt,
        lastImportedAt: source.lastImportedAt,
        itemCount: source.itemCount,
        measuredResourceCount: source.measuredResourceCount,
        networkRequiredResourceCount: source.networkRequiredResourceCount,
        unavailableResourceCount: source.unavailableResourceCount,
        identityAnchorExternalIDs: source.identityAnchorExternalIDs
      )
    } else {
      sources.append(source)
    }
    sources.sort {
      if $0.addedAt != $1.addedAt { return $0.addedAt < $1.addedAt }
      return $0.id < $1.id
    }
    updatedAt = date
  }
}

public enum LibraryProjectStoreError: Error, Equatable, LocalizedError {
  case destinationExists
  case invalidProject
  case invalidReviewState
  case unsupportedReviewSchema(Int)
  case unsupportedSchema(Int)

  public var errorDescription: String? {
    switch self {
    case .destinationExists:
      "A file or folder already exists at the selected project location."
    case .invalidProject:
      "The selected folder is not a valid PhotoDeFrigifier Library Project."
    case .invalidReviewState:
      "The Library Project review state is invalid."
    case .unsupportedReviewSchema(let version):
      "Library Project review schema version \(version) is not supported."
    case .unsupportedSchema(let version):
      "Library Project schema version \(version) is not supported."
    }
  }
}

public struct LibraryProjectContents: Sendable {
  public let project: LibraryProject
  public let catalog: CatalogSnapshot
  public let reviewState: LibraryProjectReviewState

  public init(
    project: LibraryProject,
    catalog: CatalogSnapshot,
    reviewState: LibraryProjectReviewState = LibraryProjectReviewState()
  ) {
    self.project = project
    self.catalog = catalog
    self.reviewState = reviewState
  }
}

public enum LibraryProjectStore {
  public static let catalogFilename = "catalog.jsonl"
  public static let manifestFilename = "project.json"
  public static let reviewFilename = "review.json"
  private static let pendingImportFilename = ".pending-import.json"
  private static let processLock = NSLock()

  public static func create(at directory: URL, date: Date = Date()) throws -> LibraryProject {
    guard directory.isFileURL, !FileManager.default.fileExists(atPath: directory.path) else {
      throw LibraryProjectStoreError.destinationExists
    }
    let permissions = mode_t(S_IRWXU)
    let result = directory.path.withCString { Darwin.mkdir($0, permissions) }
    guard result == 0, chmod(directory.path, permissions) == 0 else {
      throw LibraryProjectStoreError.invalidProject
    }

    do {
      let project = LibraryProject(createdAt: date)
      try CatalogJSONLStore.write(CatalogSnapshot(), to: catalogURL(for: directory))
      try write(project, to: directory)
      return project
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  public static func read(from directory: URL) throws -> LibraryProject {
    try validateDirectory(directory)
    return try withProjectLock(at: directory) {
      try recoverPendingImportIfNeeded(at: directory)
      return try readManifest(from: directory)
    }
  }

  public static func load(from directory: URL) throws -> LibraryProjectContents {
    try validateDirectory(directory)
    return try withProjectLock(at: directory) {
      try recoverPendingImportIfNeeded(at: directory)
      return LibraryProjectContents(
        project: try readManifest(from: directory),
        catalog: try CatalogJSONLStore.read(from: catalogURL(for: directory)),
        reviewState: try readReviewState(from: directory)
      )
    }
  }

  public static func write(_ project: LibraryProject, to directory: URL) throws {
    try validateDirectory(directory)
    try withProjectLock(at: directory) {
      try recoverPendingImportIfNeeded(at: directory)
      try writeManifest(project, to: directory)
    }
  }

  public static func importCatalog(
    _ incoming: CatalogSnapshot,
    source: LibraryProjectSource,
    into directory: URL,
    importedAt: Date
  ) throws -> LibraryProjectContents {
    try validateDirectory(directory)
    try CatalogJSONLStore.validate(incoming)
    guard
      incoming.sourceLibraries.count == 1,
      incoming.sourceLibraries[0].id == source.id,
      incoming.sourceLibraries[0].provider == source.provider,
      incoming.sourceLibraries[0].latestImportRunID != nil,
      !incoming.importRuns.isEmpty,
      incoming.importRuns.allSatisfy({ $0.sourceLibraryID == source.id })
    else {
      throw LibraryProjectStoreError.invalidProject
    }

    return try withProjectLock(at: directory) {
      try recoverPendingImportIfNeeded(at: directory)
      var project = try readManifest(from: directory)
      project.recordImport(source, at: importedAt)
      try validate(project)
      let pending = PendingProjectImport(
        source: source,
        importRunIDs: incoming.importRuns.map(\.id).sorted(),
        expectedLatestImportRunID: incoming.sourceLibraries[0].latestImportRunID,
        importedAt: importedAt
      )
      let reviewState = try readReviewState(from: directory)
      try writeJSON(pending, to: pendingImportURL(for: directory))

      // Keep the journal on every update error: the atomic rename may already have committed.
      let catalog = try CatalogJSONLStore.update(
        at: catalogURL(for: directory),
        importing: incoming
      )

      try writeManifest(project, to: directory)
      try? FileManager.default.removeItem(at: pendingImportURL(for: directory))
      return LibraryProjectContents(
        project: project,
        catalog: catalog,
        reviewState: reviewState
      )
    }
  }

  public static func updateReviewState(
    at directory: URL,
    update: (inout LibraryProjectReviewState) throws -> Void
  ) throws -> LibraryProjectReviewState {
    try validateDirectory(directory)
    return try withProjectLock(at: directory) {
      try recoverPendingImportIfNeeded(at: directory)
      var state = try readReviewState(from: directory)
      try update(&state)
      try LibraryProjectReviewValidator.validate(state)
      try writeJSON(state, to: reviewURL(for: directory))
      return state
    }
  }

  public static func manifestURL(for directory: URL) -> URL {
    directory.appendingPathComponent(manifestFilename, isDirectory: false)
  }

  public static func catalogURL(for directory: URL) -> URL {
    directory.appendingPathComponent(catalogFilename, isDirectory: false)
  }

  public static func reviewURL(for directory: URL) -> URL {
    directory.appendingPathComponent(reviewFilename, isDirectory: false)
  }

  private static func validate(_ project: LibraryProject) throws {
    guard project.schemaVersion == LibraryProjectSchema.currentVersion else {
      throw LibraryProjectStoreError.unsupportedSchema(project.schemaVersion)
    }
    guard
      project.updatedAt >= project.createdAt,
      project.sources.allSatisfy({ source in
        let validAccess =
          switch source.kind {
          case .folder:
            source.provider == .filesystem && source.bookmarkData?.isEmpty == false
          case .amazonInventory:
            source.provider == .amazon && source.bookmarkData?.isEmpty == false
          case .applePhotos:
            source.provider == .applePhotos && source.bookmarkData == nil
          }
        return !source.id.isEmpty && !source.displayName.isEmpty && validAccess
          && source.addedAt >= project.createdAt && source.lastImportedAt >= source.addedAt
          && source.itemCount >= 0
          && source.measuredResourceCount.map { $0 >= 0 } != false
          && source.networkRequiredResourceCount.map { $0 >= 0 } != false
          && source.unavailableResourceCount.map { $0 >= 0 } != false
          && source.identityAnchorExternalIDs.map { anchors in
            source.kind == .applePhotos && anchors.count <= 128
              && Set(anchors).count == anchors.count
              && anchors.allSatisfy { !$0.isEmpty }
          } != false
      }),
      Set(project.sources.map(\.id)).count == project.sources.count
    else {
      throw LibraryProjectStoreError.invalidProject
    }
  }

  private static func validateDirectory(_ directory: URL) throws {
    guard directory.isFileURL else { throw LibraryProjectStoreError.invalidProject }
    let values = try? directory.resourceValues(forKeys: [
      .isDirectoryKey,
      .isSymbolicLinkKey,
    ])
    guard values?.isDirectory == true, values?.isSymbolicLink != true else {
      throw LibraryProjectStoreError.invalidProject
    }
  }

  private static func withProjectLock<Result>(
    at directory: URL,
    body: () throws -> Result
  ) throws -> Result {
    processLock.lock()
    defer { processLock.unlock() }
    let lock = try CatalogFileLock(destination: manifestURL(for: directory))
    return try withExtendedLifetime(lock) {
      try body()
    }
  }

  private static func recoverPendingImportIfNeeded(at directory: URL) throws {
    let pendingURL = pendingImportURL(for: directory)
    guard FileManager.default.fileExists(atPath: pendingURL.path) else { return }
    let pending: PendingProjectImport = try readJSON(from: pendingURL)
    guard
      !pending.source.id.isEmpty,
      !pending.importRunIDs.isEmpty,
      pending.importRunIDs.allSatisfy({ !$0.isEmpty }),
      pending.expectedLatestImportRunID != nil
    else {
      throw LibraryProjectStoreError.invalidProject
    }

    let catalog = try CatalogJSONLStore.read(from: catalogURL(for: directory))
    let catalogRunIDs = Set(catalog.importRuns.map(\.id))
    let currentRunID = catalog.sourceLibraries.first { $0.id == pending.source.id }?
      .latestImportRunID
    if pending.importRunIDs.allSatisfy(catalogRunIDs.contains)
      && currentRunID == pending.expectedLatestImportRunID
    {
      var project = try readManifest(from: directory)
      project.recordImport(pending.source, at: pending.importedAt)
      try writeManifest(project, to: directory)
    }
    try FileManager.default.removeItem(at: pendingURL)
  }

  private static func readManifest(from directory: URL) throws -> LibraryProject {
    let project: LibraryProject = try readJSON(from: manifestURL(for: directory))
    try validate(project)
    return project
  }

  private static func writeManifest(_ project: LibraryProject, to directory: URL) throws {
    try validate(project)
    try writeJSON(project, to: manifestURL(for: directory))
  }

  private static func readReviewState(from directory: URL) throws -> LibraryProjectReviewState {
    let url = reviewURL(for: directory)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return LibraryProjectReviewState()
    }
    let state: LibraryProjectReviewState = try readJSON(from: url)
    try LibraryProjectReviewValidator.validate(state)
    return state
  }

  private static func readJSON<Value: Decodable>(from url: URL) throws -> Value {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let fileSize = attributes[.size] as? NSNumber,
      fileSize.intValue <= 16 * 1_024 * 1_024,
      let data = try? Data(contentsOf: url, options: .mappedIfSafe),
      let value = try? makeDecoder().decode(Value.self, from: data)
    else {
      throw LibraryProjectStoreError.invalidProject
    }
    return value
  }

  private static func writeJSON<Value: Encodable>(_ value: Value, to destination: URL) throws {
    let data = try makeEncoder().encode(value)
    guard data.count <= 16 * 1_024 * 1_024 else {
      throw LibraryProjectStoreError.invalidProject
    }
    let writer = try PrivateAtomicJSONLWriter(destination: destination)
    try writer.write(data)
    try writer.finalize()
  }

  private static func pendingImportURL(for directory: URL) -> URL {
    directory.appendingPathComponent(pendingImportFilename, isDirectory: false)
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

private struct PendingProjectImport: Codable {
  let source: LibraryProjectSource
  let importRunIDs: [String]
  let expectedLatestImportRunID: String?
  let importedAt: Date
}
