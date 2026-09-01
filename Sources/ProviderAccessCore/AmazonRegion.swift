import Foundation

public enum AmazonRegion: String, CaseIterable, Codable, Identifiable, Sendable {
  case unitedStates
  case canada
  case unitedKingdom
  case germany
  case france
  case italy
  case spain
  case netherlands
  case sweden
  case poland
  case japan

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .unitedStates: "United States"
    case .canada: "Canada"
    case .unitedKingdom: "United Kingdom"
    case .germany: "Germany"
    case .france: "France"
    case .italy: "Italy"
    case .spain: "Spain"
    case .netherlands: "Netherlands"
    case .sweden: "Sweden"
    case .poland: "Poland"
    case .japan: "Japan"
    }
  }

  public var host: String {
    switch self {
    case .unitedStates: "www.amazon.com"
    case .canada: "www.amazon.ca"
    case .unitedKingdom: "www.amazon.co.uk"
    case .germany: "www.amazon.de"
    case .france: "www.amazon.fr"
    case .italy: "www.amazon.it"
    case .spain: "www.amazon.es"
    case .netherlands: "www.amazon.nl"
    case .sweden: "www.amazon.se"
    case .poland: "www.amazon.pl"
    case .japan: "www.amazon.co.jp"
    }
  }

  public static func infer<S: Sequence>(fromCookieNames names: S) -> AmazonRegion?
  where S.Element == String {
    if names.contains(where: { $0 == "at-main" || $0 == "at_main" }) {
      return .unitedStates
    }

    guard let regionalName = names.first(where: { $0.hasPrefix("at-acb") }) else {
      return nil
    }
    let countryCode = String(regionalName.dropFirst("at-acb".count)).lowercased()
    switch countryCode {
    case "ca": return .canada
    case "uk": return .unitedKingdom
    case "de": return .germany
    case "fr": return .france
    case "it": return .italy
    case "es": return .spain
    case "nl": return .netherlands
    case "se": return .sweden
    case "pl": return .poland
    case "jp": return .japan
    default: return nil
    }
  }
}
