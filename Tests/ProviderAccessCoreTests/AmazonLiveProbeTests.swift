import Foundation
import Testing

@testable import ProviderAccessCore

@Test func optInLiveRecognizedPersonProbe() async throws {
  guard let cookiePath = ProcessInfo.processInfo.environment["AMAZON_COOKIE_FILE"] else {
    return
  }

  let cookieHeader = try String(contentsOfFile: cookiePath, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let cookies = try AmazonSessionCookies(cookieHeader: cookieHeader)
  let probe = AmazonPhotosProbe(
    region: cookies.inferredRegion ?? .unitedStates,
    cookies: cookies
  )
  let personName = ProcessInfo.processInfo.environment["AMAZON_PERSON_NAME"]

  let output = await probe.probeNamedPersonOnRecognizedPhoto(personName: personName)

  #expect(output.report.status == .success)
  #expect((output.report.aggregateCount ?? 0) > 0)
  #expect(!output.privateMetadata.peopleNames.isEmpty)
  print(
    "LIVE_AMAZON status=\(output.report.status.rawValue) matchingPhotos=\(output.report.aggregateCount ?? 0) localPeople=\(output.privateMetadata.peopleNames.count)"
  )
  for note in output.report.notes {
    print("LIVE_AMAZON note=\(note)")
  }
}

@Test func optInLiveNamedPersonPaginationProbe() async throws {
  guard let cookiePath = ProcessInfo.processInfo.environment["AMAZON_COOKIE_FILE"] else {
    return
  }

  let cookieHeader = try String(contentsOfFile: cookiePath, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let cookies = try AmazonSessionCookies(cookieHeader: cookieHeader)
  let probe = AmazonPhotosProbe(
    region: cookies.inferredRegion ?? .unitedStates,
    cookies: cookies
  )
  let personName = ProcessInfo.processInfo.environment["AMAZON_PERSON_NAME"]

  let report = await probe.probeNamedPersonPagination(
    personName: personName,
    pageSize: 25
  )

  #expect(report.status == .success)
  #expect((report.aggregateCount ?? 0) > 25)
  print(
    "LIVE_AMAZON_PAGINATION status=\(report.status.rawValue) matchingPhotos=\(report.aggregateCount ?? 0)"
  )
  for note in report.notes {
    print("LIVE_AMAZON_PAGINATION note=\(note)")
  }
}

@Test func optInLiveFullPrivateInventoryExport() async throws {
  guard let cookiePath = ProcessInfo.processInfo.environment["AMAZON_COOKIE_FILE"] else {
    return
  }

  let cookieHeader = try String(contentsOfFile: cookiePath, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let cookies = try AmazonSessionCookies(cookieHeader: cookieHeader)
  let probe = AmazonPhotosProbe(
    region: cookies.inferredRegion ?? .unitedStates,
    cookies: cookies
  )
  let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
    "amazon-private-inventory-\(UUID().uuidString).jsonl"
  )
  defer { try? FileManager.default.removeItem(at: destination) }
  let includeNamedPeople = ProcessInfo.processInfo.environment["AMAZON_INCLUDE_PEOPLE"] == "1"

  let report = await probe.exportPrivatePhotoInventory(
    to: destination,
    includeNamedPeople: includeNamedPeople
  )

  #expect(report.status == .success)
  let photoCount = try #require(report.aggregateCount)
  let contents = try String(contentsOf: destination, encoding: .utf8)
  let lineCount = contents.split(separator: "\n").count
  if includeNamedPeople {
    #expect(lineCount > photoCount + 5)
  } else {
    #expect(lineCount == photoCount + 5)
  }
  print(
    "LIVE_AMAZON_INVENTORY status=\(report.status.rawValue) photos=\(photoCount) records=\(lineCount)"
  )
  for note in report.notes {
    print("LIVE_AMAZON_INVENTORY note=\(note)")
  }
}
