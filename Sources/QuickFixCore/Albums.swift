import Foundation

/// A user album in Photos, with its folder path ("From Amazon › Events › crows").
public struct AlbumRef: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let path: String

  public init(id: String, title: String, path: String) {
    self.id = id
    self.title = title
    self.path = path
  }

  /// The folder part of the path ("From Amazon › Events"), or "" at the top level.
  public var folderPath: String {
    guard let range = path.range(of: " › ", options: .backwards) else { return "" }
    return String(path[..<range.lowerBound])
  }
}

/// An album the user added a photo to, and when. Kept newest first.
public struct RecentAlbum: Codable, Hashable, Sendable {
  public var id: String
  public var usedAt: Date

  public init(id: String, usedAt: Date) {
    self.id = id
    self.usedAt = usedAt
  }
}

public enum AlbumRules {
  /// Albums that exist for bookkeeping, not organising: the app's own marker albums and the migration's
  /// import albums. Event albums made during the import ("From Amazon › Events › …") are real albums.
  public static let bookkeepingPaths = ["Quick Fix", "From Amazon › All from Amazon", "From Amazon › Import batches"]

  public static func isBookkeeping(_ path: String) -> Bool {
    bookkeepingPaths.contains { path == $0 || path.hasPrefix("\($0) › ") }
  }

  /// The app's own marker folder: never offered as a place to file photos.
  public static func isMarker(_ path: String) -> Bool { path == "Quick Fix" || path.hasPrefix("Quick Fix › ") }

  /// Moves `id` to the front of the recent list (adding it if new), keeping at most `limit` entries.
  public static func bump(_ id: String, in list: [RecentAlbum], at date: Date, limit: Int = 20) -> [RecentAlbum] {
    Array(([RecentAlbum(id: id, usedAt: date)] + list.filter { $0.id != id }).prefix(limit))
  }

  /// Albums whose title or folder path contains every word of the query (ignoring case and accents).
  /// Recently used ones come first, newest first; then titles that start with the query; then A–Z.
  public static func search(_ albums: [AlbumRef], query: String, recentIDs: [String]) -> [AlbumRef] {
    let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
    guard !words.isEmpty else { return albums.sorted(by: byTitle) }
    let rank = Dictionary(recentIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    let first = words[0]
    return albums
      .filter { album in
        let haystack = fold(album.title) + " " + fold(album.path)
        return words.allSatisfy { haystack.contains($0) }
      }
      .sorted { a, b in
        switch (rank[a.id], rank[b.id]) {
        case let (x?, y?): return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default:
          let ap = fold(a.title).hasPrefix(first)
          let bp = fold(b.title).hasPrefix(first)
          if ap != bp { return ap }
          return byTitle(a, b)
        }
      }
  }

  public static func byTitle(_ a: AlbumRef, _ b: AlbumRef) -> Bool {
    let c = a.title.localizedStandardCompare(b.title)
    return c == .orderedSame ? a.path.localizedStandardCompare(b.path) == .orderedAscending : c == .orderedAscending
  }

  static func fold(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }
}
