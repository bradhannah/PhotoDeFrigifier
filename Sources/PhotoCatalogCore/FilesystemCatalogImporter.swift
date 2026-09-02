import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FilesystemCatalogImportError: Error, Equatable, LocalizedError {
  case duplicateRelativePath
  case invalidDirectory
  case sourceChanged
  case unreadableDirectory
  case unreadableFile

  public var errorDescription: String? {
    switch self {
    case .duplicateRelativePath:
      "The selected folder contains paths that cannot be represented uniquely."
    case .invalidDirectory:
      "The selected source is not an ordinary directory."
    case .sourceChanged:
      "The folder changed while it was being inventoried. Run the inventory again."
    case .unreadableDirectory:
      "The selected folder could not be completely enumerated."
    case .unreadableFile:
      "One media file could not be read completely."
    }
  }
}

public struct FilesystemSourceIdentity: Equatable, Sendable {
  public let sourceLibraryID: String
  public let externalAccountID: String

  public init(sourceLibraryID: String, externalAccountID: String) {
    self.sourceLibraryID = sourceLibraryID
    self.externalAccountID = externalAccountID
  }
}

public struct FilesystemCatalogImporter: URLCatalogImportAdapter {
  public let descriptor = CatalogAdapterDescriptor(
    id: "com.photodefrigifier.filesystem-directory",
    version: 2,
    provider: .filesystem
  )
  public let includeSubdirectories: Bool

  public init(includeSubdirectories: Bool = true) {
    self.includeSubdirectories = includeSubdirectories
  }

  public func importCatalog(
    from sourceURL: URL,
    importedAt: Date = Date()
  ) throws -> CatalogSnapshot {
    try importCatalog(from: sourceURL, importedAt: importedAt, sourceIdentity: nil)
  }

  public func importCatalog(
    from sourceURL: URL,
    importedAt: Date = Date(),
    sourceIdentity: FilesystemSourceIdentity
  ) throws -> CatalogSnapshot {
    try importCatalog(
      from: sourceURL, importedAt: importedAt,
      sourceIdentity: sourceIdentity as FilesystemSourceIdentity?)
  }

  private func importCatalog(
    from sourceURL: URL,
    importedAt: Date,
    sourceIdentity: FilesystemSourceIdentity?
  ) throws -> CatalogSnapshot {
    let selectedRoot = sourceURL.standardizedFileURL
    try validateRoot(selectedRoot)
    let root = try canonicalDirectoryURL(selectedRoot)
    let candidates = try enumerateMedia(in: root)
    var prepared: [PreparedFile] = []
    prepared.reserveCapacity(candidates.count)

    for candidate in candidates {
      let measurement = try measure(candidate)
      prepared.append(
        PreparedFile(
          candidate: candidate,
          measurement: measurement,
          rawRecord: rawRecord(candidate: candidate, measurement: measurement)
        ))
    }

    let finalCandidates = try enumerateMedia(in: root)
    guard
      finalCandidates.map(\.relativePath) == candidates.map(\.relativePath),
      try prepared.allSatisfy({
        try FileSignature(path: $0.candidate.url.path) == $0.measurement.signature
      })
    else {
      throw FilesystemCatalogImportError.sourceChanged
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var sourceHasher = SHA256()
    for file in prepared {
      sourceHasher.update(data: try encoder.encode(file.rawRecord))
      sourceHasher.update(data: Data([0x0A]))
    }
    let fingerprint = CatalogStableID.hex(sourceHasher.finalize())
    let sourceLibraryID =
      sourceIdentity?.sourceLibraryID
      ?? CatalogStableID.make(
        prefix: "library",
        components: [descriptor.provider.rawValue, root.path]
      )
    let externalAccountID = sourceIdentity?.externalAccountID ?? root.path
    guard !sourceLibraryID.isEmpty, !externalAccountID.isEmpty else {
      throw FilesystemCatalogImportError.invalidDirectory
    }
    let importRunID = CatalogStableID.make(
      prefix: "import",
      components: [
        descriptor.id,
        String(descriptor.version),
        "1",
        sourceLibraryID,
        fingerprint,
      ]
    )

    let sourceLibrary = SourceLibrary(
      id: sourceLibraryID,
      provider: .filesystem,
      externalAccountID: externalAccountID,
      displayName: root.lastPathComponent,
      latestImportRunID: importRunID
    )
    let importRun = ImportRun(
      id: importRunID,
      sourceLibraryID: sourceLibraryID,
      adapterID: descriptor.id,
      adapterVersion: descriptor.version,
      sourceFingerprintSHA256: fingerprint,
      sourceSchemaVersion: 1,
      capturedAt: nil,
      importedAt: importedAt,
      sourceRecordCount: prepared.count
    )

    var assets: [Asset] = []
    var sourceItems: [SourceItem] = []
    var sourceResources: [SourceResource] = []
    var byteResourcesByID: [String: ByteResource] = [:]
    var resourceLinks: [AssetResourceLink] = []
    var claims: [MetadataClaim] = []
    var observations: [SourceObservation] = []

    for (index, file) in prepared.enumerated() {
      let sourceItemID = CatalogStableID.make(
        prefix: "source-item",
        components: [sourceLibraryID, file.candidate.relativePath]
      )
      let assetID = CatalogStableID.make(prefix: "asset", components: [sourceItemID])
      let resourceID = CatalogStableID.make(
        prefix: "source-resource",
        components: [sourceItemID, file.candidate.role.rawValue]
      )
      let observationID = CatalogStableID.make(
        prefix: "observation",
        components: [importRunID, String(index + 1)]
      )
      let byteResourceID = CatalogStableID.make(
        prefix: "byte-resource",
        components: [
          ByteVerificationMethod.localSHA256.rawValue,
          file.measurement.sha256,
          String(file.measurement.byteCount),
        ]
      )
      if byteResourcesByID[byteResourceID] == nil {
        byteResourcesByID[byteResourceID] = ByteResource(
          id: byteResourceID,
          sha256: file.measurement.sha256,
          locallyMeasuredMD5: file.measurement.md5,
          byteCount: file.measurement.byteCount,
          verificationMethod: .localSHA256,
          measuredAt: importedAt
        )
      }

      observations.append(
        SourceObservation(
          id: observationID,
          importRunID: importRunID,
          sourceItemID: sourceItemID,
          lineNumber: index + 1,
          recordType: "filesystemFile",
          rawRecord: file.rawRecord
        ))
      sourceItems.append(
        SourceItem(
          id: sourceItemID,
          sourceLibraryID: sourceLibraryID,
          externalID: file.candidate.relativePath,
          firstObservedImportRunID: importRunID,
          latestObservationID: observationID,
          lastSeenImportRunID: importRunID,
          kind: file.candidate.kind
        ))
      sourceResources.append(
        SourceResource(
          id: resourceID,
          sourceItemID: sourceItemID,
          role: file.candidate.role,
          originalFilename: file.candidate.url.lastPathComponent,
          mediaType: file.candidate.mediaType,
          byteCount: file.measurement.byteCount,
          width: file.measurement.imageMetadata.width,
          height: file.measurement.imageMetadata.height
        ))
      resourceLinks.append(
        AssetResourceLink(
          id: CatalogStableID.make(prefix: "asset-resource-link", components: [resourceID]),
          sourceResourceID: resourceID,
          byteResourceID: byteResourceID,
          sourceObservationID: observationID,
          verifiedAt: importedAt
        ))
      assets.append(
        Asset(
          id: assetID,
          kind: file.candidate.kind,
          resolutionState: .provisional,
          sourceItemIDs: [sourceItemID],
          sourceResourceIDs: [resourceID]
        ))
      claims.append(
        contentsOf: makeClaims(
          file: file,
          assetID: assetID,
          sourceItemID: sourceItemID,
          importRunID: importRunID,
          observationID: observationID,
          observedAt: importedAt
        ))
    }

    return CatalogSnapshot(
      sourceLibraries: [sourceLibrary],
      importRuns: [importRun],
      assets: assets,
      sourceItems: sourceItems,
      sourceResources: sourceResources,
      byteResources: byteResourcesByID.values.sorted { $0.id < $1.id },
      assetResourceLinks: resourceLinks,
      metadataClaims: claims,
      sourceObservations: observations
    )
  }

  private func validateRoot(_ root: URL) throws {
    guard root.isFileURL else { throw FilesystemCatalogImportError.invalidDirectory }
    let values: URLResourceValues
    do {
      values = try root.resourceValues(forKeys: [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
      ])
    } catch {
      throw FilesystemCatalogImportError.invalidDirectory
    }
    guard
      values.isDirectory == true,
      values.isPackage != true,
      values.isSymbolicLink != true
    else {
      throw FilesystemCatalogImportError.invalidDirectory
    }
  }

  private func canonicalDirectoryURL(_ url: URL) throws -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let resolved = url.path.withCString { realpath($0, &buffer) }
    guard resolved != nil else { throw FilesystemCatalogImportError.invalidDirectory }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
  }

  private func enumerateMedia(in root: URL) throws -> [FileCandidate] {
    let keys: [URLResourceKey] = [
      .isDirectoryKey,
      .isHiddenKey,
      .isPackageKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ]
    var enumerationFailed = false
    var options: FileManager.DirectoryEnumerationOptions = [
      .skipsHiddenFiles,
      .skipsPackageDescendants,
    ]
    if !includeSubdirectories {
      options.insert(.skipsSubdirectoryDescendants)
    }
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: options,
        errorHandler: { _, _ in
          enumerationFailed = true
          return false
        }
      )
    else {
      throw FilesystemCatalogImportError.unreadableDirectory
    }

    var candidates: [FileCandidate] = []
    var relativePaths = Set<String>()
    while let url = enumerator.nextObject() as? URL {
      let values: URLResourceValues
      do {
        values = try url.resourceValues(forKeys: Set(keys))
      } catch {
        throw FilesystemCatalogImportError.unreadableDirectory
      }
      if values.isSymbolicLink == true {
        continue
      }
      if values.isDirectory == true {
        if values.isPackage == true
          || Self.packageExtensions.contains(url.pathExtension.lowercased())
        {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values.isHidden != true, values.isRegularFile == true else { continue }
      guard let media = Self.mediaClassification(for: url) else { continue }
      let relativePath = try relativePath(for: url, root: root)
      guard relativePaths.insert(relativePath).inserted else {
        throw FilesystemCatalogImportError.duplicateRelativePath
      }
      candidates.append(
        FileCandidate(
          url: url,
          relativePath: relativePath,
          kind: media.kind,
          role: media.role,
          mediaType: media.mediaType
        ))
    }
    guard !enumerationFailed else { throw FilesystemCatalogImportError.unreadableDirectory }
    return candidates.sorted { lhs, rhs in
      lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
    }
  }

  private func relativePath(for url: URL, root: URL) throws -> String {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard url.path.hasPrefix(rootPath) else {
      throw FilesystemCatalogImportError.duplicateRelativePath
    }
    let relativePath = String(url.path.dropFirst(rootPath.count))
    guard !relativePath.isEmpty, !relativePath.hasPrefix("../") else {
      throw FilesystemCatalogImportError.duplicateRelativePath
    }
    return relativePath
  }

  private func measure(_ candidate: FileCandidate) throws -> FileMeasurement {
    let descriptor = candidate.url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw FilesystemCatalogImportError.unreadableFile }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }

    let initial = try FileSignature(descriptor: descriptor)
    guard initial.isRegularFile else { throw FilesystemCatalogImportError.unreadableFile }
    let imageMetadata =
      candidate.kind == .photo
      ? EmbeddedImageMetadata.read(from: candidate.url)
      : EmbeddedImageMetadata()
    var sha256Hasher = SHA256()
    var md5Hasher = Insecure.MD5()
    var byteCount: Int64 = 0
    do {
      while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
        sha256Hasher.update(data: chunk)
        md5Hasher.update(data: chunk)
        let (newCount, overflow) = byteCount.addingReportingOverflow(Int64(chunk.count))
        guard !overflow else { throw FilesystemCatalogImportError.unreadableFile }
        byteCount = newCount
      }
    } catch let error as FilesystemCatalogImportError {
      throw error
    } catch {
      throw FilesystemCatalogImportError.unreadableFile
    }
    let final = try FileSignature(descriptor: descriptor)
    let pathSignature = try FileSignature(path: candidate.url.path)
    guard
      initial == final,
      initial.sameFile(as: pathSignature),
      byteCount == initial.size
    else {
      throw FilesystemCatalogImportError.sourceChanged
    }
    return FileMeasurement(
      sha256: CatalogStableID.hex(sha256Hasher.finalize()),
      md5: CatalogStableID.hex(md5Hasher.finalize()),
      byteCount: byteCount,
      modificationDate: initial.modificationDate,
      signature: initial,
      imageMetadata: imageMetadata
    )
  }

  private func rawRecord(candidate: FileCandidate, measurement: FileMeasurement) -> JSONValue {
    var object: [String: JSONValue] = [
      "recordType": .string("filesystemFile"),
      "relativePath": .string(candidate.relativePath),
      "filename": .string(candidate.url.lastPathComponent),
      "kind": .string(candidate.kind.rawValue),
      "byteCount": .integer(measurement.byteCount),
      "sha256": .string(measurement.sha256),
      "md5": .string(measurement.md5),
      "filesystemModifiedAt": .string(Self.timestamp(measurement.modificationDate)),
      "embeddedMetadata": measurement.imageMetadata.rawValue,
    ]
    if let mediaType = candidate.mediaType {
      object["mediaType"] = .string(mediaType)
    }
    return .object(object)
  }

  private func makeClaims(
    file: PreparedFile,
    assetID: String,
    sourceItemID: String,
    importRunID: String,
    observationID: String,
    observedAt: Date
  ) -> [MetadataClaim] {
    var claims: [MetadataClaim] = []
    func append(
      field: String,
      value: MetadataValue,
      rawValue: JSONValue,
      path: String,
      authorship: ClaimAuthorship,
      confidence: Double = 1
    ) {
      claims.append(
        MetadataClaim(
          id: CatalogStableID.make(
            prefix: "claim",
            components: [observationID, field, path]
          ),
          assetID: assetID,
          sourceItemID: sourceItemID,
          importRunID: importRunID,
          observationID: observationID,
          field: field,
          normalizedValue: value,
          rawValue: rawValue,
          sourceJSONPath: path,
          authorship: authorship,
          confidence: confidence,
          observedAt: observedAt
        ))
    }

    append(
      field: "filesystem.relativePath",
      value: .string(file.candidate.relativePath),
      rawValue: .string(file.candidate.relativePath),
      path: "relativePath",
      authorship: .providerDerived
    )
    let filename = file.candidate.url.lastPathComponent
    append(
      field: "filename.original",
      value: .string(filename),
      rawValue: .string(filename),
      path: "filename",
      authorship: .providerDerived
    )
    if let mediaType = file.candidate.mediaType {
      append(
        field: "media.contentType",
        value: .string(mediaType),
        rawValue: .string(mediaType),
        path: "mediaType",
        authorship: .providerDerived
      )
    }
    let modificationTimestamp = Self.timestamp(file.measurement.modificationDate)
    append(
      field: "date.filesystemModified",
      value: .timestamp(modificationTimestamp),
      rawValue: .string(modificationTimestamp),
      path: "filesystemModifiedAt",
      authorship: .providerDerived
    )
    let metadata = file.measurement.imageMetadata
    if let width = metadata.width {
      append(
        field: "dimension.width",
        value: .integer(Int64(width)),
        rawValue: .integer(Int64(width)),
        path: "embeddedMetadata.width",
        authorship: .embeddedMetadata
      )
    }
    if let height = metadata.height {
      append(
        field: "dimension.height",
        value: .integer(Int64(height)),
        rawValue: .integer(Int64(height)),
        path: "embeddedMetadata.height",
        authorship: .embeddedMetadata
      )
    }
    if let value = metadata.dateTimeOriginal {
      append(
        field: "date.embeddedOriginal",
        value: .timestamp(value),
        rawValue: .string(value),
        path: "embeddedMetadata.dateTimeOriginal",
        authorship: .embeddedMetadata,
        confidence: 0.95
      )
    }
    if let value = metadata.dateTimeDigitized {
      append(
        field: "date.embeddedDigitized",
        value: .timestamp(value),
        rawValue: .string(value),
        path: "embeddedMetadata.dateTimeDigitized",
        authorship: .embeddedMetadata,
        confidence: 0.95
      )
    }
    if let value = metadata.cameraMake {
      append(
        field: "camera.make",
        value: .string(value),
        rawValue: .string(value),
        path: "embeddedMetadata.cameraMake",
        authorship: .embeddedMetadata,
        confidence: 0.95
      )
    }
    if let value = metadata.cameraModel {
      append(
        field: "camera.model",
        value: .string(value),
        rawValue: .string(value),
        path: "embeddedMetadata.cameraModel",
        authorship: .embeddedMetadata,
        confidence: 0.95
      )
    }
    if let rawLocation = metadata.rawLocation, let location = metadata.location {
      append(
        field: "location.embedded",
        value: .location(location),
        rawValue: rawLocation,
        path: "embeddedMetadata.location",
        authorship: .embeddedMetadata,
        confidence: 0.95
      )
    }
    return claims
  }

  private static func mediaClassification(for url: URL) -> MediaClassification? {
    let fileExtension = url.pathExtension.lowercased()
    let kind: AssetKind
    let role: ResourceRole
    if photoExtensions.contains(fileExtension) {
      kind = .photo
      role = .original
    } else if videoExtensions.contains(fileExtension) {
      kind = .video
      role = .video
    } else if let type = UTType(filenameExtension: fileExtension), type.conforms(to: .image) {
      kind = .photo
      role = .original
    } else if let type = UTType(filenameExtension: fileExtension),
      type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    {
      kind = .video
      role = .video
    } else if let imageType = detectedImageType(for: url) {
      return MediaClassification(
        kind: .photo,
        role: .original,
        mediaType: imageType.preferredMIMEType
      )
    } else {
      return nil
    }
    return MediaClassification(
      kind: kind,
      role: role,
      mediaType: explicitMediaTypes[fileExtension]
        ?? UTType(filenameExtension: fileExtension)?.preferredMIMEType
    )
  }

  private static func detectedImageType(for url: URL) -> UTType? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, options),
      let identifier = CGImageSourceGetType(source) as String?
    else { return nil }
    return UTType(identifier)
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static let packageExtensions: Set<String> = [
    "app", "bundle", "framework", "photolibrary", "photoslibrary",
  ]

  private static let photoExtensions: Set<String> = [
    "arw", "avif", "bmp", "cr2", "cr3", "dng", "gif", "heic", "heif", "ico", "jpeg",
    "jpg", "nef", "nrw", "orf", "pef", "png", "raf", "rw2", "srw", "svg", "tif",
    "tiff", "webp",
  ]

  private static let videoExtensions: Set<String> = [
    "3g2", "3gp", "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts",
    "qt", "webm", "wmv",
  ]

  private static let explicitMediaTypes: [String: String] = [
    "qt": "video/quicktime",
    "svg": "image/svg+xml",
    "wmv": "video/x-ms-wmv",
  ]
}

private struct FileCandidate {
  let url: URL
  let relativePath: String
  let kind: AssetKind
  let role: ResourceRole
  let mediaType: String?
}

private struct MediaClassification {
  let kind: AssetKind
  let role: ResourceRole
  let mediaType: String?
}

private struct PreparedFile {
  let candidate: FileCandidate
  let measurement: FileMeasurement
  let rawRecord: JSONValue
}

private struct FileMeasurement {
  let sha256: String
  let md5: String
  let byteCount: Int64
  let modificationDate: Date
  let signature: FileSignature
  let imageMetadata: EmbeddedImageMetadata
}

private struct FileSignature: Equatable {
  let device: UInt64
  let inode: UInt64
  let size: Int64
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64
  let mode: mode_t

  init(descriptor: Int32) throws {
    var value = stat()
    guard fstat(descriptor, &value) == 0 else {
      throw FilesystemCatalogImportError.unreadableFile
    }
    self.init(value)
  }

  init(path: String) throws {
    var value = stat()
    let result = path.withCString { lstat($0, &value) }
    guard result == 0 else { throw FilesystemCatalogImportError.sourceChanged }
    self.init(value)
  }

  private init(_ value: stat) {
    device = UInt64(value.st_dev)
    inode = UInt64(value.st_ino)
    size = value.st_size
    modificationSeconds = Int64(value.st_mtimespec.tv_sec)
    modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
    mode = value.st_mode
  }

  var isRegularFile: Bool {
    mode & S_IFMT == S_IFREG
  }

  var modificationDate: Date {
    Date(
      timeIntervalSince1970: Double(modificationSeconds)
        + Double(modificationNanoseconds) / 1_000_000_000
    )
  }

  func sameFile(as other: FileSignature) -> Bool {
    device == other.device && inode == other.inode
  }
}

private struct EmbeddedImageMetadata {
  var width: Int?
  var height: Int?
  var dateTimeOriginal: String?
  var dateTimeDigitized: String?
  var cameraMake: String?
  var cameraModel: String?
  var rawLocation: JSONValue?
  var location: JSONValue?

  static func read(from url: URL) -> EmbeddedImageMetadata {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, options),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as NSDictionary?
    else { return EmbeddedImageMetadata() }

    var result = EmbeddedImageMetadata()
    result.width = positiveInt(properties[kCGImagePropertyPixelWidth])
    result.height = positiveInt(properties[kCGImagePropertyPixelHeight])
    if let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary {
      result.dateTimeOriginal = trimmedString(exif[kCGImagePropertyExifDateTimeOriginal])
      result.dateTimeDigitized = trimmedString(exif[kCGImagePropertyExifDateTimeDigitized])
    }
    if let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary {
      result.cameraMake = trimmedString(tiff[kCGImagePropertyTIFFMake])
      result.cameraModel = trimmedString(tiff[kCGImagePropertyTIFFModel])
    }
    if let gps = properties[kCGImagePropertyGPSDictionary] as? NSDictionary,
      let latitudeNumber = gps[kCGImagePropertyGPSLatitude] as? NSNumber,
      let longitudeNumber = gps[kCGImagePropertyGPSLongitude] as? NSNumber
    {
      let latitudeReference = trimmedString(gps[kCGImagePropertyGPSLatitudeRef])?.uppercased()
      let longitudeReference = trimmedString(gps[kCGImagePropertyGPSLongitudeRef])?.uppercased()
      var latitude = abs(latitudeNumber.doubleValue)
      var longitude = abs(longitudeNumber.doubleValue)
      if latitudeReference == "S" { latitude *= -1 }
      if longitudeReference == "W" { longitude *= -1 }
      if latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 {
        var raw: [String: JSONValue] = [
          "latitude": .number(latitudeNumber.doubleValue),
          "longitude": .number(longitudeNumber.doubleValue),
        ]
        if let latitudeReference { raw["latitudeReference"] = .string(latitudeReference) }
        if let longitudeReference { raw["longitudeReference"] = .string(longitudeReference) }
        result.rawLocation = .object(raw)
        result.location = .object([
          "latitude": .number(latitude),
          "longitude": .number(longitude),
        ])
      }
    }
    return result
  }

  var rawValue: JSONValue {
    var object: [String: JSONValue] = [:]
    if let width { object["width"] = .integer(Int64(width)) }
    if let height { object["height"] = .integer(Int64(height)) }
    if let dateTimeOriginal { object["dateTimeOriginal"] = .string(dateTimeOriginal) }
    if let dateTimeDigitized { object["dateTimeDigitized"] = .string(dateTimeDigitized) }
    if let cameraMake { object["cameraMake"] = .string(cameraMake) }
    if let cameraModel { object["cameraModel"] = .string(cameraModel) }
    if let rawLocation { object["location"] = rawLocation }
    return .object(object)
  }

  private static func positiveInt(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, number.intValue > 0 else { return nil }
    return number.intValue
  }

  private static func trimmedString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
