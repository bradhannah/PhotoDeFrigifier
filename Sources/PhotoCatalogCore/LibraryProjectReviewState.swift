import Foundation

public enum LibraryProjectReviewSchema {
  public static let currentVersion = 1
}

public enum DuplicateReviewDisposition: String, Codable, CaseIterable, Sendable {
  case confirmedDuplicate
  case rejected
}

public struct DuplicateReviewDecision: Codable, Equatable, Identifiable, Sendable {
  public var id: String { candidateID }
  public let candidateID: String
  public let disposition: DuplicateReviewDisposition
  public let decidedAt: Date

  public init(
    candidateID: String,
    disposition: DuplicateReviewDisposition,
    decidedAt: Date
  ) {
    self.candidateID = candidateID
    self.disposition = disposition
    self.decidedAt = decidedAt
  }
}

public enum PersonPrivacyCategory: String, Codable, CaseIterable, Sendable {
  case standard
  case privateCloudAcceptable
  case neverCloud

  public var restrictionLevel: Int {
    switch self {
    case .standard: 0
    case .privateCloudAcceptable: 1
    case .neverCloud: 2
    }
  }
}

public struct CanonicalPerson: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var preferredName: String
  public var aliases: [String]
  public var sourcePersonIDs: [String]
  public var privacyCategory: PersonPrivacyCategory
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: String,
    preferredName: String,
    aliases: [String] = [],
    sourcePersonIDs: [String],
    privacyCategory: PersonPrivacyCategory = .standard,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.preferredName = preferredName
    self.aliases = aliases
    self.sourcePersonIDs = sourcePersonIDs
    self.privacyCategory = privacyCategory
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct LibraryProjectReviewState: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public var duplicateDecisions: [DuplicateReviewDecision]
  public var canonicalPeople: [CanonicalPerson]

  public init(
    schemaVersion: Int = LibraryProjectReviewSchema.currentVersion,
    duplicateDecisions: [DuplicateReviewDecision] = [],
    canonicalPeople: [CanonicalPerson] = []
  ) {
    self.schemaVersion = schemaVersion
    self.duplicateDecisions = duplicateDecisions
    self.canonicalPeople = canonicalPeople
  }

  public mutating func setDuplicateDisposition(
    _ disposition: DuplicateReviewDisposition?,
    for candidateID: String,
    at date: Date = Date()
  ) {
    duplicateDecisions.removeAll { $0.candidateID == candidateID }
    if let disposition {
      duplicateDecisions.append(
        DuplicateReviewDecision(
          candidateID: candidateID,
          disposition: disposition,
          decidedAt: date
        ))
    }
    duplicateDecisions.sort { $0.candidateID < $1.candidateID }
  }

  public mutating func setDuplicateDisposition(
    _ disposition: DuplicateReviewDisposition?,
    for candidateIDs: [String],
    at date: Date = Date()
  ) {
    let ids = Set(candidateIDs)
    duplicateDecisions.removeAll { ids.contains($0.candidateID) }
    if let disposition {
      duplicateDecisions.append(
        contentsOf: ids.map {
          DuplicateReviewDecision(candidateID: $0, disposition: disposition, decidedAt: date)
        })
    }
    duplicateDecisions.sort { $0.candidateID < $1.candidateID }
  }

  @discardableResult
  public mutating func createCanonicalPerson(
    preferredName: String,
    sourcePersonID: String,
    at date: Date = Date()
  ) -> String {
    let id = "person:\(UUID().uuidString.lowercased())"
    canonicalPeople.append(
      CanonicalPerson(
        id: id,
        preferredName: preferredName,
        sourcePersonIDs: [sourcePersonID],
        createdAt: date,
        updatedAt: date
      ))
    canonicalPeople.sort { $0.id < $1.id }
    return id
  }

  public mutating func setPrivacyCategory(
    _ category: PersonPrivacyCategory,
    for personID: String,
    at date: Date = Date()
  ) {
    guard let index = canonicalPeople.firstIndex(where: { $0.id == personID }) else { return }
    canonicalPeople[index].privacyCategory = category
    canonicalPeople[index].updatedAt = date
  }
}

enum LibraryProjectReviewValidator {
  static func validate(_ state: LibraryProjectReviewState) throws {
    guard state.schemaVersion == LibraryProjectReviewSchema.currentVersion else {
      throw LibraryProjectStoreError.unsupportedReviewSchema(state.schemaVersion)
    }
    guard
      unique(state.duplicateDecisions.map(\.candidateID)),
      state.duplicateDecisions.allSatisfy({ !$0.candidateID.isEmpty }),
      unique(state.canonicalPeople.map(\.id)),
      state.canonicalPeople.allSatisfy({ person in
        validName(person.preferredName) && unique(person.aliases)
          && person.aliases.allSatisfy(validName) && !person.sourcePersonIDs.isEmpty
          && unique(person.sourcePersonIDs) && person.updatedAt >= person.createdAt
      }),
      unique(state.canonicalPeople.flatMap(\.sourcePersonIDs))
    else {
      throw LibraryProjectStoreError.invalidReviewState
    }
  }

  private static func validName(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == value && !trimmed.isEmpty && trimmed.count <= 256
      && trimmed.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
  }

  private static func unique<Value: Hashable>(_ values: [Value]) -> Bool {
    Set(values).count == values.count
  }
}
