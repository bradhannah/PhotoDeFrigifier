import Foundation

public struct AmazonDownloadCoverage: Equatable, Identifiable, Sendable {
  public var id: String { amazonSourceID }
  public let amazonSourceID: String
  public let attachedFolderSourceIDs: [String]
  public let downloadedAmazonItemIDs: [String]
  public let candidateAmazonItemIDs: [String]
  public let missingAmazonItemIDs: [String]
  public let unmatchedLocalItemIDs: [String]
  public let candidateIDs: [String]

  public init(
    amazonSourceID: String,
    attachedFolderSourceIDs: [String],
    downloadedAmazonItemIDs: [String],
    candidateAmazonItemIDs: [String],
    missingAmazonItemIDs: [String],
    unmatchedLocalItemIDs: [String],
    candidateIDs: [String]
  ) {
    self.amazonSourceID = amazonSourceID
    self.attachedFolderSourceIDs = attachedFolderSourceIDs
    self.downloadedAmazonItemIDs = downloadedAmazonItemIDs
    self.candidateAmazonItemIDs = candidateAmazonItemIDs
    self.missingAmazonItemIDs = missingAmazonItemIDs
    self.unmatchedLocalItemIDs = unmatchedLocalItemIDs
    self.candidateIDs = candidateIDs
  }
}

public enum AmazonDownloadCoverageIndex {
  public static func build(
    snapshot: CatalogSnapshot,
    project: LibraryProject,
    reviewState: LibraryProjectReviewState = LibraryProjectReviewState(),
    identityIndex: CatalogIdentityIndex? = nil,
    duplicateIndex: CatalogDuplicateIndex? = nil
  ) -> [AmazonDownloadCoverage] {
    let identity = identityIndex ?? CatalogIdentityIndex(snapshot: snapshot)
    let duplicates =
      duplicateIndex
      ?? CatalogDuplicateIndex(snapshot: snapshot, identityIndex: identity)
    let resolutions = CatalogDuplicateResolutionIndex(
      duplicateIndex: duplicates,
      reviewState: reviewState
    )
    let libraries = Dictionary(
      snapshot.sourceLibraries.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let resources = Dictionary(
      snapshot.sourceResources.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    func isCurrent(_ item: SourceItem) -> Bool {
      guard let latestRunID = libraries[item.sourceLibraryID]?.latestImportRunID else {
        return false
      }
      return item.lastSeenImportRunID == latestRunID
    }

    return project.sources.compactMap { amazonSource in
      guard amazonSource.kind == .amazonInventory else { return nil }
      let attachedFolderIDs = Set(
        project.sources.compactMap { source in
          source.kind == .folder && source.attachedToSourceID == amazonSource.id ? source.id : nil
        })
      let amazonItemIDs = Set(
        snapshot.sourceItems.compactMap { item in
          item.sourceLibraryID == amazonSource.id && isCurrent(item) ? item.id : nil
        })
      let attachedLocalItemIDs = Set(
        snapshot.sourceItems.compactMap { item in
          attachedFolderIDs.contains(item.sourceLibraryID) && isCurrent(item) ? item.id : nil
        })
      var downloadedAmazonItemIDs: Set<String> = []
      var candidateAmazonItemIDs: Set<String> = []
      var candidateLocalItemIDs: Set<String> = []
      var candidateIDs: Set<String> = []

      for candidate in identity.amazonMD5ReviewCandidates {
        let matchingAmazonItemIDs = Set(
          candidate.amazonSourceResourceIDs.compactMap { id in
            resources[id]?.sourceItemID
          }
        ).intersection(amazonItemIDs)
        let matchingLocalItemIDs = Set(
          candidate.localSourceResourceIDs.compactMap { id in
            resources[id]?.sourceItemID
          }
        ).intersection(attachedLocalItemIDs)
        guard !matchingAmazonItemIDs.isEmpty, !matchingLocalItemIDs.isEmpty else { continue }
        candidateAmazonItemIDs.formUnion(matchingAmazonItemIDs)
        candidateLocalItemIDs.formUnion(matchingLocalItemIDs)
        candidateIDs.insert(candidate.id)

        for amazonResourceID in candidate.amazonSourceResourceIDs {
          guard
            let amazonItemID = resources[amazonResourceID]?.sourceItemID,
            amazonItemIDs.contains(amazonItemID)
          else { continue }
          for localResourceID in candidate.localSourceResourceIDs {
            guard
              let localItemID = resources[localResourceID]?.sourceItemID,
              attachedLocalItemIDs.contains(localItemID),
              let pair = duplicates.pair(
                between: amazonResourceID,
                and: localResourceID
              )
            else { continue }
            if resolutions.establishesSafeIdentity(for: pair) {
              downloadedAmazonItemIDs.insert(amazonItemID)
            }
          }
        }
      }

      return AmazonDownloadCoverage(
        amazonSourceID: amazonSource.id,
        attachedFolderSourceIDs: attachedFolderIDs.sorted(),
        downloadedAmazonItemIDs: downloadedAmazonItemIDs.sorted(),
        candidateAmazonItemIDs: candidateAmazonItemIDs.sorted(),
        missingAmazonItemIDs: amazonItemIDs.subtracting(downloadedAmazonItemIDs).sorted(),
        unmatchedLocalItemIDs: attachedLocalItemIDs.subtracting(candidateLocalItemIDs).sorted(),
        candidateIDs: candidateIDs.sorted()
      )
    }.sorted { $0.amazonSourceID < $1.amazonSourceID }
  }
}
