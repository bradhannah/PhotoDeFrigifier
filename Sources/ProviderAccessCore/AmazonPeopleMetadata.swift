import Foundation

public struct AmazonPrivatePhotoMetadata: Equatable, Sendable {
  public let peopleNames: [String]
  public let keywords: [String]

  public init(peopleNames: [String], keywords: [String]) {
    self.peopleNames = peopleNames
    self.keywords = keywords
  }
}

public struct AmazonPhotoPeopleProbeOutput: Sendable {
  public let report: ProbeResult
  public let privateMetadata: AmazonPrivatePhotoMetadata

  public init(report: ProbeResult, privateMetadata: AmazonPrivatePhotoMetadata) {
    self.report = report
    self.privateMetadata = privateMetadata
  }
}

struct AmazonPrivatePhotoLookup: Equatable {
  let id: String
  let name: String
  let createdDate: String
  let md5: String
}

struct AmazonPrivatePersonLookup: Equatable {
  let name: String
  let match: String
}

enum AmazonPeopleMetadataParser {
  static func latestPhotoLookup(from data: Data) -> AmazonPrivatePhotoLookup? {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let firstPhoto = (root["data"] as? [[String: Any]])?.first,
      let id = validatedNodeID(firstPhoto["id"] as? String),
      let name = validatedName(firstPhoto["name"] as? String),
      let createdDate = validatedCreatedDate(firstPhoto["createdDate"] as? String),
      let contentProperties = firstPhoto["contentProperties"] as? [String: Any],
      let md5 = contentProperties["md5"] as? String,
      isHexMD5(md5)
    else {
      return nil
    }
    return AmazonPrivatePhotoLookup(
      id: id,
      name: name,
      createdDate: createdDate,
      md5: md5.lowercased()
    )
  }

  static func exactSearchFilters(for lookup: AmazonPrivatePhotoLookup) -> [(
    label: String, value: String
  )] {
    [
      ("creation date", "type:(PHOTOS) AND createdDate:\(lookup.createdDate)"),
      ("filename", "type:(PHOTOS) AND name:\(lookup.name)"),
    ]
  }

  static func isExactSinglePhoto(_ lookup: AmazonPrivatePhotoLookup, in data: Data) -> Bool {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let count = root["count"] as? NSNumber,
      count.intValue == 1,
      let photos = root["data"] as? [[String: Any]],
      photos.count == 1,
      photos[0]["id"] as? String == lookup.id,
      let contentProperties = photos[0]["contentProperties"] as? [String: Any],
      let md5 = contentProperties["md5"] as? String
    else {
      return false
    }
    return md5.caseInsensitiveCompare(lookup.md5) == .orderedSame
  }

  static func namedPerson(from data: Data, requestedName: String? = nil)
    -> AmazonPrivatePersonLookup?
  {
    let people = namedPeople(from: data)

    guard let requestedName else { return people.first }
    let normalizedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedName.isEmpty { return people.first }
    guard normalizedName.count <= 200 else { return nil }
    guard
      !normalizedName.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
    else {
      return nil
    }
    let matches = people.filter {
      $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
    }
    guard matches.count == 1 else { return nil }
    return matches[0]
  }

  static func namedPeople(from data: Data) -> [AmazonPrivatePersonLookup] {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let aggregations = root["aggregations"] as? [String: Any]
    else {
      return []
    }

    var people: [AmazonPrivatePersonLookup] = []
    var seenMatches = Set<String>()
    for category in ["people", "allPeople"] {
      for entry in aggregations[category] as? [[String: Any]] ?? [] {
        guard
          let match = validatedFacetMatch(entry["match"] as? String),
          let searchData = entry["searchData"] as? [String: Any],
          let name = sanitizedPrivateValue(searchData["clusterName"] as? String)
        else {
          continue
        }
        if seenMatches.insert(match).inserted {
          people.append(AmazonPrivatePersonLookup(name: name, match: match))
        }
      }
    }
    return people.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  static func recognizedPersonSearchFilter(for person: AmazonPrivatePersonLookup) -> String {
    "type:(PHOTOS) AND people:(\(person.match))"
  }

  static func containsPhoto(in data: Data) -> Bool {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let count = root["count"] as? NSNumber,
      count.intValue > 0,
      let firstPhoto = (root["data"] as? [[String: Any]])?.first,
      validatedNodeID(firstPhoto["id"] as? String) != nil,
      let contentProperties = firstPhoto["contentProperties"] as? [String: Any],
      let md5 = contentProperties["md5"] as? String,
      isHexMD5(md5)
    else {
      return false
    }
    return true
  }

  static func nextToken(from data: Data) -> String? {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let token = root["nextToken"] as? String,
      !token.isEmpty,
      token.count <= 4_096,
      !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      return nil
    }
    return token
  }

  static func nodeIDs(from data: Data, limit: Int) -> Set<String> {
    guard
      limit > 0,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let photos = root["data"] as? [[String: Any]]
    else {
      return []
    }
    return Set(photos.prefix(limit).compactMap { validatedNodeID($0["id"] as? String) })
  }

  static func privateMetadata(from data: Data) -> AmazonPrivatePhotoMetadata {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return AmazonPrivatePhotoMetadata(peopleNames: [], keywords: [])
    }

    var peopleNames = Set<String>()
    if let aggregations = root["aggregations"] as? [String: Any] {
      for category in ["people", "allPeople", "clusterId"] {
        for entry in aggregations[category] as? [[String: Any]] ?? [] {
          guard
            let searchData = entry["searchData"] as? [String: Any],
            let name = sanitizedPrivateValue(searchData["clusterName"] as? String)
          else {
            continue
          }
          peopleNames.insert(name)
        }
      }
    }

    var keywords = Set<String>()
    if let photos = root["data"] as? [[String: Any]] {
      for photo in photos.prefix(5) {
        for value in photo["keywords"] as? [String] ?? [] {
          if let keyword = sanitizedPrivateValue(value) {
            keywords.insert(keyword)
          }
        }
      }
    }

    return AmazonPrivatePhotoMetadata(
      peopleNames: peopleNames.sorted(),
      keywords: keywords.sorted()
    )
  }

  private static func isHexMD5(_ value: String) -> Bool {
    value.count == 32
      && value.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
      }
  }

  static func validatedNodeID(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.count <= 256 else { return nil }
    guard
      value.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
      })
    else {
      return nil
    }
    return value
  }

  private static func validatedFacetMatch(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.count <= 256 else { return nil }
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    )
    guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return value
  }

  private static func validatedName(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.count <= 512 else { return nil }
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard
      value.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else {
      return nil
    }
    return value
  }

  private static func validatedCreatedDate(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.count <= 40 else { return nil }
    let allowed = CharacterSet(charactersIn: "0123456789-:.TZ+")
    guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return value
  }

  private static func sanitizedPrivateValue(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 200 else { return nil }
    guard
      !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      return nil
    }
    return trimmed
  }
}
