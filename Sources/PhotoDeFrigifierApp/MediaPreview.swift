import AVFoundation
import ApplePhotosAdapter
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PhotoCatalogCore
import SwiftUI

enum MediaPreviewError: Error, LocalizedError {
  case invalidSource
  case sourceChanged
  case unsupported

  var errorDescription: String? {
    switch self {
    case .invalidSource: "The source file is no longer safely accessible."
    case .sourceChanged: "The source file changed after it was cataloged. Rescan before review."
    case .unsupported: "A preview is not available for this media."
    }
  }
}

private final class PreviewLoadAwaiter: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<CGImage, Error>?
  private var result: Result<CGImage, Error>?

  func install(_ continuation: CheckedContinuation<CGImage, Error>) {
    lock.lock()
    if let result {
      lock.unlock()
      continuation.resume(with: result)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func finish(_ result: Result<CGImage, Error>) {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }

  func cancel() {
    finish(.failure(CancellationError()))
  }
}

actor MediaPreviewStore {
  private struct LoadWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  private var images: [String: CGImage] = [:]
  private var imageCosts: [String: Int] = [:]
  private var cacheOrder: [String] = []
  private var cacheCost = 0
  private var cacheGeneration = 0
  private var inFlight: [String: Task<CGImage, Error>] = [:]
  private var inFlightConsumers: [String: Set<UUID>] = [:]
  private var activeLoadCount = 0
  private var loadWaiters: [LoadWaiter] = []
  private let maximumCacheCost = 64 * 1_024 * 1_024
  private let maximumConcurrentLoads = 4

  func thumbnail(
    for reference: CatalogPreviewReference,
    maximumPixelSize: Int
  ) async throws -> CGImage {
    let cacheKey = "\(reference.cacheKey)|\(maximumPixelSize)"
    if let cached = images[cacheKey] {
      cacheOrder.removeAll { $0 == cacheKey }
      cacheOrder.append(cacheKey)
      return cached
    }
    try Task.checkCancellation()
    let generation = cacheGeneration
    let inFlightKey = "\(generation)|\(cacheKey)"
    let loadTask: Task<CGImage, Error>
    if let existingLoad = inFlight[inFlightKey] {
      loadTask = existingLoad
    } else {
      try await acquireLoadSlot()
      if let existingLoad = inFlight[inFlightKey] {
        releaseLoadSlot()
        loadTask = existingLoad
      } else {
        let newLoad = Task {
          try await Self.loadThumbnail(
            reference: reference,
            maximumPixelSize: maximumPixelSize
          )
        }
        inFlight[inFlightKey] = newLoad
        loadTask = newLoad
        Task { [weak self] in
          _ = await newLoad.result
          await self?.completeLoad(inFlightKey)
        }
      }
    }
    let consumerID = UUID()
    inFlightConsumers[inFlightKey, default: []].insert(consumerID)
    let image: CGImage
    do {
      image = try await withTaskCancellationHandler {
        try await Self.awaitLoad(loadTask)
      } onCancel: {
        Task { await self.cancelLoadConsumer(consumerID, inFlightKey: inFlightKey) }
      }
      finishLoadConsumer(consumerID, inFlightKey: inFlightKey)
    } catch is CancellationError {
      cancelLoadConsumer(consumerID, inFlightKey: inFlightKey)
      throw CancellationError()
    } catch {
      finishLoadConsumer(consumerID, inFlightKey: inFlightKey)
      throw error
    }
    try Task.checkCancellation()
    if let cached = images[cacheKey] { return cached }
    guard generation == cacheGeneration else { return image }
    let cost = image.bytesPerRow * image.height
    images[cacheKey] = image
    imageCosts[cacheKey] = cost
    cacheCost += cost
    cacheOrder.append(cacheKey)
    while cacheCost > maximumCacheCost, cacheOrder.count > 1 {
      let evicted = cacheOrder.removeFirst()
      images.removeValue(forKey: evicted)
      cacheCost -= imageCosts.removeValue(forKey: evicted) ?? 0
    }
    return image
  }

  func removeAll() {
    images.removeAll()
    imageCosts.removeAll()
    cacheOrder.removeAll()
    cacheCost = 0
    cacheGeneration += 1
    for load in inFlight.values { load.cancel() }
    let waiters = loadWaiters
    loadWaiters.removeAll()
    for waiter in waiters { waiter.continuation.resume(returning: false) }
  }

  private func acquireLoadSlot() async throws {
    if activeLoadCount < maximumConcurrentLoads {
      activeLoadCount += 1
      return
    }
    let waiterID = UUID()
    let acquired = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        loadWaiters.append(LoadWaiter(id: waiterID, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelLoadWaiter(waiterID) }
    }
    guard acquired else { throw CancellationError() }
    if Task.isCancelled {
      releaseLoadSlot()
      throw CancellationError()
    }
  }

  private func cancelLoadWaiter(_ id: UUID) {
    guard let index = loadWaiters.firstIndex(where: { $0.id == id }) else { return }
    loadWaiters.remove(at: index).continuation.resume(returning: false)
  }

  private func cancelLoadConsumer(_ id: UUID, inFlightKey: String) {
    guard inFlightConsumers[inFlightKey]?.remove(id) != nil else { return }
    if inFlightConsumers[inFlightKey]?.isEmpty == true {
      inFlightConsumers.removeValue(forKey: inFlightKey)
      inFlight[inFlightKey]?.cancel()
    }
  }

  private func finishLoadConsumer(_ id: UUID, inFlightKey: String) {
    guard inFlightConsumers[inFlightKey]?.remove(id) != nil else { return }
    if inFlightConsumers[inFlightKey]?.isEmpty == true {
      inFlightConsumers.removeValue(forKey: inFlightKey)
    }
  }

  private func completeLoad(_ inFlightKey: String) {
    inFlight.removeValue(forKey: inFlightKey)
    releaseLoadSlot()
  }

  private func releaseLoadSlot() {
    if loadWaiters.isEmpty {
      activeLoadCount -= 1
    } else {
      loadWaiters.removeFirst().continuation.resume(returning: true)
    }
  }

  private static func loadThumbnail(
    reference: CatalogPreviewReference,
    maximumPixelSize: Int
  ) async throws -> CGImage {
    switch reference.location {
    case .applePhotos(let localIdentifier):
      do {
        return try await ApplePhotosThumbnailProvider().thumbnail(
          localIdentifier: localIdentifier,
          targetPixelSize: CGSize(width: maximumPixelSize, height: maximumPixelSize)
        )
      } catch ApplePhotosThumbnailError.cancelled {
        throw CancellationError()
      }
    case .filesystem(
      let bookmarkData,
      let relativePath,
      let expectedByteCount,
      let expectedSHA256
    ):
      return try await withResolvedFileDescriptor(
        bookmarkData: bookmarkData,
        relativePath: relativePath,
        expectedByteCount: expectedByteCount,
        expectedSHA256: expectedSHA256
      ) { fileURL in
        switch reference.kind {
        case .photo, .unknown:
          return try imageThumbnail(fileURL: fileURL, maximumPixelSize: maximumPixelSize)
        case .video:
          return try await videoThumbnail(
            fileURL: fileURL,
            maximumPixelSize: maximumPixelSize
          )
        case .audio:
          throw MediaPreviewError.unsupported
        }
      }
    }
  }

  private static func awaitLoad(_ loadTask: Task<CGImage, Error>) async throws -> CGImage {
    let awaiter = PreviewLoadAwaiter()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        awaiter.install(continuation)
        Task {
          awaiter.finish(await loadTask.result)
        }
      }
    } onCancel: {
      awaiter.cancel()
    }
  }

  private static func withResolvedFileDescriptor<Result: Sendable>(
    bookmarkData: Data,
    relativePath: String,
    expectedByteCount: Int64?,
    expectedSHA256: String,
    body: (URL) async throws -> Result
  ) async throws -> Result {
    guard Self.isSafeRelativePath(relativePath) else { throw MediaPreviewError.invalidSource }
    var isStale = false
    let root = try URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    guard !isStale else { throw MediaPreviewError.invalidSource }
    let accessed = root.startAccessingSecurityScopedResource()
    defer { if accessed { root.stopAccessingSecurityScopedResource() } }

    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let rootDescriptor = open(
      canonicalRoot.path,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard rootDescriptor >= 0 else { throw MediaPreviewError.invalidSource }
    defer { close(rootDescriptor) }

    let components = relativePath.split(separator: "/").map(String.init)
    var parentDescriptor = rootDescriptor
    var ownedParentDescriptor: Int32?
    defer { if let ownedParentDescriptor { close(ownedParentDescriptor) } }
    for component in components.dropLast() {
      let nextDescriptor = component.withCString { componentPointer in
        openat(
          parentDescriptor,
          componentPointer,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
      }
      guard nextDescriptor >= 0 else { throw MediaPreviewError.invalidSource }
      if let ownedParentDescriptor { close(ownedParentDescriptor) }
      ownedParentDescriptor = nextDescriptor
      parentDescriptor = nextDescriptor
    }
    guard let filename = components.last else { throw MediaPreviewError.invalidSource }
    let fileDescriptor = filename.withCString { filenamePointer in
      openat(parentDescriptor, filenamePointer, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard fileDescriptor >= 0 else { throw MediaPreviewError.invalidSource }
    defer { close(fileDescriptor) }

    var before = stat()
    guard fstat(fileDescriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
      throw MediaPreviewError.invalidSource
    }
    if let expectedByteCount, before.st_size != expectedByteCount {
      throw MediaPreviewError.sourceChanged
    }
    if try await sha256(fileDescriptor: fileDescriptor) != expectedSHA256.lowercased() {
      throw MediaPreviewError.sourceChanged
    }
    guard lseek(fileDescriptor, 0, SEEK_SET) >= 0 else {
      throw MediaPreviewError.invalidSource
    }
    let result = try await body(URL(fileURLWithPath: "/dev/fd/\(fileDescriptor)"))
    var after = stat()
    guard fstat(fileDescriptor, &after) == 0 else { throw MediaPreviewError.invalidSource }
    guard
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
    else { throw MediaPreviewError.sourceChanged }
    return result
  }

  private static func sha256(fileDescriptor: Int32) async throws -> String {
    guard lseek(fileDescriptor, 0, SEEK_SET) >= 0 else {
      throw MediaPreviewError.invalidSource
    }
    let file = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
    var hasher = SHA256()
    while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
      try Task.checkCancellation()
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  private static func imageThumbnail(fileURL: URL, maximumPixelSize: Int) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
      throw MediaPreviewError.unsupported
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      throw MediaPreviewError.unsupported
    }
    return image
  }

  private static func videoThumbnail(fileURL: URL, maximumPixelSize: Int) async throws -> CGImage {
    let asset = AVURLAsset(
      url: fileURL,
      options: [
        AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
      ]
    )
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
    return try await generator.image(at: .zero).image
  }
}

struct MediaThumbnail: View {
  let reference: CatalogPreviewReference?
  let previewStore: MediaPreviewStore
  let maximumPixelSize: Int
  var label: String?

  @State private var image: CGImage?
  @State private var errorMessage: String?

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.primary.opacity(0.055))
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipShape(RoundedRectangle(cornerRadius: 12))
      } else if reference == nil {
        placeholder(icon: "icloud.slash", text: "Local media not downloaded")
      } else if let errorMessage {
        placeholder(icon: "photo.badge.exclamationmark", text: errorMessage)
      } else {
        ProgressView()
      }
      if let label {
        Text(label)
          .font(.system(size: 10, weight: .semibold, design: .monospaced))
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(.ultraThinMaterial, in: Capsule())
          .padding(8)
      }
    }
    .aspectRatio(4 / 3, contentMode: .fit)
    .task(id: reference?.cacheKey) {
      image = nil
      errorMessage = nil
      guard let reference else { return }
      do {
        let loadedImage = try await previewStore.thumbnail(
          for: reference,
          maximumPixelSize: maximumPixelSize
        )
        try Task.checkCancellation()
        guard self.reference?.cacheKey == reference.cacheKey else { return }
        image = loadedImage
      } catch is CancellationError {
        return
      } catch {
        guard self.reference?.cacheKey == reference.cacheKey else { return }
        errorMessage = error.localizedDescription
      }
    }
  }

  private func placeholder(icon: String, text: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 24, weight: .medium))
      Text(text)
        .font(.caption)
        .multilineTextAlignment(.center)
    }
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}
