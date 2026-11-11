import Foundation

/// A lightweight, Sendable description of one Photos item. Built from PHAsset by the app;
/// everything in QuickFixCore works on these so it can be tested without a Photos library.
public struct AssetSummary: Sendable, Hashable, Identifiable {
  public enum Kind: String, Sendable, Codable, Hashable {
    case photo, livePhoto, video, other
  }

  /// PHAsset.localIdentifier. On a Mac this is "<UUID>/L0/001", where <UUID> matches osxphotos' uuid.
  public let id: String
  public var creationDate: Date?
  public var kind: Kind
  public var isScreenshot: Bool
  public var pixelWidth: Int
  public var pixelHeight: Int
  public var duration: TimeInterval
  public var isFavorite: Bool
  public var hasLocation: Bool
  public var hasAdjustments: Bool

  public init(
    id: String, creationDate: Date?, kind: Kind, isScreenshot: Bool = false, pixelWidth: Int = 0,
    pixelHeight: Int = 0, duration: TimeInterval = 0, isFavorite: Bool = false, hasLocation: Bool = false,
    hasAdjustments: Bool = false
  ) {
    self.id = id
    self.creationDate = creationDate
    self.kind = kind
    self.isScreenshot = isScreenshot
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.duration = duration
    self.isFavorite = isFavorite
    self.hasLocation = hasLocation
    self.hasAdjustments = hasAdjustments
  }

  public var megapixels: Double { Double(pixelWidth) * Double(pixelHeight) / 1_000_000 }
  public var isUndated: Bool { DateRules.isUndated(creationDate) }
  public var isVideo: Bool { kind == .video }
}

/// The closing call on a photo for this pass. Choosing one moves on to the next photo.
public enum Verdict: String, Codable, Sendable, CaseIterable, Hashable {
  case goodEnough
  case lookLater
  case inOrder
  /// Important to keep, but not to see every day: tagged with the "Archived" keyword, then hidden in Photos in a
  /// batch (macOS asks once per batch).
  case archived

  /// Button label.
  public var title: String {
    switch self {
    case .goodEnough: "Good Enough"
    case .lookLater: "Look at Later"
    case .inOrder: "Everything is in Order!"
    case .archived: "Archive"
    }
  }

  /// How the call reads afterwards ("Last call: Archived").
  public var pastTitle: String { self == .archived ? "Archived" : title }

  /// Label for narrow windows.
  public var shortTitle: String {
    switch self {
    case .goodEnough: "Good Enough"
    case .lookLater: "Later"
    case .inOrder: "In Order!"
    case .archived: "Archive"
    }
  }

  public var key: Character {
    switch self {
    case .goodEnough: "1"
    case .lookLater: "2"
    case .inOrder: "3"
    case .archived: "A"
    }
  }
}

/// Markers that say something should happen to a photo later. Tagging never changes the photo itself.
public enum Flag: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
  case delete
  case blurry
  case records

  public var title: String {
    switch self {
    case .delete: "To Delete"
    case .blurry: "Blurry"
    case .records: "To Records"
    }
  }

  public static func < (lhs: Flag, rhs: Flag) -> Bool {
    allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
  }
}

/// Everything the review store knows about one photo. Stored in review-store.json under its local identifier.
public struct AssetRecord: Codable, Sendable, Equatable {
  /// Original filename, kept so people and scripts can read the JSON without opening Photos.
  public var filename: String?
  public var verdict: Verdict?
  public var verdictAt: Date?
  public var flags: [Flag]
  public var reviewCount: Int
  public var lastReviewedAt: Date?
  /// Set when the date was redated with only a year or month known (the "Date approximate" convention).
  public var dateApproximate: Bool?
  public var note: String?
  /// Where the original was saved by the records export, if it has been.
  public var exportedTo: String?
  /// When the app moved it to Recently Deleted.
  public var deletedAt: Date?
  /// When the app hid it in Photos (archived photos are hidden in batches, after they're tagged).
  public var hiddenAt: Date?

  public init() {
    flags = []
    reviewCount = 0
  }

  public func has(_ flag: Flag) -> Bool { flags.contains(flag) }

  public mutating func set(_ flag: Flag, _ on: Bool) {
    var set = Set(flags)
    if on { set.insert(flag) } else { set.remove(flag) }
    flags = set.sorted()
  }

  public func reviewed(since date: Date) -> Bool {
    guard let lastReviewedAt else { return false }
    return lastReviewedAt >= date
  }

  /// Albums in Photos that mirror this record ("Look at Later" plus each flag's title).
  public var mirrorLabels: Set<String> {
    var labels = Set(flags.map(\.title))
    if verdict == .lookLater { labels.insert(Verdict.lookLater.title) }
    return labels
  }

  enum CodingKeys: String, CodingKey {
    case filename, verdict, verdictAt, flags, reviewCount, lastReviewedAt, dateApproximate, note, exportedTo,
      deletedAt, hiddenAt
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    filename = try c.decodeIfPresent(String.self, forKey: .filename)
    verdict = try c.decodeIfPresent(Verdict.self, forKey: .verdict)
    verdictAt = try c.decodeIfPresent(Date.self, forKey: .verdictAt)
    flags = (try c.decodeIfPresent([Flag].self, forKey: .flags) ?? []).sorted()
    reviewCount = try c.decodeIfPresent(Int.self, forKey: .reviewCount) ?? 0
    lastReviewedAt = try c.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
    dateApproximate = try c.decodeIfPresent(Bool.self, forKey: .dateApproximate)
    note = try c.decodeIfPresent(String.self, forKey: .note)
    exportedTo = try c.decodeIfPresent(String.self, forKey: .exportedTo)
    deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    hiddenAt = try c.decodeIfPresent(Date.self, forKey: .hiddenAt)
  }
}

/// One trip through a scope. A photo counts as done for the pass once it was reviewed after `startedAt`.
public struct PassState: Codable, Sendable, Equatable {
  public var number: Int
  /// Seed for the stable shuffle, so the order (and "where you left off") survives relaunches.
  public var seed: UInt64
  public var startedAt: Date
  /// Photos skipped this pass, in the order they were skipped. They go to the back of the queue.
  public var skipped: [String]

  public init(number: Int, seed: UInt64, startedAt: Date, skipped: [String] = []) {
    self.number = number
    self.seed = seed
    self.startedAt = startedAt
    self.skipped = skipped
  }

  public static func fresh(number: Int = 1, startedAt: Date = .now) -> PassState {
    // Kept below 2^53 so the seed survives a round trip through JavaScript or other JSON readers.
    PassState(number: number, seed: UInt64.random(in: 1...(1 << 53)), startedAt: startedAt)
  }
}

/// One line of the append-only action log (actions.jsonl).
public struct ActionLogEntry: Codable, Sendable, Equatable {
  public var at: Date
  public var asset: String
  public var filename: String?
  /// verdict, flag, unflag, date, rotate, favorite, delete, export, skip, note, undo
  public var action: String
  public var before: String?
  public var after: String?
  public var scope: String?

  public init(
    at: Date = .now, asset: String, filename: String? = nil, action: String, before: String? = nil,
    after: String? = nil, scope: String? = nil
  ) {
    self.at = at
    self.asset = asset
    self.filename = filename
    self.action = action
    self.before = before
    self.after = after
    self.scope = scope
  }
}
