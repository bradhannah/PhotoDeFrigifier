import Foundation

public enum CatalogPreviewProvenance: Equatable, Sendable {
  case direct
  case appleAssetRendition
  case amazonReviewCandidate(candidateID: String, localSourceResourceID: String)
}

public enum CatalogPreviewLocation: Equatable, Sendable {
  case filesystem(
    bookmarkData: Data,
    relativePath: String,
    expectedByteCount: Int64?,
    expectedSHA256: String
  )
  case applePhotos(localIdentifier: String)
}

public struct CatalogPreviewReference: Equatable, Sendable {
  public let cacheKey: String
  public let kind: AssetKind
  public let location: CatalogPreviewLocation
  public let provenance: CatalogPreviewProvenance

  public init(
    cacheKey: String,
    kind: AssetKind,
    location: CatalogPreviewLocation,
    provenance: CatalogPreviewProvenance
  ) {
    self.cacheKey = cacheKey
    self.kind = kind
    self.location = location
    self.provenance = provenance
  }
}

public struct CatalogPreviewIndex: Sendable {
  private let directReferences: [String: CatalogPreviewReference]
  private let amazonReferences: [String: CatalogPreviewReference]

  public init(
    snapshot: CatalogSnapshot,
    project: LibraryProject,
    identityIndex: CatalogIdentityIndex? = nil
  ) {
    let identity = identityIndex ?? CatalogIdentityIndex(snapshot: snapshot)
    let projectSources = Dictionary(
      project.sources.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
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
    let byteResources = Dictionary(
      snapshot.byteResources.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let byteResourceIDByCurrentResourceID = Dictionary(
      snapshot.assetResourceLinks.compactMap { link -> (String, String)? in
        guard
          let resource = resources[link.sourceResourceID],
          let item = items[resource.sourceItemID],
          link.sourceObservationID == item.latestObservationID
        else { return nil }
        return (resource.id, link.byteResourceID)
      },
      uniquingKeysWith: { first, _ in first }
    )

    func isCurrent(_ item: SourceItem) -> Bool {
      guard let latestRunID = libraries[item.sourceLibraryID]?.latestImportRunID else {
        return false
      }
      return item.lastSeenImportRunID == latestRunID
    }

    var direct: [String: CatalogPreviewReference] = [:]
    for resource in snapshot.sourceResources {
      guard
        let item = items[resource.sourceItemID],
        let library = libraries[item.sourceLibraryID],
        isCurrent(item),
        resource.latestObservationID == item.latestObservationID
      else { continue }
      let cacheKey = "\(resource.id)|\(item.latestObservationID)"
      switch library.provider {
      case .filesystem:
        guard
          let source = projectSources[library.id],
          source.kind == .folder,
          let bookmarkData = source.bookmarkData,
          let byteResourceID = byteResourceIDByCurrentResourceID[resource.id],
          let expectedSHA256 = byteResources[byteResourceID]?.sha256
        else { continue }
        direct[resource.id] = CatalogPreviewReference(
          cacheKey: cacheKey,
          kind: item.kind,
          location: .filesystem(
            bookmarkData: bookmarkData,
            relativePath: item.externalID,
            expectedByteCount: resource.byteCount,
            expectedSHA256: expectedSHA256
          ),
          provenance: .direct
        )
      case .applePhotos:
        direct[resource.id] = CatalogPreviewReference(
          cacheKey: cacheKey,
          kind: item.kind,
          location: .applePhotos(localIdentifier: item.externalID),
          provenance: .appleAssetRendition
        )
      case .amazon, .googlePhotos:
        continue
      }
    }

    var amazon: [String: CatalogPreviewReference] = [:]
    for candidate in identity.amazonMD5ReviewCandidates {
      for amazonResourceID in candidate.amazonSourceResourceIDs {
        guard
          let amazonResource = resources[amazonResourceID],
          let amazonItem = items[amazonResource.sourceItemID]
        else { continue }
        let attachedLocalResourceID = candidate.localSourceResourceIDs.first { resourceID in
          guard
            let resource = resources[resourceID],
            let item = items[resource.sourceItemID],
            let source = projectSources[item.sourceLibraryID]
          else { return false }
          return source.kind == .folder
            && source.attachedToSourceID == amazonItem.sourceLibraryID
            && direct[resourceID] != nil
        }
        guard
          let attachedLocalResourceID,
          let localReference = direct[attachedLocalResourceID]
        else { continue }
        amazon[amazonResourceID] = CatalogPreviewReference(
          cacheKey: localReference.cacheKey,
          kind: localReference.kind,
          location: localReference.location,
          provenance: .amazonReviewCandidate(
            candidateID: candidate.id,
            localSourceResourceID: attachedLocalResourceID
          )
        )
      }
    }

    directReferences = direct
    amazonReferences = amazon
  }

  public func reference(forSourceResourceID sourceResourceID: String) -> CatalogPreviewReference? {
    directReferences[sourceResourceID] ?? amazonReferences[sourceResourceID]
  }
}
