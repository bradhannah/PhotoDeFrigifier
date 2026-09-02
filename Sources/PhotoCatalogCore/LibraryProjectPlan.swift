import Foundation

public struct AppleRoutingPlan: Equatable, Sendable {
  public let visibleAssetIDs: [String]
  public let hiddenAssetIDs: [String]
  public let excludedAssetIDs: [String]
  public let unresolvedAssetIDs: [String]
}

public struct GoogleRoutingPlan: Equatable, Sendable {
  public let includedAssetIDs: [String]
  public let excludedAssetIDs: [String]
  public let unresolvedAssetIDs: [String]
}

public struct ArchiveRoutingPlan: Equatable, Sendable {
  public let assetIDs: [String]
  public let configuredSlots: [LibraryProjectDestinationSlot]
}

public enum LibraryProjectPlanBlocker: Equatable, Sendable {
  case noCurrentAssets
  case unresolvedDuplicatePairs([String])
  case contradictoryDuplicatePairs([String])
  case duplicateGroupsTooLarge([String])
  case unassignedSourcePeople([String])
  case incompletePersonRouting([String])
  case applePhotosNotConnected
  case destinationNotConfigured(LibraryProjectDestinationSlot)
  case archiveIndependenceUnverified
  case amazonItemsMissingDownloads([String])
}

public enum LibraryProjectCleanupBlocker: Equatable, Sendable {
  case destructiveOperationsNotSupported
  case archiveProtectionUnverified
}

public struct LibraryProjectPlan: Equatable, Sendable {
  public let currentAssetIDs: [String]
  public let apple: AppleRoutingPlan
  public let google: GoogleRoutingPlan
  public let archives: ArchiveRoutingPlan
  public let blockers: [LibraryProjectPlanBlocker]
  public let cleanupBlockers: [LibraryProjectCleanupBlocker]

  public var isConfigurationComplete: Bool { blockers.isEmpty }

  public init(
    project: LibraryProject,
    catalog: CatalogSnapshot,
    reviewState: LibraryProjectReviewState,
    identityIndex: CatalogIdentityIndex? = nil,
    duplicateIndex: CatalogDuplicateIndex? = nil,
    peopleIndex: CatalogPeopleIndex? = nil
  ) {
    let identity = identityIndex ?? CatalogIdentityIndex(snapshot: catalog)
    let duplicates =
      duplicateIndex
      ?? CatalogDuplicateIndex(snapshot: catalog, identityIndex: identity)
    let duplicateResolutions = CatalogDuplicateResolutionIndex(
      duplicateIndex: duplicates,
      reviewState: reviewState
    )
    let people =
      peopleIndex
      ?? CatalogPeopleIndex(
        snapshot: catalog,
        reviewState: reviewState,
        identityIndex: identity,
        duplicateIndex: duplicates
      )
    let libraries = Dictionary(
      catalog.sourceLibraries.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let items = Dictionary(
      catalog.sourceItems.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let observations = Dictionary(
      catalog.sourceObservations.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let resources = Dictionary(
      catalog.sourceResources.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    func isCurrent(_ item: SourceItem) -> Bool {
      guard let latestRunID = libraries[item.sourceLibraryID]?.latestImportRunID else {
        return false
      }
      return item.lastSeenImportRunID == latestRunID
    }

    let currentItemIDs = Set(catalog.sourceItems.filter(isCurrent).map(\.id))
    let currentAssets = catalog.assets.filter { asset in
      asset.sourceItemIDs.contains(where: currentItemIDs.contains)
    }
    let currentAssetIDSet = Set(currentAssets.map(\.id))
    let assetIDByResourceID = currentAssets.reduce(into: [String: String]()) { result, asset in
      for resourceID in asset.sourceResourceIDs { result[resourceID] = asset.id }
    }
    let currentResourceIDsByAssetID = currentAssets.reduce(into: [String: Set<String>]()) {
      result, asset in
      result[asset.id] = Set(
        asset.sourceResourceIDs.filter { resourceID in
          guard let resource = resources[resourceID], let item = items[resource.sourceItemID] else {
            return false
          }
          return isCurrent(item) && resource.latestObservationID == item.latestObservationID
        })
    }
    var establishedResourceGraph: [String: Set<String>] = [:]
    for pair in duplicates.pairs
    where duplicateResolutions.establishesSafeIdentity(for: pair) {
      establishedResourceGraph[pair.first.sourceResourceID, default: []].insert(
        pair.second.sourceResourceID)
      establishedResourceGraph[pair.second.sourceResourceID, default: []].insert(
        pair.first.sourceResourceID)
    }
    let currentResourceIDSet = Set(currentResourceIDsByAssetID.values.flatMap { $0 })
    var resourceComponentIDByResourceID: [String: String] = [:]
    for resourceID in currentResourceIDSet.sorted()
    where resourceComponentIDByResourceID[resourceID] == nil {
      var component: Set<String> = [resourceID]
      var pending = [resourceID]
      while let pendingResourceID = pending.popLast() {
        for neighbor in establishedResourceGraph[pendingResourceID, default: []]
        where currentResourceIDSet.contains(neighbor) && component.insert(neighbor).inserted {
          pending.append(neighbor)
        }
      }
      let componentID = component.min() ?? resourceID
      for componentResourceID in component {
        resourceComponentIDByResourceID[componentResourceID] = componentID
      }
    }
    struct AssetPairKey: Hashable {
      let first: String
      let second: String

      init(_ first: String, _ second: String) {
        self.first = min(first, second)
        self.second = max(first, second)
      }
    }
    let candidateAssetPairs = Set(
      duplicates.pairs.compactMap { pair -> AssetPairKey? in
        guard
          duplicateResolutions.establishesSafeIdentity(for: pair),
          let firstAssetID = assetIDByResourceID[pair.first.sourceResourceID],
          let secondAssetID = assetIDByResourceID[pair.second.sourceResourceID],
          firstAssetID != secondAssetID
        else { return nil }
        return AssetPairKey(firstAssetID, secondAssetID)
      })
    var duplicateAssetGraph: [String: Set<String>] = [:]
    for assetPair in candidateAssetPairs {
      let firstResourceIDs = currentResourceIDsByAssetID[assetPair.first, default: []]
      let secondResourceIDs = currentResourceIDsByAssetID[assetPair.second, default: []]
      let firstSignature = firstResourceIDs.map {
        resourceComponentIDByResourceID[$0] ?? $0
      }.sorted()
      let secondSignature = secondResourceIDs.map {
        resourceComponentIDByResourceID[$0] ?? $0
      }.sorted()
      guard
        !firstResourceIDs.isEmpty,
        firstResourceIDs.count == secondResourceIDs.count,
        firstSignature == secondSignature
      else { continue }
      duplicateAssetGraph[assetPair.first, default: []].insert(assetPair.second)
      duplicateAssetGraph[assetPair.second, default: []].insert(assetPair.first)
    }
    var representativeByAssetID: [String: String] = [:]
    for assetID in currentAssetIDSet.sorted() where representativeByAssetID[assetID] == nil {
      var component: Set<String> = [assetID]
      var pending = [assetID]
      while let pendingAssetID = pending.popLast() {
        for neighbor in duplicateAssetGraph[pendingAssetID, default: []]
        where currentAssetIDSet.contains(neighbor) && component.insert(neighbor).inserted {
          pending.append(neighbor)
        }
      }
      let representativeID =
        component.sorted { lhs, rhs in
          let lhsAsset = currentAssets.first { $0.id == lhs }
          let rhsAsset = currentAssets.first { $0.id == rhs }
          let lhsProviders = Set(
            lhsAsset?.sourceItemIDs.compactMap { itemID in
              items[itemID].flatMap { libraries[$0.sourceLibraryID]?.provider }
            } ?? [])
          let rhsProviders = Set(
            rhsAsset?.sourceItemIDs.compactMap { itemID in
              items[itemID].flatMap { libraries[$0.sourceLibraryID]?.provider }
            } ?? [])
          func providerRank(_ providers: Set<CatalogProvider>) -> Int {
            if providers.contains(.filesystem) { return 0 }
            if providers.contains(.applePhotos) { return 1 }
            if providers.contains(.googlePhotos) { return 2 }
            return 3
          }
          let lhsRank = providerRank(lhsProviders)
          let rhsRank = providerRank(rhsProviders)
          return lhsRank == rhsRank ? lhs < rhs : lhsRank < rhsRank
        }.first ?? assetID
      for componentAssetID in component {
        representativeByAssetID[componentAssetID] = representativeID
      }
    }
    currentAssetIDs = Array(Set(representativeByAssetID.values)).sorted()

    let assetsByItemID = currentAssets.reduce(into: [String: String]()) { result, asset in
      for itemID in asset.sourceItemIDs where currentItemIDs.contains(itemID) {
        result[itemID] = asset.id
      }
    }
    let currentSourcePersonIDs = Set<String>(
      catalog.sourcePeople.compactMap { person -> String? in
        guard
          observations[person.observationID]?.importRunID
            == libraries[person.sourceLibraryID]?.latestImportRunID
        else { return nil }
        return person.id
      })
    let assignedSourcePersonIDs = Set(reviewState.canonicalPeople.flatMap(\.sourcePersonIDs))
    let currentMembershipClaims = catalog.personMembershipClaims.filter { claim in
      guard
        currentSourcePersonIDs.contains(claim.sourcePersonID),
        let item = items[claim.sourceItemID],
        isCurrent(item),
        claim.importRunID == libraries[item.sourceLibraryID]?.latestImportRunID
      else { return false }
      return assetsByItemID[item.id] == claim.assetID
    }
    let unassignedSourcePersonIDs = Set(
      currentMembershipClaims.compactMap { claim in
        assignedSourcePersonIDs.contains(claim.sourcePersonID) ? nil : claim.sourcePersonID
      })
    let unresolvedPersonAssetIDs = Set(
      currentMembershipClaims.compactMap { claim in
        unassignedSourcePersonIDs.contains(claim.sourcePersonID)
          ? representativeByAssetID[claim.assetID]
          : nil
      })

    var appleVisible: [String] = []
    var appleHidden: [String] = []
    var appleExcluded: [String] = []
    var appleUnresolved: [String] = []
    var googleIncluded: [String] = []
    var googleExcluded: [String] = []
    var googleUnresolved: [String] = []
    for assetID in currentAssetIDs {
      if unresolvedPersonAssetIDs.contains(assetID) {
        appleUnresolved.append(assetID)
        googleUnresolved.append(assetID)
        continue
      }
      guard let routing = people.effectiveRoutingByAssetID[assetID] else {
        appleVisible.append(assetID)
        googleIncluded.append(assetID)
        continue
      }
      switch routing.apple {
      case .visible: appleVisible.append(assetID)
      case .hidden: appleHidden.append(assetID)
      case .exclude: appleExcluded.append(assetID)
      case nil: appleUnresolved.append(assetID)
      }
      switch routing.google {
      case .include: googleIncluded.append(assetID)
      case .exclude: googleExcluded.append(assetID)
      case nil: googleUnresolved.append(assetID)
      }
    }
    apple = AppleRoutingPlan(
      visibleAssetIDs: appleVisible,
      hiddenAssetIDs: appleHidden,
      excludedAssetIDs: appleExcluded,
      unresolvedAssetIDs: appleUnresolved
    )
    google = GoogleRoutingPlan(
      includedAssetIDs: googleIncluded,
      excludedAssetIDs: googleExcluded,
      unresolvedAssetIDs: googleUnresolved
    )

    let configuredArchiveSlots = [
      LibraryProjectDestinationSlot.archiveOne,
      .archiveTwo,
    ].filter { project.destinations[$0] != nil }
    archives = ArchiveRoutingPlan(
      assetIDs: currentAssetIDs,
      configuredSlots: configuredArchiveSlots
    )

    let unresolvedPairIDs = Set(
      duplicates.pairs.compactMap { pair -> String? in
        duplicateResolutions.resolution(for: pair) == .unresolved ? pair.id : nil
      })

    let membershipPersonIDs = Set(people.memberships.map(\.canonicalPersonID))
    let incompletePersonIDs = reviewState.canonicalPeople.compactMap { person in
      membershipPersonIDs.contains(person.id) && !person.routing.isComplete ? person.id : nil
    }
    let coverages = AmazonDownloadCoverageIndex.build(
      snapshot: catalog,
      project: project,
      reviewState: reviewState,
      identityIndex: identity,
      duplicateIndex: duplicates
    )
    let missingAmazonItemIDs = coverages.flatMap(\.missingAmazonItemIDs).sorted()

    var blockers: [LibraryProjectPlanBlocker] = []
    if currentAssetIDs.isEmpty { blockers.append(.noCurrentAssets) }
    if !unresolvedPairIDs.isEmpty {
      blockers.append(.unresolvedDuplicatePairs(unresolvedPairIDs.sorted()))
    }
    if !duplicateResolutions.contradictoryPairIDs.isEmpty {
      blockers.append(.contradictoryDuplicatePairs(duplicateResolutions.contradictoryPairIDs))
    }
    if !duplicates.oversizedGroupIDs.isEmpty {
      blockers.append(.duplicateGroupsTooLarge(duplicates.oversizedGroupIDs))
    }
    if !unassignedSourcePersonIDs.isEmpty {
      blockers.append(.unassignedSourcePeople(unassignedSourcePersonIDs.sorted()))
    }
    if !incompletePersonIDs.isEmpty {
      blockers.append(.incompletePersonRouting(incompletePersonIDs.sorted()))
    }
    if (!appleVisible.isEmpty || !appleHidden.isEmpty)
      && !project.sources.contains(where: { $0.kind == .applePhotos })
    {
      blockers.append(.applePhotosNotConnected)
    }
    if !googleIncluded.isEmpty && project.destinations.googleReadyExport == nil {
      blockers.append(.destinationNotConfigured(.googleReadyExport))
    }
    if !currentAssetIDs.isEmpty && project.destinations.archiveOne == nil {
      blockers.append(.destinationNotConfigured(.archiveOne))
    }
    if !currentAssetIDs.isEmpty && project.destinations.archiveTwo == nil {
      blockers.append(.destinationNotConfigured(.archiveTwo))
    }
    if !currentAssetIDs.isEmpty,
      let firstVolume = project.destinations.archiveOne?.volumeUUID,
      let secondVolume = project.destinations.archiveTwo?.volumeUUID,
      firstVolume == secondVolume
    {
      blockers.append(.archiveIndependenceUnverified)
    } else if !currentAssetIDs.isEmpty
      && (project.destinations.archiveOne?.volumeUUID == nil
        || project.destinations.archiveTwo?.volumeUUID == nil)
    {
      blockers.append(.archiveIndependenceUnverified)
    }
    if !missingAmazonItemIDs.isEmpty {
      blockers.append(.amazonItemsMissingDownloads(missingAmazonItemIDs))
    }
    self.blockers = blockers
    cleanupBlockers = [.destructiveOperationsNotSupported, .archiveProtectionUnverified]
  }
}
