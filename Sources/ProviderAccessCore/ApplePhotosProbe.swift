import Foundation
import Photos

@MainActor
public enum ApplePhotosProbe {
  public static func runInventory() async -> ProbeResult {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    guard status == .authorized || status == .limited else {
      return ProbeResult(
        provider: .apple,
        mechanism: .photoKitPermission,
        operation: "Read-only PhotoKit inventory",
        status: .blocked,
        notes: ["PhotoKit authorization: \(authorizationName(status))"]
      )
    }

    let normalOptions = PHFetchOptions()
    normalOptions.includeHiddenAssets = false
    let normalAssets = PHAsset.fetchAssets(with: normalOptions)

    let allOptions = PHFetchOptions()
    allOptions.includeHiddenAssets = true
    let allAssets = PHAsset.fetchAssets(with: allOptions)

    var imageCount = 0
    var videoCount = 0
    var audioCount = 0
    var hiddenCount = 0
    var favoriteCount = 0
    var resourceCounts: [String: Int] = [:]

    allAssets.enumerateObjects { asset, index, _ in
      switch asset.mediaType {
      case .image: imageCount += 1
      case .video: videoCount += 1
      case .audio: audioCount += 1
      case .unknown: break
      @unknown default: break
      }
      if asset.isHidden { hiddenCount += 1 }
      if asset.isFavorite { favoriteCount += 1 }

      guard index < 200 else { return }
      for resource in PHAssetResource.assetResources(for: asset) {
        resourceCounts[resourceName(resource.type), default: 0] += 1
      }
    }

    let albumCount = PHAssetCollection.fetchAssetCollections(
      with: .album,
      subtype: .any,
      options: nil
    ).count

    let resourceNotes = resourceCounts.keys.sorted().map {
      "Sampled resource \($0): \(resourceCounts[$0] ?? 0)"
    }

    return ProbeResult(
      provider: .apple,
      mechanism: .photoKitPermission,
      operation: "Read-only PhotoKit inventory",
      status: .success,
      aggregateCount: allAssets.count,
      responseFieldPaths: [
        "PHAsset.creationDate",
        "PHAsset.duration",
        "PHAsset.isFavorite",
        "PHAsset.isHidden",
        "PHAsset.location",
        "PHAsset.mediaSubtypes",
        "PHAsset.mediaType",
        "PHAsset.pixelHeight",
        "PHAsset.pixelWidth",
        "PHAssetResource.originalFilename",
        "PHAssetResource.type",
        "PHAssetResource.uniformTypeIdentifier",
      ],
      notes: [
        "PhotoKit authorization: \(authorizationName(status))",
        "Normal assets: \(normalAssets.count)",
        "Hidden-inclusive assets: \(allAssets.count)",
        "Images: \(imageCount)",
        "Videos: \(videoCount)",
        "Audio: \(audioCount)",
        "Hidden: \(hiddenCount)",
        "Favorites: \(favoriteCount)",
        "User albums: \(albumCount)",
      ] + resourceNotes
    )
  }

  private static func authorizationName(_ status: PHAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "not determined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .authorized: "authorized"
    case .limited: "limited"
    @unknown default: "unknown"
    }
  }

  private static func resourceName(_ type: PHAssetResourceType) -> String {
    switch type {
    case .photo: "photo"
    case .video: "video"
    case .audio: "audio"
    case .alternatePhoto: "alternate photo"
    case .fullSizePhoto: "full-size photo"
    case .fullSizeVideo: "full-size video"
    case .adjustmentData: "adjustment data"
    case .adjustmentBasePhoto: "adjustment base photo"
    case .pairedVideo: "paired video"
    case .fullSizePairedVideo: "full-size paired video"
    case .adjustmentBaseVideo: "adjustment base video"
    case .adjustmentBasePairedVideo: "adjustment base paired video"
    case .photoProxy: "photo proxy"
    @unknown default: "unknown"
    }
  }
}
