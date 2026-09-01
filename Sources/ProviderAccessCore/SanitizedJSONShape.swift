import Foundation

public enum SanitizedJSONShape {
  public static func fieldPaths(from data: Data, maximumDepth: Int = 8) throws -> [String] {
    let object = try JSONSerialization.jsonObject(with: data)
    var paths = Set<String>()
    collectPaths(from: object, path: "", depth: 0, maximumDepth: maximumDepth, into: &paths)
    return paths.sorted()
  }

  public static func topLevelInteger(named name: String, from data: Data) -> Int? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any],
      let number = dictionary[name] as? NSNumber
    else {
      return nil
    }
    return number.intValue
  }

  public static func safeProviderError(from data: Data) -> String? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any]
    else {
      return nil
    }

    for key in ["code", "errorCode", "error", "Message", "message", "error_description"] {
      guard let value = dictionary[key] as? String else { continue }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed.count <= 240, isSafeErrorText(trimmed) else { continue }
      let lowercased = trimmed.lowercased()
      if lowercased == "no auth method provided" {
        return "No Auth Method Provided"
      }
      if lowercased.hasPrefix("invalid filter") {
        return "Invalid filter syntax."
      }
      if lowercased.contains("invalid fieldname to search on") {
        return "Unsupported search field."
      }
      if lowercased.contains("unsupported aggregation category") {
        return "Unsupported aggregation category."
      }
    }
    return nil
  }

  private static func collectPaths(
    from value: Any,
    path: String,
    depth: Int,
    maximumDepth: Int,
    into paths: inout Set<String>
  ) {
    guard depth <= maximumDepth else { return }

    if let dictionary = value as? [String: Any] {
      for (key, child) in dictionary {
        let safeKey = sanitizedKey(key)
        let childPath = path.isEmpty ? safeKey : "\(path).\(safeKey)"
        paths.insert(childPath)
        collectPaths(
          from: child,
          path: childPath,
          depth: depth + 1,
          maximumDepth: maximumDepth,
          into: &paths
        )
      }
      return
    }

    if let array = value as? [Any] {
      let arrayPath = "\(path)[]"
      paths.insert(arrayPath)
      for child in array.prefix(5) {
        collectPaths(
          from: child,
          path: arrayPath,
          depth: depth + 1,
          maximumDepth: maximumDepth,
          into: &paths
        )
      }
    }
  }

  private static func sanitizedKey(_ key: String) -> String {
    guard key.count <= 64 else { return "<dynamic-key>" }
    let allowed = key.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-")).contains($0)
    }
    return allowed ? key : "<dynamic-key>"
  }

  private static func isSafeErrorText(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    let sensitiveMarkers = [
      "atza|", "authorization:", "bearer ", "cookie:", "session-id=", "session-token=",
      "token=",
    ]
    guard !sensitiveMarkers.contains(where: lowercased.contains) else { return false }
    return !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}
