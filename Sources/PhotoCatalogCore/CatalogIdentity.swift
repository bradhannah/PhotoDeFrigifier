import Foundation

public struct AutomaticResourceMatch: Equatable, Sendable {
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

public struct CatalogIdentityIndex: Equatable, Sendable {
  public let automaticMatches: [AutomaticResourceMatch]
  public let reportedDigestCandidates: [ReportedDigestCandidate]

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
      guard let byteCount = resource.byteCount else { continue }
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
}
