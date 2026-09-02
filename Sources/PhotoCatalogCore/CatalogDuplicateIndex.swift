import Foundation

public enum DuplicateEvidenceKind: String, CaseIterable, Codable, Hashable, Sendable {
  case exactSHA256
  case amazonMD5
  case exactFilename
  case matchingFilenameStem

  fileprivate var priority: Int {
    switch self {
    case .exactSHA256: 0
    case .amazonMD5: 1
    case .exactFilename: 2
    case .matchingFilenameStem: 3
    }
  }
}

public struct DuplicateOccurrence: Equatable, Identifiable, Sendable {
  public var id: String { sourceResourceID }
  public let sourceResourceID: String
  public let sourceItemID: String
  public let sourceLibraryID: String
  public let sourceObservationID: String
  public let provider: CatalogProvider
  public let filename: String
  public let kind: AssetKind
  public let role: ResourceRole
  public let mediaType: String?
  public let byteCount: Int64?
  public let width: Int?
  public let height: Int?

  public init(
    sourceResourceID: String,
    sourceItemID: String,
    sourceLibraryID: String,
    sourceObservationID: String,
    provider: CatalogProvider,
    filename: String,
    kind: AssetKind,
    role: ResourceRole,
    mediaType: String?,
    byteCount: Int64?,
    width: Int?,
    height: Int?
  ) {
    self.sourceResourceID = sourceResourceID
    self.sourceItemID = sourceItemID
    self.sourceLibraryID = sourceLibraryID
    self.sourceObservationID = sourceObservationID
    self.provider = provider
    self.filename = filename
    self.kind = kind
    self.role = role
    self.mediaType = mediaType
    self.byteCount = byteCount
    self.width = width
    self.height = height
  }
}

public struct DuplicateCandidatePair: Equatable, Identifiable, Sendable {
  public let id: String
  public let first: DuplicateOccurrence
  public let second: DuplicateOccurrence
  public let evidence: [DuplicateEvidenceKind]
  public let legacyDecisionCandidateIDs: [String]

  public var isAutomatic: Bool { evidence.contains(.exactSHA256) }

  public init(
    id: String,
    first: DuplicateOccurrence,
    second: DuplicateOccurrence,
    evidence: [DuplicateEvidenceKind],
    legacyDecisionCandidateIDs: [String]
  ) {
    self.id = id
    self.first = first
    self.second = second
    self.evidence = evidence
    self.legacyDecisionCandidateIDs = legacyDecisionCandidateIDs
  }
}

public struct DuplicateCandidateGroup: Equatable, Identifiable, Sendable {
  public let id: String
  public let evidence: [DuplicateEvidenceKind]
  public let occurrences: [DuplicateOccurrence]
  public let legacyDecisionCandidateIDs: [String]

  public var isAutomatic: Bool { evidence.contains(.exactSHA256) }

  public init(
    id: String,
    evidence: [DuplicateEvidenceKind],
    occurrences: [DuplicateOccurrence],
    legacyDecisionCandidateIDs: [String] = []
  ) {
    self.id = id
    self.evidence = evidence
    self.occurrences = occurrences
    self.legacyDecisionCandidateIDs = legacyDecisionCandidateIDs
  }
}

public struct CatalogDuplicateIndex: Equatable, Sendable {
  public let groups: [DuplicateCandidateGroup]
  public let pairs: [DuplicateCandidatePair]
  public let oversizedGroupIDs: [String]
  private let pairsByResourceKey: [String: DuplicateCandidatePair]

  public init(
    snapshot: CatalogSnapshot,
    identityIndex: CatalogIdentityIndex? = nil
  ) {
    let identity = identityIndex ?? CatalogIdentityIndex(snapshot: snapshot)
    let libraries = Dictionary(
      snapshot.sourceLibraries.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let items = Dictionary(
      snapshot.sourceItems.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let resources = Dictionary(
      snapshot.sourceResources.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let automaticGroupIDByResourceID = identity.automaticMatches.reduce(
      into: [String: String]()
    ) { result, match in
      for resourceID in match.sourceResourceIDs { result[resourceID] = match.id }
    }

    func isCurrent(_ item: SourceItem) -> Bool {
      guard let latestRunID = libraries[item.sourceLibraryID]?.latestImportRunID else {
        return false
      }
      return item.lastSeenImportRunID == latestRunID
    }

    func occurrence(_ resourceID: String) -> DuplicateOccurrence? {
      guard
        let resource = resources[resourceID],
        let item = items[resource.sourceItemID],
        let library = libraries[item.sourceLibraryID],
        isCurrent(item),
        resource.latestObservationID == item.latestObservationID
      else { return nil }
      return DuplicateOccurrence(
        sourceResourceID: resource.id,
        sourceItemID: item.id,
        sourceLibraryID: item.sourceLibraryID,
        sourceObservationID: item.latestObservationID,
        provider: library.provider,
        filename: resource.originalFilename ?? "Unnamed resource",
        kind: item.kind,
        role: resource.role,
        mediaType: resource.mediaType,
        byteCount: resource.byteCount,
        width: resource.width,
        height: resource.height
      )
    }

    struct MutableGroup {
      var evidence: Set<DuplicateEvidenceKind>
      var occurrences: [DuplicateOccurrence]
      var legacyDecisionCandidateIDs: Set<String>
    }
    struct MutablePair {
      let first: DuplicateOccurrence
      let second: DuplicateOccurrence
      var evidence: Set<DuplicateEvidenceKind>
      var legacyDecisionCandidateIDs: Set<String>
    }
    var grouped: [String: MutableGroup] = [:]
    var paired: [String: MutablePair] = [:]
    var oversizedKeys: Set<String> = []
    var materializedReviewPairCount = 0

    func add(
      resourceIDs: [String],
      evidence: DuplicateEvidenceKind,
      legacyDecisionCandidateID: String? = nil
    ) {
      let occurrences = resourceIDs.compactMap(occurrence).uniqued(by: \.sourceResourceID)
        .sorted { lhs, rhs in
          let lhsPriority = Self.providerPriority(lhs.provider)
          let rhsPriority = Self.providerPriority(rhs.provider)
          return lhsPriority == rhsPriority
            ? lhs.sourceResourceID < rhs.sourceResourceID
            : lhsPriority < rhsPriority
        }
      guard Set(occurrences.map(\.sourceItemID)).count > 1 else { return }
      let key = occurrences.map(\.sourceResourceID).joined(separator: "|")
      var group =
        grouped[key]
        ?? MutableGroup(
          evidence: [],
          occurrences: occurrences,
          legacyDecisionCandidateIDs: []
        )
      group.evidence.insert(evidence)
      if let legacyDecisionCandidateID {
        group.legacyDecisionCandidateIDs.insert(legacyDecisionCandidateID)
      }
      grouped[key] = group
      let isFilenameEvidence = evidence == .exactFilename || evidence == .matchingFilenameStem
      let estimatedPairCount =
        occurrences.count > 100
        ? Int.max : occurrences.count * (occurrences.count - 1) / 2
      let localRepresentatives = Dictionary(
        grouping: occurrences.filter { $0.provider != .amazon },
        by: \.sourceLibraryID
      ).values.compactMap(\.first).sorted { $0.sourceResourceID < $1.sourceResourceID }
      let amazonOccurrences = occurrences.filter { $0.provider == .amazon }
      let estimatedAmazonPairCount = localRepresentatives.count * amazonOccurrences.count
      if (isFilenameEvidence
        && (occurrences.count > 100
          || materializedReviewPairCount + estimatedPairCount > 20_000))
        || (evidence == .amazonMD5
          && materializedReviewPairCount + estimatedAmazonPairCount > 20_000)
      {
        oversizedKeys.insert(key)
        return
      }

      func addPair(_ first: DuplicateOccurrence, _ second: DuplicateOccurrence) {
        guard first.sourceItemID != second.sourceItemID else { return }
        let pairID = Self.pairID(first, second)
        let wasReviewPair = paired[pairID].map { !$0.evidence.contains(.exactSHA256) } ?? false
        var pair =
          paired[pairID]
          ?? MutablePair(
            first: first,
            second: second,
            evidence: [],
            legacyDecisionCandidateIDs: []
          )
        pair.evidence.insert(evidence)
        if let firstAutomaticGroupID = automaticGroupIDByResourceID[first.sourceResourceID],
          firstAutomaticGroupID == automaticGroupIDByResourceID[second.sourceResourceID]
        {
          pair.evidence.insert(.exactSHA256)
        }
        if let legacyDecisionCandidateID {
          pair.legacyDecisionCandidateIDs.insert(legacyDecisionCandidateID)
        }
        paired[pairID] = pair
        let isReviewPair = !pair.evidence.contains(.exactSHA256)
        if !wasReviewPair && isReviewPair {
          materializedReviewPairCount += 1
        } else if wasReviewPair && !isReviewPair {
          materializedReviewPairCount -= 1
        }
      }

      if evidence == .amazonMD5 {
        for localOccurrence in localRepresentatives {
          for amazonOccurrence in amazonOccurrences {
            addPair(localOccurrence, amazonOccurrence)
          }
        }
      } else if evidence == .exactSHA256, let anchor = occurrences.first {
        for occurrence in occurrences.dropFirst() {
          addPair(anchor, occurrence)
        }
      } else {
        for firstIndex in occurrences.indices {
          for secondIndex in occurrences.indices where secondIndex > firstIndex {
            addPair(occurrences[firstIndex], occurrences[secondIndex])
          }
        }
      }
    }

    for match in identity.automaticMatches {
      add(resourceIDs: match.sourceResourceIDs, evidence: .exactSHA256)
    }
    for candidate in identity.amazonMD5ReviewCandidates {
      add(
        resourceIDs: candidate.localSourceResourceIDs + candidate.amazonSourceResourceIDs,
        evidence: .amazonMD5,
        legacyDecisionCandidateID: candidate.id
      )
    }

    struct FilenameKey: Hashable {
      let value: String
      let kind: AssetKind
      let compatibilityClass: String
    }
    var exactNames: [FilenameKey: Set<String>] = [:]
    var stems: [FilenameKey: Set<String>] = [:]
    var fullNamesByStem: [FilenameKey: Set<String>] = [:]
    for resource in snapshot.sourceResources {
      guard
        resource.role != .sidecar,
        let item = items[resource.sourceItemID],
        item.kind != .unknown,
        isCurrent(item),
        resource.latestObservationID == item.latestObservationID,
        let originalFilename = resource.originalFilename
      else { continue }
      let normalizedName = Self.normalizedFilename(originalFilename)
      guard !normalizedName.isEmpty else { continue }
      let exactKey = FilenameKey(
        value: normalizedName,
        kind: item.kind,
        compatibilityClass: resource.role.compatibilityClass
      )
      exactNames[exactKey, default: []].insert(resource.id)

      let stem = Self.normalizedStem(normalizedName)
      guard !stem.isEmpty else { continue }
      let stemKey = FilenameKey(
        value: stem,
        kind: item.kind,
        compatibilityClass: resource.role.compatibilityClass
      )
      stems[stemKey, default: []].insert(resource.id)
      fullNamesByStem[stemKey, default: []].insert(normalizedName)
    }
    for resourceIDs in exactNames.values where resourceIDs.count > 1 {
      add(resourceIDs: resourceIDs.sorted(), evidence: .exactFilename)
    }
    for (key, resourceIDs) in stems
    where resourceIDs.count > 1 && fullNamesByStem[key, default: []].count > 1 {
      add(resourceIDs: resourceIDs.sorted(), evidence: .matchingFilenameStem)
    }

    groups = grouped.map { key, group in
      DuplicateCandidateGroup(
        id: CatalogStableID.make(prefix: "duplicate-group", components: [key]),
        evidence: group.evidence.sorted { $0.priority < $1.priority },
        occurrences: group.occurrences,
        legacyDecisionCandidateIDs: group.legacyDecisionCandidateIDs.sorted()
      )
    }.sorted { lhs, rhs in
      let lhsPriority = lhs.evidence.first?.priority ?? Int.max
      let rhsPriority = rhs.evidence.first?.priority ?? Int.max
      return lhsPriority == rhsPriority ? lhs.id < rhs.id : lhsPriority < rhsPriority
    }
    let oversizedIDs = Set(
      oversizedKeys.map {
        CatalogStableID.make(prefix: "duplicate-group", components: [$0])
      })
    oversizedGroupIDs = groups.compactMap { group in
      oversizedIDs.contains(group.id) && !group.isAutomatic ? group.id : nil
    }.sorted()
    pairs = paired.map { id, pair in
      DuplicateCandidatePair(
        id: id,
        first: pair.first,
        second: pair.second,
        evidence: pair.evidence.sorted { $0.priority < $1.priority },
        legacyDecisionCandidateIDs: pair.legacyDecisionCandidateIDs.sorted()
      )
    }.sorted { lhs, rhs in
      let lhsPriority = lhs.evidence.first?.priority ?? Int.max
      let rhsPriority = rhs.evidence.first?.priority ?? Int.max
      return lhsPriority == rhsPriority ? lhs.id < rhs.id : lhsPriority < rhsPriority
    }
    pairsByResourceKey = Dictionary(
      uniqueKeysWithValues: pairs.map { pair in
        (Self.resourcePairKey(pair.first.sourceResourceID, pair.second.sourceResourceID), pair)
      }
    )
  }

  public func pair(
    between firstSourceResourceID: String,
    and secondSourceResourceID: String
  ) -> DuplicateCandidatePair? {
    pairsByResourceKey[Self.resourcePairKey(firstSourceResourceID, secondSourceResourceID)]
  }

  public static func pairID(_ first: DuplicateOccurrence, _ second: DuplicateOccurrence) -> String {
    pairID(
      firstSourceResourceID: first.sourceResourceID,
      firstSourceObservationID: first.sourceObservationID,
      secondSourceResourceID: second.sourceResourceID,
      secondSourceObservationID: second.sourceObservationID
    )
  }

  public static func pairID(
    firstSourceResourceID: String,
    firstSourceObservationID: String,
    secondSourceResourceID: String,
    secondSourceObservationID: String
  ) -> String {
    let occurrences = [
      "\(firstSourceResourceID)|\(firstSourceObservationID)",
      "\(secondSourceResourceID)|\(secondSourceObservationID)",
    ].sorted()
    return CatalogStableID.make(
      prefix: "duplicate-pair",
      components: occurrences
    )
  }

  private static func normalizedFilename(_ filename: String) -> String {
    filename.precomposedStringWithCanonicalMapping.folding(
      options: [.caseInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
  }

  private static func resourcePairKey(_ firstResourceID: String, _ secondResourceID: String)
    -> String
  {
    [firstResourceID, secondResourceID].sorted().joined(separator: "|")
  }

  private static func normalizedStem(_ filename: String) -> String {
    (filename as NSString).deletingPathExtension
  }

  private static func providerPriority(_ provider: CatalogProvider) -> Int {
    switch provider {
    case .filesystem: 0
    case .applePhotos: 1
    case .amazon: 2
    case .googlePhotos: 3
    }
  }
}

public enum DuplicatePairResolution: Equatable, Sendable {
  case automatic
  case confirmed
  case rejected
  case unresolved

  public var establishesIdentity: Bool {
    self == .automatic || self == .confirmed
  }
}

public struct CatalogDuplicateResolutionIndex: Equatable, Sendable {
  public let resolutionByPairID: [String: DuplicatePairResolution]
  public let contradictoryPairIDs: [String]
  public let suppressedConfirmedPairIDs: [String]

  public init(
    duplicateIndex: CatalogDuplicateIndex,
    reviewState: LibraryProjectReviewState
  ) {
    let pairDecisionsByID = Dictionary(
      reviewState.duplicatePairDecisions.map { ($0.id, $0) },
      uniquingKeysWith: { first, second in
        first.decidedAt >= second.decidedAt ? first : second
      }
    )
    let resolutions: [String: DuplicatePairResolution] = Dictionary(
      uniqueKeysWithValues: duplicateIndex.pairs.map { pair in
        if pair.isAutomatic { return (pair.id, .automatic) }
        if let decision = pairDecisionsByID[pair.id] {
          return (
            pair.id,
            decision.disposition == .confirmedDuplicate ? .confirmed : .rejected
          )
        }
        return (pair.id, .unresolved)
      })
    var establishedGraph: [String: Set<String>] = [:]
    for pair in duplicateIndex.pairs
    where resolutions[pair.id]?.establishesIdentity == true {
      establishedGraph[pair.first.sourceResourceID, default: []].insert(
        pair.second.sourceResourceID)
      establishedGraph[pair.second.sourceResourceID, default: []].insert(
        pair.first.sourceResourceID)
    }
    var contradictoryIDs: Set<String> = []
    var unsafeResourceIDs: Set<String> = []
    for pair in duplicateIndex.pairs where resolutions[pair.id] == .rejected {
      var visited: Set<String> = [pair.first.sourceResourceID]
      var pending = [pair.first.sourceResourceID]
      while let resourceID = pending.popLast() {
        for neighbor in establishedGraph[resourceID, default: []]
        where visited.insert(neighbor).inserted {
          pending.append(neighbor)
        }
      }
      if visited.contains(pair.second.sourceResourceID) {
        contradictoryIDs.insert(pair.id)
        unsafeResourceIDs.formUnion(visited)
      }
    }
    let suppressedIDs = duplicateIndex.pairs.compactMap { pair -> String? in
      guard resolutions[pair.id] == .confirmed else { return nil }
      return unsafeResourceIDs.contains(pair.first.sourceResourceID)
        || unsafeResourceIDs.contains(pair.second.sourceResourceID)
        ? pair.id : nil
    }
    resolutionByPairID = resolutions
    contradictoryPairIDs = contradictoryIDs.sorted()
    suppressedConfirmedPairIDs = suppressedIDs.sorted()
  }

  public func resolution(for pair: DuplicateCandidatePair) -> DuplicatePairResolution {
    resolutionByPairID[pair.id] ?? .unresolved
  }

  public func establishesSafeIdentity(for pair: DuplicateCandidatePair) -> Bool {
    let resolution = resolution(for: pair)
    return resolution == .automatic
      || (resolution == .confirmed && !suppressedConfirmedPairIDs.contains(pair.id))
  }
}

extension Array {
  fileprivate func uniqued<Value: Hashable>(by keyPath: KeyPath<Element, Value>) -> [Element] {
    var seen: Set<Value> = []
    return filter { seen.insert($0[keyPath: keyPath]).inserted }
  }
}
