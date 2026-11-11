import Foundation

/// How sure we are about one piece of a photo's metadata.
public enum HealthStatus: String, Sendable, Hashable {
  /// Present and checked.
  case good
  /// Approximate, or never checked.
  case unsure
  /// Absent, or a known problem.
  case missing
  /// Doesn't apply to this item (a screenshot has no location to fix).
  case notApplicable

  public var glyph: String {
    switch self {
    case .good: "✓"
    case .unsure: "?"
    case .missing: "✕"
    case .notApplicable: "–"
    }
  }
}

/// The things the panel reports. Each is something the app can actually measure.
public enum HealthSignal: String, Sendable, Hashable, CaseIterable {
  case date, location, size, sharpness, album

  public var title: String {
    switch self {
    case .date: "Date"
    case .location: "Location"
    case .size: "Size"
    case .sharpness: "Sharpness"
    case .album: "Album"
    }
  }
}

public struct HealthItem: Sendable, Hashable, Identifiable {
  public var signal: HealthSignal
  public var status: HealthStatus
  public var detail: String
  public var id: HealthSignal { signal }

  public init(_ signal: HealthSignal, _ status: HealthStatus, _ detail: String) {
    self.signal = signal
    self.status = status
    self.detail = detail
  }
}

public enum HealthRules {
  /// Keyword the migration (and the photo-date-repair convention) uses for estimated dates.
  public static let approximateKeyword = "Date approximate"

  /// - Parameters:
  ///   - albumPaths: paths of the user albums containing the photo ("From Amazon › All from Amazon").
  ///   - keywords: the photo's keywords from Photos, or nil when they couldn't be read (then they're ignored).
  public static func evaluate(
    _ asset: AssetSummary, record: AssetRecord?, albumPaths: [String], keywords: [String]?,
    calendar: Calendar = .current
  ) -> [HealthItem] {
    [
      date(asset, record, keywords, calendar),
      location(asset),
      size(asset),
      sharpness(asset, record),
      album(albumPaths),
    ]
  }

  static func date(_ a: AssetSummary, _ r: AssetRecord?, _ keywords: [String]?, _ calendar: Calendar) -> HealthItem {
    guard let d = a.creationDate, !DateRules.isUndated(d, calendar: calendar) else {
      return HealthItem(.date, .missing, "No date (1 Jan 1900)")
    }
    let shown = d.formatted(.dateTime.day().month(.abbreviated).year())
    if r?.dateApproximate == true || keywords?.contains(approximateKeyword) == true {
      return HealthItem(.date, .unsure, "Approximate: \(shown)")
    }
    return HealthItem(.date, .good, shown)
  }

  static func location(_ a: AssetSummary) -> HealthItem {
    if a.hasLocation { return HealthItem(.location, .good, "Has a location") }
    if a.isScreenshot { return HealthItem(.location, .notApplicable, "Doesn’t apply (screenshot)") }
    return HealthItem(.location, .missing, "No location")
  }

  static func size(_ a: AssetSummary) -> HealthItem {
    guard a.pixelWidth > 0, a.pixelHeight > 0 else { return HealthItem(.size, .notApplicable, "Unknown") }
    let mp = a.megapixels
    let text = "\(a.pixelWidth)×\(a.pixelHeight) · \(String(format: mp < 10 ? "%.1f" : "%.0f", mp)) MP"
    if a.kind == .video {
      // 1280×720 is 0.92 MP; anything smaller is a low-quality clip.
      return HealthItem(.size, mp >= 0.9 ? .good : .unsure, text)
    }
    if mp >= 2 { return HealthItem(.size, .good, text) }
    if mp >= 1 { return HealthItem(.size, .unsure, text) }
    return HealthItem(.size, .missing, text + " (small)")
  }

  /// Sharpness comes from your own review: the app doesn't guess. Marked blurry is a problem; a photo you've
  /// reviewed without marking it blurry counts as checked.
  static func sharpness(_ a: AssetSummary, _ r: AssetRecord?) -> HealthItem {
    if r?.has(.blurry) == true { return HealthItem(.sharpness, .missing, "Marked blurry") }
    if a.kind == .video || a.isScreenshot {
      return HealthItem(.sharpness, .notApplicable, a.kind == .video ? "Doesn’t apply (video)" : "Doesn’t apply (screenshot)")
    }
    if (r?.reviewCount ?? 0) > 0 { return HealthItem(.sharpness, .good, "Reviewed, not blurry") }
    return HealthItem(.sharpness, .unsure, "Not checked yet")
  }

  static func album(_ paths: [String]) -> HealthItem {
    if paths.isEmpty { return HealthItem(.album, .missing, "In no album") }
    let own = paths.filter { !AlbumRules.isBookkeeping($0) }
    if own.isEmpty { return HealthItem(.album, .unsure, "Only in import albums") }
    let first = own[0].components(separatedBy: " › ").last ?? own[0]
    return HealthItem(.album, .good, own.count == 1 ? first : "\(first) +\(own.count - 1) more")
  }
}
