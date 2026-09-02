import AppKit
import CoreGraphics
import Foundation
import Photos

public enum ApplePhotosThumbnailError: Error, Equatable, LocalizedError {
  case assetNotFound
  case cancelled
  case requiresNetwork
  case unavailable

  public var errorDescription: String? {
    switch self {
    case .assetNotFound: "The Apple Photos item is no longer available."
    case .cancelled: "The Apple Photos preview request was cancelled."
    case .requiresNetwork: "This Apple Photos preview requires an iCloud download."
    case .unavailable: "Apple Photos could not provide a preview."
    }
  }
}

public struct ApplePhotosThumbnailProvider: Sendable {
  public init() {}

  public func thumbnail(
    localIdentifier: String,
    targetPixelSize: CGSize
  ) async throws -> CGImage {
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
    guard let asset = assets.firstObject else { throw ApplePhotosThumbnailError.assetNotFound }
    let state = PhotoThumbnailRequestState(manager: PHImageManager.default())

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        state.install(continuation)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.version = .current
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        let requestID = PHImageManager.default().requestImage(
          for: asset,
          targetSize: targetPixelSize,
          contentMode: .aspectFit,
          options: options
        ) { image, information in
          if information?[PHImageCancelledKey] as? Bool == true {
            state.finish(.failure(ApplePhotosThumbnailError.cancelled))
            return
          }
          if information?[PHImageErrorKey] as? Error != nil {
            state.finish(.failure(ApplePhotosThumbnailError.unavailable))
            return
          }
          if information?[PHImageResultIsDegradedKey] as? Bool == true { return }
          guard let image else {
            let requiresNetwork = information?[PHImageResultIsInCloudKey] as? Bool == true
            state.finish(
              .failure(
                requiresNetwork
                  ? ApplePhotosThumbnailError.requiresNetwork
                  : ApplePhotosThumbnailError.unavailable
              ))
            return
          }
          var proposedRect = CGRect(origin: .zero, size: image.size)
          guard
            let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
          else {
            state.finish(.failure(ApplePhotosThumbnailError.unavailable))
            return
          }
          state.finish(.success(cgImage))
        }
        state.setRequestID(requestID)
      }
    } onCancel: {
      state.cancel()
    }
  }
}

private final class PhotoThumbnailRequestState: @unchecked Sendable {
  private let lock = NSLock()
  private let manager: PHImageManager
  private var continuation: CheckedContinuation<CGImage, Error>?
  private var requestID: PHImageRequestID?
  private var isFinished = false
  private var isCancelled = false

  init(manager: PHImageManager) {
    self.manager = manager
  }

  func install(_ continuation: CheckedContinuation<CGImage, Error>) {
    lock.lock()
    if isCancelled {
      isFinished = true
      lock.unlock()
      continuation.resume(throwing: ApplePhotosThumbnailError.cancelled)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func setRequestID(_ requestID: PHImageRequestID) {
    lock.lock()
    self.requestID = requestID
    let shouldCancel = isCancelled
    lock.unlock()
    if shouldCancel { manager.cancelImageRequest(requestID) }
  }

  func cancel() {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }
    isCancelled = true
    let requestID = requestID
    let continuation = continuation
    self.continuation = nil
    isFinished = continuation != nil
    lock.unlock()
    if let requestID { manager.cancelImageRequest(requestID) }
    continuation?.resume(throwing: ApplePhotosThumbnailError.cancelled)
  }

  func finish(_ result: Result<CGImage, Error>) {
    lock.lock()
    guard !isFinished, let continuation else {
      lock.unlock()
      return
    }
    isFinished = true
    self.continuation = nil
    lock.unlock()
    continuation.resume(with: result)
  }
}
