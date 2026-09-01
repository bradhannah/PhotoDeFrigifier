import Foundation

public enum CatalogMerge {
  public static func merging(
    _ incoming: CatalogSnapshot,
    into existing: CatalogSnapshot
  ) throws -> CatalogSnapshot {
    try CatalogJSONLStore.validate(existing)
    try CatalogJSONLStore.validate(incoming)
    try rejectIdentityConflicts(existing: existing, incoming: incoming)
    if incoming.importRuns.allSatisfy({ run in
      existing.importRuns.contains { sameImportIdentity($0, run) }
    }) {
      return existing
    }

    var result = existing
    result.sourceLibraries = mergeSourceLibraries(
      existing.sourceLibraries, incoming.sourceLibraries)
    result.importRuns = appendingUnique(existing.importRuns, incoming.importRuns, id: \.id)
    result.sourceItems = mergeSourceItems(existing.sourceItems, incoming.sourceItems)
    result.sourceResources = upserting(
      existing.sourceResources, with: incoming.sourceResources, id: \.id)
    result.byteResources = appendingUnique(existing.byteResources, incoming.byteResources, id: \.id)
    result.assetResourceLinks = upserting(
      existing.assetResourceLinks,
      with: incoming.assetResourceLinks,
      id: \.sourceResourceID
    )
    result.metadataClaims = appendingUnique(
      existing.metadataClaims, incoming.metadataClaims, id: \.id)
    result.sourcePeople = upserting(existing.sourcePeople, with: incoming.sourcePeople, id: \.id)
    result.personNameClaims = appendingUnique(
      existing.personNameClaims,
      incoming.personNameClaims,
      id: \.id
    )
    result.personMembershipClaims = appendingUnique(
      existing.personMembershipClaims,
      incoming.personMembershipClaims,
      id: \.id
    )
    result.sourceObservations = appendingUnique(
      existing.sourceObservations,
      incoming.sourceObservations,
      id: \.id
    )
    result.assets = mergeAssets(existing.assets, incoming.assets)
    try CatalogJSONLStore.validate(result)
    return result
  }

  private static func sameImportIdentity(_ lhs: ImportRun, _ rhs: ImportRun) -> Bool {
    lhs.sourceLibraryID == rhs.sourceLibraryID
      && lhs.adapterID == rhs.adapterID
      && lhs.adapterVersion == rhs.adapterVersion
      && lhs.sourceSchemaVersion == rhs.sourceSchemaVersion
      && lhs.sourceFingerprintSHA256 == rhs.sourceFingerprintSHA256
  }

  private static func rejectIdentityConflicts(
    existing: CatalogSnapshot,
    incoming: CatalogSnapshot
  ) throws {
    let libraries = Dictionary(uniqueKeysWithValues: existing.sourceLibraries.map { ($0.id, $0) })
    for value in incoming.sourceLibraries {
      guard let current = libraries[value.id] else { continue }
      guard
        current.provider == value.provider,
        current.externalAccountID == nil || value.externalAccountID == nil
          || current.externalAccountID == value.externalAccountID
      else { throw CatalogStoreError.conflictingEntity("source library") }
    }

    let runs = Dictionary(uniqueKeysWithValues: existing.importRuns.map { ($0.id, $0) })
    for value in incoming.importRuns {
      guard let current = runs[value.id] else { continue }
      guard
        sameImportIdentity(current, value),
        current.sourceRecordCount == value.sourceRecordCount,
        current.capturedAt == value.capturedAt
      else { throw CatalogStoreError.conflictingEntity("import run") }
    }

    let assets = Dictionary(uniqueKeysWithValues: existing.assets.map { ($0.id, $0) })
    for value in incoming.assets {
      guard let current = assets[value.id] else { continue }
      guard !Set(current.sourceItemIDs).isDisjoint(with: value.sourceItemIDs) else {
        throw CatalogStoreError.conflictingEntity("asset")
      }
    }

    let items = Dictionary(uniqueKeysWithValues: existing.sourceItems.map { ($0.id, $0) })
    for value in incoming.sourceItems {
      guard let current = items[value.id] else { continue }
      guard
        current.sourceLibraryID == value.sourceLibraryID,
        current.externalID == value.externalID
      else { throw CatalogStoreError.conflictingEntity("source item") }
    }

    let resources = Dictionary(uniqueKeysWithValues: existing.sourceResources.map { ($0.id, $0) })
    for value in incoming.sourceResources {
      guard let current = resources[value.id] else { continue }
      guard current.sourceItemID == value.sourceItemID else {
        throw CatalogStoreError.conflictingEntity("source resource")
      }
    }

    let byteResources = Dictionary(
      uniqueKeysWithValues: existing.byteResources.map { ($0.id, $0) })
    for value in incoming.byteResources {
      guard let current = byteResources[value.id] else { continue }
      guard current == value else { throw CatalogStoreError.conflictingEntity("byte resource") }
    }

    let links = Dictionary(uniqueKeysWithValues: existing.assetResourceLinks.map { ($0.id, $0) })
    for value in incoming.assetResourceLinks {
      guard let current = links[value.id] else { continue }
      guard current.sourceResourceID == value.sourceResourceID else {
        throw CatalogStoreError.conflictingEntity("asset-resource link")
      }
    }

    let claims = Dictionary(uniqueKeysWithValues: existing.metadataClaims.map { ($0.id, $0) })
    for value in incoming.metadataClaims {
      guard let current = claims[value.id] else { continue }
      guard sameClaimIdentity(current, value) else {
        throw CatalogStoreError.conflictingEntity("metadata claim")
      }
    }

    let people = Dictionary(uniqueKeysWithValues: existing.sourcePeople.map { ($0.id, $0) })
    for value in incoming.sourcePeople {
      guard let current = people[value.id] else { continue }
      guard
        current.sourceLibraryID == value.sourceLibraryID,
        current.externalID == value.externalID
      else { throw CatalogStoreError.conflictingEntity("source person") }
    }

    let memberships = Dictionary(
      uniqueKeysWithValues: existing.personMembershipClaims.map { ($0.id, $0) })
    for value in incoming.personMembershipClaims {
      guard let current = memberships[value.id] else { continue }
      guard current == value else {
        throw CatalogStoreError.conflictingEntity("person membership")
      }
    }

    let personNames = Dictionary(
      uniqueKeysWithValues: existing.personNameClaims.map { ($0.id, $0) })
    for value in incoming.personNameClaims {
      guard let current = personNames[value.id] else { continue }
      guard samePersonNameClaimIdentity(current, value) else {
        throw CatalogStoreError.conflictingEntity("person name claim")
      }
    }

    let observations = Dictionary(
      uniqueKeysWithValues: existing.sourceObservations.map { ($0.id, $0) })
    for value in incoming.sourceObservations {
      guard let current = observations[value.id] else { continue }
      guard current == value else {
        throw CatalogStoreError.conflictingEntity("source observation")
      }
    }
  }

  private static func sameClaimIdentity(_ lhs: MetadataClaim, _ rhs: MetadataClaim) -> Bool {
    lhs.assetID == rhs.assetID
      && lhs.sourceItemID == rhs.sourceItemID
      && lhs.importRunID == rhs.importRunID
      && lhs.observationID == rhs.observationID
      && lhs.field == rhs.field
      && lhs.normalizedValue == rhs.normalizedValue
      && lhs.rawValue == rhs.rawValue
      && lhs.sourceJSONPath == rhs.sourceJSONPath
      && lhs.authorship == rhs.authorship
      && lhs.confidence == rhs.confidence
  }

  private static func samePersonNameClaimIdentity(
    _ lhs: PersonNameClaim,
    _ rhs: PersonNameClaim
  ) -> Bool {
    lhs.sourcePersonID == rhs.sourcePersonID
      && lhs.importRunID == rhs.importRunID
      && lhs.observationID == rhs.observationID
      && lhs.displayName == rhs.displayName
      && lhs.authorship == rhs.authorship
      && lhs.confidence == rhs.confidence
  }

  private static func mergeAssets(_ existing: [Asset], _ incoming: [Asset]) -> [Asset] {
    var result = existing
    var indices = Dictionary(uniqueKeysWithValues: result.indices.map { (result[$0].id, $0) })
    for asset in incoming {
      guard let index = indices[asset.id] else {
        indices[asset.id] = result.count
        result.append(asset)
        continue
      }
      let current = result[index]
      result[index] = Asset(
        id: current.id,
        kind: current.kind == .unknown ? asset.kind : current.kind,
        resolutionState: current.resolutionState == .provisional
          ? asset.resolutionState
          : current.resolutionState,
        sourceItemIDs: Array(Set(current.sourceItemIDs + asset.sourceItemIDs)).sorted(),
        sourceResourceIDs: Array(Set(current.sourceResourceIDs + asset.sourceResourceIDs)).sorted()
      )
    }
    return result
  }

  private static func mergeSourceLibraries(
    _ existing: [SourceLibrary],
    _ incoming: [SourceLibrary]
  ) -> [SourceLibrary] {
    var result = existing
    var indices = Dictionary(uniqueKeysWithValues: result.indices.map { (result[$0].id, $0) })
    for library in incoming {
      guard let index = indices[library.id] else {
        indices[library.id] = result.count
        result.append(library)
        continue
      }
      let current = result[index]
      result[index] = SourceLibrary(
        id: current.id,
        provider: current.provider,
        externalAccountID: current.externalAccountID ?? library.externalAccountID,
        displayName: library.displayName ?? current.displayName
      )
    }
    return result
  }

  private static func mergeSourceItems(
    _ existing: [SourceItem],
    _ incoming: [SourceItem]
  ) -> [SourceItem] {
    var result = existing
    var indices = Dictionary(uniqueKeysWithValues: result.indices.map { (result[$0].id, $0) })
    for item in incoming {
      guard let index = indices[item.id] else {
        indices[item.id] = result.count
        result.append(item)
        continue
      }
      let current = result[index]
      result[index] = SourceItem(
        id: current.id,
        sourceLibraryID: current.sourceLibraryID,
        externalID: current.externalID,
        firstObservedImportRunID: current.firstObservedImportRunID,
        latestObservationID: item.latestObservationID,
        kind: current.kind == .unknown ? item.kind : current.kind
      )
    }
    return result
  }

  private static func upserting<Value>(
    _ existing: [Value],
    with incoming: [Value],
    id: KeyPath<Value, String>
  ) -> [Value] {
    var result = existing
    var indices = Dictionary(
      uniqueKeysWithValues: result.indices.map { (result[$0][keyPath: id], $0) })
    for value in incoming {
      let identifier = value[keyPath: id]
      if let index = indices[identifier] {
        result[index] = value
      } else {
        indices[identifier] = result.count
        result.append(value)
      }
    }
    return result
  }

  private static func appendingUnique<Value>(
    _ existing: [Value],
    _ incoming: [Value],
    id: KeyPath<Value, String>
  ) -> [Value] {
    var result = existing
    var identifiers = Set(existing.map { $0[keyPath: id] })
    for value in incoming where identifiers.insert(value[keyPath: id]).inserted {
      result.append(value)
    }
    return result
  }
}
