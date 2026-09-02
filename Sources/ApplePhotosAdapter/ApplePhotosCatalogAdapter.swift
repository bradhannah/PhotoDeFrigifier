import CryptoKit
import Foundation
import PhotoCatalogCore
import Photos
import UniformTypeIdentifiers

public enum ApplePhotosCatalogAdapterError: Error, Equatable, LocalizedError {
  case authorizationDenied
  case incompleteAuthorization
  case unavailable

  public var errorDescription: String? {
    switch self {
    case .authorizationDenied:
      "Apple Photos access was denied."
    case .incompleteAuthorization:
      "Full Apple Photos access is required for a complete inventory."
    case .unavailable:
      "The system Apple Photos library is currently unavailable."
    }
  }
}

public struct ApplePhotosImportProgress: Equatable, Sendable {
  public let completedAssets: Int
  public let totalAssets: Int
  public let measuredResources: Int
  public let networkRequiredResources: Int

  public init(
    completedAssets: Int,
    totalAssets: Int,
    measuredResources: Int,
    networkRequiredResources: Int
  ) {
    self.completedAssets = completedAssets
    self.totalAssets = totalAssets
    self.measuredResources = measuredResources
    self.networkRequiredResources = networkRequiredResources
  }
}

public struct ApplePhotosCaptureResult: Sendable {
  public let snapshot: CatalogSnapshot
  public let measuredResourceCount: Int
  public let networkRequiredResourceCount: Int
  public let unavailableResourceCount: Int

  public init(
    snapshot: CatalogSnapshot,
    measuredResourceCount: Int,
    networkRequiredResourceCount: Int,
    unavailableResourceCount: Int
  ) {
    self.snapshot = snapshot
    self.measuredResourceCount = measuredResourceCount
    self.networkRequiredResourceCount = networkRequiredResourceCount
    self.unavailableResourceCount = unavailableResourceCount
  }
}

public struct ApplePhotosCatalogAdapter: Sendable {
  public init() {}

  public func capture(
    sourceIdentity: ApplePhotosSourceIdentity,
    importedAt: Date = Date(),
    progress: (@Sendable (ApplePhotosImportProgress) -> Void)? = nil
  ) async throws -> ApplePhotosCaptureResult {
    let initialStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    let status =
      initialStatus == .notDetermined
      ? await PHPhotoLibrary.requestAuthorization(for: .readWrite)
      : initialStatus
    guard status != .limited else {
      throw ApplePhotosCatalogAdapterError.incompleteAuthorization
    }
    guard status == .authorized else {
      throw ApplePhotosCatalogAdapterError.authorizationDenied
    }
    guard PHPhotoLibrary.shared().unavailabilityReason == nil else {
      throw ApplePhotosCatalogAdapterError.unavailable
    }

    let fetchOptions = PHFetchOptions()
    fetchOptions.includeHiddenAssets = true
    fetchOptions.includeAllBurstAssets = true
    let assets = PHAsset.fetchAssets(with: fetchOptions)
    let albumsByAssetID = Self.albumMemberships()
    var observations: [ApplePhotoObservation] = []
    observations.reserveCapacity(assets.count)
    var measuredResourceCount = 0
    var networkRequiredResourceCount = 0
    var unavailableResourceCount = 0
    let progressInterval = max(assets.count / 200, 1)

    for index in 0..<assets.count {
      try Task.checkCancellation()
      let asset = assets.object(at: index)
      let resources = PHAssetResource.assetResources(for: asset)
      let sortedResources = resources.sorted(by: AppleResourceMapper.sortsBefore)
      var resourceKeyCounts: [String: Int] = [:]
      var resourceObservations: [ProviderResourceObservation] = []
      resourceObservations.reserveCapacity(sortedResources.count)

      for resource in sortedResources {
        let baseKey = AppleResourceMapper.baseKey(for: resource)
        let ordinal = resourceKeyCounts[baseKey, default: 0]
        resourceKeyCounts[baseKey] = ordinal + 1
        let resourceKey = "\(baseKey)|\(ordinal)"
        let role = AppleResourceMapper.role(
          for: resource.type,
          contentType: resource.contentType
        )
        let readResult: LocalResourceReadResult
        if AppleResourceMapper.shouldMeasure(resource.type) {
          readResult = await Self.readLocalResource(resource)
        } else {
          readResult = .notRequested
        }
        switch readResult.state {
        case .measured: measuredResourceCount += 1
        case .requiresNetwork: networkRequiredResourceCount += 1
        case .unavailable: unavailableResourceCount += 1
        case .notRequested: break
        }
        resourceObservations.append(
          ProviderResourceObservation(
            externalID: resourceKey,
            role: role,
            filename: resource.originalFilename,
            mediaType: resource.contentType.preferredMIMEType,
            byteCount: readResult.measurement?.byteCount,
            width: resource.pixelWidth > 0 ? resource.pixelWidth : nil,
            height: resource.pixelHeight > 0 ? resource.pixelHeight : nil,
            nativeResourceType: AppleResourceMapper.name(resource.type),
            localReadState: readResult.state,
            localMeasurement: readResult.measurement
          ))
      }

      observations.append(
        ApplePhotoObservation(
          localIdentifier: asset.localIdentifier,
          kind: AppleResourceMapper.kind(asset.mediaType),
          resources: resourceObservations,
          metadata: Self.metadata(
            for: asset,
            albums: albumsByAssetID[asset.localIdentifier] ?? []
          )
        ))
      if (index + 1).isMultiple(of: progressInterval) || index + 1 == assets.count {
        progress?(
          ApplePhotosImportProgress(
            completedAssets: index + 1,
            totalAssets: assets.count,
            measuredResources: measuredResourceCount,
            networkRequiredResources: networkRequiredResourceCount
          ))
      }
    }

    let snapshot = try ApplePhotosCatalogBuilder.build(
      observations: observations,
      sourceIdentity: sourceIdentity,
      importedAt: importedAt
    )
    return ApplePhotosCaptureResult(
      snapshot: snapshot,
      measuredResourceCount: measuredResourceCount,
      networkRequiredResourceCount: networkRequiredResourceCount,
      unavailableResourceCount: unavailableResourceCount
    )
  }

  private static func albumMemberships() -> [String: [JSONValue]] {
    var result: [String: [JSONValue]] = [:]
    let fetchOptions = PHFetchOptions()
    fetchOptions.includeHiddenAssets = true
    fetchOptions.includeAllBurstAssets = true
    for collectionType in [PHAssetCollectionType.album, .smartAlbum] {
      let collections = PHAssetCollection.fetchAssetCollections(
        with: collectionType,
        subtype: .any,
        options: nil
      )
      collections.enumerateObjects { collection, _, _ in
        let assets = PHAsset.fetchAssets(in: collection, options: fetchOptions)
        let album = JSONValue.object([
          "collectionType": .integer(Int64(collection.assetCollectionType.rawValue)),
          "localIdentifier": .string(collection.localIdentifier),
          "subtype": .integer(Int64(collection.assetCollectionSubtype.rawValue)),
          "title": collection.localizedTitle.map(JSONValue.string) ?? .null,
        ])
        assets.enumerateObjects { asset, _, _ in
          result[asset.localIdentifier, default: []].append(album)
        }
      }
    }
    return result.mapValues { albums in
      albums.sorted { lhs, rhs in
        (lhs["localIdentifier"]?.stringValue ?? "")
          < (rhs["localIdentifier"]?.stringValue ?? "")
      }
    }
  }

  private static func metadata(for asset: PHAsset, albums: [JSONValue]) -> [String: JSONValue] {
    var metadata: [String: JSONValue] = [
      "addedDate": .string(timestamp(asset.addedDate)),
      "albums": .array(albums),
      "burstSelectionTypes": .integer(Int64(asset.burstSelectionTypes.rawValue)),
      "contentType": .string(asset.contentType.identifier),
      "duration": .number(asset.duration),
      "favorite": .boolean(asset.isFavorite),
      "hasAdjustments": .boolean(asset.hasAdjustments),
      "hidden": .boolean(asset.isHidden),
      "mediaSubtypes": .integer(Int64(asset.mediaSubtypes.rawValue)),
      "pixelHeight": .integer(Int64(asset.pixelHeight)),
      "pixelWidth": .integer(Int64(asset.pixelWidth)),
      "playbackStyle": .integer(Int64(asset.playbackStyle.rawValue)),
      "representsBurst": .boolean(asset.representsBurst),
      "sourceType": .integer(Int64(asset.sourceType.rawValue)),
    ]
    if let creationDate = asset.creationDate {
      metadata["creationDate"] = .string(timestamp(creationDate))
    }
    if let modificationDate = asset.modificationDate {
      metadata["modificationDate"] = .string(timestamp(modificationDate))
    }
    if let burstIdentifier = asset.burstIdentifier {
      metadata["burstIdentifier"] = .string(burstIdentifier)
    }
    if let adjustmentFormatIdentifier = asset.adjustmentFormatIdentifier {
      metadata["adjustmentFormatIdentifier"] = .string(adjustmentFormatIdentifier)
    }
    if let location = asset.location {
      metadata["location"] = .object([
        "altitude": .number(location.altitude),
        "latitude": .number(location.coordinate.latitude),
        "longitude": .number(location.coordinate.longitude),
      ])
    }
    return metadata
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func readLocalResource(_ resource: PHAssetResource) async
    -> LocalResourceReadResult
  {
    await withCheckedContinuation { continuation in
      let accumulator = ResourceDigestAccumulator()
      let options = PHAssetResourceRequestOptions()
      options.isNetworkAccessAllowed = false
      PHAssetResourceManager.default().requestData(
        for: resource,
        options: options,
        dataReceivedHandler: { data in
          accumulator.append(data)
        },
        completionHandler: { error in
          guard let error else {
            continuation.resume(returning: .measured(accumulator.measurement()))
            return
          }
          let nsError = error as NSError
          if nsError.domain == PHPhotosErrorDomain
            && nsError.code == PHPhotosError.networkAccessRequired.rawValue
          {
            continuation.resume(returning: .requiresNetwork)
          } else {
            continuation.resume(returning: .unavailable)
          }
        }
      )
    }
  }
}

enum AppleResourceMapper {
  static func kind(_ mediaType: PHAssetMediaType) -> AssetKind {
    switch mediaType {
    case .image: .photo
    case .video: .video
    case .audio: .audio
    case .unknown: .unknown
    @unknown default: .unknown
    }
  }

  static func role(for type: PHAssetResourceType, contentType: UTType) -> ResourceRole {
    switch type {
    case .photo:
      contentType.conforms(to: .rawImage) ? .raw : .primary
    case .video, .fullSizeVideo, .adjustmentBaseVideo:
      .video
    case .pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo:
      .pairedVideo
    case .adjustmentBasePhoto:
      contentType.conforms(to: .rawImage) ? .raw : .original
    case .alternatePhoto:
      contentType.conforms(to: .rawImage) ? .raw : .original
    case .fullSizePhoto, .photoProxy:
      .edited
    case .audio:
      .audio
    case .adjustmentData:
      .sidecar
    @unknown default:
      .sidecar
    }
  }

  static func shouldMeasure(_ type: PHAssetResourceType) -> Bool {
    switch type {
    case .adjustmentData, .photoProxy:
      false
    default:
      true
    }
  }

  static func name(_ type: PHAssetResourceType) -> String {
    switch type {
    case .photo: "photo"
    case .video: "video"
    case .audio: "audio"
    case .alternatePhoto: "alternatePhoto"
    case .fullSizePhoto: "fullSizePhoto"
    case .fullSizeVideo: "fullSizeVideo"
    case .adjustmentData: "adjustmentData"
    case .adjustmentBasePhoto: "adjustmentBasePhoto"
    case .pairedVideo: "pairedVideo"
    case .fullSizePairedVideo: "fullSizePairedVideo"
    case .adjustmentBaseVideo: "adjustmentBaseVideo"
    case .adjustmentBasePairedVideo: "adjustmentBasePairedVideo"
    case .photoProxy: "photoProxy"
    @unknown default: "unknown:\(type.rawValue)"
    }
  }

  static func baseKey(for resource: PHAssetResource) -> String {
    [
      String(resource.type.rawValue),
      resource.contentType.identifier,
      resource.originalFilename,
      String(resource.pixelWidth),
      String(resource.pixelHeight),
    ].joined(separator: "|")
  }

  static func sortsBefore(_ lhs: PHAssetResource, _ rhs: PHAssetResource) -> Bool {
    baseKey(for: lhs).utf8.lexicographicallyPrecedes(baseKey(for: rhs).utf8)
  }
}

private struct LocalResourceReadResult: Sendable {
  let state: LocalResourceReadState
  let measurement: LocalResourceMeasurement?

  static let notRequested = LocalResourceReadResult(state: .notRequested, measurement: nil)
  static let requiresNetwork = LocalResourceReadResult(state: .requiresNetwork, measurement: nil)
  static let unavailable = LocalResourceReadResult(state: .unavailable, measurement: nil)

  static func measured(_ measurement: LocalResourceMeasurement) -> LocalResourceReadResult {
    LocalResourceReadResult(state: .measured, measurement: measurement)
  }
}

private final class ResourceDigestAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var sha256 = SHA256()
  private var md5 = Insecure.MD5()
  private var byteCount: Int64 = 0

  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    sha256.update(data: data)
    md5.update(data: data)
    byteCount += Int64(data.count)
  }

  func measurement() -> LocalResourceMeasurement {
    lock.lock()
    defer { lock.unlock() }
    return LocalResourceMeasurement(
      sha256: hex(sha256.finalize()),
      md5: hex(md5.finalize()),
      byteCount: byteCount
    )
  }

  private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
