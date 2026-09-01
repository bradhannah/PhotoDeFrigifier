import Foundation

public enum AmazonCookieHeaderFile {
  private static let maximumBytes = 65_536

  public static func load(from url: URL) throws -> String {
    guard url.isFileURL else { throw ProviderProbeError.invalidCookieInput }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard
      let size = attributes[.size] as? NSNumber,
      size.intValue > 0,
      size.intValue <= maximumBytes
    else {
      throw ProviderProbeError.invalidCookieInput
    }

    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard
      data.count <= maximumBytes,
      let header = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ),
      !header.isEmpty
    else {
      throw ProviderProbeError.invalidCookieInput
    }
    _ = try AmazonSessionCookies(cookieHeader: header)
    return header
  }
}
