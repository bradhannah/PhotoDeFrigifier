import Foundation
import Observation

/// The file format of review-store.json. Documented in docs/REVIEW_STORE.md and the photo-review-store skill.
public struct ReviewStoreData: Codable, Sendable, Equatable {
  public static let formatName = "photodefrigifier-review-store"
  public static let currentVersion = 1

  public var format: String
  public var version: Int
  public var updatedAt: Date
  /// Keyed by PHAsset.localIdentifier ("<UUID>/L0/001" on a Mac).
  public var assets: [String: AssetRecord]
  /// Keyed by Scope.key ("library", "queue:undated", "album:<id>").
  public var passes: [String: PassState]

  public init(updatedAt: Date = .now, assets: [String: AssetRecord] = [:], passes: [String: PassState] = [:]) {
    format = Self.formatName
    version = Self.currentVersion
    self.updatedAt = updatedAt
    self.assets = assets
    self.passes = passes
  }
}

public enum ReviewStoreError: LocalizedError {
  case unreadable(URL, movedTo: URL, underlying: Error)
  case newerVersion(Int)

  public var errorDescription: String? {
    switch self {
    case .unreadable(_, let movedTo, let underlying):
      "The review store couldn't be read (\(underlying.localizedDescription)). It was kept as \(movedTo.lastPathComponent) and a new one was started."
    case .newerVersion(let v):
      "The review store was written by a newer version of PhotoDeFrigifier (format \(v)). Update the app before using it."
    }
  }
}

/// Holds the review store in memory and saves it as JSON. Every change is also appended to actions.jsonl.
/// Not thread-safe: the app uses it from the main actor only.
@Observable
public final class ReviewStore {
  public private(set) var data: ReviewStoreData
  public let directory: URL
  public var fileURL: URL { directory.appendingPathComponent("review-store.json") }
  public var logURL: URL { directory.appendingPathComponent("actions.jsonl") }
  public var backupURL: URL { directory.appendingPathComponent("review-store.backup.json") }
  /// Set when loading had to start fresh or something went wrong saving; the app shows it.
  public var problem: String?

  @ObservationIgnored private var backedUp = false
  @ObservationIgnored private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    e.dateEncodingStrategy = .iso8601
    return e
  }()
  @ObservationIgnored private let lineEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    e.dateEncodingStrategy = .iso8601
    return e
  }()

  public static var defaultDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("PhotoDeFrigifier", isDirectory: true)
  }

  /// Opens (or creates) the store in `directory`. A file that can't be decoded is never overwritten:
  /// it's renamed aside and `problem` explains what happened.
  public init(directory: URL = ReviewStore.defaultDirectory) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("review-store.json")
    guard FileManager.default.fileExists(atPath: url.path) else {
      data = ReviewStoreData()
      return
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      let loaded = try decoder.decode(ReviewStoreData.self, from: Data(contentsOf: url))
      if loaded.version > ReviewStoreData.currentVersion { throw ReviewStoreError.newerVersion(loaded.version) }
      data = loaded
    } catch let error as ReviewStoreError {
      throw error
    } catch {
      let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
      let aside = directory.appendingPathComponent("review-store.unreadable-\(stamp).json")
      try FileManager.default.moveItem(at: url, to: aside)
      data = ReviewStoreData()
      problem = ReviewStoreError.unreadable(url, movedTo: aside, underlying: error).errorDescription
    }
  }

  // MARK: Records

  public func record(_ id: String) -> AssetRecord? { data.assets[id] }

  /// Applies `change` to the record (creating it if needed) and returns (before, after).
  @discardableResult
  public func update(_ id: String, _ change: (inout AssetRecord) -> Void) -> (AssetRecord?, AssetRecord) {
    let before = data.assets[id]
    var record = before ?? AssetRecord()
    change(&record)
    data.assets[id] = record
    return (before, record)
  }

  /// Puts a record back exactly as it was (nil removes it). Used by undo.
  public func restore(_ id: String, to record: AssetRecord?) {
    data.assets[id] = record
  }

  // MARK: Passes

  public func pass(for key: String) -> PassState {
    if let pass = data.passes[key] { return pass }
    let fresh = PassState.fresh()
    data.passes[key] = fresh
    return fresh
  }

  public func setPass(_ pass: PassState, for key: String) {
    data.passes[key] = pass
  }

  // MARK: Saving

  public func save() {
    do {
      if !backedUp, FileManager.default.fileExists(atPath: fileURL.path) {
        // One copy per launch of the file as it was before this session's changes.
        try? FileManager.default.removeItem(at: backupURL)
        try FileManager.default.copyItem(at: fileURL, to: backupURL)
        backedUp = true
      }
      data.updatedAt = .now
      try encoder.encode(data).write(to: fileURL, options: .atomic)
    } catch {
      problem = "Couldn't save the review store: \(error.localizedDescription)"
    }
  }

  public func log(_ entry: ActionLogEntry) {
    do {
      var line = try lineEncoder.encode(entry)
      line.append(0x0A)
      if let handle = try? FileHandle(forWritingTo: logURL) {
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
      } else {
        try line.write(to: logURL)
      }
    } catch {
      problem = "Couldn't write the action log: \(error.localizedDescription)"
    }
  }
}
