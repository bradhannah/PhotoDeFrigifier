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

public struct CatalogPeopleIndex: Equatable, Sendable {
  public let memberships: [CanonicalPersonMembership]
  public let effectivePrivacyByAssetID: [String: PersonPrivacyCategory]

  public init(
    snapshot: CatalogSnapshot,
    reviewState: LibraryProjectReviewState,
    identityIndex: CatalogIdentityIndex? = nil
  ) {
    let identity = identityIndex ?? CatalogIdentityIndex(snapshot: snapshot)
    let confirmedCandidateIDs = Set(
      reviewState.duplicateDecisions.compactMap { decision in
        decision.disposition == .confirmedDuplicate ? decision.candidateID : nil
      })
    var resourceGraph: [String: Set<String>] = [:]
    for match in identity.automaticMatches {
      Self.connect(match.sourceResourceIDs, graph: &resourceGraph)
    }
    for candidate in identity.amazonMD5ReviewCandidates
    where confirmedCandidateIDs.contains(candidate.id) {
      Self.connect(
        candidate.localSourceResourceIDs + candidate.amazonSourceResourceIDs,
        graph: &resourceGraph
      )
    }

    let libraries = Dictionary(
      uniqueKeysWithValues: snapshot.sourceLibraries.map { ($0.id, $0) })
    let items = Dictionary(uniqueKeysWithValues: snapshot.sourceItems.map { ($0.id, $0) })
    let observations = Dictionary(
      uniqueKeysWithValues: snapshot.sourceObservations.map { ($0.id, $0) })
    let resourcesByItemID = Dictionary(grouping: snapshot.sourceResources, by: \.sourceItemID)
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
    effectivePrivacyByAssetID = memberships.reduce(into: [:]) { result, membership in
      guard let category = peopleByID[membership.canonicalPersonID]?.privacyCategory else { return }
      if let current = result[membership.assetID],
        current.restrictionLevel >= category.restrictionLevel
      {
        return
      }
      result[membership.assetID] = category
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
