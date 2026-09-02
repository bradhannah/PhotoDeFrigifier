import Foundation

public struct CanonicalPersonMembership: Equatable, Identifiable, Sendable {
  public var id: String { "\(canonicalPersonID)|\(assetID)" }
  public let canonicalPersonID: String
  public let assetID: String
  public let originatingClaimIDs: [String]
  public let isPropagated: Bool

  public init(
    canonicalPersonID: String,
    assetID: String,
    originatingClaimIDs: [String],
    isPropagated: Bool
  ) {
    self.canonicalPersonID = canonicalPersonID
    self.assetID = assetID
    self.originatingClaimIDs = originatingClaimIDs
    self.isPropagated = isPropagated
  }
}

public struct EffectivePersonRouting: Equatable, Sendable {
  public let canonicalPersonIDs: [String]
  public let apple: ApplePersonRoute?
  public let google: GooglePersonRoute?

  public init(
    canonicalPersonIDs: [String],
    apple: ApplePersonRoute?,
    google: GooglePersonRoute?
  ) {
    self.canonicalPersonIDs = canonicalPersonIDs
    self.apple = apple
    self.google = google
  }
}

public struct CatalogPeopleIndex: Equatable, Sendable {
  public let memberships: [CanonicalPersonMembership]
  public let effectiveRoutingByAssetID: [String: EffectivePersonRouting]

  public init(
    snapshot: CatalogSnapshot,
    reviewState: LibraryProjectReviewState,
    identityIndex: CatalogIdentityIndex? = nil,
    duplicateIndex: CatalogDuplicateIndex? = nil
  ) {
    let identity = identityIndex ?? CatalogIdentityIndex(snapshot: snapshot)
    let duplicates =
      duplicateIndex
      ?? CatalogDuplicateIndex(snapshot: snapshot, identityIndex: identity)
    let resolutions = CatalogDuplicateResolutionIndex(
      duplicateIndex: duplicates,
      reviewState: reviewState
    )
    var resourceGraph: [String: Set<String>] = [:]
    for pair in duplicates.pairs where resolutions.establishesSafeIdentity(for: pair) {
      Self.connect(
        [pair.first.sourceResourceID, pair.second.sourceResourceID],
        graph: &resourceGraph
      )
    }

    let libraries = Dictionary(
      uniqueKeysWithValues: snapshot.sourceLibraries.map { ($0.id, $0) })
    let items = Dictionary(uniqueKeysWithValues: snapshot.sourceItems.map { ($0.id, $0) })
    let observations = Dictionary(
      uniqueKeysWithValues: snapshot.sourceObservations.map { ($0.id, $0) })
    let resourcesByItemID = Dictionary(
      grouping: snapshot.sourceResources.filter { resource in
        resource.latestObservationID == items[resource.sourceItemID]?.latestObservationID
      },
      by: \.sourceItemID
    )
    let assetsByItemID = snapshot.assets.reduce(into: [String: String]()) { result, asset in
      for itemID in asset.sourceItemIDs { result[itemID] = asset.id }
    }
    let assetsByResourceID = snapshot.assets.reduce(into: [String: String]()) { result, asset in
      for resourceID in asset.sourceResourceIDs { result[resourceID] = asset.id }
    }
    let currentSourcePersonIDs = Set<String>(
      snapshot.sourcePeople.compactMap { person -> String? in
        guard
          observations[person.observationID]?.importRunID
            == libraries[person.sourceLibraryID]?.latestImportRunID
        else { return nil }
        return person.id
      })

    struct MembershipKey: Hashable {
      let personID: String
      let assetID: String
    }
    struct MembershipValue {
      var claimIDs: Set<String>
      var isPropagated: Bool
    }
    var values: [MembershipKey: MembershipValue] = [:]

    for person in reviewState.canonicalPeople {
      let assignedSourcePersonIDs = Set(person.sourcePersonIDs).intersection(currentSourcePersonIDs)
      guard !assignedSourcePersonIDs.isEmpty else { continue }
      for claim in snapshot.personMembershipClaims {
        guard
          assignedSourcePersonIDs.contains(claim.sourcePersonID),
          let item = items[claim.sourceItemID],
          item.lastSeenImportRunID == libraries[item.sourceLibraryID]?.latestImportRunID,
          claim.importRunID == libraries[item.sourceLibraryID]?.latestImportRunID,
          assetsByItemID[item.id] == claim.assetID
        else { continue }

        let directKey = MembershipKey(personID: person.id, assetID: claim.assetID)
        var direct =
          values[directKey]
          ?? MembershipValue(claimIDs: [], isPropagated: false)
        direct.claimIDs.insert(claim.id)
        direct.isPropagated = false
        values[directKey] = direct

        let startingResources = resourcesByItemID[item.id, default: []].map(\.id)
        let connectedResources = Self.connectedResources(
          from: startingResources,
          graph: resourceGraph
        )
        for resourceID in connectedResources {
          guard let assetID = assetsByResourceID[resourceID], assetID != claim.assetID else {
            continue
          }
          let key = MembershipKey(personID: person.id, assetID: assetID)
          var propagated =
            values[key]
            ?? MembershipValue(claimIDs: [], isPropagated: true)
          propagated.claimIDs.insert(claim.id)
          values[key] = propagated
        }
      }
    }

    memberships = values.map { key, value in
      CanonicalPersonMembership(
        canonicalPersonID: key.personID,
        assetID: key.assetID,
        originatingClaimIDs: value.claimIDs.sorted(),
        isPropagated: value.isPropagated
      )
    }.sorted { $0.id < $1.id }

    let peopleByID = Dictionary(
      uniqueKeysWithValues: reviewState.canonicalPeople.map { ($0.id, $0) })
    let membershipsByAssetID = Dictionary(grouping: memberships, by: \.assetID)
    effectiveRoutingByAssetID = membershipsByAssetID.mapValues { assetMemberships in
      let personIDs = Array(Set(assetMemberships.map(\.canonicalPersonID))).sorted()
      let people = personIDs.compactMap { peopleByID[$0] }
      let appleRoutes = people.compactMap(\.routing.apple)
      let googleRoutes = people.compactMap(\.routing.google)
      let apple =
        appleRoutes.count == people.count
        ? appleRoutes.max { $0.restrictionLevel < $1.restrictionLevel }
        : nil
      let google: GooglePersonRoute? =
        googleRoutes.count == people.count
        ? (googleRoutes.contains(.exclude) ? .exclude : .include)
        : nil
      return EffectivePersonRouting(
        canonicalPersonIDs: personIDs,
        apple: apple,
        google: google
      )
    }
  }

  private static func connect(_ resourceIDs: [String], graph: inout [String: Set<String>]) {
    guard let first = resourceIDs.first else { return }
    for resourceID in resourceIDs.dropFirst() {
      graph[first, default: []].insert(resourceID)
      graph[resourceID, default: []].insert(first)
    }
  }

  private static func connectedResources(
    from startingResourceIDs: [String],
    graph: [String: Set<String>]
  ) -> Set<String> {
    var visited = Set(startingResourceIDs)
    var pending = startingResourceIDs
    while let resourceID = pending.popLast() {
      for neighbor in graph[resourceID, default: []] where visited.insert(neighbor).inserted {
        pending.append(neighbor)
      }
    }
    return visited
  }
}
