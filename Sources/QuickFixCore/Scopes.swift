import Foundation

/// Built-in queues: sets of photos worth a look, worked out from the library and the review store.
public enum SmartQueue: String, CaseIterable, Sendable, Codable, Hashable {
  case notReviewed
  case undated
  case lookLater
  case toDelete
  case blurry
  case toRecords
  case screenshots
  case shortVideos
  case lowResolution
  case noLocation

  public var title: String {
    switch self {
    case .notReviewed: "Not Reviewed Yet"
    case .undated: "Undated (1900)"
    case .lookLater: "Look at Later"
    case .toDelete: "To Delete"
    case .blurry: "Blurry"
    case .toRecords: "To Records"
    case .screenshots: "Screenshots"
    case .shortVideos: "Short Videos (< 3 s)"
    case .lowResolution: "Low Resolution (< 1 MP)"
    case .noLocation: "No Location"
    }
  }

  public var systemImage: String {
    switch self {
    case .notReviewed: "sparkles"
    case .undated: "calendar.badge.exclamationmark"
    case .lookLater: "clock"
    case .toDelete: "trash"
    case .blurry: "aqi.medium"
    case .toRecords: "folder.badge.person.crop"
    case .screenshots: "camera.viewfinder"
    case .shortVideos: "video.badge.ellipsis"
    case .lowResolution: "square.resize.down"
    case .noLocation: "location.slash"
    }
  }

  /// Queues that collect what you marked, shown in their own sidebar group.
  public var isMarkQueue: Bool { [.lookLater, .toDelete, .blurry, .toRecords].contains(self) }

  public func matches(_ asset: AssetSummary, _ record: AssetRecord?) -> Bool {
    switch self {
    case .notReviewed: (record?.reviewCount ?? 0) == 0
    case .undated: asset.isUndated
    case .lookLater: record?.verdict == .lookLater
    case .toDelete: record?.has(.delete) == true && record?.deletedAt == nil
    case .blurry: record?.has(.blurry) == true
    case .toRecords: record?.has(.records) == true
    case .screenshots: asset.isScreenshot
    case .shortVideos: asset.kind == .video && asset.duration < 3
    case .lowResolution: asset.kind != .video && asset.pixelWidth > 0 && asset.megapixels < 1
    case .noLocation: !asset.hasLocation
    }
  }
}

/// What the review screen is working through.
public enum Scope: Hashable, Sendable {
  case library
  case queue(SmartQueue)
  /// An album or a folder of albums (all photos in it), by PhotoKit local identifier.
  case album(id: String, title: String)

  /// Key used for pass state in the review store.
  public var key: String {
    switch self {
    case .library: "library"
    case .queue(let q): "queue:\(q.rawValue)"
    case .album(let id, _): "album:\(id)"
    }
  }

  public var title: String {
    switch self {
    case .library: "All Photos"
    case .queue(let q): q.title
    case .album(_, let title): title
    }
  }
}

public enum ReviewOrder: String, Codable, CaseIterable, Sendable {
  case shuffle
  case oldestFirst
  case newestFirst

  public var title: String {
    switch self {
    case .shuffle: "Shuffled"
    case .oldestFirst: "Oldest First"
    case .newestFirst: "Newest First"
    }
  }
}
