import Foundation

public enum GoogleBrowserWorkflow {
  public static let takeoutURL = URL(
    string: "https://takeout.google.com/settings/takeout/custom/photos"
  )!

  public static let iCloudTransferURL = URL(
    string: "https://takeout.google.com/takeout/transfer/custom/photos"
  )!
}

public enum GoogleTakeoutInspector {
  private static let mediaExtensions: Set<String> = [
    "3g2", "3gp", "avi", "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "m4v",
    "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "png", "raw", "tif", "tiff", "webp",
    "wmv",
  ]

  public static func inspect(directory: URL) async throws -> ProbeResult {
    try await Task.detached(priority: .userInitiated) {
      try inspectSynchronously(directory: directory)
    }.value
  }

  private static func inspectSynchronously(directory: URL) throws -> ProbeResult {
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      throw ProviderProbeError.directoryUnavailable
    }

    var mediaCount = 0
    var jsonCount = 0
    var albumMetadataCount = 0
    var sampledJSONCount = 0
    var fieldPaths = Set<String>()

    for case let fileURL as URL in enumerator {
      let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys))
      guard resourceValues?.isRegularFile == true else { continue }

      let fileExtension = fileURL.pathExtension.lowercased()
      if mediaExtensions.contains(fileExtension) {
        mediaCount += 1
        continue
      }

      guard fileExtension == "json" else { continue }
      jsonCount += 1
      if fileURL.lastPathComponent.lowercased() == "metadata.json" {
        albumMetadataCount += 1
      }

      guard sampledJSONCount < 200 else { continue }
      guard let data = try? Data(contentsOf: fileURL), data.count <= 2_000_000 else { continue }
      if let paths = try? SanitizedJSONShape.fieldPaths(from: data) {
        fieldPaths.formUnion(paths)
        sampledJSONCount += 1
      }
    }

    return ProbeResult(
      provider: .google,
      mechanism: .manualExport,
      operation: "Inspect expanded Google Takeout",
      status: .success,
      aggregateCount: mediaCount,
      responseFieldPaths: fieldPaths.sorted(),
      notes: [
        "Media files: \(mediaCount)",
        "JSON files: \(jsonCount)",
        "Album metadata files: \(albumMetadataCount)",
        "JSON shapes sampled: \(sampledJSONCount)",
      ]
    )
  }
}
