import Foundation

public enum CatalogStoreError: Error, Equatable, LocalizedError {
  case conflictingEntity(String)
  case duplicateEntity(String)
  case invalidManifest
  case invalidRecord(Int)
  case invalidReference(String)
  case invalidSummary
  case missingSummary
  case unsupportedSchema(Int)

  public var errorDescription: String? {
    switch self {
    case .conflictingEntity(let kind):
      "The catalog merge contains conflicting \(kind) identities."
    case .duplicateEntity(let kind):
      "The catalog contains a duplicate \(kind) identifier."
    case .invalidManifest:
      "The catalog manifest is invalid."
    case .invalidRecord(let line):
      "The catalog contains an invalid record at line \(line)."
    case .invalidReference(let kind):
      "The catalog contains an invalid \(kind) relationship."
    case .invalidSummary:
      "The catalog completion summary does not match its records."
    case .missingSummary:
      "The catalog does not end with a completion summary."
    case .unsupportedSchema(let version):
      "Catalog schema version \(version) is not supported."
    }
  }
}

public enum CatalogJSONLStore {
  private static let supportedLegacySchemaVersion = 2
  private static let processWriteLock = NSLock()

  public static func write(_ snapshot: CatalogSnapshot, to destination: URL) throws {
    processWriteLock.lock()
    defer { processWriteLock.unlock() }
    let lock = try CatalogFileLock(destination: destination)
    try withExtendedLifetime(lock) {
      try writeUnlocked(snapshot, to: destination)
    }
  }

  public static func update(
    at destination: URL,
    importing incoming: CatalogSnapshot
  ) throws -> CatalogSnapshot {
    processWriteLock.lock()
    defer { processWriteLock.unlock() }
    let lock = try CatalogFileLock(destination: destination)
    return try withExtendedLifetime(lock) {
      let updated: CatalogSnapshot
      if FileManager.default.fileExists(atPath: destination.path) {
        updated = try CatalogMerge.merging(incoming, into: read(from: destination))
      } else {
        updated = incoming
      }
      try writeUnlocked(updated, to: destination)
      return updated
    }
  }

  private static func writeUnlocked(_ snapshot: CatalogSnapshot, to destination: URL) throws {
    try validate(snapshot)
    let writer = try PrivateAtomicJSONLWriter(destination: destination)
    let encoder = makeEncoder()
    try writer.write(
      encoder.encode(
        CatalogManifestLine(
          recordType: "catalogManifest",
          schemaVersion: snapshot.schemaVersion,
          containsPrivateMetadata: true
        )))
    try write(
      snapshot.sourceLibraries, recordType: "sourceLibrary", writer: writer, encoder: encoder)
    try write(snapshot.importRuns, recordType: "importRun", writer: writer, encoder: encoder)
    try write(snapshot.assets, recordType: "asset", writer: writer, encoder: encoder)
    try write(snapshot.sourceItems, recordType: "sourceItem", writer: writer, encoder: encoder)
    try write(
      snapshot.sourceResources, recordType: "sourceResource", writer: writer, encoder: encoder)
    try write(snapshot.byteResources, recordType: "byteResource", writer: writer, encoder: encoder)
    try write(
      snapshot.assetResourceLinks, recordType: "assetResourceLink", writer: writer, encoder: encoder
    )
    try write(
      snapshot.metadataClaims, recordType: "metadataClaim", writer: writer, encoder: encoder)
    try write(snapshot.sourcePeople, recordType: "sourcePerson", writer: writer, encoder: encoder)
    try write(
      snapshot.personNameClaims,
      recordType: "personNameClaim",
      writer: writer,
      encoder: encoder
    )
    try write(
      snapshot.personMembershipClaims,
      recordType: "personMembershipClaim",
      writer: writer,
      encoder: encoder
    )
    try write(
      snapshot.sourceObservations,
      recordType: "sourceObservation",
      writer: writer,
      encoder: encoder
    )
    try writer.write(encoder.encode(CatalogSummaryLine(snapshot: snapshot)))
    try writer.finalize()
  }

  public static func read(from source: URL) throws -> CatalogSnapshot {
    let decoder = makeDecoder()
    var snapshot = CatalogSnapshot()
    var manifestSeen = false
    var summary: CatalogSummaryLine?
    var finalLineNumber = 0

    _ = try JSONLReader.forEachLine(at: source) { lineNumber, data in
      finalLineNumber = lineNumber
      let header: CatalogRecordHeader
      do {
        header = try decoder.decode(CatalogRecordHeader.self, from: data)
      } catch {
        throw CatalogStoreError.invalidRecord(lineNumber)
      }
      if summary != nil {
        throw CatalogStoreError.missingSummary
      }
      do {
        switch header.recordType {
        case "catalogManifest":
          guard lineNumber == 1, !manifestSeen else { throw CatalogStoreError.invalidManifest }
          let manifest = try decoder.decode(CatalogManifestLine.self, from: data)
          guard manifest.containsPrivateMetadata else { throw CatalogStoreError.invalidManifest }
          guard
            manifest.schemaVersion == CatalogSchema.currentVersion
              || manifest.schemaVersion == supportedLegacySchemaVersion
          else {
            throw CatalogStoreError.unsupportedSchema(manifest.schemaVersion)
          }
          snapshot = CatalogSnapshot(schemaVersion: manifest.schemaVersion)
          manifestSeen = true
        case "sourceLibrary":
          snapshot.sourceLibraries.append(
            try decodeValue(SourceLibrary.self, data: data, decoder: decoder))
        case "importRun":
          snapshot.importRuns.append(try decodeValue(ImportRun.self, data: data, decoder: decoder))
        case "asset":
          snapshot.assets.append(try decodeValue(Asset.self, data: data, decoder: decoder))
        case "sourceItem":
          snapshot.sourceItems.append(
            try decodeValue(SourceItem.self, data: data, decoder: decoder))
        case "sourceResource":
          snapshot.sourceResources.append(
            try decodeValue(SourceResource.self, data: data, decoder: decoder))
        case "byteResource":
          snapshot.byteResources.append(
            try decodeValue(ByteResource.self, data: data, decoder: decoder))
        case "assetResourceLink":
          snapshot.assetResourceLinks.append(
            try decodeValue(AssetResourceLink.self, data: data, decoder: decoder))
        case "metadataClaim":
          snapshot.metadataClaims.append(
            try decodeValue(MetadataClaim.self, data: data, decoder: decoder))
        case "sourcePerson":
          snapshot.sourcePeople.append(
            try decodeValue(SourcePerson.self, data: data, decoder: decoder))
        case "personNameClaim":
          snapshot.personNameClaims.append(
            try decodeValue(PersonNameClaim.self, data: data, decoder: decoder)
          )
        case "personMembershipClaim":
          snapshot.personMembershipClaims.append(
            try decodeValue(PersonMembershipClaim.self, data: data, decoder: decoder)
          )
        case "sourceObservation":
          snapshot.sourceObservations.append(
            try decodeValue(SourceObservation.self, data: data, decoder: decoder)
          )
        case "catalogSummary":
          summary = try decoder.decode(CatalogSummaryLine.self, from: data)
        default:
          throw CatalogStoreError.invalidRecord(lineNumber)
        }
      } catch let error as CatalogStoreError {
        throw error
      } catch {
        throw CatalogStoreError.invalidRecord(lineNumber)
      }
    }

    guard manifestSeen else { throw CatalogStoreError.invalidManifest }
    guard let summary, summary.recordType == "catalogSummary", finalLineNumber > 1 else {
      throw CatalogStoreError.missingSummary
    }
    guard summary.matches(snapshot) else { throw CatalogStoreError.invalidSummary }
    let currentSnapshot = migrateToCurrentSchema(snapshot)
    try validate(currentSnapshot)
    return currentSnapshot
  }

  public static func validate(_ snapshot: CatalogSnapshot) throws {
    guard snapshot.schemaVersion == CatalogSchema.currentVersion else {
      throw CatalogStoreError.unsupportedSchema(snapshot.schemaVersion)
    }
    try requireUnique(snapshot.sourceLibraries.map(\.id), kind: "source library")
    try requireUnique(snapshot.importRuns.map(\.id), kind: "import run")
    try requireUnique(snapshot.assets.map(\.id), kind: "asset")
    try requireUnique(snapshot.sourceItems.map(\.id), kind: "source item")
    try requireUnique(snapshot.sourceResources.map(\.id), kind: "source resource")
    try requireUnique(snapshot.byteResources.map(\.id), kind: "byte resource")
    try requireUnique(snapshot.assetResourceLinks.map(\.id), kind: "asset-resource link")
    try requireUnique(snapshot.metadataClaims.map(\.id), kind: "metadata claim")
    try requireUnique(snapshot.sourcePeople.map(\.id), kind: "source person")
    try requireUnique(snapshot.personNameClaims.map(\.id), kind: "person name claim")
    try requireUnique(snapshot.personMembershipClaims.map(\.id), kind: "person membership")
    try requireUnique(snapshot.sourceObservations.map(\.id), kind: "source observation")

    try requireUnique(
      snapshot.sourceLibraries.compactMap { library in
        library.externalAccountID.map {
          SourceLibraryNaturalKey(provider: library.provider, externalAccountID: $0)
        }
      },
      kind: "source library natural key"
    )
    try requireUnique(
      snapshot.importRuns.map {
        ImportIdentityKey(
          sourceLibraryID: $0.sourceLibraryID,
          adapterID: $0.adapterID,
          adapterVersion: $0.adapterVersion,
          sourceSchemaVersion: $0.sourceSchemaVersion,
          sourceFingerprintSHA256: $0.sourceFingerprintSHA256
        )
      },
      kind: "import identity"
    )
    try requireUnique(
      snapshot.sourceItems.map {
        SourceNaturalKey(sourceLibraryID: $0.sourceLibraryID, externalID: $0.externalID)
      },
      kind: "source item natural key"
    )
    try requireUnique(
      snapshot.sourcePeople.map {
        SourceNaturalKey(sourceLibraryID: $0.sourceLibraryID, externalID: $0.externalID)
      },
      kind: "source person natural key"
    )
    try requireUnique(
      snapshot.sourceObservations.map {
        ObservationLineKey(importRunID: $0.importRunID, lineNumber: $0.lineNumber)
      },
      kind: "source observation line"
    )
    try requireUnique(
      snapshot.personNameClaims.map {
        PersonObservationKey(sourcePersonID: $0.sourcePersonID, observationID: $0.observationID)
      },
      kind: "person name observation"
    )

    let librariesByID = Dictionary(
      uniqueKeysWithValues: snapshot.sourceLibraries.map { ($0.id, $0) })
    let runsByID = Dictionary(uniqueKeysWithValues: snapshot.importRuns.map { ($0.id, $0) })
    let assetsByID = Dictionary(uniqueKeysWithValues: snapshot.assets.map { ($0.id, $0) })
    let itemsByID = Dictionary(uniqueKeysWithValues: snapshot.sourceItems.map { ($0.id, $0) })
    let resourcesByID = Dictionary(
      uniqueKeysWithValues: snapshot.sourceResources.map { ($0.id, $0) })
    let byteResourcesByID = Dictionary(
      uniqueKeysWithValues: snapshot.byteResources.map { ($0.id, $0) })
    let observationsByID = Dictionary(
      uniqueKeysWithValues: snapshot.sourceObservations.map { ($0.id, $0) }
    )
    let peopleByID = Dictionary(uniqueKeysWithValues: snapshot.sourcePeople.map { ($0.id, $0) })
    let runsByLibraryID = Dictionary(grouping: snapshot.importRuns, by: \.sourceLibraryID)
    let observationCountsByRunID = Dictionary(
      grouping: snapshot.sourceObservations,
      by: \.importRunID
    ).mapValues(\.count)

    guard
      snapshot.sourceLibraries.allSatisfy({ library in
        let hasRuns = runsByLibraryID[library.id]?.isEmpty == false
        if !hasRuns { return library.latestImportRunID == nil }
        return library.latestImportRunID.map {
          runsByID[$0]?.sourceLibraryID == library.id
        } == true
      })
    else {
      throw CatalogStoreError.invalidReference("source library latest import")
    }

    guard
      snapshot.importRuns.allSatisfy({ run in
        librariesByID[run.sourceLibraryID] != nil
          && !run.adapterID.isEmpty
          && run.adapterVersion > 0
          && run.sourceSchemaVersion > 0
          && isSHA256(run.sourceFingerprintSHA256)
          && run.sourceRecordCount >= 0
          && observationCountsByRunID[run.id, default: 0] == run.sourceRecordCount
      })
    else {
      throw CatalogStoreError.invalidReference("import run observations")
    }

    guard
      snapshot.byteResources.allSatisfy({
        $0.byteCount >= 0 && $0.verificationMethod == .localSHA256 && isSHA256($0.sha256)
          && ($0.locallyMeasuredMD5.map(isMD5) ?? true)
      })
    else {
      throw CatalogStoreError.invalidReference("byte resource identity")
    }

    guard
      snapshot.sourceObservations.allSatisfy({ observation in
        guard observation.lineNumber > 0, let run = runsByID[observation.importRunID] else {
          return false
        }
        if let sourceItemID = observation.sourceItemID,
          itemsByID[sourceItemID]?.sourceLibraryID != run.sourceLibraryID
        {
          return false
        }
        if let sourcePersonID = observation.sourcePersonID,
          peopleByID[sourcePersonID]?.sourceLibraryID != run.sourceLibraryID
        {
          return false
        }
        return true
      })
    else {
      throw CatalogStoreError.invalidReference("source observation")
    }
    guard
      snapshot.sourceItems.allSatisfy({ item in
        guard
          librariesByID[item.sourceLibraryID] != nil,
          runsByID[item.firstObservedImportRunID]?.sourceLibraryID == item.sourceLibraryID,
          let latestObservation = observationsByID[item.latestObservationID]
        else { return false }
        return latestObservation.sourceItemID == item.id
          && runsByID[latestObservation.importRunID]?.sourceLibraryID == item.sourceLibraryID
          && latestObservation.importRunID == item.lastSeenImportRunID
          && item.lastSeenImportRunID.map {
            runsByID[$0]?.sourceLibraryID == item.sourceLibraryID
          } != false
      })
    else {
      throw CatalogStoreError.invalidReference("source item")
    }
    guard
      snapshot.sourceResources.allSatisfy({ resource in
        itemsByID[resource.sourceItemID] != nil
          && resource.byteCount.map { $0 >= 0 } ?? true
          && resource.width.map { $0 >= 0 } ?? true
          && resource.height.map { $0 >= 0 } ?? true
      })
    else {
      throw CatalogStoreError.invalidReference("source resource item")
    }

    var owningAssetByItemID: [String: String] = [:]
    var owningAssetByResourceID: [String: String] = [:]
    guard
      snapshot.assets.allSatisfy({ asset in
        guard
          !asset.sourceItemIDs.isEmpty,
          Set(asset.sourceItemIDs).count == asset.sourceItemIDs.count,
          Set(asset.sourceResourceIDs).count == asset.sourceResourceIDs.count,
          asset.sourceItemIDs.allSatisfy({ itemsByID[$0] != nil }),
          asset.sourceResourceIDs.allSatisfy({ resourceID in
            guard let resource = resourcesByID[resourceID] else { return false }
            return asset.sourceItemIDs.contains(resource.sourceItemID)
          })
        else { return false }
        for itemID in asset.sourceItemIDs {
          guard owningAssetByItemID.updateValue(asset.id, forKey: itemID) == nil else {
            return false
          }
        }
        for resourceID in asset.sourceResourceIDs {
          guard owningAssetByResourceID.updateValue(asset.id, forKey: resourceID) == nil else {
            return false
          }
        }
        return true
      })
        && owningAssetByItemID.count == itemsByID.count
        && owningAssetByResourceID.count == resourcesByID.count
    else {
      throw CatalogStoreError.invalidReference("asset")
    }

    try requireUnique(
      snapshot.assetResourceLinks.map(\.sourceResourceID),
      kind: "verified source resource"
    )
    guard
      snapshot.assetResourceLinks.allSatisfy({ link in
        guard
          let sourceResource = resourcesByID[link.sourceResourceID],
          let byteResource = byteResourcesByID[link.byteResourceID],
          let observation = observationsByID[link.sourceObservationID]
        else { return false }
        return observation.sourceItemID == sourceResource.sourceItemID
          && (sourceResource.byteCount.map { $0 == byteResource.byteCount } ?? true)
      })
    else {
      throw CatalogStoreError.invalidReference("verified resource")
    }
    guard
      snapshot.metadataClaims.allSatisfy({
        owningAssetByItemID[$0.sourceItemID] == $0.assetID
          && assetsByID[$0.assetID] != nil
          && runsByID[$0.importRunID]?.sourceLibraryID
            == itemsByID[$0.sourceItemID]?.sourceLibraryID
          && observationsByID[$0.observationID]?.importRunID == $0.importRunID
          && observationsByID[$0.observationID]?.sourceItemID == $0.sourceItemID
      })
    else {
      throw CatalogStoreError.invalidReference("metadata claim")
    }
    guard
      snapshot.sourcePeople.allSatisfy({ person in
        librariesByID[person.sourceLibraryID] != nil
          && observationsByID[person.observationID].map { observation in
            runsByID[observation.importRunID]?.sourceLibraryID == person.sourceLibraryID
              && observation.sourcePersonID == person.id
          } == true
      })
    else {
      throw CatalogStoreError.invalidReference("source person")
    }
    guard
      snapshot.personNameClaims.allSatisfy({ claim in
        guard
          let person = peopleByID[claim.sourcePersonID],
          let run = runsByID[claim.importRunID],
          let observation = observationsByID[claim.observationID]
        else { return false }
        return run.sourceLibraryID == person.sourceLibraryID
          && observation.importRunID == claim.importRunID
          && observation.sourcePersonID == claim.sourcePersonID
      })
    else {
      throw CatalogStoreError.invalidReference("person name claim")
    }
    guard
      snapshot.personMembershipClaims.allSatisfy({
        peopleByID[$0.sourcePersonID]?.sourceLibraryID
          == itemsByID[$0.sourceItemID]?.sourceLibraryID
          && owningAssetByItemID[$0.sourceItemID] == $0.assetID
          && assetsByID[$0.assetID] != nil
          && runsByID[$0.importRunID]?.sourceLibraryID
            == itemsByID[$0.sourceItemID]?.sourceLibraryID
          && observationsByID[$0.observationID]?.importRunID == $0.importRunID
          && observationsByID[$0.observationID]?.sourceItemID == $0.sourceItemID
      })
    else {
      throw CatalogStoreError.invalidReference("person membership")
    }
  }

  private static func migrateToCurrentSchema(_ snapshot: CatalogSnapshot) -> CatalogSnapshot {
    guard snapshot.schemaVersion == supportedLegacySchemaVersion else { return snapshot }
    let latestRunsByLibraryID = Dictionary(
      grouping: snapshot.importRuns,
      by: \.sourceLibraryID
    ).mapValues { runs in
      runs.max { lhs, rhs in
        lhs.importedAt == rhs.importedAt ? lhs.id < rhs.id : lhs.importedAt < rhs.importedAt
      }?.id
    }
    let observationsByID = Dictionary(
      snapshot.sourceObservations.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let libraries = snapshot.sourceLibraries.map { library in
      SourceLibrary(
        id: library.id,
        provider: library.provider,
        externalAccountID: library.externalAccountID,
        displayName: library.displayName,
        latestImportRunID: library.latestImportRunID ?? latestRunsByLibraryID[library.id] ?? nil
      )
    }
    let items = snapshot.sourceItems.map { item in
      SourceItem(
        id: item.id,
        sourceLibraryID: item.sourceLibraryID,
        externalID: item.externalID,
        firstObservedImportRunID: item.firstObservedImportRunID,
        latestObservationID: item.latestObservationID,
        lastSeenImportRunID: item.lastSeenImportRunID
          ?? observationsByID[item.latestObservationID]?.importRunID,
        kind: item.kind
      )
    }
    return CatalogSnapshot(
      schemaVersion: CatalogSchema.currentVersion,
      sourceLibraries: libraries,
      importRuns: snapshot.importRuns,
      assets: snapshot.assets,
      sourceItems: items,
      sourceResources: snapshot.sourceResources,
      byteResources: snapshot.byteResources,
      assetResourceLinks: snapshot.assetResourceLinks,
      metadataClaims: snapshot.metadataClaims,
      sourcePeople: snapshot.sourcePeople,
      personNameClaims: snapshot.personNameClaims,
      personMembershipClaims: snapshot.personMembershipClaims,
      sourceObservations: snapshot.sourceObservations
    )
  }

  private static func write<T: Codable>(
    _ values: [T],
    recordType: String,
    writer: PrivateAtomicJSONLWriter,
    encoder: JSONEncoder
  ) throws {
    for value in values {
      try writer.write(encoder.encode(CatalogValueLine(recordType: recordType, value: value)))
    }
  }

  private static func decodeValue<T: Codable>(
    _ type: T.Type,
    data: Data,
    decoder: JSONDecoder
  ) throws -> T {
    try decoder.decode(CatalogValueLine<T>.self, from: data).value
  }

  private static func requireUnique<Value: Hashable>(_ identifiers: [Value], kind: String) throws {
    guard Set(identifiers).count == identifiers.count else {
      throw CatalogStoreError.duplicateEntity(kind)
    }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && isHex(value)
  }

  private static func isMD5(_ value: String) -> Bool {
    value.count == 32 && isHex(value)
  }

  private static func isHex(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 48...57, 65...70, 97...102: true
      default: false
      }
    }
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.timeIntervalSinceReferenceDate)
    }
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self))
    }
    return decoder
  }
}

private struct SourceLibraryNaturalKey: Hashable {
  let provider: CatalogProvider
  let externalAccountID: String
}

private struct ImportIdentityKey: Hashable {
  let sourceLibraryID: String
  let adapterID: String
  let adapterVersion: Int
  let sourceSchemaVersion: Int
  let sourceFingerprintSHA256: String
}

private struct SourceNaturalKey: Hashable {
  let sourceLibraryID: String
  let externalID: String
}

private struct ObservationLineKey: Hashable {
  let importRunID: String
  let lineNumber: Int
}

private struct PersonObservationKey: Hashable {
  let sourcePersonID: String
  let observationID: String
}

private struct CatalogRecordHeader: Decodable {
  let recordType: String
}

private struct CatalogManifestLine: Codable {
  let recordType: String
  let schemaVersion: Int
  let containsPrivateMetadata: Bool
}

private struct CatalogValueLine<Value: Codable>: Codable {
  let recordType: String
  let value: Value
}

private struct CatalogSummaryLine: Codable {
  let recordType: String
  let sourceLibraryCount: Int
  let importRunCount: Int
  let assetCount: Int
  let sourceItemCount: Int
  let sourceResourceCount: Int
  let byteResourceCount: Int
  let assetResourceLinkCount: Int
  let metadataClaimCount: Int
  let sourcePersonCount: Int
  let personNameClaimCount: Int
  let personMembershipClaimCount: Int
  let sourceObservationCount: Int
  let complete: Bool

  init(snapshot: CatalogSnapshot) {
    recordType = "catalogSummary"
    sourceLibraryCount = snapshot.sourceLibraries.count
    importRunCount = snapshot.importRuns.count
    assetCount = snapshot.assets.count
    sourceItemCount = snapshot.sourceItems.count
    sourceResourceCount = snapshot.sourceResources.count
    byteResourceCount = snapshot.byteResources.count
    assetResourceLinkCount = snapshot.assetResourceLinks.count
    metadataClaimCount = snapshot.metadataClaims.count
    sourcePersonCount = snapshot.sourcePeople.count
    personNameClaimCount = snapshot.personNameClaims.count
    personMembershipClaimCount = snapshot.personMembershipClaims.count
    sourceObservationCount = snapshot.sourceObservations.count
    complete = true
  }

  func matches(_ snapshot: CatalogSnapshot) -> Bool {
    complete
      && sourceLibraryCount == snapshot.sourceLibraries.count
      && importRunCount == snapshot.importRuns.count
      && assetCount == snapshot.assets.count
      && sourceItemCount == snapshot.sourceItems.count
      && sourceResourceCount == snapshot.sourceResources.count
      && byteResourceCount == snapshot.byteResources.count
      && assetResourceLinkCount == snapshot.assetResourceLinks.count
      && metadataClaimCount == snapshot.metadataClaims.count
      && sourcePersonCount == snapshot.sourcePeople.count
      && personNameClaimCount == snapshot.personNameClaims.count
      && personMembershipClaimCount == snapshot.personMembershipClaims.count
      && sourceObservationCount == snapshot.sourceObservations.count
  }
}
