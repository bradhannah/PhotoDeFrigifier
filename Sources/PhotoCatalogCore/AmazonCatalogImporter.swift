import Foundation

public enum AmazonCatalogImportError: Error, Equatable, LocalizedError {
  case duplicatePerson(Int)
  case duplicatePersonMembership(Int)
  case duplicatePhoto(Int)
  case incompleteInventory
  case invalidManifest
  case invalidRecord(Int)
  case invalidSummary
  case missingAccountIdentity
  case missingManifest
  case missingSummary
  case unsupportedSchema(Int)
  case wrongProvider

  public var errorDescription: String? {
    switch self {
    case .duplicatePerson(let line):
      "A duplicate source-scoped person was found at line \(line)."
    case .duplicatePersonMembership(let line):
      "A duplicate person membership was found at line \(line)."
    case .duplicatePhoto(let line):
      "A duplicate photo identifier was found at line \(line)."
    case .incompleteInventory:
      "The Amazon inventory is incomplete or contains dangling relationships."
    case .invalidManifest:
      "The Amazon inventory manifest is invalid."
    case .invalidRecord(let line):
      "The Amazon inventory contains an invalid record at line \(line)."
    case .invalidSummary:
      "The Amazon inventory completion summary is invalid."
    case .missingAccountIdentity:
      "The Amazon inventory does not contain a stable account identity."
    case .missingManifest:
      "The Amazon inventory does not begin with a manifest."
    case .missingSummary:
      "The Amazon inventory does not end with a completion summary."
    case .unsupportedSchema(let version):
      "Amazon inventory schema version \(version) is not supported."
    case .wrongProvider:
      "The inventory was not produced by the Amazon adapter."
    }
  }
}

public struct AmazonCatalogImporter: URLCatalogImportAdapter {
  public let descriptor = CatalogAdapterDescriptor(
    id: "com.photodefrigifier.amazon-private-jsonl",
    version: 3,
    provider: .amazon
  )

  public init() {}

  public func importCatalog(
    from sourceURL: URL,
    importedAt: Date = Date()
  ) throws -> CatalogSnapshot {
    let decoder = JSONDecoder()
    var records: [ParsedRecord] = []
    var photos: [ParsedPhoto] = []
    var people: [ParsedPerson] = []
    var memberships: [ParsedMembership] = []
    var photoIDs = Set<String>()
    var personKeys = Set<String>()
    var membershipKeys = Set<String>()
    var manifest: Manifest?
    var summary: Summary?
    var rootOwnerID: String?
    var rootMetadataSeen = false

    let fingerprint = try JSONLReader.forEachLine(at: sourceURL) { lineNumber, data in
      let raw: JSONValue
      do {
        raw = try decoder.decode(JSONValue.self, from: data)
      } catch {
        throw AmazonCatalogImportError.invalidRecord(lineNumber)
      }
      guard
        let object = raw.objectValue,
        let recordType = object["recordType"]?.stringValue
      else {
        throw AmazonCatalogImportError.invalidRecord(lineNumber)
      }
      records.append(ParsedRecord(lineNumber: lineNumber, recordType: recordType, raw: raw))

      switch recordType {
      case "manifest":
        guard lineNumber == 1, manifest == nil else {
          throw AmazonCatalogImportError.invalidManifest
        }
        guard
          let schemaVersionValue = object["schemaVersion"]?.intValue,
          let schemaVersion = Int(exactly: schemaVersionValue),
          let provider = object["provider"]?.stringValue,
          object["containsPrivateMetadata"]?.boolValue == true
        else {
          throw AmazonCatalogImportError.invalidManifest
        }
        guard schemaVersion == 1 else {
          throw AmazonCatalogImportError.unsupportedSchema(schemaVersion)
        }
        guard provider == "amazon" else { throw AmazonCatalogImportError.wrongProvider }
        manifest = Manifest(
          schemaVersion: schemaVersion,
          capturedAt: object["capturedAt"]?.stringValue
        )
      case "rootMetadata":
        guard !rootMetadataSeen else {
          throw AmazonCatalogImportError.invalidRecord(lineNumber)
        }
        rootMetadataSeen = true
        guard
          let ownerID = object["value"]?.value(at: ["data"])?.firstObjectValue?["ownerId"]?
            .stringValue,
          !ownerID.isEmpty
        else {
          throw AmazonCatalogImportError.invalidRecord(lineNumber)
        }
        rootOwnerID = ownerID
      case "photoNode":
        guard
          let node = object["value"],
          let externalID = node["id"]?.stringValue,
          !externalID.isEmpty
        else {
          throw AmazonCatalogImportError.invalidRecord(lineNumber)
        }
        guard photoIDs.insert(externalID).inserted else {
          throw AmazonCatalogImportError.duplicatePhoto(lineNumber)
        }
        photos.append(ParsedPhoto(lineNumber: lineNumber, externalID: externalID, node: node))
      case "person":
        guard let key = object["personKey"]?.stringValue, !key.isEmpty else {
          throw AmazonCatalogImportError.invalidRecord(lineNumber)
        }
        guard personKeys.insert(key).inserted else {
          throw AmazonCatalogImportError.duplicatePerson(lineNumber)
        }
        people.append(
          ParsedPerson(
            lineNumber: lineNumber,
            externalID: key,
            name: object["name"]?.stringValue
          ))
      case "personMembership":
        guard
          let personKey = object["personKey"]?.stringValue,
          let photoID = object["photoNodeId"]?.stringValue
        else {
          throw AmazonCatalogImportError.invalidRecord(lineNumber)
        }
        let membershipKey = personKey + "\0" + photoID
        guard membershipKeys.insert(membershipKey).inserted else {
          throw AmazonCatalogImportError.duplicatePersonMembership(lineNumber)
        }
        memberships.append(
          ParsedMembership(
            lineNumber: lineNumber,
            personExternalID: personKey,
            photoExternalID: photoID
          ))
      case "summary":
        guard summary == nil else { throw AmazonCatalogImportError.invalidSummary }
        guard
          let expectedValue = object["expectedPhotoCount"]?.intValue,
          let uniqueValue = object["uniquePhotoCount"]?.intValue,
          let personValue = object["namedPersonCount"]?.intValue,
          let membershipValue = object["personMembershipCount"]?.intValue,
          let expectedPhotoCount = Int(exactly: expectedValue),
          let uniquePhotoCount = Int(exactly: uniqueValue),
          let namedPersonCount = Int(exactly: personValue),
          let membershipCount = Int(exactly: membershipValue),
          object["complete"]?.boolValue == true
        else {
          throw AmazonCatalogImportError.invalidSummary
        }
        summary = Summary(
          lineNumber: lineNumber,
          expectedPhotoCount: expectedPhotoCount,
          uniquePhotoCount: uniquePhotoCount,
          namedPersonCount: namedPersonCount,
          membershipCount: membershipCount
        )
      default:
        break
      }
    }

    guard let manifest else { throw AmazonCatalogImportError.missingManifest }
    guard let summary else { throw AmazonCatalogImportError.missingSummary }
    guard summary.lineNumber == records.last?.lineNumber else {
      throw AmazonCatalogImportError.missingSummary
    }
    guard
      summary.expectedPhotoCount == photos.count,
      summary.uniquePhotoCount == photos.count,
      summary.namedPersonCount == people.count,
      summary.membershipCount == memberships.count
    else {
      throw AmazonCatalogImportError.invalidSummary
    }

    guard let accountID = rootOwnerID else {
      throw AmazonCatalogImportError.missingAccountIdentity
    }
    guard
      memberships.allSatisfy({
        photoIDs.contains($0.photoExternalID) && personKeys.contains($0.personExternalID)
      })
    else {
      throw AmazonCatalogImportError.incompleteInventory
    }

    let sourceLibraryID = CatalogStableID.make(
      prefix: "library",
      components: [descriptor.provider.rawValue, accountID]
    )
    let importRunID = CatalogStableID.make(
      prefix: "import",
      components: [
        descriptor.id,
        String(descriptor.version),
        String(manifest.schemaVersion),
        sourceLibraryID,
        fingerprint,
      ]
    )
    let sourceLibrary = SourceLibrary(
      id: sourceLibraryID,
      provider: .amazon,
      externalAccountID: accountID,
      displayName: nil,
      latestImportRunID: importRunID
    )
    let importRun = ImportRun(
      id: importRunID,
      sourceLibraryID: sourceLibraryID,
      adapterID: descriptor.id,
      adapterVersion: descriptor.version,
      sourceFingerprintSHA256: fingerprint,
      sourceSchemaVersion: manifest.schemaVersion,
      capturedAt: manifest.capturedAt,
      importedAt: importedAt,
      sourceRecordCount: records.count
    )

    let photoByLine = Dictionary(uniqueKeysWithValues: photos.map { ($0.lineNumber, $0) })
    let personByLine = Dictionary(uniqueKeysWithValues: people.map { ($0.lineNumber, $0) })
    let membershipByLine = Dictionary(uniqueKeysWithValues: memberships.map { ($0.lineNumber, $0) })
    var observations: [SourceObservation] = []
    observations.reserveCapacity(records.count)
    for record in records {
      let externalPhotoID =
        photoByLine[record.lineNumber]?.externalID
        ?? membershipByLine[record.lineNumber]?.photoExternalID
      let sourceItemID = externalPhotoID.map {
        CatalogStableID.make(prefix: "source-item", components: [sourceLibraryID, $0])
      }
      let sourcePersonID = personByLine[record.lineNumber].map {
        CatalogStableID.make(
          prefix: "source-person",
          components: [sourceLibraryID, $0.externalID]
        )
      }
      observations.append(
        SourceObservation(
          id: observationID(importRunID: importRunID, lineNumber: record.lineNumber),
          importRunID: importRunID,
          sourceItemID: sourceItemID,
          sourcePersonID: sourcePersonID,
          lineNumber: record.lineNumber,
          recordType: record.recordType,
          rawRecord: record.raw
        ))
    }

    var assets: [Asset] = []
    var sourceItems: [SourceItem] = []
    var sourceResources: [SourceResource] = []
    var claims: [MetadataClaim] = []
    assets.reserveCapacity(photos.count)
    sourceItems.reserveCapacity(photos.count)
    sourceResources.reserveCapacity(photos.count)

    for photo in photos {
      let sourceItemID = CatalogStableID.make(
        prefix: "source-item",
        components: [sourceLibraryID, photo.externalID]
      )
      let assetID = CatalogStableID.make(prefix: "asset", components: [sourceItemID])
      let observationID = observationID(importRunID: importRunID, lineNumber: photo.lineNumber)
      let mediaType = photo.node.value(at: ["contentProperties", "contentType"])?.stringValue
      let kind: AssetKind
      if mediaType?.hasPrefix("image/") == true {
        kind = .photo
      } else if mediaType?.hasPrefix("video/") == true {
        kind = .video
      } else {
        kind = .unknown
      }
      let resourceRole: ResourceRole = kind == .video ? .video : .primary
      let resourceID = CatalogStableID.make(
        prefix: "source-resource",
        components: [sourceItemID, "primary"]
      )
      let byteCount = photo.node.value(at: ["contentProperties", "size"])?.intValue
      let width = photo.node.value(at: ["contentProperties", "image", "width"])?.intValue
        .flatMap(Int.init(exactly:))
      let height = photo.node.value(at: ["contentProperties", "image", "height"])?.intValue
        .flatMap(Int.init(exactly:))
      var digests: [ReportedDigest] = []
      if let md5 = photo.node.value(at: ["contentProperties", "md5"])?.stringValue,
        Self.isHexDigest(md5, length: 32)
      {
        digests.append(
          ReportedDigest(algorithm: "md5", value: md5.lowercased(), reportingProvider: .amazon)
        )
      }

      sourceItems.append(
        SourceItem(
          id: sourceItemID,
          sourceLibraryID: sourceLibraryID,
          externalID: photo.externalID,
          firstObservedImportRunID: importRunID,
          latestObservationID: observationID,
          lastSeenImportRunID: importRunID,
          kind: kind
        ))
      sourceResources.append(
        SourceResource(
          id: resourceID,
          sourceItemID: sourceItemID,
          role: resourceRole,
          originalFilename: photo.node["name"]?.stringValue,
          mediaType: mediaType,
          byteCount: byteCount,
          width: width,
          height: height,
          reportedDigests: digests
        ))
      assets.append(
        Asset(
          id: assetID,
          kind: kind,
          resolutionState: .provisional,
          sourceItemIDs: [sourceItemID],
          sourceResourceIDs: [resourceID]
        ))
      claims.append(
        contentsOf: makeClaims(
          node: photo.node,
          assetID: assetID,
          sourceItemID: sourceItemID,
          importRunID: importRunID,
          observationID: observationID,
          observedAt: importedAt
        ))
    }

    var sourcePeople: [SourcePerson] = []
    var personNameClaims: [PersonNameClaim] = []
    sourcePeople.reserveCapacity(people.count)
    for person in people {
      let sourcePersonID = CatalogStableID.make(
        prefix: "source-person",
        components: [sourceLibraryID, person.externalID]
      )
      let personObservationID = observationID(
        importRunID: importRunID,
        lineNumber: person.lineNumber
      )
      sourcePeople.append(
        SourcePerson(
          id: sourcePersonID,
          sourceLibraryID: sourceLibraryID,
          externalID: person.externalID,
          displayName: person.name,
          observationID: personObservationID
        ))
      if let name = person.name, !name.isEmpty {
        personNameClaims.append(
          PersonNameClaim(
            id: CatalogStableID.make(
              prefix: "person-name-claim",
              components: [personObservationID, sourcePersonID]
            ),
            sourcePersonID: sourcePersonID,
            importRunID: importRunID,
            observationID: personObservationID,
            displayName: name,
            authorship: .unknown,
            confidence: 1,
            observedAt: importedAt
          ))
      }
    }

    var membershipClaims: [PersonMembershipClaim] = []
    membershipClaims.reserveCapacity(memberships.count)
    for membership in memberships {
      let sourceItemID = CatalogStableID.make(
        prefix: "source-item",
        components: [sourceLibraryID, membership.photoExternalID]
      )
      let sourcePersonID = CatalogStableID.make(
        prefix: "source-person",
        components: [sourceLibraryID, membership.personExternalID]
      )
      let observationID = observationID(
        importRunID: importRunID,
        lineNumber: membership.lineNumber
      )
      membershipClaims.append(
        PersonMembershipClaim(
          id: CatalogStableID.make(
            prefix: "person-membership",
            components: [observationID, sourcePersonID, sourceItemID]
          ),
          sourcePersonID: sourcePersonID,
          sourceItemID: sourceItemID,
          assetID: CatalogStableID.make(prefix: "asset", components: [sourceItemID]),
          importRunID: importRunID,
          observationID: observationID,
          confidence: 1
        ))
    }

    return CatalogSnapshot(
      sourceLibraries: [sourceLibrary],
      importRuns: [importRun],
      assets: assets,
      sourceItems: sourceItems,
      sourceResources: sourceResources,
      metadataClaims: claims,
      sourcePeople: sourcePeople,
      personNameClaims: personNameClaims,
      personMembershipClaims: membershipClaims,
      sourceObservations: observations
    )
  }

  private func makeClaims(
    node: JSONValue,
    assetID: String,
    sourceItemID: String,
    importRunID: String,
    observationID: String,
    observedAt: Date
  ) -> [MetadataClaim] {
    struct Mapping {
      enum ValueKind {
        case boolean
        case integer
        case location
        case string
        case timestamp
      }

      let field: String
      let path: [String]
      let valueKind: ValueKind
      let authorship: ClaimAuthorship
      let confidence: Double
    }
    let mappings = [
      Mapping(
        field: "filename.original", path: ["name"], valueKind: .string,
        authorship: .providerDerived, confidence: 1),
      Mapping(
        field: "date.providerCreated", path: ["createdDate"], valueKind: .timestamp,
        authorship: .providerDerived, confidence: 1),
      Mapping(
        field: "date.providerModified", path: ["modifiedDate"], valueKind: .timestamp,
        authorship: .providerDerived, confidence: 1),
      Mapping(
        field: "date.providerContent", path: ["contentProperties", "contentDate"],
        valueKind: .timestamp, authorship: .providerDerived, confidence: 0.9),
      Mapping(
        field: "date.embeddedOriginal", path: ["contentProperties", "image", "dateTimeOriginal"],
        valueKind: .timestamp, authorship: .embeddedMetadata, confidence: 0.95),
      Mapping(
        field: "date.embeddedDigitized", path: ["contentProperties", "image", "dateTimeDigitized"],
        valueKind: .timestamp, authorship: .embeddedMetadata, confidence: 0.95),
      Mapping(
        field: "dimension.width", path: ["contentProperties", "image", "width"],
        valueKind: .integer, authorship: .embeddedMetadata, confidence: 0.95),
      Mapping(
        field: "dimension.height", path: ["contentProperties", "image", "height"],
        valueKind: .integer, authorship: .embeddedMetadata, confidence: 0.95),
      Mapping(
        field: "camera.make", path: ["contentProperties", "image", "make"], valueKind: .string,
        authorship: .embeddedMetadata, confidence: 0.95),
      Mapping(
        field: "camera.model", path: ["contentProperties", "image", "model"], valueKind: .string,
        authorship: .embeddedMetadata, confidence: 0.95),
      Mapping(
        field: "location.embedded", path: ["contentProperties", "image", "location"],
        valueKind: .location, authorship: .embeddedMetadata, confidence: 0.9),
      Mapping(
        field: "favorite.provider", path: ["settings", "favorite"], valueKind: .boolean,
        authorship: .userAuthored, confidence: 0.9),
      Mapping(
        field: "media.contentType", path: ["contentProperties", "contentType"], valueKind: .string,
        authorship: .providerDerived, confidence: 1),
      Mapping(
        field: "source.status", path: ["status"], valueKind: .string, authorship: .providerDerived,
        confidence: 1),
    ]

    return mappings.compactMap { mapping in
      guard let value = node.value(at: mapping.path), value != .null else { return nil }
      let normalizedValue: MetadataValue
      switch mapping.valueKind {
      case .boolean:
        guard let value = value.boolValue else { return nil }
        normalizedValue = .boolean(value)
      case .integer:
        guard let value = value.intValue else { return nil }
        normalizedValue = .integer(value)
      case .location:
        normalizedValue = .location(value)
      case .string:
        guard let value = value.stringValue else { return nil }
        normalizedValue = .string(value)
      case .timestamp:
        guard let value = value.stringValue else { return nil }
        normalizedValue = .timestamp(value)
      }
      let sourcePath = mapping.path.joined(separator: ".")
      return MetadataClaim(
        id: CatalogStableID.make(
          prefix: "claim",
          components: [observationID, mapping.field, sourcePath]
        ),
        assetID: assetID,
        sourceItemID: sourceItemID,
        importRunID: importRunID,
        observationID: observationID,
        field: mapping.field,
        normalizedValue: normalizedValue,
        rawValue: value,
        sourceJSONPath: sourcePath,
        authorship: mapping.authorship,
        confidence: mapping.confidence,
        observedAt: observedAt
      )
    }
  }

  private func observationID(importRunID: String, lineNumber: Int) -> String {
    CatalogStableID.make(
      prefix: "observation",
      components: [importRunID, String(lineNumber)]
    )
  }

  private static func isHexDigest(_ value: String, length: Int) -> Bool {
    value.count == length
      && value.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 48...57, 65...70, 97...102: true
        default: false
        }
      }
  }
}

private struct Manifest {
  let schemaVersion: Int
  let capturedAt: String?
}

private struct Summary {
  let lineNumber: Int
  let expectedPhotoCount: Int
  let uniquePhotoCount: Int
  let namedPersonCount: Int
  let membershipCount: Int
}

private struct ParsedRecord {
  let lineNumber: Int
  let recordType: String
  let raw: JSONValue
}

private struct ParsedPhoto {
  let lineNumber: Int
  let externalID: String
  let node: JSONValue
}

private struct ParsedPerson {
  let lineNumber: Int
  let externalID: String
  let name: String?
}

private struct ParsedMembership {
  let lineNumber: Int
  let personExternalID: String
  let photoExternalID: String
}

extension JSONValue {
  fileprivate var firstObjectValue: [String: JSONValue]? {
    guard case .array(let values) = self else { return nil }
    return values.first?.objectValue
  }
}
