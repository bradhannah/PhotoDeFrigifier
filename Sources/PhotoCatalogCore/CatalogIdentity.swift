import Foundation

public struct AutomaticResourceMatch: Equatable, Identifiable, Sendable {
  public var id: String {
    "\(sha256)|\(byteCount)|\(sourceResourceIDs.joined(separator: ","))"
  }

  public let sha256: String
  public let byteCount: Int64
  public let sourceResourceIDs: [String]

  public init(sha256: String, byteCount: Int64, sourceResourceIDs: [String]) {
    self.sha256 = sha256
    self.byteCount = byteCount
    self.sourceResourceIDs = sourceResourceIDs
  }
}

public struct ReportedDigestCandidate: Equatable, Sendable {
  public let algorithm: String
  public let digest: String
  public let byteCount: Int64
  public let sourceResourceIDs: [String]

  public init(
    algorithm: String,
    digest: String,
    byteCount: Int64,
    sourceResourceIDs: [String]
  ) {
    self.algorithm = algorithm
    self.digest = digest
    self.byteCount = byteCount
    self.sourceResourceIDs = sourceResourceIDs
  }
}

public struct AmazonMD5ReviewCandidate: Equatable, Identifiable, Sendable {
  public let id: String
  public let locallyMeasuredSHA256: String
  public let byteCount: Int64
  public let localSourceResourceIDs: [String]
  public let amazonSourceResourceIDs: [String]

  public init(
    id: String,
    locallyMeasuredSHA256: String,
    byteCount: Int64,
    localSourceResourceIDs: [String],
    amazonSourceResourceIDs: [String]
  ) {
    self.id = id
    self.locallyMeasuredSHA256 = locallyMeasuredSHA256
    self.byteCount = byteCount
    self.localSourceResourceIDs = localSourceResourceIDs
    self.amazonSourceResourceIDs = amazonSourceResourceIDs
  }
}

public struct CatalogIdentityIndex: Equatable, Sendable {
  public let automaticMatches: [AutomaticResourceMatch]
  public let reportedDigestCandidates: [ReportedDigestCandidate]
  public let amazonMD5ReviewCandidates: [AmazonMD5ReviewCandidate]

  public init(snapshot: CatalogSnapshot) {
    let resources = Dictionary(
      snapshot.sourceResources.map { ($0.id, $0) },
      uniquingKeysWith: { current, _ in current }
    )
    let byteResources = Dictionary(
      snapshot.byteResources.map { ($0.id, $0) },
      uniquingKeysWith: { current, _ in current }
    )
    let sourceItems = Dictionary(
      snapshot.sourceItems.map { ($0.id, $0) },
      uniquingKeysWith: { current, _ in current }
    )
    let sourceLibraries = Dictionary(
      snapshot.sourceLibraries.map { ($0.id, $0) },
      uniquingKeysWith: { current, _ in current }
    )

    func isCurrentlyPresent(_ sourceItemID: String) -> Bool {
      guard let item = sourceItems[sourceItemID] else { return false }
      guard let latestImportRunID = sourceLibraries[item.sourceLibraryID]?.latestImportRunID else {
        return false
      }
      return item.lastSeenImportRunID == latestImportRunID
    }

    func isCurrent(_ resource: SourceResource) -> Bool {
      guard let item = sourceItems[resource.sourceItemID] else { return false }
      return isCurrentlyPresent(item.id)
        && resource.latestObservationID == item.latestObservationID
    }

    struct VerifiedKey: Hashable {
      let sha256: String
      let byteCount: Int64
      let compatibilityClass: String
    }
    var verifiedGroups: [VerifiedKey: Set<String>] = [:]
    for link in snapshot.assetResourceLinks {
      guard
        let sourceResource = resources[link.sourceResourceID],
        let byteResource = byteResources[link.byteResourceID],
        isCurrent(sourceResource),
        sourceResource.latestObservationID == link.sourceObservationID,
        sourceItems[sourceResource.sourceItemID]?.latestObservationID
          == link.sourceObservationID,
        byteResource.verificationMethod == .localSHA256,
        Self.isSHA256(byteResource.sha256)
      else { continue }
      let key = VerifiedKey(
        sha256: byteResource.sha256.lowercased(),
        byteCount: byteResource.byteCount,
        compatibilityClass: sourceResource.role.compatibilityClass
      )
      verifiedGroups[key, default: []].insert(sourceResource.id)
    }
    automaticMatches = verifiedGroups.compactMap { key, resourceIDs in
      let sourceItemIDs = Set(resourceIDs.compactMap { resources[$0]?.sourceItemID })
      guard sourceItemIDs.count > 1 else { return nil }
      return AutomaticResourceMatch(
        sha256: key.sha256,
        byteCount: key.byteCount,
        sourceResourceIDs: resourceIDs.sorted()
      )
    }.sorted { lhs, rhs in
      (lhs.sha256, lhs.byteCount) < (rhs.sha256, rhs.byteCount)
    }

    struct ReportedKey: Hashable {
      let algorithm: String
      let digest: String
      let byteCount: Int64
      let compatibilityClass: String
    }
    var reportedGroups: [ReportedKey: Set<String>] = [:]
    for resource in snapshot.sourceResources {
      guard isCurrent(resource), let byteCount = resource.byteCount else {
        continue
      }
      for digest in resource.reportedDigests {
        let key = ReportedKey(
          algorithm: digest.algorithm.lowercased(),
          digest: digest.value.lowercased(),
          byteCount: byteCount,
          compatibilityClass: resource.role.compatibilityClass
        )
        reportedGroups[key, default: []].insert(resource.id)
      }
    }
    reportedDigestCandidates = reportedGroups.compactMap { key, resourceIDs in
      let sourceItemIDs = Set(resourceIDs.compactMap { resources[$0]?.sourceItemID })
      guard sourceItemIDs.count > 1 else { return nil }
      return ReportedDigestCandidate(
        algorithm: key.algorithm,
        digest: key.digest,
        byteCount: key.byteCount,
        sourceResourceIDs: resourceIDs.sorted()
      )
    }.sorted { lhs, rhs in
      (lhs.algorithm, lhs.digest, lhs.byteCount) < (rhs.algorithm, rhs.digest, rhs.byteCount)
    }

    struct MD5BridgeKey: Hashable {
      let md5: String
      let byteCount: Int64
      let compatibilityClass: String
    }
    struct LocalMD5Anchor {
      let sha256: String
      var sourceResourceIDs: Set<String>
    }
    var localAnchors: [MD5BridgeKey: [String: LocalMD5Anchor]] = [:]
    for link in snapshot.assetResourceLinks {
      guard
        let resource = resources[link.sourceResourceID],
        let item = sourceItems[resource.sourceItemID],
        sourceLibraries[item.sourceLibraryID]?.provider != .amazon,
        isCurrentlyPresent(item.id),
        item.latestObservationID == link.sourceObservationID,
        let bytes = byteResources[link.byteResourceID],
        let md5 = bytes.locallyMeasuredMD5?.lowercased(),
        Self.isMD5(md5)
      else { continue }
      let key = MD5BridgeKey(
        md5: md5,
        byteCount: bytes.byteCount,
        compatibilityClass: resource.role.compatibilityClass
      )
      var anchors = localAnchors[key, default: [:]]
      var anchor =
        anchors[bytes.sha256]
        ?? LocalMD5Anchor(sha256: bytes.sha256, sourceResourceIDs: [])
      anchor.sourceResourceIDs.insert(resource.id)
      anchors[bytes.sha256] = anchor
      localAnchors[key] = anchors
    }

    var amazonResources: [MD5BridgeKey: Set<String>] = [:]
    for resource in snapshot.sourceResources {
      guard
        let item = sourceItems[resource.sourceItemID],
        sourceLibraries[item.sourceLibraryID]?.provider == .amazon,
        isCurrent(resource),
        let byteCount = resource.byteCount
      else { continue }
      for digest in resource.reportedDigests where digest.reportingProvider == .amazon {
        let md5 = digest.value.lowercased()
        guard digest.algorithm.lowercased() == "md5", Self.isMD5(md5) else { continue }
        let key = MD5BridgeKey(
          md5: md5,
          byteCount: byteCount,
          compatibilityClass: resource.role.compatibilityClass
        )
        amazonResources[key, default: []].insert(resource.id)
      }
    }

    amazonMD5ReviewCandidates = localAnchors.flatMap { key, anchors in
      guard let amazonResourceIDs = amazonResources[key], !amazonResourceIDs.isEmpty else {
        return [AmazonMD5ReviewCandidate]()
      }
      // One reported digest cannot safely choose between known-different local bytes.
      guard anchors.count == 1 else { return [] }
      return anchors.values.map { anchor in
        AmazonMD5ReviewCandidate(
          id: CatalogStableID.make(
            prefix: "amazon-md5-review",
            components: [
              anchor.sha256,
              String(key.byteCount),
              key.compatibilityClass,
              key.md5,
            ] + amazonResourceIDs.sorted()
          ),
          locallyMeasuredSHA256: anchor.sha256,
          byteCount: key.byteCount,
          localSourceResourceIDs: anchor.sourceResourceIDs.sorted(),
          amazonSourceResourceIDs: amazonResourceIDs.sorted()
        )
      }
    }.sorted { $0.id < $1.id }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 48...57, 65...70, 97...102: true
        default: false
        }
      }
  }

  private static func isMD5(_ value: String) -> Bool {
    value.count == 32
      && value.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 48...57, 65...70, 97...102: true
        default: false
        }
      }
  }
}
