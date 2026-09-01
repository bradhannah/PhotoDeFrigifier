import Foundation
import Testing

@testable import ProviderAccessCore

@Test
func inspectsTakeoutUsingOnlyCountsAndFieldShapes() async throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  try Data([0xFF, 0xD8, 0xFF]).write(to: root.appending(path: "private-photo.jpg"))
  try Data(
    """
    {
      "title": "private-photo.jpg",
      "description": "private description",
      "photoTakenTime": { "timestamp": "123" },
      "geoData": { "latitude": 1.0, "longitude": 2.0 }
    }
    """.utf8
  ).write(to: root.appending(path: "private-photo.jpg.json"))
  try Data("{\"title\":\"Private Album\"}".utf8)
    .write(to: root.appending(path: "metadata.json"))

  let report = try await GoogleTakeoutInspector.inspect(directory: root)

  #expect(report.status == .success)
  #expect(report.aggregateCount == 1)
  #expect(report.responseFieldPaths.contains("photoTakenTime.timestamp"))
  #expect(report.responseFieldPaths.contains("geoData.latitude"))
  #expect(!report.notes.contains(where: { $0.contains("private-photo") }))
  #expect(!report.responseFieldPaths.contains(where: { $0.contains("private description") }))
}
