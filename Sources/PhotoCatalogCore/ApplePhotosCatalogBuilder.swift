import CryptoKit
import Foundation

public struct ApplePhotosSourceIdentity: Equatable, Sendable {
  public let sourceLibraryID: String
  public let externalAccountID: String

  public init(sourceLibraryID: String, externalAccountID: String) {
    self.sourceLibraryID = sourceLibraryID
    self.externalAccountID = externalAccountID
  }

  public static func make() -> ApplePhotosSourceIdentity {
    let externalAccountID = "system-library:\(UUID().uuidString.lowercased())"
    return ApplePhotosSourceIdentity(
      sourceLibraryID: CatalogStableID.make(
        prefix: "library",
        components: [CatalogProvider.applePhotos.rawValue, externalAccountID]
      ),
      externalAccountID: externalAccountID
    )
  }
}

public enum ApplePhotosCatalogBuildError: Error, Equatable, LocalizedError {
  case duplicateAssetIdentifier
  case duplicateResourceIdentifier
  case invalidMeasurement
  case sourceLibraryAlreadyConnected
  case sourceLibraryChanged

  public var errorDescription: String? {
    switch self {
    case .duplicateAssetIdentifier:
      "Apple Photos returned a duplicate asset identifier."
    case .duplicateResourceIdentifier:
      "Apple Photos returned a duplicate resource identifier for one asset."
    case .invalidMeasurement:
      "An Apple Photos resource measurement was incomplete or invalid."
    case .sourceLibraryAlreadyConnected:
      "This system Photos library is already connected. Use Rescan on its source card."
    case .sourceLibraryChanged:
      "The system Photos library no longer matches this project source. Add it as a new source instead."
    }
  }
}

public enum ApplePhotosCatalogBuilder {
  public static let descriptor = CatalogAdapterDescriptor(
    id: "com.photodefrigifier.apple-photokit",
    version: 1,
    provider: .applePhotos
  )

  public static func updatedIdentityAnchors(
    previous: [String],
    incoming: [String],
    limit: Int = 64
  ) throws -> [String] {
    let previous = Array(Set(previous)).sorted()
    let incoming = Array(Set(incoming)).sorted()
    let incomingSet = Set(incoming)
    guard previous.isEmpty || previous.contains(where: incomingSet.contains) else {
      throw ApplePhotosCatalogBuildError.sourceLibraryChanged
    }
    let retained = previous.filter(incomingSet.contains)
    let retainedSet = Set(retained)
    let additions = incoming.filter { !retainedSet.contains($0) }
    return Array((retained + additions).prefix(max(limit, 0)))
  }

  public static func build(
    observations: [ApplePhotoObservation],
    sourceIdentity: ApplePhotosSourceIdentity,
    importedAt: Date = Date()
  ) throws -> CatalogSnapshot {
    let observations = observations.sorted { $0.localIdentifier < $1.localIdentifier }
    guard Set(observations.map(\.localIdentifier)).count == observations.count else {
      throw ApplePhotosCatalogBuildError.duplicateAssetIdentifier
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var prepared: [(ApplePhotoObservation, JSONValue)] = []
    var fingerprintHasher = SHA256()
    for observation in observations {
      let resources = observation.resources.sorted { $0.externalID < $1.externalID }
      guard Set(resources.map(\.externalID)).count == resources.count else {
        throw ApplePhotosCatalogBuildError.duplicateResourceIdentifier
      }
      let normalized = ApplePhotoObservation(
        localIdentifier: observation.localIdentifier,
        kind: observation.kind,
        resources: resources,
        metadata: observation.metadata
      )
      let encoded = try encoder.encode(normalized)
      fingerprintHasher.update(data: encoded)
      fingerprintHasher.update(data: Data([0x0A]))
      prepared.append((normalized, try JSONDecoder().decode(JSONValue.self, from: encoded)))
    }

    let fingerprint = CatalogStableID.hex(fingerprintHasher.finalize())
    let importRunID = CatalogStableID.make(
      prefix: "import",
      components: [
        descriptor.id,
        String(descriptor.version),
        "1",
        sourceIdentity.sourceLibraryID,
        fingerprint,
      ]
    )
    let sourceLibrary = SourceLibrary(
      id: sourceIdentity.sourceLibraryID,
      provider: .applePhotos,
      externalAccountID: sourceIdentity.externalAccountID,
      displayName: "Apple Photos",
      latestImportRunID: importRunID
    )
    let importRun = ImportRun(
      id: importRunID,
      sourceLibraryID: sourceIdentity.sourceLibraryID,
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
    var links: [AssetResourceLink] = []
    var claims: [MetadataClaim] = []
    var sourceObservations: [SourceObservation] = []

    for (index, preparedObservation) in prepared.enumerated() {
      let (observation, rawRecord) = preparedObservation
      let sourceItemID = CatalogStableID.make(
        prefix: "source-item",
        components: [sourceIdentity.sourceLibraryID, observation.localIdentifier]
      )
      let assetID = CatalogStableID.make(prefix: "asset", components: [sourceItemID])
      let observationID = CatalogStableID.make(
        prefix: "observation",
        components: [importRunID, String(index + 1)]
      )
      var resourceIDs: [String] = []

      sourceObservations.append(
        SourceObservation(
          id: observationID,
          importRunID: importRunID,
          sourceItemID: sourceItemID,
          lineNumber: index + 1,
          recordType: "applePhotoKitAsset",
          rawRecord: rawRecord
        ))
      sourceItems.append(
        SourceItem(
          id: sourceItemID,
          sourceLibraryID: sourceIdentity.sourceLibraryID,
          externalID: observation.localIdentifier,
          firstObservedImportRunID: importRunID,
          latestObservationID: observationID,
          lastSeenImportRunID: importRunID,
          kind: observation.kind
        ))

      for resource in observation.resources {
        let resourceID = CatalogStableID.make(
          prefix: "source-resource",
          components: [sourceItemID, resource.externalID]
        )
        resourceIDs.append(resourceID)
        let measuredByteCount = resource.localMeasurement?.byteCount
        sourceResources.append(
          SourceResource(
            id: resourceID,
            sourceItemID: sourceItemID,
            role: resource.role,
            originalFilename: resource.filename,
            mediaType: resource.mediaType,
            byteCount: measuredByteCount ?? resource.byteCount,
            width: resource.width,
            height: resource.height,
            reportedDigests: resource.reportedDigests
          ))
        if let measurement = resource.localMeasurement {
          guard
            resource.localReadState == .measured,
            Self.isHex(measurement.sha256, length: 64),
            Self.isHex(measurement.md5, length: 32),
            measurement.byteCount >= 0
          else {
            throw ApplePhotosCatalogBuildError.invalidMeasurement
          }
          let byteResourceID = CatalogStableID.make(
            prefix: "byte-resource",
            components: [
              ByteVerificationMethod.localSHA256.rawValue,
              measurement.sha256.lowercased(),
              String(measurement.byteCount),
            ]
          )
          if byteResourcesByID[byteResourceID] == nil {
            byteResourcesByID[byteResourceID] = ByteResource(
              id: byteResourceID,
              sha256: measurement.sha256.lowercased(),
              locallyMeasuredMD5: measurement.md5.lowercased(),
              byteCount: measurement.byteCount,
              verificationMethod: .localSHA256,
              measuredAt: importedAt
            )
          }
          links.append(
            AssetResourceLink(
              id: CatalogStableID.make(
                prefix: "asset-resource-link",
                components: [resourceID]
              ),
              sourceResourceID: resourceID,
              byteResourceID: byteResourceID,
              sourceObservationID: observationID,
              verifiedAt: importedAt
            ))
        } else if resource.localReadState == .measured {
          throw ApplePhotosCatalogBuildError.invalidMeasurement
        }
      }

      assets.append(
        Asset(
          id: assetID,
          kind: observation.kind,
          resolutionState: .provisional,
          sourceItemIDs: [sourceItemID],
          sourceResourceIDs: resourceIDs.sorted()
        ))
      claims.append(
        contentsOf: makeClaims(
          metadata: observation.metadata,
          assetID: assetID,
          sourceItemID: sourceItemID,
          importRunID: importRunID,
          observationID: observationID,
          observedAt: importedAt
        ))
    }

    let snapshot = CatalogSnapshot(
      sourceLibraries: [sourceLibrary],
      importRuns: [importRun],
      assets: assets,
      sourceItems: sourceItems,
      sourceResources: sourceResources,
      byteResources: byteResourcesByID.values.sorted { $0.id < $1.id },
      assetResourceLinks: links,
      metadataClaims: claims,
      sourceObservations: sourceObservations
    )
    try CatalogJSONLStore.validate(snapshot)
    return snapshot
  }

  private static func makeClaims(
    metadata: [String: JSONValue],
    assetID: String,
    sourceItemID: String,
    importRunID: String,
    observationID: String,
    observedAt: Date
  ) -> [MetadataClaim] {
    metadata.keys.sorted().compactMap { field in
      guard let rawValue = metadata[field] else { return nil }
      return MetadataClaim(
        id: CatalogStableID.make(
          prefix: "claim",
          components: [observationID, field, "metadata.\(field)"]
        ),
        assetID: assetID,
        sourceItemID: sourceItemID,
        importRunID: importRunID,
        observationID: observationID,
        field: "apple.\(field)",
        normalizedValue: metadataValue(rawValue, field: field),
        rawValue: rawValue,
        sourceJSONPath: "metadata.\(field)",
        authorship: .providerDerived,
        confidence: 1,
        observedAt: observedAt
      )
    }
  }

  private static func metadataValue(_ value: JSONValue, field: String) -> MetadataValue {
    if field == "location" { return .location(value) }
    switch value {
    case .boolean(let value): return .boolean(value)
    case .integer(let value): return .integer(value)
    case .number(let value): return .number(value)
    case .string(let value): return .string(value)
    case .array(let values):
      return values.allSatisfy { $0.stringValue != nil }
        ? .stringList(values.compactMap(\.stringValue))
        : .json(value)
    case .null, .object: return .json(value)
    }
  }

  private static func isHex(_ value: String, length: Int) -> Bool {
    value.count == length
      && value.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 48...57, 65...70, 97...102: true
        default: false
        }
      }
  }
}
