import AVFoundation
import AppKit
import CoreImage
import Observation
import Photos
import QuickFixCore
import UniformTypeIdentifiers

/// Wraps a non-Sendable value so it can cross a continuation or a Sendable closure.
/// Only used where PhotoKit hands back objects on its own queue and we pass them straight to the main actor.
struct Unchecked<T>: @unchecked Sendable {
  let value: T
}

/// Mutable box for a value produced inside a `performChanges` block (placeholders).
final class Box<T>: @unchecked Sendable {
  var value: T?
}

/// Identifier for our rotation edits, so a later rotation starts from the original instead of the edit.
let rotationAdjustmentFormat = "com.photodefrigifier.rotate"
let rotationAdjustmentVersion = "1"

struct AlbumNode: Identifiable, Hashable {
  let id: String
  let title: String
  let isFolder: Bool
  let count: Int?
  let path: String
  var children: [AlbumNode]?
}


enum PhotoLibraryError: LocalizedError {
  case notFound
  case rotateUnsupported(String)
  case noEditingInput
  case renderFailed
  case noResource
  case keywordFailed(String)
  case photosScriptFailed(String)
  case hiddenNotReachable
  case albumNotEditable

  var errorDescription: String? {
    switch self {
    case .notFound: "That photo is no longer in the library."
    case .rotateUnsupported(let what): "Rotating \(what) isn't supported yet. Rotate it in Photos with ⌘R."
    case .noEditingInput: "Photos couldn't provide the image for editing."
    case .renderFailed: "The rotated image couldn't be written."
    case .noResource: "No original file was found for this item."
    case .keywordFailed(let why): "Photos didn't set the keyword. \(why)"
    case .photosScriptFailed(let why): "Photos couldn't do that. \(why)"
    case .albumNotEditable: "That album can't be changed from here (shared or smart albums are read-only)."
    case .hiddenNotReachable:
      "This photo is hidden and Photos keeps the Hidden album locked to other apps. Unhide it in Photos › Hidden."
    }
  }
}

/// All PhotoKit access lives here, on the main actor.
@MainActor
@Observable
final class PhotoLibrary: NSObject {
  enum Access: Equatable { case unknown, granted, limited, denied }

  /// Folder in Photos holding the albums that mirror the app's markers.
  static let mirrorFolderTitle = "Quick Fix"

  private(set) var access: Access = .unknown
  private(set) var summaries: [AssetSummary] = []
  private(set) var summaryByID: [String: AssetSummary] = [:]
  private(set) var albums: [AlbumNode] = []
  private(set) var albumPaths: [String: String] = [:]
  /// Albums a photo can be added to (editable, not the app's own Quick Fix markers), A–Z.
  private(set) var pickableAlbums: [AlbumRef] = []
  private(set) var albumByID: [String: AlbumRef] = [:]
  /// Folders, for choosing where a new album goes.
  private(set) var folderRefs: [AlbumRef] = []
  /// Album id → the folder that holds it.
  private(set) var albumParent: [String: String] = [:]
  private(set) var isLoading = false
  /// Bumped when an item's pixels changed (a rotation), so views reload its image.
  private(set) var imageRevision: [String: Int] = [:]
  /// Bumped after every library change; views that cache album membership watch it.
  private(set) var changeCount = 0

  @ObservationIgnored private var fetchResult: PHFetchResult<PHAsset>?
  @ObservationIgnored private var assetCache: [String: PHAsset] = [:]
  @ObservationIgnored private var filenameCache: [String: String] = [:]
  @ObservationIgnored private let imageManager = PHCachingImageManager()
  @ObservationIgnored private var observing = false
  @ObservationIgnored private var albumReloadTask: Task<Void, Never>?
  @ObservationIgnored private var mirrorAlbumIDs: [String: String] = [:]

  static let fullImageSize = CGSize(width: 2400, height: 2400)

  // MARK: Access and loading

  func start() async {
    var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if status == .notDetermined {
      status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }
    switch status {
    case .authorized: access = .granted
    case .limited: access = .limited
    default: access = .denied
    }
    guard access == .granted else { return }
    if !observing {
      PHPhotoLibrary.shared().register(self)
      observing = true
    }
    await reload()
  }

  func reload() async {
    isLoading = true
    let options = Self.visibleOnly()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    let result = PHAsset.fetchAssets(with: options)
    fetchResult = result
    let boxed = Unchecked(value: result)
    let list = await Task.detached(priority: .userInitiated) {
      let r = boxed.value
      var out: [AssetSummary] = []
      out.reserveCapacity(r.count)
      for i in 0..<r.count { out.append(Self.summary(of: r.object(at: i))) }
      return out
    }.value
    summaries = list
    summaryByID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    assetCache.removeAll()
    reloadAlbums()
    isLoading = false
  }

  /// Fetch options for everything the app shows: hidden photos (Photos' Hidden album) are always left out,
  /// so they never appear in a queue, an album, the counts, or the delete and records reviews.
  nonisolated static func visibleOnly() -> PHFetchOptions {
    let options = PHFetchOptions()
    options.includeHiddenAssets = false
    return options
  }

  /// How many items are in Photos' Hidden album (for the self-check only).
  func hiddenCount() -> (count: Int, shown: Int) {
    let options = PHFetchOptions()
    options.includeHiddenAssets = true
    let all = PHAsset.fetchAssets(with: options)
    let ids = (0..<all.count).map { all.object(at: $0) }.filter(\.isHidden).map(\.localIdentifier)
    return (ids.count, ids.filter { summaryByID[$0] != nil }.count)
  }

  nonisolated static func summary(of a: PHAsset) -> AssetSummary {
    let kind: AssetSummary.Kind =
      switch a.mediaType {
      case .video: .video
      case .image: a.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo
      default: .other
      }
    return AssetSummary(
      id: a.localIdentifier, creationDate: a.creationDate, kind: kind,
      isScreenshot: a.mediaSubtypes.contains(.photoScreenshot), pixelWidth: a.pixelWidth,
      pixelHeight: a.pixelHeight, duration: a.duration, isFavorite: a.isFavorite, hasLocation: a.location != nil,
      hasAdjustments: a.hasAdjustments)
  }

  func asset(_ id: String) -> PHAsset? {
    if let a = assetCache[id] { return a }
    let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    if let a { assetCache[id] = a }
    return a
  }

  func filename(_ id: String) -> String? {
    if let name = filenameCache[id] { return name }
    guard let a = asset(id) else { return nil }
    let resources = PHAssetResource.assetResources(for: a)
    let primary =
      resources.first { [.photo, .video].contains($0.type) } ?? resources.first
    let name = primary?.originalFilename
    if let name { filenameCache[id] = name }
    return name
  }

  // MARK: Albums

  func reloadAlbums() {
    var paths: [String: String] = [:]
    var pickable: [AlbumRef] = []
    var folders: [AlbumRef] = []
    var parents: [String: String] = [:]
    func walk(_ fetch: PHFetchResult<PHCollection>, prefix: String, parent: String?) -> [AlbumNode] {
      var nodes: [AlbumNode] = []
      for i in 0..<fetch.count {
        let c = fetch.object(at: i)
        let title = c.localizedTitle ?? "Untitled"
        let path = prefix.isEmpty ? title : "\(prefix) › \(title)"
        if let list = c as? PHCollectionList {
          if !AlbumRules.isMarker(path) { folders.append(AlbumRef(id: c.localIdentifier, title: title, path: path)) }
          let kids = walk(PHCollection.fetchCollections(in: list, options: nil), prefix: path, parent: c.localIdentifier)
          nodes.append(
            AlbumNode(id: c.localIdentifier, title: title, isFolder: true, count: nil, path: path,
                      children: kids.isEmpty ? nil : kids))
        } else if let album = c as? PHAssetCollection {
          paths[c.localIdentifier] = path
          if let parent { parents[c.localIdentifier] = parent }
          if album.canPerform(.addContent), !AlbumRules.isMarker(path) {
            pickable.append(AlbumRef(id: c.localIdentifier, title: title, path: path))
          }
          nodes.append(
            AlbumNode(id: c.localIdentifier, title: title, isFolder: false,
                      count: PHAsset.fetchAssets(in: album, options: Self.visibleOnly()).count, path: path, children: nil))
        }
      }
      return nodes
    }
    albums = walk(PHCollectionList.fetchTopLevelUserCollections(with: nil), prefix: "", parent: nil)
    albumPaths = paths
    pickableAlbums = pickable.sorted(by: AlbumRules.byTitle)
    albumByID = Dictionary(pickable.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    folderRefs = folders.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    albumParent = parents
  }

  /// Albums that hold other photos taken the same day as this one, most shared first (bookkeeping albums left
  /// out). Undated photos have no "same day".
  func sameDayAlbums(as id: String, sampleLimit: Int = 60) -> [AlbumRef] {
    guard let s = summaryByID[id], let date = s.creationDate, !s.isUndated else { return [] }
    let calendar = Calendar.current
    let others = summaries.lazy
      .filter { $0.id != id && $0.creationDate.map { calendar.isDate($0, inSameDayAs: date) } == true }
      .prefix(sampleLimit)
    var tally: [String: (album: AlbumRef, count: Int)] = [:]
    for other in others {
      for album in albums(containing: other.id) where albumByID[album.id] != nil && !AlbumRules.isBookkeeping(album.path) {
        tally[album.id, default: (album, 0)].count += 1
      }
    }
    return tally.values.sorted { $0.count > $1.count }.map(\.album)
  }

  /// Adds the photo to an album, or removes it.
  func setAlbum(_ assetID: String, albumID: String, member: Bool) async throws {
    let changed = Box<Bool>()
    try await PHPhotoLibrary.shared().performChanges { @Sendable in
      guard
        let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject,
        let request = PHAssetCollectionChangeRequest(for: album)
      else { return }
      if member { request.addAssets([asset] as NSArray) } else { request.removeAssets([asset] as NSArray) }
      changed.value = true
    }
    if changed.value != true { throw PhotoLibraryError.albumNotEditable }
  }

  /// Makes a new album (in `folderID`, or at the top level) with the photo already in it. Returns the album id.
  func createAlbum(title: String, folderID: String?, adding assetID: String) async throws -> String {
    let created = Box<String>()
    try await PHPhotoLibrary.shared().performChanges { @Sendable in
      let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
      if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject {
        request.addAssets([asset] as NSArray)
      }
      let placeholder = request.placeholderForCreatedAssetCollection
      created.value = placeholder.localIdentifier
      if let folderID,
        let folder = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [folderID], options: nil).firstObject
      {
        PHCollectionListChangeRequest(for: folder)?.addChildCollections([placeholder] as NSArray)
      }
    }
    guard let id = created.value else { throw PhotoLibraryError.albumNotEditable }
    reloadAlbums()
    return id
  }

  /// Every photo in an album, or in all albums inside a folder.
  func memberIDs(of collectionID: String) -> [String] {
    if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [collectionID], options: nil)
      .firstObject
    {
      let r = PHAsset.fetchAssets(in: album, options: Self.visibleOnly())
      return (0..<r.count).map { r.object(at: $0).localIdentifier }
    }
    if let folder = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [collectionID], options: nil)
      .firstObject
    {
      var seen = Set<String>()
      var out: [String] = []
      let kids = PHCollection.fetchCollections(in: folder, options: nil)
      for i in 0..<kids.count {
        for id in memberIDs(of: kids.object(at: i).localIdentifier) where seen.insert(id).inserted {
          out.append(id)
        }
      }
      return out
    }
    return []
  }

  func albums(containing id: String) -> [AlbumRef] {
    guard let a = asset(id) else { return [] }
    let r = PHAssetCollection.fetchAssetCollectionsContaining(a, with: .album, options: nil)
    return (0..<r.count).map {
      let c = r.object(at: $0)
      let title = c.localizedTitle ?? "Untitled"
      return AlbumRef(id: c.localIdentifier, title: title, path: albumPaths[c.localIdentifier] ?? title)
    }
    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  // MARK: Clipboard and Photos

  /// The photo at full size: the current version (edits included), upright. Used for copying.
  func fullImage(for id: String) async -> NSImage? {
    guard let a = asset(id) else { return nil }
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .none
    options.isNetworkAccessAllowed = true
    options.version = .current
    let result: Unchecked<NSImage?> = await withCheckedContinuation { cont in
      let once = Box<Bool>()
      PHImageManager.default().requestImage(
        for: a, targetSize: PHImageManagerMaximumSize, contentMode: .default, options: options
      ) { @Sendable image, info in
        if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
        if once.value == true { return }
        once.value = true
        cont.resume(returning: Unchecked(value: image))
      }
    }
    return result.value
  }

  /// Saves the item's file into a fresh temporary folder (for copying a video as a file). Returns the file.
  func exportForClipboard(_ id: String) async throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoDeFrigifier-clipboard", isDirectory: true)
    try? FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return try await exportOriginal(id, to: folder)
  }

  /// Brings Photos forward showing this item.
  func showInPhotos(_ id: String) async throws {
    _ = try await Self.runPhotosScript(Self.spotlightScript, arguments: [id])
  }

  private static let spotlightScript = [
    "on run argv",
    "  tell application \"Photos\"",
    "    activate",
    "    spotlight media item id (item 1 of argv)",
    "  end tell",
    "  return \"\"",
    "end run",
  ]

  // MARK: Images

  func image(for id: String, size: CGSize, fast: Bool) async -> NSImage? {
    guard let a = asset(id) else { return nil }
    let options = PHImageRequestOptions()
    options.deliveryMode = fast ? .fastFormat : .highQualityFormat
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = true
    options.version = .current
    let result: Unchecked<NSImage?> = await withCheckedContinuation { cont in
      let once = Box<Bool>()
      imageManager.requestImage(for: a, targetSize: size, contentMode: .aspectFit, options: options) {
        @Sendable image, info in
        if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
        if once.value == true { return }
        once.value = true
        cont.resume(returning: Unchecked(value: image))
      }
    }
    return result.value
  }

  func prefetch(_ ids: [String]) {
    let assets = ids.compactMap { asset($0) }.filter { $0.mediaType == .image }
    guard !assets.isEmpty else { return }
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = true
    imageManager.startCachingImages(
      for: assets, targetSize: Self.fullImageSize, contentMode: .aspectFit, options: options)
  }

  func playerItem(for id: String) async -> AVPlayerItem? {
    guard let a = asset(id), a.mediaType == .video else { return nil }
    let options = PHVideoRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .automatic
    let result: Unchecked<AVPlayerItem?> = await withCheckedContinuation { cont in
      PHImageManager.default().requestPlayerItem(forVideo: a, options: options) { @Sendable item, _ in
        cont.resume(returning: Unchecked(value: item))
      }
    }
    return result.value
  }

  // MARK: Changes

  func setFavorite(_ id: String, _ on: Bool) async throws {
    try await PHPhotoLibrary.shared().performChanges { @Sendable in
      guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
      PHAssetChangeRequest(for: a).isFavorite = on
    }
  }

  func setDate(_ id: String, _ date: Date) async throws {
    try await PHPhotoLibrary.shared().performChanges { @Sendable in
      guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
      PHAssetChangeRequest(for: a).creationDate = date
    }
  }

  /// Moves items to Recently Deleted. macOS shows its own confirmation first; cancelling throws.
  func delete(_ ids: [String]) async throws {
    try await PHPhotoLibrary.shared().performChanges { @Sendable in
      let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
      PHAssetChangeRequest.deleteAssets(assets)
    }
  }

  /// Rotates a still photo by quarter turns (positive = clockwise) as a normal Photos edit,
  /// so "Revert to Original" in Photos still works. Repeated rotations start from the original.
  func rotate(_ id: String, quarterTurns: Int) async throws {
    guard let a = asset(id) else { throw PhotoLibraryError.notFound }
    guard a.mediaType == .image else { throw PhotoLibraryError.rotateUnsupported("videos") }
    if a.mediaSubtypes.contains(.photoLive) { throw PhotoLibraryError.rotateUnsupported("Live Photos") }

    let editing = try await contentEditingInput(for: a)
    var previous = 0
    if let adj = editing.adjustmentData, adj.formatIdentifier == rotationAdjustmentFormat,
      let text = String(data: adj.data, encoding: .utf8), let degrees = Int(text)
    {
      previous = degrees
    }
    let total = ((previous + quarterTurns * 90) % 360 + 360) % 360

    if total == 0 && previous != 0 {
      // Back to how it was: drop our edit rather than saving a 0° render.
      try await PHPhotoLibrary.shared().performChanges { @Sendable in
        guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
        PHAssetChangeRequest(for: a).revertAssetContentToOriginal()
      }
    } else {
      guard let source = editing.fullSizeImageURL else { throw PhotoLibraryError.noEditingInput }
      let orientation = editing.fullSizeImageOrientation
      let output = PHContentEditingOutput(contentEditingInput: editing)
      output.adjustmentData = PHAdjustmentData(
        formatIdentifier: rotationAdjustmentFormat, formatVersion: rotationAdjustmentVersion,
        data: Data(String(total).utf8))
      let type: UTType =
        output.supportedRenderedContentTypes.contains(.jpeg) ? .jpeg : (output.defaultRenderedContentType ?? .jpeg)
      let destination = try output.renderedContentURL(for: type)
      try await Task.detached(priority: .userInitiated) {
        try renderRotated(source: source, orientation: orientation, degreesClockwise: total, to: destination, type: type)
      }.value
      let boxed = Unchecked(value: output)
      try await PHPhotoLibrary.shared().performChanges { @Sendable in
        guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
        PHAssetChangeRequest(for: a).contentEditingOutput = boxed.value
      }
    }
    assetCache[id] = nil
    imageRevision[id, default: 0] += 1
  }

  /// Asks Photos for an editable copy (read-only until an output is saved). If our own rotation is already
  /// applied, Photos hands back the original plus our adjustment data instead of the rendered edit.
  func contentEditingInput(for a: PHAsset) async throws -> PHContentEditingInput {
    let options = PHContentEditingInputRequestOptions()
    options.isNetworkAccessAllowed = true
    options.canHandleAdjustmentData = { @Sendable (adjustment: PHAdjustmentData) -> Bool in
      adjustment.formatIdentifier == rotationAdjustmentFormat && adjustment.formatVersion == rotationAdjustmentVersion
    }
    let input: Unchecked<PHContentEditingInput> = try await withCheckedThrowingContinuation { cont in
      a.requestContentEditingInput(with: options) { @Sendable input, info in
        if let input {
          cont.resume(returning: Unchecked(value: input))
        } else {
          cont.resume(throwing: (info[PHContentEditingInputErrorKey] as? Error) ?? PhotoLibraryError.noEditingInput)
        }
      }
    }
    return input.value
  }

  /// Runs an empty change block. Changes nothing; the self-check uses it to prove change blocks run safely
  /// on Photos' own queue.
  func emptyChange() async throws {
    try await PHPhotoLibrary.shared().performChanges { @Sendable in }
  }

  // MARK: Keywords (AppleScript) and hiding

  /// The keyword that marks a photo as safely archived. It travels with the photo (Info panel, search, exports).
  static let archiveKeyword = "Archived"

  /// PhotoKit can't touch keywords, so this asks Photos itself through AppleScript (`osascript`, run off the main
  /// thread with a timeout). The first use asks for permission to control Photos. Returns the photo's keywords
  /// afterwards, as Photos reports them.
  func setKeyword(_ id: String, _ keyword: String, add: Bool) async throws -> [String] {
    try await Self.runPhotosScript(Self.keywordScript, arguments: [id, keyword, add ? "add" : "remove"])
  }

  /// Read-only: the photo's keywords as Photos reports them.
  func keywords(_ id: String) async throws -> [String] {
    try await Self.runPhotosScript(Self.keywordScript, arguments: [id, "", "read"])
  }

  private static let keywordScript = [
    "on run argv",
    "  set theID to item 1 of argv",
    "  set theKeyword to item 2 of argv",
    "  set mode to item 3 of argv",
    "  tell application \"Photos\"",
    "    set theItem to media item id theID",
    "    set kw to keywords of theItem",
    "    if kw is missing value then set kw to {}",
    "    if mode is \"add\" then",
    "      if kw does not contain theKeyword then set keywords of theItem to (kw & {theKeyword})",
    "    else if mode is \"remove\" then",
    "      set kept to {}",
    "      repeat with k in kw",
    "        if (contents of k) is not theKeyword then set end of kept to (contents of k)",
    "      end repeat",
    "      set keywords of theItem to kept",
    "    end if",
    "    set out to keywords of theItem",
    "  end tell",
    "  if out is missing value then return \"\"",
    "  set AppleScript's text item delimiters to linefeed",
    "  return out as text",
    "end run",
  ]

  nonisolated private static func runPhotosScript(_ lines: [String], arguments: [String]) async throws -> [String] {
    try await Task.detached(priority: .userInitiated) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = lines.flatMap { ["-e", $0] } + arguments
      let out = Pipe()
      let err = Pipe()
      process.standardOutput = out
      process.standardError = err
      try process.run()
      let deadline = Date().addingTimeInterval(45)
      while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
      if process.isRunning {
        process.terminate()
        throw PhotoLibraryError.photosScriptFailed("Photos didn't answer within 45 seconds. Is it stuck?")
      }
      let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      guard process.terminationStatus == 0 else {
        let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let reason =
          message.contains("-1743") || message.contains("Not authorized")
          ? "Allow PhotoDeFrigifier to control Photos in System Settings › Privacy & Security › Automation."
          : message.trimmingCharacters(in: .whitespacesAndNewlines)
        throw PhotoLibraryError.photosScriptFailed(reason)
      }
      return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }.value
  }

  /// Hides or unhides photos in ONE request, so macOS asks once for the whole batch. Unhiding can fail when
  /// Photos keeps the Hidden album locked to other apps. Returns how many were found and changed.
  @discardableResult
  func setHidden(_ ids: [String], _ hidden: Bool) async throws -> Int {
    let found = Box<Int>()
    try await PHPhotoLibrary.shared().performChanges { @Sendable in
      let options = PHFetchOptions()
      options.includeHiddenAssets = true
      let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
      found.value = assets.count
      for i in 0..<assets.count { PHAssetChangeRequest(for: assets.object(at: i)).isHidden = hidden }
    }
    if (found.value ?? 0) == 0 { throw PhotoLibraryError.hiddenNotReachable }
    return found.value ?? 0
  }

  /// Saves the current version of the original (the edited render if there is one) into `folder`.
  /// Never overwrites: a clash gets " (2)", " (3)" … Returns the written file after checking it isn't empty.
  func exportOriginal(_ id: String, to folder: URL) async throws -> URL {
    guard let a = asset(id) else { throw PhotoLibraryError.notFound }
    let resources = PHAssetResource.assetResources(for: a)
    let original = resources.first { [.photo, .video].contains($0.type) } ?? resources.first
    let current = resources.first { [.fullSizePhoto, .fullSizeVideo].contains($0.type) } ?? original
    guard let original, let current else { throw PhotoLibraryError.noResource }
    let base = (original.originalFilename as NSString).deletingPathExtension
    let ext = (current.originalFilename as NSString).pathExtension
    var destination = folder.appendingPathComponent(base).appendingPathExtension(ext)
    var n = 2
    while FileManager.default.fileExists(atPath: destination.path) {
      destination = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
      n += 1
    }
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    let target = destination
    let resource = Unchecked(value: current)
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      PHAssetResourceManager.default().writeData(for: resource.value, toFile: target, options: options) { @Sendable error in
        if let error { cont.resume(throwing: error) } else { cont.resume() }
      }
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.intValue ?? 0
    guard size > 0 else {
      try? FileManager.default.removeItem(at: target)
      throw PhotoLibraryError.noResource
    }
    return target
  }

  // MARK: Marker albums ("Quick Fix" folder)

  /// Adds or removes the photo from the marker album with this title, creating the folder and album if needed.
  func setMirror(_ id: String, label: String, on: Bool) async throws {
    let albumID = try await mirrorAlbum(named: label, create: on)
    guard let albumID else { return }
    try await PHPhotoLibrary.shared().performChanges { @Sendable in
      guard
        let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
        let request = PHAssetCollectionChangeRequest(for: album)
      else { return }
      if on { request.addAssets([asset] as NSArray) } else { request.removeAssets([asset] as NSArray) }
    }
  }

  private func mirrorAlbum(named title: String, create: Bool) async throws -> String? {
    if let id = mirrorAlbumIDs[title],
      PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject != nil
    {
      return id
    }
    let folder = try await mirrorFolder(create: create)
    guard let folder else { return nil }
    let kids = PHCollection.fetchCollections(in: folder, options: nil)
    for i in 0..<kids.count where kids.object(at: i).localizedTitle == title && kids.object(at: i) is PHAssetCollection {
      mirrorAlbumIDs[title] = kids.object(at: i).localIdentifier
      return kids.object(at: i).localIdentifier
    }
    guard create else { return nil }
    let folderID = folder.localIdentifier
    let created = Box<String>()
    try await PHPhotoLibrary.shared().performChanges { @Sendable in
      let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
      let placeholder = request.placeholderForCreatedAssetCollection
      created.value = placeholder.localIdentifier
      if let folder = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [folderID], options: nil).firstObject {
        PHCollectionListChangeRequest(for: folder)?.addChildCollections([placeholder] as NSArray)
      }
    }
    mirrorAlbumIDs[title] = created.value
    return created.value
  }

  private func mirrorFolder(create: Bool) async throws -> PHCollectionList? {
    let top = PHCollectionList.fetchTopLevelUserCollections(with: nil)
    for i in 0..<top.count {
      if let list = top.object(at: i) as? PHCollectionList, list.localizedTitle == Self.mirrorFolderTitle {
        return list
      }
    }
    guard create else { return nil }
    let created = Box<String>()
    let title = Self.mirrorFolderTitle
    try await PHPhotoLibrary.shared().performChanges { @Sendable in
      created.value =
        PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: title)
        .placeholderForCreatedCollectionList.localIdentifier
    }
    guard let id = created.value else { return nil }
    return PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [id], options: nil).firstObject
  }

  // MARK: Change tracking

  fileprivate func apply(_ change: PHChange) {
    changeCount += 1
    assetCache.removeAll()
    if let fetchResult, let details = change.changeDetails(for: fetchResult) {
      self.fetchResult = details.fetchResultAfterChanges
      if details.hasIncrementalChanges {
        let removed = Set(details.removedObjects.map(\.localIdentifier))
        if !removed.isEmpty {
          summaries.removeAll { removed.contains($0.id) }
          for id in removed { summaryByID[id] = nil }
        }
        for a in details.changedObjects {
          let s = Self.summary(of: a)
          summaryByID[s.id] = s
          if let i = summaries.firstIndex(where: { $0.id == s.id }) { summaries[i] = s }
        }
        for a in details.insertedObjects {
          let s = Self.summary(of: a)
          summaryByID[s.id] = s
          summaries.append(s)
        }
      } else {
        Task { await reload() }
        return
      }
    }
    albumReloadTask?.cancel()
    albumReloadTask = Task {
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      reloadAlbums()
    }
  }
}

extension PhotoLibrary: PHPhotoLibraryChangeObserver {
  nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
    let boxed = Unchecked(value: changeInstance)
    Task { @MainActor in self.apply(boxed.value) }
  }
}

/// Draws `source` upright (using its EXIF orientation), turns it, and writes JPEG or HEIC to `destination`.
func renderRotated(source: URL, orientation: Int32, degreesClockwise: Int, to destination: URL, type: UTType) throws {
  guard var image = CIImage(contentsOf: source) else { throw PhotoLibraryError.renderFailed }
  if let o = CGImagePropertyOrientation(rawValue: UInt32(orientation)) { image = image.oriented(o) }
  let turn: CGImagePropertyOrientation =
    switch degreesClockwise {
    case 90: .right
    case 180: .down
    case 270: .left
    default: .up
    }
  image = image.oriented(turn)
  let context = CIContext()
  let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
  if type == .heic {
    try context.writeHEIFRepresentation(of: image, to: destination, format: .RGBA8, colorSpace: space)
  } else {
    try context.writeJPEGRepresentation(
      of: image, to: destination, colorSpace: space,
      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
  }
}
