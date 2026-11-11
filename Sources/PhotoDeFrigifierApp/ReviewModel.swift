import AppKit
import Observation
import Photos
import QuickFixCore
import SwiftUI

/// The review session: which scope you're in, where you are in it, and every action you can take on a photo.
@MainActor
@Observable
final class ReviewModel {
  let library = PhotoLibrary()
  let store: ReviewStore

  // Where we are
  private(set) var scope: Scope = .library
  private(set) var trail: [String] = []
  private(set) var position = -1
  private(set) var passTotal = 0
  private(set) var passDone = 0
  private(set) var queueCounts: [SmartQueue: Int] = [:]
  @ObservationIgnored private var upcoming: [String] = []
  @ObservationIgnored private var upcomingIndex = 0
  @ObservationIgnored private var candidates: [AssetSummary] = []

  // Session
  private(set) var sessionReviewed: Set<String> = []
  let sessionStartedAt = Date()
  private(set) var lastAppliedDate: Date?

  // Current photo details
  private(set) var currentFilename: String?
  private(set) var currentAlbums: [AlbumRef] = []
  /// The photo's keywords as Photos reports them (read through AppleScript, a moment after it's shown);
  /// nil until read, or when Photos can't be asked.
  private(set) var currentKeywords: [String]?
  @ObservationIgnored private var keywordCache: [String: [String]] = [:]
  @ObservationIgnored private var keywordTask: Task<Void, Never>?
  @ObservationIgnored private var keywordsUnavailable = false

  // UI state
  var status: String?
  var busy = false
  var showRedate = false
  var showDeleteReview = false
  var showRecords = false
  var showAlbumPicker = false
  var sheetOpen: Bool { showRedate || showDeleteReview || showRecords || showAlbumPicker }

  /// Albums you've added photos to, newest first (kept between launches).
  private(set) var recentAlbumEntries: [RecentAlbum] = [] {
    didSet {
      if let data = try? JSONEncoder().encode(recentAlbumEntries) {
        UserDefaults.standard.set(data, forKey: "recentAlbums")
      }
    }
  }
  /// Until you've used a few albums, Recent is filled from the albums of photos you reviewed most recently.
  @ObservationIgnored private var seedAlbumIDs: [String] = []

  // Settings
  var order: ReviewOrder {
    didSet { UserDefaults.standard.set(order.rawValue, forKey: "order"); rebuildQueue() }
  }
  var skipInOrder: Bool {
    didSet { UserDefaults.standard.set(skipInOrder, forKey: "skipInOrder"); rebuildQueue() }
  }
  var mirrorToAlbums: Bool {
    didSet { UserDefaults.standard.set(mirrorToAlbums, forKey: "mirrorToAlbums") }
  }
  /// The health panel on the photo; when off, a slim colour strip stays on the edge (H toggles).
  var showHealth: Bool {
    didSet { UserDefaults.standard.set(showHealth, forKey: "showHealth") }
  }
  var sessionGoal: Int {
    didSet { UserDefaults.standard.set(sessionGoal, forKey: "sessionGoal") }
  }
  var recordsFolder: URL? {
    didSet { UserDefaults.standard.set(recordsFolder?.path, forKey: "recordsFolder") }
  }

  @ObservationIgnored private var undoStack: [UndoItem] = []
  @ObservationIgnored private var statusTask: Task<Void, Never>?
  @ObservationIgnored private var noteSaveTask: Task<Void, Never>?
  @ObservationIgnored private var keyMonitor: Any?
  @ObservationIgnored private var mirrorChain: Task<Void, Never>?
  /// The main review window; single-key shortcuts only apply there.
  @ObservationIgnored weak var reviewWindow: NSWindow?

  enum UndoItem {
    case record(id: String, before: AssetRecord?, after: AssetRecord, countedInSession: Bool)
    case favorite(id: String, before: Bool)
    case date(id: String, before: Date?, recordBefore: AssetRecord?)
    case rotate(id: String, quarterTurns: Int)
    case skip(id: String, scopeKey: String, passBefore: PassState)
    case archive(id: String, before: AssetRecord?, after: AssetRecord, countedInSession: Bool)
    case album(id: String, album: AlbumRef, added: Bool)
  }

  init() {
    let defaults = UserDefaults.standard
    order = ReviewOrder(rawValue: defaults.string(forKey: "order") ?? "") ?? .shuffle
    skipInOrder = defaults.object(forKey: "skipInOrder") as? Bool ?? true
    mirrorToAlbums = defaults.object(forKey: "mirrorToAlbums") as? Bool ?? true
    showHealth = defaults.object(forKey: "showHealth") as? Bool ?? true
    if let data = defaults.data(forKey: "recentAlbums"),
      let saved = try? JSONDecoder().decode([RecentAlbum].self, from: data)
    {
      recentAlbumEntries = saved
    }
    sessionGoal = defaults.object(forKey: "sessionGoal") as? Int ?? 20
    recordsFolder = defaults.string(forKey: "recordsFolder").map { URL(fileURLWithPath: $0) } ?? Self.findRecordsFolder()
    do {
      store = try ReviewStore()
    } catch {
      // Fall back to a store in a temporary folder so the app still opens; the problem is shown.
      let temp = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoDeFrigifier-\(UUID().uuidString)")
      store = (try? ReviewStore(directory: temp))!
      store.problem = "\(error.localizedDescription) Reviews this session are NOT being saved."
    }
  }

  // MARK: Derived

  var currentID: String? { trail.indices.contains(position) ? trail[position] : nil }
  var current: AssetSummary? { currentID.flatMap { library.summaryByID[$0] } }
  var currentRecord: AssetRecord? { currentID.flatMap { store.record($0) } }

  /// What the health panel shows for the current photo. Only measured facts: see QuickFixCore/Health.swift.
  var health: [HealthItem] {
    guard let asset = current else { return [] }
    return HealthRules.evaluate(
      asset, record: currentRecord, albumPaths: currentAlbums.map(\.path), keywords: currentKeywords)
  }
  var isPassComplete: Bool { position >= trail.count && upcomingIndex >= upcoming.count && passTotal > 0 }
  var isScopeEmpty: Bool { passTotal == 0 && !library.isLoading }
  var sessionCount: Int { sessionReviewed.count }
  var passNumber: Int { store.data.passes[scope.key]?.number ?? 1 }
  var canGoBack: Bool { position > 0 }
  var canUndo: Bool { !undoStack.isEmpty }

  var flaggedForDeletion: [String] {
    store.data.assets.compactMap { id, r in
      r.has(.delete) && r.deletedAt == nil && library.summaryByID[id] != nil ? id : nil
    }.sorted()
  }

  /// Archived photos that are tagged but still visible, waiting for the batch hide.
  var archivedToHide: [String] {
    store.data.assets.compactMap { id, r in
      r.verdict == .archived && r.hiddenAt == nil && library.summaryByID[id] != nil ? id : nil
    }.sorted()
  }

  var flaggedForRecords: [String] {
    store.data.assets.compactMap { id, r in
      r.has(.records) && r.deletedAt == nil && library.summaryByID[id] != nil ? id : nil
    }.sorted()
  }

  // MARK: Start-up and scope

  func start() async {
    await library.start()
    if library.access == .granted {
      select(scope)
      seedRecentAlbums()
    }
    if let problem = store.problem { flash(problem, seconds: 12) }
    if CommandLine.arguments.contains("--self-check") { await writeSelfCheck() }
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
      await writeSnapshots(to: URL(fileURLWithPath: args[i + 1]))
    }
  }

  /// Development aid: `open PhotoDeFrigifier.app --args --snapshot <folder>` renders the window at a few sizes
  /// into PNGs (the app drawing its own views, so no screen-recording permission is needed), restores the
  /// window size and quits. Changes nothing in Photos or the review store.
  private func writeSnapshots(to folder: URL) async {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? await Task.sleep(for: .seconds(2))
    guard let window = reviewWindow else {
      NSApp.terminate(nil)
      return
    }
    let original = window.frame
    for size in [CGSize(width: 1440, height: 900), CGSize(width: 1100, height: 760), CGSize(width: 860, height: 640)] {
      window.setContentSize(size)
      try? await Task.sleep(for: .seconds(2))
      guard let view = window.contentView?.superview ?? window.contentView,
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      else { continue }
      view.cacheDisplay(in: view.bounds, to: rep)
      if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: folder.appendingPathComponent("window-\(Int(size.width))x\(Int(size.height)).png"))
      }
    }
    window.setFrame(original, display: false)
    // The album picker, as a sheet (read-only: opening it changes nothing).
    if current != nil {
      showAlbumPicker = true
      try? await Task.sleep(for: .seconds(2))
      if let sheet = window.attachedSheet, let view = sheet.contentView,
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      {
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("album-picker.png"))
      }
      showAlbumPicker = false
      try? await Task.sleep(for: .milliseconds(500))
    }
    NSApp.terminate(nil)
  }

  /// Read-only diagnostics: `open PhotoDeFrigifier.app --args --self-check` writes self-check.json next to the
  /// review store (counts and timings only, no photo content) and quits. Changes nothing in Photos.
  private func writeSelfCheck() async {
    var report: [String: Any] = ["access": "\(library.access)", "at": Self.logDate(.now)]
    let ids = library.summaries.map(\.id)
    report["assets"] = ids.count
    report["kinds"] = Dictionary(grouping: library.summaries, by: \.kind.rawValue).mapValues(\.count)
    let hidden = library.hiddenCount()
    report["hidden"] = ["inPhotos": hidden.count, "shownInApp": hidden.shown]
    report["queues"] = Dictionary(uniqueKeysWithValues: queueCounts.map { ($0.key.rawValue, $0.value) })
    func flatten(_ nodes: [AlbumNode]) -> [AlbumNode] { nodes.flatMap { [$0] + flatten($0.children ?? []) } }
    let all = flatten(library.albums)
    report["albums"] = all.filter { !$0.isFolder }.count
    report["folders"] = all.filter(\.isFolder).count
    report["identifierFormatOK"] = ids.prefix(50).allSatisfy { $0.hasSuffix("/L0/001") }
    let sample = Array(ids.shuffled().prefix(50))
    var t = Date()
    let names = sample.compactMap { library.filename($0) }
    report["filenameLookups"] = ["found": names.count, "of": sample.count, "msEach": Date().timeIntervalSince(t) * 1000 / 50]
    t = Date()
    let memberships = sample.map { library.albums(containing: $0).count }
    report["albumLookups"] = ["withAlbums": memberships.filter { $0 > 0 }.count, "msEach": Date().timeIntervalSince(t) * 1000 / 50]
    if let biggest = all.filter({ !$0.isFolder }).max(by: { ($0.count ?? 0) < ($1.count ?? 0) }) {
      t = Date()
      report["biggestAlbumMembers"] = ["count": biggest.count ?? 0, "fetched": library.memberIDs(of: biggest.id).count,
                                       "ms": Date().timeIntervalSince(t) * 1000]
    }
    if let folder = all.first(where: \.isFolder) {
      report["firstFolderMembers"] = library.memberIDs(of: folder.id).count
    }
    if let first = sample.first {
      t = Date()
      let thumb = await library.image(for: first, size: CGSize(width: 400, height: 400), fast: true)
      report["thumbnail"] = ["ok": thumb != nil, "ms": Date().timeIntervalSince(t) * 1000]
    }
    report["queue"] = ["scope": scope.key, "total": passTotal, "done": passDone, "current": currentID != nil]
    report["mirrorFolderExists"] = library.albums.contains { $0.title == PhotoLibrary.mirrorFolderTitle }
    // Exercise each PhotoKit callback path that runs on Photos' own queues, without changing anything:
    // an empty change block, a video player item, an editing input, and an export to a temporary folder.
    var callbacks: [String: String] = [:]
    do { try await library.emptyChange(); callbacks["performChanges"] = "ok" } catch {
      callbacks["performChanges"] = error.localizedDescription
    }
    if let video = library.summaries.first(where: \.isVideo) {
      callbacks["playerItem"] = await library.playerItem(for: video.id) != nil ? "ok" : "nil"
    }
    if let photo = library.summaries.last(where: { $0.kind == .photo }), let a = library.asset(photo.id) {
      do { _ = try await library.contentEditingInput(for: a); callbacks["editingInput"] = "ok" } catch {
        callbacks["editingInput"] = error.localizedDescription
      }
      let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-selfcheck-\(UUID().uuidString)")
      try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
      do { _ = try await library.exportOriginal(photo.id, to: temp); callbacks["export"] = "ok" } catch {
        callbacks["export"] = error.localizedDescription
      }
      try? FileManager.default.removeItem(at: temp)
    }
    // Read-only AppleScript check (the Archive key's keyword path). The first run asks to control Photos.
    if let first = library.summaries.first {
      do { _ = try await library.keywords(first.id); callbacks["keywordsRead"] = "ok" } catch {
        callbacks["keywordsRead"] = error.localizedDescription
      }
    }
    report["callbacks"] = callbacks
    let url = store.directory.appendingPathComponent("self-check.json")
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: url)
    }
    NSApp.terminate(nil)
  }

  func select(_ newScope: Scope) {
    scope = newScope
    switch newScope {
    case .library: candidates = library.summaries
    case .queue(let q): candidates = library.summaries.filter { q.matches($0, store.record($0.id)) }
    case .album(let id, _): candidates = library.memberIDs(of: id).compactMap { library.summaryByID[$0] }
    }
    trail = []
    position = -1
    rebuildQueue()
    advance()
  }

  /// Re-orders what's left (after a settings change) without losing the photos already visited.
  private func rebuildQueue() {
    let pass = store.pass(for: scope.key)
    let snap = QueueBuilder.build(
      candidates: candidates, records: store.data.assets, pass: pass, order: order, skipInOrder: skipInOrder)
    let visited = Set(trail)
    upcoming = snap.remaining.filter { !visited.contains($0) }
    upcomingIndex = 0
    passTotal = snap.total
    passDone = snap.done
    queueCounts = QueueBuilder.queueCounts(library.summaries, records: store.data.assets)
  }

  private func refreshProgress() {
    let pass = store.pass(for: scope.key)
    let snap = QueueBuilder.build(
      candidates: candidates, records: store.data.assets, pass: pass, order: .oldestFirst, skipInOrder: skipInOrder)
    passTotal = snap.total
    passDone = snap.done
    queueCounts = QueueBuilder.queueCounts(library.summaries, records: store.data.assets)
  }

  func startNextPass() {
    let old = store.pass(for: scope.key)
    store.setPass(PassState.fresh(number: old.number + 1), for: scope.key)
    store.save()
    select(scope)
  }

  // MARK: Navigation

  func advance() {
    if position + 1 < trail.count {
      position += 1
      loadDetails()
      return
    }
    let pass = store.pass(for: scope.key)
    while upcomingIndex < upcoming.count {
      let next = upcoming[upcomingIndex]
      upcomingIndex += 1
      // Reviewed somewhere else since the queue was built, or gone from the library.
      if store.record(next)?.reviewed(since: pass.startedAt) == true { continue }
      guard library.summaryByID[next] != nil else { continue }
      trail.append(next)
      position = trail.count - 1
      loadDetails()
      library.prefetch(Array(upcoming[upcomingIndex..<min(upcomingIndex + 3, upcoming.count)]))
      return
    }
    position = trail.count
    loadDetails()
  }

  func goBack() {
    guard position > 0 else { return }
    position = min(position, trail.count) - 1
    loadDetails()
  }

  func jump(to id: String) {
    if let i = trail.lastIndex(of: id) {
      position = i
    } else {
      trail.insert(id, at: min(max(position, 0), trail.count))
      position = trail.firstIndex(of: id) ?? 0
    }
    loadDetails()
  }

  private func loadDetails() {
    keywordTask?.cancel()
    guard let id = currentID else {
      currentFilename = nil
      currentAlbums = []
      currentKeywords = nil
      return
    }
    currentFilename = library.filename(id)
    currentAlbums = library.albums(containing: id)
    currentKeywords = keywordCache[id]
    guard currentKeywords == nil, !keywordsUnavailable else { return }
    // Asking Photos takes a moment, so wait until the photo has been on screen briefly (skipping fast is free).
    keywordTask = Task {
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled, currentID == id else { return }
      do {
        let keywords = try await library.keywords(id)
        keywordCache[id] = keywords
        if currentID == id { currentKeywords = keywords }
      } catch {
        // No permission or Photos not answering: stop asking this session; Date falls back to the app's own notes.
        keywordsUnavailable = true
      }
    }
  }

  func refreshAlbumsForCurrent() {
    if let id = currentID { currentAlbums = library.albums(containing: id) }
  }

  // MARK: Review actions

  func setVerdict(_ verdict: Verdict) {
    if verdict == .archived {
      archive()
      return
    }
    guard let id = currentID else { return }
    changeRecord(id, action: "verdict", detail: verdict.rawValue, countsAsReview: true) { r in
      r.verdict = verdict
      r.verdictAt = .now
    }
    advance()
  }

  func toggle(_ flag: Flag) {
    guard let id = currentID else { return }
    let turningOn = !(store.record(id)?.has(flag) ?? false)
    // Marking for deletion or for records finishes with the photo, so it counts as reviewed and moves on.
    let finishes = turningOn && (flag == .delete || flag == .records)
    changeRecord(id, action: turningOn ? "flag" : "unflag", detail: flag.rawValue, countsAsReview: finishes) { r in
      r.set(flag, turningOn)
    }
    if finishes { advance() }
  }

  func skip() {
    guard let id = currentID else {
      advance()
      return
    }
    var pass = store.pass(for: scope.key)
    let before = pass
    if !pass.skipped.contains(id) {
      pass.skipped.append(id)
      store.setPass(pass, for: scope.key)
      store.save()
      undoStack.append(.skip(id: id, scopeKey: scope.key, passBefore: before))
    }
    advance()
  }

  func setNote(_ text: String) {
    guard let id = currentID else { return }
    store.update(id) { r in
      r.note = text.isEmpty ? nil : text
      if r.filename == nil { r.filename = currentFilename }
    }
    noteSaveTask?.cancel()
    noteSaveTask = Task {
      try? await Task.sleep(for: .milliseconds(800))
      guard !Task.isCancelled else { return }
      store.save()
      store.log(ActionLogEntry(asset: id, filename: store.record(id)?.filename, action: "note", after: text, scope: scope.key))
    }
  }

  /// Every review-store change goes through here: before/after for undo, the log, saving, and album mirroring.
  @discardableResult
  private func changeRecord(
    _ id: String, action: String, detail: String, countsAsReview: Bool, pushUndo: Bool = true,
    _ change: (inout AssetRecord) -> Void
  ) -> (before: AssetRecord?, after: AssetRecord, counted: Bool) {
    let name = currentFilename
    let (before, after) = store.update(id) { r in
      change(&r)
      if r.filename == nil { r.filename = name }
      if countsAsReview {
        r.reviewCount += 1
        r.lastReviewedAt = .now
      }
    }
    store.save()
    store.log(ActionLogEntry(asset: id, filename: after.filename, action: action, after: detail, scope: scope.key))
    var counted = false
    if countsAsReview, sessionReviewed.insert(id).inserted {
      counted = true
      if sessionGoal > 0, sessionReviewed.count == sessionGoal {
        flash("Session goal reached: \(sessionGoal) photos. Keep going, or call it a day.", seconds: 5)
      }
    }
    if pushUndo { undoStack.append(.record(id: id, before: before, after: after, countedInSession: counted)) }
    mirror(id, from: before, to: after)
    refreshProgress()
    return (before, after, counted)
  }

  /// Important to keep, but not to see every day. Adds the "Archived" keyword in Photos, checks Photos reports
  /// it, records the verdict and moves on. Hiding happens later for the whole batch (`hideArchived`), because
  /// macOS asks for confirmation on every hide request.
  func archive() {
    guard let id = currentID, !busy else { return }
    let keyword = PhotoLibrary.archiveKeyword
    run("Archiving…") {
      let keywords = try await self.library.setKeyword(id, keyword, add: true)
      guard keywords.contains(keyword) else {
        throw PhotoLibraryError.keywordFailed("Photos reported keywords: \(keywords.joined(separator: ", ")).")
      }
      self.keywordCache[id] = keywords
      let change = self.changeRecord(
        id, action: "archive", detail: "keyword \(keyword)", countsAsReview: true, pushUndo: false
      ) { r in
        r.verdict = .archived
        r.verdictAt = .now
      }
      self.undoStack.append(
        .archive(id: id, before: change.before, after: change.after, countedInSession: change.counted))
      if self.currentID == id { self.advance() }
      let waiting = self.archivedToHide.count
      self.flash("Archived. \(waiting) waiting to be hidden: use Hide Archived when you're done.")
    }
  }

  /// Hides every archived photo that's still visible, in one request: one macOS confirmation for the batch.
  func hideArchived() async {
    let ids = archivedToHide
    guard !ids.isEmpty, !busy else { return }
    busy = true
    defer { busy = false }
    do {
      try await library.setHidden(ids, true)
    } catch {
      let ns = error as NSError
      if (error as? PHPhotosError)?.code == .userCancelled || ns.code == NSUserCancelledError {
        flash("Nothing was hidden.")
      } else {
        flash("Couldn't hide: \(error.localizedDescription)")
      }
      return
    }
    let now = Date()
    for id in ids {
      store.update(id) { $0.hiddenAt = now }
      store.log(ActionLogEntry(asset: id, filename: store.record(id)?.filename, action: "hide", after: "hidden"))
    }
    store.save()
    refreshProgress()
    flash("\(ids.count) archived photo\(ids.count == 1 ? "" : "s") hidden in Photos.", seconds: 5)
  }

  private func mirror(_ id: String, from before: AssetRecord?, to after: AssetRecord?) {
    guard mirrorToAlbums else { return }
    let old = before?.mirrorLabels ?? []
    let new = after?.mirrorLabels ?? []
    let changes = new.subtracting(old).map { ($0, true) } + old.subtracting(new).map { ($0, false) }
    guard !changes.isEmpty else { return }
    let previous = mirrorChain
    mirrorChain = Task {
      await previous?.value
      do {
        for (label, on) in changes { try await library.setMirror(id, label: label, on: on) }
        if id == currentID { refreshAlbumsForCurrent() }
      } catch {
        flash("Couldn't update the Quick Fix albums in Photos: \(error.localizedDescription)")
      }
    }
  }

  // MARK: Albums

  /// Up to five albums for ⌥1–⌥5 and the top of the picker: ones you used, newest first, then seeds.
  var recentAlbums: [AlbumRef] {
    var out: [AlbumRef] = []
    var seen = Set<String>()
    for id in recentAlbumEntries.map(\.id) + seedAlbumIDs where seen.insert(id).inserted {
      if let album = library.albumByID[id] { out.append(album) }
      if out.count == 5 { break }
    }
    return out
  }

  func recentLabel(_ albumID: String) -> String {
    guard let used = recentAlbumEntries.first(where: { $0.id == albumID })?.usedAt else { return "From recent photos" }
    if Date().timeIntervalSince(used) < 60 { return "Used just now" }
    return "Used " + used.formatted(.relative(presentation: .named))
  }

  func isInAlbum(_ albumID: String) -> Bool { currentAlbums.contains { $0.id == albumID } }

  private func seedRecentAlbums() {
    let reviewed = store.data.assets
      .compactMap { id, r in r.lastReviewedAt.map { (id, $0) } }
      .sorted { $0.1 > $1.1 }
      .prefix(40)
    var ids: [String] = []
    for (assetID, _) in reviewed where library.summaryByID[assetID] != nil {
      for album in library.albums(containing: assetID)
      where library.albumByID[album.id] != nil && !AlbumRules.isBookkeeping(album.path) && !ids.contains(album.id) {
        ids.append(album.id)
      }
      if ids.count >= 5 { break }
    }
    seedAlbumIDs = ids
  }

  /// ⌥1–⌥5: add the photo to (or take it out of) that recent album.
  func quickAlbum(_ index: Int) {
    let recent = recentAlbums
    guard recent.indices.contains(index) else {
      flash("No recent album \(index + 1) yet. Press L to pick one.")
      return
    }
    toggleAlbum(recent[index])
  }

  /// Adds the current photo to the album, or removes it if it's already there. With `thenNext`, moves on after.
  func toggleAlbum(_ album: AlbumRef, thenNext: Bool = false) {
    guard let id = currentID, !busy else { return }
    let adding = !isInAlbum(album.id)
    if thenNext && !adding {
      skip()
      return
    }
    run(nil) {
      try await self.library.setAlbum(id, albumID: album.id, member: adding)
      self.undoStack.append(.album(id: id, album: album, added: adding))
      self.store.log(ActionLogEntry(asset: id, filename: self.currentFilename, action: adding ? "album-add" : "album-remove",
                                    after: album.path, scope: self.scope.key))
      if adding { self.recentAlbumEntries = AlbumRules.bump(album.id, in: self.recentAlbumEntries, at: .now) }
      if self.currentID == id { self.refreshAlbumsForCurrent() }
      self.flash(adding ? "Added to \(album.title) · ⌘Z to undo" : "Removed from \(album.title) · ⌘Z to undo")
      if thenNext { self.skip() }
    }
  }

  /// Makes a new album with the current photo in it; it becomes ⌥1.
  func createAlbumAndAdd(title: String, folderID: String?) {
    guard let id = currentID, !busy else { return }
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    run("Making the album…") {
      let albumID = try await self.library.createAlbum(title: name, folderID: folderID, adding: id)
      let album = self.library.albumByID[albumID] ?? AlbumRef(id: albumID, title: name, path: name)
      self.undoStack.append(.album(id: id, album: album, added: true))
      self.store.log(ActionLogEntry(asset: id, filename: self.currentFilename, action: "album-create",
                                    after: album.path, scope: self.scope.key))
      self.recentAlbumEntries = AlbumRules.bump(albumID, in: self.recentAlbumEntries, at: .now)
      if self.currentID == id { self.refreshAlbumsForCurrent() }
      self.flash("Made “\(name)” and added the photo · ⌘Z to undo")
    }
  }

  // MARK: Clipboard

  /// ⌘C or right-click › Copy: a photo goes on the clipboard as a full-size image (edits included);
  /// a video goes on as a file, so it pastes into Finder, Messages or Mail.
  func copyCurrent() {
    guard let id = currentID, let asset = current, !busy else { return }
    busy = true
    status = asset.isVideo ? "Copying the video…" : "Copying the photo…"
    Task {
      defer { busy = false }
      let board = NSPasteboard.general
      do {
        if asset.isVideo {
          let url = try await library.exportForClipboard(id)
          board.clearContents()
          board.writeObjects([url as NSURL])
        } else {
          guard let image = await library.fullImage(for: id) else { throw PhotoLibraryError.noResource }
          board.clearContents()
          board.writeObjects([image])
        }
        flash(asset.isVideo ? "Video copied. Paste it into Finder, Messages or Mail." : "Photo copied to the clipboard.")
      } catch {
        flash("Couldn't copy: \(error.localizedDescription)", seconds: 6)
      }
    }
  }

  func copyFilename() {
    guard let name = currentFilename else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(name, forType: .string)
    flash("Copied “\(name)”")
  }

  func showInPhotos() {
    guard let id = currentID else { return }
    run(nil) { try await self.library.showInPhotos(id) }
  }

  // MARK: Photo fixes

  func rotate(clockwise: Bool) {
    guard let id = currentID, !busy else { return }
    let turns = clockwise ? 1 : -1
    run("Rotating…") {
      try await self.library.rotate(id, quarterTurns: turns)
      self.undoStack.append(.rotate(id: id, quarterTurns: turns))
      self.store.log(ActionLogEntry(asset: id, filename: self.currentFilename, action: "rotate",
                                    after: clockwise ? "90° clockwise" : "90° anticlockwise", scope: self.scope.key))
    }
  }

  func toggleFavorite() {
    guard let id = currentID, let asset = current else { return }
    let before = asset.isFavorite
    run(nil) {
      try await self.library.setFavorite(id, !before)
      self.undoStack.append(.favorite(id: id, before: before))
      self.store.log(ActionLogEntry(asset: id, filename: self.currentFilename, action: "favorite",
                                    before: String(before), after: String(!before), scope: self.scope.key))
    }
  }

  func applyDate(_ date: Date, approximate: Bool) {
    guard let id = currentID else { return }
    let before = current?.creationDate
    let recordBefore = store.record(id)
    run("Changing the date…") {
      try await self.library.setDate(id, date)
      self.store.update(id) { r in
        r.dateApproximate = approximate ? true : nil
        if r.filename == nil { r.filename = self.currentFilename }
      }
      self.store.save()
      self.store.log(ActionLogEntry(asset: id, filename: self.currentFilename, action: "date",
                                    before: before.map(Self.logDate), after: Self.logDate(date), scope: self.scope.key))
      self.undoStack.append(.date(id: id, before: before, recordBefore: recordBefore))
      self.lastAppliedDate = date
      self.refreshProgress()
    }
  }

  // MARK: Undo

  func undo() {
    guard let item = undoStack.popLast(), !busy else { return }
    switch item {
    case .record(let id, let before, let after, let counted):
      store.restore(id, to: before)
      store.save()
      store.log(ActionLogEntry(asset: id, filename: after.filename, action: "undo", scope: scope.key))
      if counted { sessionReviewed.remove(id) }
      mirror(id, from: after, to: before)
      refreshProgress()
      jump(to: id)
      flash("Undone")
    case .skip(let id, let key, let passBefore):
      store.setPass(passBefore, for: key)
      store.save()
      jump(to: id)
      flash("Undone")
    case .favorite(let id, let before):
      run("Undoing…") {
        try await self.library.setFavorite(id, before)
        self.jump(to: id)
      }
    case .date(let id, let before, let recordBefore):
      guard let before else { return }
      run("Undoing…") {
        try await self.library.setDate(id, before)
        self.store.restore(id, to: recordBefore)
        self.store.save()
        self.store.log(ActionLogEntry(asset: id, action: "undo", after: Self.logDate(before), scope: self.scope.key))
        self.jump(to: id)
      }
    case .archive(let id, let before, let after, let counted):
      run("Undoing…") {
        if self.store.record(id)?.hiddenAt != nil {
          do {
            try await self.library.setHidden([id], false)
          } catch {
            // Put the undo back so it can be retried once the photo is reachable.
            self.undoStack.append(item)
            throw error
          }
        }
        self.keywordCache[id] = try await self.library.setKeyword(id, PhotoLibrary.archiveKeyword, add: false)
        self.store.restore(id, to: before)
        self.store.save()
        self.store.log(ActionLogEntry(asset: id, filename: after.filename, action: "undo", after: "unarchive",
                                      scope: self.scope.key))
        if counted { self.sessionReviewed.remove(id) }
        self.refreshProgress()
        self.jump(to: id)
      }
    case .album(let id, let album, let added):
      run("Undoing…") {
        try await self.library.setAlbum(id, albumID: album.id, member: !added)
        self.store.log(ActionLogEntry(asset: id, action: "undo", after: (added ? "album-add " : "album-remove ") + album.path,
                                      scope: self.scope.key))
        self.jump(to: id)
        self.flash(added ? "Taken back out of \(album.title)" : "Put back in \(album.title)")
      }
    case .rotate(let id, let turns):
      run("Undoing…") {
        try await self.library.rotate(id, quarterTurns: -turns)
        self.jump(to: id)
      }
    }
  }

  // MARK: Deleting and records

  func deleteFlagged(_ ids: [String]) async -> Bool {
    guard !ids.isEmpty else { return false }
    busy = true
    defer { busy = false }
    do {
      try await library.delete(ids)
    } catch {
      let ns = error as NSError
      if (error as? PHPhotosError)?.code == .userCancelled || ns.code == NSUserCancelledError {
        flash("Nothing was deleted.")
      } else {
        flash("Couldn't delete: \(error.localizedDescription)")
      }
      return false
    }
    for id in ids {
      store.update(id) { $0.deletedAt = .now }
      store.log(ActionLogEntry(asset: id, filename: store.record(id)?.filename, action: "delete", after: "Recently Deleted"))
    }
    store.save()
    refreshProgress()
    flash("\(ids.count) moved to Recently Deleted in Photos (kept there for 30 days).", seconds: 5)
    return true
  }

  func unflag(_ ids: [String], _ flag: Flag) {
    for id in ids {
      let (before, after) = store.update(id) { $0.set(flag, false) }
      store.log(ActionLogEntry(asset: id, filename: after.filename, action: "unflag", after: flag.rawValue))
      mirror(id, from: before, to: after)
    }
    store.save()
    refreshProgress()
  }

  /// Saves each item's original into the records folder, then marks it for deletion so it shows up in the
  /// delete review. Nothing is removed from Photos here.
  func exportRecords(_ ids: [String], progress: @escaping (Int, Int) -> Void) async -> (saved: Int, failed: [String]) {
    guard let folder = recordsFolder else { return (0, ids) }
    busy = true
    defer { busy = false }
    var saved = 0
    var failed: [String] = []
    for (i, id) in ids.enumerated() {
      progress(i, ids.count)
      do {
        let url = try await library.exportOriginal(id, to: folder)
        let (before, after) = store.update(id) { r in
          r.exportedTo = url.path
          r.set(.delete, true)
          if r.filename == nil { r.filename = self.library.filename(id) }
        }
        store.log(ActionLogEntry(asset: id, filename: after.filename, action: "export", after: url.path))
        mirror(id, from: before, to: after)
        saved += 1
      } catch {
        failed.append(store.record(id)?.filename ?? id)
      }
    }
    progress(ids.count, ids.count)
    store.save()
    refreshProgress()
    return (saved, failed)
  }

  /// Looks for a Google Drive "Personal Records" folder to offer as the default destination.
  static func findRecordsFolder() -> URL? {
    let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
    guard let drives = try? FileManager.default.contentsOfDirectory(atPath: cloud.path) else { return nil }
    for drive in drives where drive.hasPrefix("GoogleDrive-") {
      let myDrive = cloud.appendingPathComponent(drive).appendingPathComponent("My Drive")
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: myDrive.path) else { continue }
      if let match = names.first(where: { $0.lowercased().contains("personal") && $0.lowercased().contains("record") }) {
        return myDrive.appendingPathComponent(match)
      }
    }
    return nil
  }

  // MARK: Helpers

  private func run(_ message: String?, _ work: @escaping @MainActor () async throws -> Void) {
    busy = true
    if let message { status = message }
    Task {
      defer { busy = false }
      do {
        try await work()
        if message != nil { status = nil }
      } catch {
        flash(error.localizedDescription, seconds: 6)
      }
    }
  }

  func flash(_ message: String, seconds: Double = 3) {
    status = message
    statusTask?.cancel()
    statusTask = Task {
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      status = nil
    }
  }

  static func logDate(_ date: Date) -> String {
    date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.colon))
  }

  // MARK: Keyboard

  func installKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      return self.handle(event) ? nil : event
    }
  }

  /// Single-key shortcuts for the review screen. Ignored while typing in a text field or when a sheet is open.
  private func handle(_ event: NSEvent) -> Bool {
    if sheetOpen || busy { return false }
    guard let window = event.window, window === reviewWindow else { return false }
    if window.firstResponder is NSTextView { return false }
    let mods = event.modifierFlags.intersection([.command, .control, .option])
    if mods == [.command], event.charactersIgnoringModifiers == "z" {
      undo()
      return true
    }
    if mods == [.command], event.charactersIgnoringModifiers == "c", current != nil {
      copyCurrent()
      return true
    }
    if mods == [.option], current != nil, let c = event.charactersIgnoringModifiers, let n = Int(c), (1...5).contains(n) {
      quickAlbum(n - 1)
      return true
    }
    guard mods.isEmpty else { return false }
    switch event.keyCode {
    case 123: goBack(); return true  // ←
    case 124, 49: skip(); return true  // → or space
    default: break
    }
    guard current != nil, let key = event.charactersIgnoringModifiers?.lowercased().first else { return false }
    switch key {
    case "1": setVerdict(.goodEnough)
    case "2": setVerdict(.lookLater)
    case "3": setVerdict(.inOrder)
    case "a": archive()
    case "d": toggle(.delete)
    case "b": toggle(.blurry)
    case "p": toggle(.records)
    case "r", "]": rotate(clockwise: true)
    case "e", "[": rotate(clockwise: false)
    case "f": toggleFavorite()
    case "t": showRedate = true
    case "u": undo()
    case "h": showHealth.toggle()
    case "l": showAlbumPicker = true
    default: return false
    }
    return true
  }
}
