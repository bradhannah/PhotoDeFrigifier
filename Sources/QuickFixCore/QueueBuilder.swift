import Foundation

public struct QueueSnapshot: Sendable, Equatable {
  /// Photos still to see this pass, in order (skipped ones at the back).
  public var remaining: [String]
  /// Photos in the pass (candidates, minus any left out because they're already "in order").
  public var total: Int
  /// Photos in the pass already reviewed since the pass started.
  public var done: Int

  public init(remaining: [String], total: Int, done: Int) {
    self.remaining = remaining
    self.total = total
    self.done = done
  }
}

public enum QueueBuilder {
  /// Orders a scope's photos for one pass.
  /// - A photo already reviewed during this pass is done and left out of `remaining`.
  /// - With `skipInOrder`, photos marked "Everything is in Order!" or archived in an EARLIER pass are left out;
  ///   they were finished. Marked during this pass, they count as done.
  /// - The shuffle is stable for a given seed, so closing and reopening resumes in the same order.
  public static func build(
    candidates: [AssetSummary], records: [String: AssetRecord], pass: PassState, order: ReviewOrder,
    skipInOrder: Bool
  ) -> QueueSnapshot {
    var eligible: [AssetSummary] = []
    eligible.reserveCapacity(candidates.count)
    var done = 0
    var open: [AssetSummary] = []
    for asset in candidates {
      let record = records[asset.id]
      if record?.deletedAt != nil { continue }
      let reviewedThisPass = record?.reviewed(since: pass.startedAt) ?? false
      if skipInOrder, record?.verdict == .inOrder || record?.verdict == .archived, !reviewedThisPass { continue }
      eligible.append(asset)
      if reviewedThisPass { done += 1 } else { open.append(asset) }
    }

    switch order {
    case .shuffle:
      open.sort { shuffleKey($0.id, pass.seed) < shuffleKey($1.id, pass.seed) }
    case .oldestFirst:
      open.sort { ($0.creationDate ?? .distantPast, $0.id) < ($1.creationDate ?? .distantPast, $1.id) }
    case .newestFirst:
      open.sort { ($0.creationDate ?? .distantPast, $0.id) > ($1.creationDate ?? .distantPast, $1.id) }
    }

    var ids = open.map(\.id)
    if !pass.skipped.isEmpty {
      let skippedOrder = Dictionary(pass.skipped.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
      let front = ids.filter { skippedOrder[$0] == nil }
      let back = ids.filter { skippedOrder[$0] != nil }.sorted { skippedOrder[$0]! < skippedOrder[$1]! }
      ids = front + back
    }
    return QueueSnapshot(remaining: ids, total: eligible.count, done: done)
  }

  /// Deterministic 64-bit mix of an identifier and a seed (FNV-1a, then a SplitMix64 finaliser).
  /// Swift's Hasher is randomised per launch, so it can't be used for an order that must persist.
  public static func shuffleKey(_ id: String, _ seed: UInt64) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in id.utf8 {
      h ^= UInt64(byte)
      h = h &* 0x0000_0100_0000_01b3
    }
    var z = h ^ seed &+ 0x9e37_79b9_7f4a_7c15
    z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
    z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
    return z ^ (z >> 31)
  }

  /// Counts for every smart queue in one pass over the library.
  public static func queueCounts(_ assets: [AssetSummary], records: [String: AssetRecord]) -> [SmartQueue: Int] {
    var counts: [SmartQueue: Int] = [:]
    for asset in assets {
      let record = records[asset.id]
      for queue in SmartQueue.allCases where queue.matches(asset, record) {
        counts[queue, default: 0] += 1
      }
    }
    return counts
  }
}
