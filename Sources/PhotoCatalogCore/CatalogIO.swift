import CryptoKit
import Darwin
import Foundation

enum CatalogIOError: Error, Equatable {
  case emptyLine(Int)
  case invalidDestination
  case lineTooLong(Int)
  case lockFailed
  case sourceChanged
}

enum CatalogStableID {
  static func make(prefix: String, components: [String]) -> String {
    var hasher = SHA256()
    for component in components {
      hasher.update(data: Data(component.utf8))
      hasher.update(data: Data([0]))
    }
    return "\(prefix):\(hex(hasher.finalize()))"
  }

  static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}

enum JSONLReader {
  private static let maximumLineBytes = 16 * 1_024 * 1_024

  static func forEachLine(
    at url: URL,
    body: (_ lineNumber: Int, _ data: Data) throws -> Void
  ) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let initialIdentity = try FileIdentity(descriptor: handle.fileDescriptor)
    var hasher = SHA256()
    var buffer = Data()
    var lineNumber = 0

    while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
      hasher.update(data: chunk)
      buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 0x0A) {
        guard newline <= maximumLineBytes else {
          throw CatalogIOError.lineTooLong(lineNumber + 1)
        }
        var line = Data(buffer[..<newline])
        buffer.removeSubrange(...newline)
        lineNumber += 1
        if line.last == 0x0D {
          line.removeLast()
        }
        guard !line.isEmpty else { throw CatalogIOError.emptyLine(lineNumber) }
        try body(lineNumber, line)
      }
      guard buffer.count <= maximumLineBytes else {
        throw CatalogIOError.lineTooLong(lineNumber + 1)
      }
    }

    if !buffer.isEmpty {
      lineNumber += 1
      if buffer.last == 0x0D {
        buffer.removeLast()
      }
      guard !buffer.isEmpty else { throw CatalogIOError.emptyLine(lineNumber) }
      try body(lineNumber, buffer)
    }

    guard initialIdentity == (try FileIdentity(descriptor: handle.fileDescriptor)) else {
      throw CatalogIOError.sourceChanged
    }
    return CatalogStableID.hex(hasher.finalize())
  }
}

private struct FileIdentity: Equatable {
  let device: UInt64
  let inode: UInt64
  let size: Int64
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64

  init(descriptor: Int32) throws {
    var information = stat()
    guard fstat(descriptor, &information) == 0 else { throw CatalogIOError.sourceChanged }
    device = UInt64(information.st_dev)
    inode = UInt64(information.st_ino)
    size = information.st_size
    modificationSeconds = Int64(information.st_mtimespec.tv_sec)
    modificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
  }
}

final class CatalogFileLock {
  private let descriptor: Int32

  init(destination: URL) throws {
    guard destination.isFileURL else { throw CatalogIOError.invalidDestination }
    let lockURL = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).lock"
    )
    let permissions = mode_t(S_IRUSR | S_IWUSR)
    descriptor = lockURL.path.withCString {
      Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, permissions)
    }
    guard descriptor >= 0 else { throw CatalogIOError.lockFailed }
    guard fchmod(descriptor, permissions) == 0, flock(descriptor, LOCK_EX) == 0 else {
      Darwin.close(descriptor)
      throw CatalogIOError.lockFailed
    }
  }

  deinit {
    flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }
}

final class PrivateAtomicJSONLWriter {
  private let destination: URL
  private let temporaryURL: URL
  private let handle: FileHandle
  private var isClosed = false
  private var isFinalized = false

  init(destination: URL) throws {
    guard destination.isFileURL else { throw CatalogIOError.invalidDestination }
    self.destination = destination
    temporaryURL = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).partial"
    )
    let permissions = mode_t(S_IRUSR | S_IWUSR)
    let descriptor = temporaryURL.path.withCString {
      Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, permissions)
    }
    guard descriptor >= 0 else {
      throw CatalogIOError.invalidDestination
    }
    guard fchmod(descriptor, permissions) == 0 else {
      Darwin.close(descriptor)
      try? FileManager.default.removeItem(at: temporaryURL)
      throw CatalogIOError.invalidDestination
    }
    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
  }

  deinit {
    try? close()
    if !isFinalized {
      try? FileManager.default.removeItem(at: temporaryURL)
    }
  }

  func write(_ data: Data) throws {
    try handle.write(contentsOf: data)
    try handle.write(contentsOf: Data([0x0A]))
  }

  func finalize() throws {
    guard fchmod(handle.fileDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
      throw CatalogIOError.invalidDestination
    }
    try handle.synchronize()
    try close()
    let renameResult = temporaryURL.path.withCString { temporaryPath in
      destination.path.withCString { destinationPath in
        Darwin.rename(temporaryPath, destinationPath)
      }
    }
    guard renameResult == 0 else { throw CatalogIOError.invalidDestination }
    isFinalized = true
  }

  private func close() throws {
    guard !isClosed else { return }
    try handle.close()
    isClosed = true
  }
}
