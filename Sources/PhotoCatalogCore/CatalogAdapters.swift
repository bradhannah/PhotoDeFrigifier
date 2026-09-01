import Foundation

public struct CatalogAdapterDescriptor: Equatable, Sendable {
  public let id: String
  public let version: Int
  public let provider: CatalogProvider

  public init(id: String, version: Int, provider: CatalogProvider) {
    self.id = id
    self.version = version
    self.provider = provider
  }
}

public protocol URLCatalogImportAdapter: Sendable {
  var descriptor: CatalogAdapterDescriptor { get }
  func importCatalog(from sourceURL: URL, importedAt: Date) throws -> CatalogSnapshot
}

// PhotoKit code should convert PHAsset data into this public-framework-free boundary.
public struct ApplePhotoObservation: Codable, Equatable, Sendable {
  public let localIdentifier: String
  public let kind: AssetKind
  public let resources: [ProviderResourceObservation]
  public let metadata: [String: JSONValue]

  public init(
    localIdentifier: String,
    kind: AssetKind,
    resources: [ProviderResourceObservation],
    metadata: [String: JSONValue]
  ) {
    self.localIdentifier = localIdentifier
    self.kind = kind
    self.resources = resources
    self.metadata = metadata
  }
}

// A Takeout adapter should pair each media file with its sidecar before emitting this value.
public struct GoogleTakeoutObservation: Codable, Equatable, Sendable {
  public let sourceRelativePath: String
  public let mediaResource: ProviderResourceObservation
  public let sidecarResource: ProviderResourceObservation?
  public let sidecarMetadata: [String: JSONValue]

  public init(
    sourceRelativePath: String,
    mediaResource: ProviderResourceObservation,
    sidecarResource: ProviderResourceObservation?,
    sidecarMetadata: [String: JSONValue]
  ) {
    self.sourceRelativePath = sourceRelativePath
    self.mediaResource = mediaResource
    self.sidecarResource = sidecarResource
    self.sidecarMetadata = sidecarMetadata
  }
}

public struct ProviderResourceObservation: Codable, Equatable, Sendable {
  public let externalID: String
  public let role: ResourceRole
  public let filename: String?
  public let mediaType: String?
  public let byteCount: Int64?
  public let reportedDigests: [ReportedDigest]

  public init(
    externalID: String,
    role: ResourceRole,
    filename: String? = nil,
    mediaType: String? = nil,
    byteCount: Int64? = nil,
    reportedDigests: [ReportedDigest] = []
  ) {
    self.externalID = externalID
    self.role = role
    self.filename = filename
    self.mediaType = mediaType
    self.byteCount = byteCount
    self.reportedDigests = reportedDigests
  }
}
