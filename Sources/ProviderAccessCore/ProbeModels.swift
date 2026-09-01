import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
  case apple
  case google
  case amazon
}

public enum AccessMechanism: String, Codable, Sendable {
  case photoKitPermission
  case browserHandoff
  case manualExport
  case sessionCookie
  case oauthRegisteredClient
}

public enum ProbeStatus: String, Codable, Sendable {
  case success
  case failure
  case blocked
}

public struct ProbeResult: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let provider: ProviderKind
  public let mechanism: AccessMechanism
  public let operation: String
  public let status: ProbeStatus
  public let timestamp: Date
  public let httpStatus: Int?
  public let durationMilliseconds: Int?
  public let aggregateCount: Int?
  public let responseFieldPaths: [String]
  public let notes: [String]

  public init(
    id: UUID = UUID(),
    provider: ProviderKind,
    mechanism: AccessMechanism,
    operation: String,
    status: ProbeStatus,
    timestamp: Date = Date(),
    httpStatus: Int? = nil,
    durationMilliseconds: Int? = nil,
    aggregateCount: Int? = nil,
    responseFieldPaths: [String] = [],
    notes: [String] = []
  ) {
    self.id = id
    self.provider = provider
    self.mechanism = mechanism
    self.operation = operation
    self.status = status
    self.timestamp = timestamp
    self.httpStatus = httpStatus
    self.durationMilliseconds = durationMilliseconds
    self.aggregateCount = aggregateCount
    self.responseFieldPaths = responseFieldPaths
    self.notes = notes
  }
}

public enum ProviderProbeError: LocalizedError, Equatable, Sendable {
  case invalidCookieInput
  case missingRequiredCookie(String)
  case disallowedRequest
  case invalidResponse
  case responseTooLarge
  case directoryUnavailable

  public var errorDescription: String? {
    switch self {
    case .invalidCookieInput:
      "Cookie input is malformed. Paste the Cookie request header from Amazon Photos."
    case .missingRequiredCookie(let name):
      "The required \(name) cookie is missing."
    case .disallowedRequest:
      "The request is outside the read-only endpoint allowlist."
    case .invalidResponse:
      "The provider returned an invalid response."
    case .responseTooLarge:
      "The provider response exceeded the probe safety limit."
    case .directoryUnavailable:
      "The selected export directory could not be inspected."
    }
  }
}
