import Foundation

public struct AmazonSessionCookies: Equatable, Sendable {
  private let values: [String: String]

  public init(cookieHeader: String) throws {
    let containsControlCharacter = cookieHeader.unicodeScalars.contains {
      CharacterSet.controlCharacters.contains($0)
    }
    guard !containsControlCharacter else {
      throw ProviderProbeError.invalidCookieInput
    }

    var parsed: [String: String] = [:]
    for component in cookieHeader.split(separator: ";") {
      let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
      guard pair.count == 2 else { continue }
      let name = pair[0].trimmingCharacters(in: .whitespaces)
      let value = pair[1].trimmingCharacters(in: .whitespaces)
      guard Self.isAllowedCookieName(name), !value.isEmpty else { continue }
      parsed[name] = value
    }

    guard parsed["session-id"] != nil else {
      throw ProviderProbeError.missingRequiredCookie("session-id")
    }
    guard parsed.keys.contains(where: Self.isAuthenticationCookieName) else {
      throw ProviderProbeError.missingRequiredCookie("at/at-acb")
    }
    guard parsed.keys.contains(where: { $0.hasPrefix("ubid") }) else {
      throw ProviderProbeError.missingRequiredCookie("ubid")
    }

    values = parsed
  }

  public var normalizedHeader: String {
    values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
  }

  public var sessionID: String {
    values["session-id"] ?? ""
  }

  public var cookieNames: [String] {
    values.keys.sorted()
  }

  public var inferredRegion: AmazonRegion? {
    AmazonRegion.infer(fromCookieNames: values.keys)
  }

  private static func isAllowedCookieName(_ name: String) -> Bool {
    switch name {
    case "session-id", "session-id-time", "session-token":
      true
    default:
      name.hasPrefix("ubid")
        || isAuthenticationCookieName(name)
        || name.hasPrefix("sess-at-")
        || name.hasPrefix("sst-")
        || name.hasPrefix("sso-state-")
        || name.hasPrefix("x-acb")
    }
  }

  private static func isAuthenticationCookieName(_ name: String) -> Bool {
    name == "at-main" || name == "at_main" || name.hasPrefix("at-acb")
  }
}
