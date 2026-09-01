import Foundation
import Testing

@testable import ProviderAccessCore

@Test func privateJSONLWriterFinalizesWithRestrictedPermissions() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("inventory.jsonl")

  let writer = try AmazonPrivateJSONLWriter(destination: destination)
  try writer.write(["recordType": "fixture", "value": ["id": "private-id"]])
  try writer.finalize()

  let contents = try String(contentsOf: destination, encoding: .utf8)
  let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
  let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
  #expect(contents.split(separator: "\n").count == 1)
  #expect(permissions.intValue & 0o777 == 0o600)
}

@Test func privateJSONLWriterRemovesAbandonedPartialFiles() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("inventory.jsonl")

  do {
    let writer = try AmazonPrivateJSONLWriter(destination: destination)
    try writer.write(["recordType": "fixture"])
  }

  let remainingFiles = try FileManager.default.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: nil
  )
  #expect(remainingFiles.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func privateJSONLWriterAtomicallyReplacesAnExistingExport() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("inventory.jsonl")
  try Data("old\n".utf8).write(to: destination)

  let writer = try AmazonPrivateJSONLWriter(destination: destination)
  try writer.write(["recordType": "replacement"])
  try writer.finalize()

  let contents = try String(contentsOf: destination, encoding: .utf8)
  #expect(!contents.contains("old"))
  #expect(contents.contains("replacement"))
}
