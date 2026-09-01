import Foundation
import Testing

@testable import ProviderAccessCore

@Test func loadsAndValidatesCookieHeaderFromASelectedFile() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "cookie-\(UUID().uuidString).secret"
  )
  defer { try? FileManager.default.removeItem(at: url) }
  let header = "session-id=123-456; at-acbca=token-value; ubid-acbca=account-value"
  try Data("\n\(header)\n".utf8).write(to: url)

  #expect(try AmazonCookieHeaderFile.load(from: url) == header)
}

@Test func rejectsOversizedOrUnauthenticatedCookieFiles() throws {
  let oversizedURL = FileManager.default.temporaryDirectory.appendingPathComponent(
    "cookie-oversized-\(UUID().uuidString).secret"
  )
  let invalidURL = FileManager.default.temporaryDirectory.appendingPathComponent(
    "cookie-invalid-\(UUID().uuidString).secret"
  )
  defer {
    try? FileManager.default.removeItem(at: oversizedURL)
    try? FileManager.default.removeItem(at: invalidURL)
  }
  try Data(repeating: 0x61, count: 65_537).write(to: oversizedURL)
  try Data("locale=en_CA".utf8).write(to: invalidURL)

  #expect(throws: ProviderProbeError.self) {
    try AmazonCookieHeaderFile.load(from: oversizedURL)
  }
  #expect(throws: ProviderProbeError.self) {
    try AmazonCookieHeaderFile.load(from: invalidURL)
  }
}
