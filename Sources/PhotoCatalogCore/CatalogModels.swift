import Foundation

public enum CatalogSchema {
  public static let currentVersion = 4
}

public enum CatalogProvider: String, Codable, CaseIterable, Sendable {
  case amazon
  case applePhotos
  case filesystem
  case googlePhotos
}

public struct SourceLibrary: Codable, Equatable, Sendable {
  public let id: String
  public let provider: CatalogProvider
  public let externalAccountID: String?
  public let displayName: String?
  public let latestImportRunID: String?

  public init(
    id: String,
    provider: CatalogProvider,
    externalAccountID: String? = nil,
    displayName: String? = nil,
    latestImportRunID: String? = nil
  ) {
    self.id = id
    self.provider = provider
    self.externalAccountID = externalAccountID
    self.displayName = displayName
    self.latestImportRunID = latestImportRunID
  }
}

public struct ImportRun: Codable, Equatable, Sendable {
  public let id: String
  public let sourceLibraryID: String
  public let adapterID: String
  public let adapterVersion: Int
  public let sourceFingerprintSHA256: String
  public let sourceSchemaVersion: Int
  public let capturedAt: String?
  public let importedAt: Date
  public let sourceRecordCount: Int

  public init(
    id: String,
    sourceLibraryID: String,
    adapterID: String,
    adapterVersion: Int,
    sourceFingerprintSHA256: String,
    sourceSchemaVersion: Int,
    capturedAt: String?,
    importedAt: Date,
    sourceRecordCount: Int
  ) {
    self.id = id
    self.sourceLibraryID = sourceLibraryID
    self.adapterID = adapterID
    self.adapterVersion = adapterVersion
    self.sourceFingerprintSHA256 = sourceFingerprintSHA256
    self.sourceSchemaVersion = sourceSchemaVersion
    self.capturedAt = capturedAt
    self.importedAt = importedAt
    self.sourceRecordCount = sourceRecordCount
  }
}

public enum AssetKind: String, Codable, Hashable, Sendable {
  case audio
  case photo
  case unknown
  case video
}

public enum AssetResolutionState: String, Codable, Sendable {
  case provisional
  case reconciled
  case reviewRequired
}

public struct Asset: Codable, Equatable, Sendable {
  public let id: String
  public let kind: AssetKind
  public let resolutionState: AssetResolutionState
  public let sourceItemIDs: [String]
  public let sourceResourceIDs: [String]

  public init(
    id: String,
    kind: AssetKind,
    resolutionState: AssetResolutionState,
    sourceItemIDs: [String],
    sourceResourceIDs: [String]
  ) {
    self.id = id
    self.kind = kind
    self.resolutionState = resolutionState
    self.sourceItemIDs = sourceItemIDs
    self.sourceResourceIDs = sourceResourceIDs
  }
}

public struct SourceItem: Codable, Equatable, Sendable {
  public let id: String
  public let sourceLibraryID: String
  public let externalID: String
  public let firstObservedImportRunID: String
  public let latestObservationID: String
  public let lastSeenImportRunID: String?
  public let kind: AssetKind

  public init(
    id: String,
    sourceLibraryID: String,
    externalID: String,
    firstObservedImportRunID: String,
    latestObservationID: String,
    lastSeenImportRunID: String? = nil,
    kind: AssetKind
  ) {
    self.id = id
    self.sourceLibraryID = sourceLibraryID
    self.externalID = externalID
    self.firstObservedImportRunID = firstObservedImportRunID
    self.latestObservationID = latestObservationID
    self.lastSeenImportRunID = lastSeenImportRunID
    self.kind = kind
  }
}

public enum ResourceRole: String, Codable, CaseIterable, Sendable {
  case audio
  case edited
  case original
  case pairedVideo
  case primary
  case raw
  case sidecar
  case video

  var compatibilityClass: String {
    switch self {
    case .audio: "audio"
    case .original, .primary: "photo-original"
    case .edited: "photo-edited"
    case .pairedVideo: "paired-video"
    case .raw: "raw"
    case .sidecar: "sidecar"
    case .video: "video"
    }
  }
}

public struct ReportedDigest: Codable, Equatable, Sendable {
  public let algorithm: String
  public let value: String
  public let reportingProvider: CatalogProvider

  public init(algorithm: String, value: String, reportingProvider: CatalogProvider) {
    self.algorithm = algorithm
    self.value = value
    self.reportingProvider = reportingProvider
  }
}

public struct SourceResource: Codable, Equatable, Sendable {
  public let id: String
  public let sourceItemID: String
  public let latestObservationID: String?
  public let role: ResourceRole
  public let originalFilename: String?
  public let mediaType: String?
  public let byteCount: Int64?
  public let width: Int?
  public let height: Int?
  public let reportedDigests: [ReportedDigest]

  public init(
    id: String,
    sourceItemID: String,
    latestObservationID: String? = nil,
    role: ResourceRole,
    originalFilename: String? = nil,
    mediaType: String? = nil,
    byteCount: Int64? = nil,
    width: Int? = nil,
    height: Int? = nil,
    reportedDigests: [ReportedDigest] = []
  ) {
    self.id = id
    self.sourceItemID = sourceItemID
    self.latestObservationID = latestObservationID
    self.role = role
    self.originalFilename = originalFilename
    self.mediaType = mediaType
    self.byteCount = byteCount
    self.width = width
    self.height = height
    self.reportedDigests = reportedDigests
  }
}

public enum ByteVerificationMethod: String, Codable, Sendable {
  case localSHA256
}

public struct ByteResource: Codable, Equatable, Sendable {
  public let id: String
  public let sha256: String
  public let locallyMeasuredMD5: String?
  public let byteCount: Int64
  public let verificationMethod: ByteVerificationMethod
  public let measuredAt: Date

  public init(
    id: String,
    sha256: String,
    locallyMeasuredMD5: String? = nil,
    byteCount: Int64,
    verificationMethod: ByteVerificationMethod,
    measuredAt: Date
  ) {
    self.id = id
    self.sha256 = sha256
    self.locallyMeasuredMD5 = locallyMeasuredMD5
    self.byteCount = byteCount
    self.verificationMethod = verificationMethod
    self.measuredAt = measuredAt
  }
}

public struct AssetResourceLink: Codable, Equatable, Sendable {
  public let id: String
  public let sourceResourceID: String
  public let byteResourceID: String
  public let sourceObservationID: String
  public let verifiedAt: Date

  public init(
    id: String,
    sourceResourceID: String,
    byteResourceID: String,
    sourceObservationID: String,
    verifiedAt: Date
  ) {
    self.id = id
    self.sourceResourceID = sourceResourceID
    self.byteResourceID = byteResourceID
    self.sourceObservationID = sourceObservationID
    self.verifiedAt = verifiedAt
  }
}

public enum ClaimAuthorship: String, Codable, Sendable {
  case embeddedMetadata
  case inferred
  case providerDerived
  case unknown
  case userAuthored
}

public enum MetadataValue: Codable, Equatable, Sendable {
  case boolean(Bool)
  case integer(Int64)
  case json(JSONValue)
  case location(JSONValue)
  case number(Double)
  case string(String)
  case stringList([String])
  case timestamp(String)
}

public struct MetadataClaim: Codable, Equatable, Sendable {
  public let id: String
  public let assetID: String
  public let sourceItemID: String
  public let importRunID: String
  public let observationID: String
  public let field: String
  public let normalizedValue: MetadataValue
  public let rawValue: JSONValue
  public let sourceJSONPath: String
  public let authorship: ClaimAuthorship
  public let confidence: Double
  public let observedAt: Date

  public init(
    id: String,
    assetID: String,
    sourceItemID: String,
    importRunID: String,
    observationID: String,
    field: String,
    normalizedValue: MetadataValue,
    rawValue: JSONValue,
    sourceJSONPath: String,
    authorship: ClaimAuthorship,
    confidence: Double,
    observedAt: Date
  ) {
    self.id = id
    self.assetID = assetID
    self.sourceItemID = sourceItemID
    self.importRunID = importRunID
    self.observationID = observationID
    self.field = field
    self.normalizedValue = normalizedValue
    self.rawValue = rawValue
    self.sourceJSONPath = sourceJSONPath
    self.authorship = authorship
    self.confidence = confidence
    self.observedAt = observedAt
  }
}

public struct SourcePerson: Codable, Equatable, Sendable {
  public let id: String
  public let sourceLibraryID: String
  public let externalID: String
  public let displayName: String?
  public let observationID: String

  public init(
    id: String,
    sourceLibraryID: String,
    externalID: String,
    displayName: String?,
    observationID: String
  ) {
    self.id = id
    self.sourceLibraryID = sourceLibraryID
    self.externalID = externalID
    self.displayName = displayName
    self.observationID = observationID
  }
}

public struct PersonNameClaim: Codable, Equatable, Sendable {
  public let id: String
  public let sourcePersonID: String
  public let importRunID: String
  public let observationID: String
  public let displayName: String
  public let authorship: ClaimAuthorship
  public let confidence: Double
  public let observedAt: Date

  public init(
    id: String,
    sourcePersonID: String,
    importRunID: String,
    observationID: String,
    displayName: String,
    authorship: ClaimAuthorship,
    confidence: Double,
    observedAt: Date
  ) {
    self.id = id
    self.sourcePersonID = sourcePersonID
    self.importRunID = importRunID
    self.observationID = observationID
    self.displayName = displayName
    self.authorship = authorship
    self.confidence = confidence
    self.observedAt = observedAt
  }
}

public struct PersonMembershipClaim: Codable, Equatable, Sendable {
  public let id: String
  public let sourcePersonID: String
  public let sourceItemID: String
  public let assetID: String
  public let importRunID: String
  public let observationID: String
  public let confidence: Double

  public init(
    id: String,
    sourcePersonID: String,
    sourceItemID: String,
    assetID: String,
    importRunID: String,
    observationID: String,
    confidence: Double
  ) {
    self.id = id
    self.sourcePersonID = sourcePersonID
    self.sourceItemID = sourceItemID
    self.assetID = assetID
    self.importRunID = importRunID
    self.observationID = observationID
    self.confidence = confidence
  }
}

public struct SourceObservation: Codable, Equatable, Sendable {
  public let id: String
  public let importRunID: String
  public let sourceItemID: String?
  public let sourcePersonID: String?
  public let lineNumber: Int
  public let recordType: String
  public let rawRecord: JSONValue

  public init(
    id: String,
    importRunID: String,
    sourceItemID: String?,
    sourcePersonID: String? = nil,
    lineNumber: Int,
    recordType: String,
    rawRecord: JSONValue
  ) {
    self.id = id
    self.importRunID = importRunID
    self.sourceItemID = sourceItemID
    self.sourcePersonID = sourcePersonID
    self.lineNumber = lineNumber
    self.recordType = recordType
    self.rawRecord = rawRecord
  }
}

public struct CatalogSnapshot: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public var sourceLibraries: [SourceLibrary]
  public var importRuns: [ImportRun]
  public var assets: [Asset]
  public var sourceItems: [SourceItem]
  public var sourceResources: [SourceResource]
  public var byteResources: [ByteResource]
  public var assetResourceLinks: [AssetResourceLink]
  public var metadataClaims: [MetadataClaim]
  public var sourcePeople: [SourcePerson]
  public var personNameClaims: [PersonNameClaim]
  public var personMembershipClaims: [PersonMembershipClaim]
  public var sourceObservations: [SourceObservation]

  public init(
    schemaVersion: Int = CatalogSchema.currentVersion,
    sourceLibraries: [SourceLibrary] = [],
    importRuns: [ImportRun] = [],
    assets: [Asset] = [],
    sourceItems: [SourceItem] = [],
    sourceResources: [SourceResource] = [],
    byteResources: [ByteResource] = [],
    assetResourceLinks: [AssetResourceLink] = [],
    metadataClaims: [MetadataClaim] = [],
    sourcePeople: [SourcePerson] = [],
    personNameClaims: [PersonNameClaim] = [],
    personMembershipClaims: [PersonMembershipClaim] = [],
    sourceObservations: [SourceObservation] = []
  ) {
    self.schemaVersion = schemaVersion
    self.sourceLibraries = sourceLibraries
    self.importRuns = importRuns
    self.assets = assets
    self.sourceItems = sourceItems
    self.sourceResources = sourceResources
    self.byteResources = byteResources
    self.assetResourceLinks = assetResourceLinks
    self.metadataClaims = metadataClaims
    self.sourcePeople = sourcePeople
    self.personNameClaims = personNameClaims
    self.personMembershipClaims = personMembershipClaims
    self.sourceObservations = sourceObservations
  }
}
