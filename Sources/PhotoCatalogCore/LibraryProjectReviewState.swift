import Foundation

public enum LibraryProjectReviewSchema {
  public static let currentVersion = 2
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

public struct DuplicatePairReviewDecision: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let firstSourceResourceID: String
  public let firstSourceObservationID: String
  public let secondSourceResourceID: String
  public let secondSourceObservationID: String
  public let disposition: DuplicateReviewDisposition
  public let decidedAt: Date

  public init(
    firstSourceResourceID: String,
    firstSourceObservationID: String,
    secondSourceResourceID: String,
    secondSourceObservationID: String,
    disposition: DuplicateReviewDisposition,
    decidedAt: Date
  ) {
    let firstComesFirst = firstSourceResourceID < secondSourceResourceID
    self.firstSourceResourceID = firstComesFirst ? firstSourceResourceID : secondSourceResourceID
    self.firstSourceObservationID =
      firstComesFirst
      ? firstSourceObservationID : secondSourceObservationID
    self.secondSourceResourceID = firstComesFirst ? secondSourceResourceID : firstSourceResourceID
    self.secondSourceObservationID =
      firstComesFirst
      ? secondSourceObservationID : firstSourceObservationID
    self.id = CatalogDuplicateIndex.pairID(
      firstSourceResourceID: firstSourceResourceID,
      firstSourceObservationID: firstSourceObservationID,
      secondSourceResourceID: secondSourceResourceID,
      secondSourceObservationID: secondSourceObservationID
    )
    self.disposition = disposition
    self.decidedAt = decidedAt
  }
}

public enum ApplePersonRoute: String, Codable, CaseIterable, Sendable {
  case visible
  case hidden
  case exclude

  public var restrictionLevel: Int {
    switch self {
    case .visible: 0
    case .hidden: 1
    case .exclude: 2
    }
  }
}

public enum GooglePersonRoute: String, Codable, CaseIterable, Sendable {
  case include
  case exclude
}

public struct PersonRouting: Codable, Equatable, Sendable {
  public var apple: ApplePersonRoute?
  public var google: GooglePersonRoute?

  public init(apple: ApplePersonRoute? = nil, google: GooglePersonRoute? = nil) {
    self.apple = apple
    self.google = google
  }

  public var isComplete: Bool { apple != nil && google != nil }
}

public struct CanonicalPerson: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var preferredName: String
  public var aliases: [String]
  public var sourcePersonIDs: [String]
  public var routing: PersonRouting
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: String,
    preferredName: String,
    aliases: [String] = [],
    sourcePersonIDs: [String],
    routing: PersonRouting = PersonRouting(),
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.preferredName = preferredName
    self.aliases = aliases
    self.sourcePersonIDs = sourcePersonIDs
    self.routing = routing
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct LibraryProjectReviewState: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public var duplicateDecisions: [DuplicateReviewDecision]
  public var duplicatePairDecisions: [DuplicatePairReviewDecision]
  public var canonicalPeople: [CanonicalPerson]

  public init(
    schemaVersion: Int = LibraryProjectReviewSchema.currentVersion,
    duplicateDecisions: [DuplicateReviewDecision] = [],
    duplicatePairDecisions: [DuplicatePairReviewDecision] = [],
    canonicalPeople: [CanonicalPerson] = []
  ) {
    self.schemaVersion = schemaVersion
    self.duplicateDecisions = duplicateDecisions
    self.duplicatePairDecisions = duplicatePairDecisions
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

  public mutating func setDuplicatePairDisposition(
    _ disposition: DuplicateReviewDisposition?,
    first: DuplicateOccurrence,
    second: DuplicateOccurrence,
    at date: Date = Date()
  ) {
    let id = CatalogDuplicateIndex.pairID(first, second)
    duplicatePairDecisions.removeAll { $0.id == id }
    if let disposition {
      duplicatePairDecisions.append(
        DuplicatePairReviewDecision(
          firstSourceResourceID: first.sourceResourceID,
          firstSourceObservationID: first.sourceObservationID,
          secondSourceResourceID: second.sourceResourceID,
          secondSourceObservationID: second.sourceObservationID,
          disposition: disposition,
          decidedAt: date
        ))
    }
    duplicatePairDecisions.sort { $0.id < $1.id }
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

  public mutating func setAppleRoute(
    _ route: ApplePersonRoute?,
    for personID: String,
    at date: Date = Date()
  ) {
    guard let index = canonicalPeople.firstIndex(where: { $0.id == personID }) else { return }
    canonicalPeople[index].routing.apple = route
    canonicalPeople[index].updatedAt = date
  }

  public mutating func setGoogleRoute(
    _ route: GooglePersonRoute?,
    for personID: String,
    at date: Date = Date()
  ) {
    guard let index = canonicalPeople.firstIndex(where: { $0.id == personID }) else { return }
    canonicalPeople[index].routing.google = route
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
      unique(state.duplicatePairDecisions.map(\.id)),
      state.duplicatePairDecisions.allSatisfy({ decision in
        !decision.firstSourceResourceID.isEmpty && !decision.secondSourceResourceID.isEmpty
          && !decision.firstSourceObservationID.isEmpty
          && !decision.secondSourceObservationID.isEmpty
          && decision.firstSourceResourceID != decision.secondSourceResourceID
          && decision.id
            == CatalogDuplicateIndex.pairID(
              firstSourceResourceID: decision.firstSourceResourceID,
              firstSourceObservationID: decision.firstSourceObservationID,
              secondSourceResourceID: decision.secondSourceResourceID,
              secondSourceObservationID: decision.secondSourceObservationID
            )
      }),
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

enum LegacyPersonPrivacyCategoryV1: String, Decodable {
  case standard
  case privateCloudAcceptable
  case neverCloud
}

struct LegacyCanonicalPersonV1: Decodable {
  let id: String
  let preferredName: String
  let aliases: [String]
  let sourcePersonIDs: [String]
  let privacyCategory: LegacyPersonPrivacyCategoryV1
  let createdAt: Date
  let updatedAt: Date
}

struct LegacyLibraryProjectReviewStateV1: Decodable {
  let duplicateDecisions: [DuplicateReviewDecision]
  let canonicalPeople: [LegacyCanonicalPersonV1]
}

extension LibraryProjectReviewState {
  init(migrating legacy: LegacyLibraryProjectReviewStateV1) {
    self.init(
      duplicateDecisions: legacy.duplicateDecisions,
      canonicalPeople: legacy.canonicalPeople.map { person in
        let routing =
          switch person.privacyCategory {
          case .standard:
            PersonRouting()
          case .privateCloudAcceptable:
            PersonRouting(apple: .hidden)
          case .neverCloud:
            PersonRouting(apple: .exclude, google: .exclude)
          }
        return CanonicalPerson(
          id: person.id,
          preferredName: person.preferredName,
          aliases: person.aliases,
          sourcePersonIDs: person.sourcePersonIDs,
          routing: routing,
          createdAt: person.createdAt,
          updatedAt: person.updatedAt
        )
      }
    )
  }
}
