import Foundation
import Testing

@testable import QuickFixCore

private func asset(_ id: String, year: Int? = 2010, kind: AssetSummary.Kind = .photo) -> AssetSummary {
  var date: Date?
  if let year {
    date = Calendar.current.date(from: DateComponents(year: year, month: 6, day: 1, hour: 12))
  }
  return AssetSummary(id: id, creationDate: date, kind: kind, pixelWidth: 4000, pixelHeight: 3000)
}

private func tempDir() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("qf-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Test func shuffleIsStableForASeedAndDiffersAcrossSeeds() {
  let assets = (0..<200).map { asset("ID-\($0)/L0/001") }
  let pass = PassState(number: 1, seed: 42, startedAt: .distantPast)
  let a = QueueBuilder.build(candidates: assets, records: [:], pass: pass, order: .shuffle, skipInOrder: true)
  let b = QueueBuilder.build(
    candidates: assets.reversed(), records: [:], pass: pass, order: .shuffle, skipInOrder: true)
  #expect(a.remaining == b.remaining)
  #expect(a.remaining.count == 200)
  #expect(a.total == 200 && a.done == 0)
  var other = pass
  other.seed = 43
  let c = QueueBuilder.build(candidates: assets, records: [:], pass: other, order: .shuffle, skipInOrder: true)
  #expect(c.remaining != a.remaining)
  #expect(Set(c.remaining) == Set(a.remaining))
}

@Test func reviewedThisPassIsDoneAndEarlierInOrderIsLeftOut() {
  let start = Date(timeIntervalSince1970: 1_000_000)
  let pass = PassState(number: 2, seed: 7, startedAt: start)
  var reviewedNow = AssetRecord()
  reviewedNow.verdict = .goodEnough
  reviewedNow.lastReviewedAt = start.addingTimeInterval(60)
  var inOrderBefore = AssetRecord()
  inOrderBefore.verdict = .inOrder
  inOrderBefore.lastReviewedAt = start.addingTimeInterval(-60)
  var inOrderNow = AssetRecord()
  inOrderNow.verdict = .inOrder
  inOrderNow.lastReviewedAt = start.addingTimeInterval(30)
  var lookLaterBefore = AssetRecord()
  lookLaterBefore.verdict = .lookLater
  lookLaterBefore.lastReviewedAt = start.addingTimeInterval(-60)
  var deleted = AssetRecord()
  deleted.deletedAt = start
  let records = ["a": reviewedNow, "b": inOrderBefore, "c": inOrderNow, "d": lookLaterBefore, "e": deleted]
  let assets = ["a", "b", "c", "d", "e", "f"].map { asset($0) }

  let snap = QueueBuilder.build(candidates: assets, records: records, pass: pass, order: .oldestFirst, skipInOrder: true)
  #expect(Set(snap.remaining) == ["d", "f"])
  #expect(snap.total == 4)  // a, c, d, f
  #expect(snap.done == 2)  // a, c

  let all = QueueBuilder.build(candidates: assets, records: records, pass: pass, order: .oldestFirst, skipInOrder: false)
  #expect(Set(all.remaining) == ["b", "d", "f"])
  #expect(all.total == 5)
}

@Test func skippedPhotosGoToTheBackInSkipOrder() {
  let assets = (1...5).map { asset("p\($0)", year: 2000 + $0) }
  let pass = PassState(number: 1, seed: 1, startedAt: .distantPast, skipped: ["p3", "p1"])
  let snap = QueueBuilder.build(candidates: assets, records: [:], pass: pass, order: .oldestFirst, skipInOrder: true)
  #expect(snap.remaining == ["p2", "p4", "p5", "p3", "p1"])
}

@Test func datedOrdersPutUndatedFirstOrLast() {
  let assets = [asset("new", year: 2020), asset("none", year: nil), asset("old", year: 1999)]
  let pass = PassState(number: 1, seed: 1, startedAt: .distantPast)
  let oldest = QueueBuilder.build(candidates: assets, records: [:], pass: pass, order: .oldestFirst, skipInOrder: true)
  #expect(oldest.remaining == ["none", "old", "new"])
  let newest = QueueBuilder.build(candidates: assets, records: [:], pass: pass, order: .newestFirst, skipInOrder: true)
  #expect(newest.remaining == ["new", "old", "none"])
}

@Test func smartQueuesMatchTheRightPhotos() {
  var flagged = AssetRecord()
  flagged.set(.delete, true)
  flagged.set(.blurry, true)
  flagged.reviewCount = 1
  var screenshot = asset("s")
  screenshot.isScreenshot = true
  var clip = asset("v", kind: .video)
  clip.duration = 1.5
  var tiny = asset("t")
  tiny.pixelWidth = 640
  tiny.pixelHeight = 480
  let undated = asset("u", year: 1900)
  let counts = QueueBuilder.queueCounts([screenshot, clip, tiny, undated, asset("x")], records: ["x": flagged])
  #expect(counts[.screenshots] == 1)
  #expect(counts[.shortVideos] == 1)
  #expect(counts[.lowResolution] == 1)
  #expect(counts[.undated] == 1)
  #expect(counts[.toDelete] == 1)
  #expect(counts[.blurry] == 1)
  #expect(counts[.notReviewed] == 4)
  #expect(counts[.noLocation] == 5)
}

@Test func placeholderDatesFollowTheConventions() throws {
  let cal = Calendar(identifier: .gregorian)
  let yearOnly = try #require(DateRules.placeholder(year: 1987, month: nil, day: nil, calendar: cal))
  #expect(cal.dateComponents([.year, .month, .day, .hour], from: yearOnly) == DateComponents(year: 1987, month: 7, day: 1, hour: 12))
  let monthOnly = try #require(DateRules.placeholder(year: 1987, month: 3, day: nil, calendar: cal))
  #expect(cal.component(.day, from: monthOnly) == 15)
  #expect(DateRules.placeholder(year: 1987, month: 2, day: 31, calendar: cal) == nil)
  #expect(DateRules.isApproximate(month: 3, day: nil))
  #expect(!DateRules.isApproximate(month: 3, day: 4))
  #expect(DateRules.isUndated(cal.date(from: DateComponents(year: 1900, month: 1, day: 1)), calendar: cal))
  #expect(!DateRules.isUndated(yearOnly, calendar: cal))
  #expect(DateRules.isUndated(nil))
}

@Test func storeRoundTripsAndKeepsABackup() throws {
  let dir = try tempDir()
  let store = try ReviewStore(directory: dir)
  store.update("A/L0/001") { r in
    r.verdict = .lookLater
    r.set(.records, true)
    r.set(.blurry, true)
    r.reviewCount = 1
    r.filename = "IMG_0001.JPG"
  }
  store.setPass(PassState(number: 3, seed: 99, startedAt: Date(timeIntervalSince1970: 5)), for: "library")
  store.save()
  store.log(ActionLogEntry(asset: "A/L0/001", action: "verdict", after: "lookLater"))
  store.log(ActionLogEntry(asset: "A/L0/001", action: "flag", after: "records"))

  let reopened = try ReviewStore(directory: dir)
  let record = try #require(reopened.record("A/L0/001"))
  #expect(record.flags == [.blurry, .records])
  #expect(record.mirrorLabels == ["Look at Later", "Blurry", "To Records"])
  #expect(reopened.data.passes["library"]?.seed == 99)
  reopened.update("B/L0/001") { $0.note = "second" }
  reopened.save()
  #expect(FileManager.default.fileExists(atPath: reopened.backupURL.path))
  let lines = try String(contentsOf: reopened.logURL, encoding: .utf8).split(separator: "\n")
  #expect(lines.count == 2)

  let json = try String(contentsOf: reopened.fileURL, encoding: .utf8)
  #expect(json.contains("\"format\" : \"photodefrigifier-review-store\""))
  #expect(json.contains("A/L0/001"))  // slashes not escaped, so the file is easy to read and grep
}

@Test func unreadableStoreIsSetAsideNotOverwritten() throws {
  let dir = try tempDir()
  try Data("{ not json".utf8).write(to: dir.appendingPathComponent("review-store.json"))
  let store = try ReviewStore(directory: dir)
  #expect(store.problem != nil)
  #expect(store.data.assets.isEmpty)
  let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
  #expect(names.contains { $0.hasPrefix("review-store.unreadable-") })
}

@Test func recordsWithMissingFieldsStillDecode() throws {
  let json = #"{"verdict":"inOrder"}"#
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let record = try decoder.decode(AssetRecord.self, from: Data(json.utf8))
  #expect(record.verdict == .inOrder)
  #expect(record.flags.isEmpty)
  #expect(record.reviewCount == 0)
}

@Test func archivedPhotosAreFinishedLikeInOrder() {
  let start = Date(timeIntervalSince1970: 2_000_000)
  let pass = PassState(number: 2, seed: 5, startedAt: start)
  var archivedBefore = AssetRecord()
  archivedBefore.verdict = .archived
  archivedBefore.lastReviewedAt = start.addingTimeInterval(-10)
  let snap = QueueBuilder.build(
    candidates: [asset("kept"), asset("archived")], records: ["archived": archivedBefore], pass: pass,
    order: .oldestFirst, skipInOrder: true)
  #expect(snap.remaining == ["kept"])
  #expect(snap.total == 1)
  #expect(Verdict.archived.key == "A")
  #expect(Verdict.archived.pastTitle == "Archived")
  #expect(Verdict.inOrder.pastTitle == Verdict.inOrder.title)
}

@Test func healthRulesOnlyReportWhatCanBeMeasured() {
  let cal = Calendar(identifier: .gregorian)
  func statuses(_ a: AssetSummary, _ r: AssetRecord? = nil, albums: [String] = [], keywords: [String]? = nil)
    -> [HealthSignal: HealthStatus]
  {
    Dictionary(uniqueKeysWithValues: HealthRules.evaluate(a, record: r, albumPaths: albums, keywords: keywords, calendar: cal)
      .map { ($0.signal, $0.status) })
  }
  // An undated small scan, only in import albums, never reviewed.
  var scan = asset("scan", year: 1900)
  scan.pixelWidth = 900
  scan.pixelHeight = 700
  let s = statuses(scan, albums: ["From Amazon › All from Amazon", "Quick Fix › Blurry"])
  #expect(s[.date] == .missing && s[.location] == .missing && s[.size] == .missing)
  #expect(s[.sharpness] == .unsure && s[.album] == .unsure)

  // A good photo in one of the user's albums, reviewed, with a location.
  var good = asset("good", year: 2024)
  good.hasLocation = true
  var reviewed = AssetRecord()
  reviewed.reviewCount = 1
  let g = statuses(good, reviewed, albums: ["Family › Spring 2024"])
  #expect(g.values.allSatisfy { $0 == .good })

  // Approximate dates come from the app's own redates or the "Date approximate" keyword.
  #expect(statuses(good, keywords: ["Date approximate"])[.date] == .unsure)
  var approx = AssetRecord()
  approx.dateApproximate = true
  #expect(statuses(good, approx)[.date] == .unsure)

  // Screenshots and videos: rows that don't apply are grey, not red.
  var shot = asset("shot", year: 2021)
  shot.isScreenshot = true
  #expect(statuses(shot)[.location] == .notApplicable)
  #expect(statuses(shot)[.sharpness] == .notApplicable)
  var clip = asset("clip", year: 2015, kind: .video)
  clip.pixelWidth = 1280
  clip.pixelHeight = 720
  #expect(statuses(clip)[.size] == .good)
  #expect(statuses(clip)[.sharpness] == .notApplicable)

  // Marked blurry always shows as a problem.
  var blurry = AssetRecord()
  blurry.set(.blurry, true)
  #expect(statuses(clip, blurry)[.sharpness] == .missing)
  #expect(HealthStatus.unsure.glyph == "?")
}

@Test func albumRulesRankRecentsAndSkipBookkeeping() {
  let albums = [
    AlbumRef(id: "x", title: "Xmas at the Hannahs", path: "From Amazon › Events › Xmas at the Hannahs"),
    AlbumRef(id: "c", title: "crows", path: "From Amazon › Events › crows"),
    AlbumRef(id: "m", title: "Christmas morning", path: "Family › Christmas morning"),
    AlbumRef(id: "a", title: "All from Amazon", path: "From Amazon › All from Amazon"),
    AlbumRef(id: "e", title: "Éclairs", path: "Food › Éclairs"),
  ]
  #expect(AlbumRules.isBookkeeping("From Amazon › All from Amazon"))
  #expect(AlbumRules.isBookkeeping("From Amazon › Import batches › 03 2005-2006"))
  #expect(AlbumRules.isBookkeeping("Quick Fix › Blurry"))
  #expect(!AlbumRules.isBookkeeping("From Amazon › Events › crows"))
  #expect(AlbumRules.isMarker("Quick Fix › To Delete") && !AlbumRules.isMarker("From Amazon › Events › crows"))
  #expect(albums[0].folderPath == "From Amazon › Events")
  #expect(AlbumRef(id: "t", title: "Top", path: "Top").folderPath == "")

  // Every word must match title or path; recent albums first, then title-prefix matches, then A–Z.
  #expect(AlbumRules.search(albums, query: "xmas", recentIDs: []).map(\.id) == ["x"])
  #expect(AlbumRules.search(albums, query: "events", recentIDs: ["x"]).map(\.id) == ["x", "c"])
  #expect(AlbumRules.search(albums, query: "chr", recentIDs: []).map(\.id) == ["m"])
  #expect(AlbumRules.search(albums, query: "eclairs", recentIDs: []).map(\.id) == ["e"])
  #expect(AlbumRules.search(albums, query: "c", recentIDs: ["c"]).first?.id == "c")
  #expect(AlbumRules.search(albums, query: "", recentIDs: []).first?.id == "a")

  // Recent list: newest first, no repeats, capped.
  let t0 = Date(timeIntervalSince1970: 0)
  var recent: [RecentAlbum] = []
  recent = AlbumRules.bump("x", in: recent, at: t0)
  recent = AlbumRules.bump("c", in: recent, at: t0.addingTimeInterval(1))
  recent = AlbumRules.bump("x", in: recent, at: t0.addingTimeInterval(2))
  #expect(recent.map(\.id) == ["x", "c"])
  #expect(AlbumRules.bump("m", in: recent, at: t0, limit: 2).map(\.id) == ["m", "x"])

  // Event albums from the import now count as the user's own albums in the health panel.
  let good = HealthRules.album(["From Amazon › All from Amazon", "From Amazon › Events › crows"])
  #expect(good.status == .good && good.detail == "crows")
}
