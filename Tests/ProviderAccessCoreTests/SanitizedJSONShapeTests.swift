import Foundation
import Testing

@testable import ProviderAccessCore

@Test
func extractsFieldPathsWithoutScalarValues() throws {
  let data = Data(
    """
    {
      "count": 1,
      "data": [
        {
          "id": "secret-provider-id",
          "contentProperties": {
            "size": 123,
            "md5": "secret-hash"
          }
        }
      ]
    }
    """.utf8
  )

  let paths = try SanitizedJSONShape.fieldPaths(from: data)

  #expect(paths.contains("count"))
  #expect(paths.contains("data[]"))
  #expect(paths.contains("data[].id"))
  #expect(paths.contains("data[].contentProperties.md5"))
  #expect(!paths.contains(where: { $0.contains("secret-provider-id") }))
  #expect(SanitizedJSONShape.topLevelInteger(named: "count", from: data) == 1)
}

@Test
func redactsOversizedDynamicKeys() throws {
  let dynamicKey = String(repeating: "a", count: 80)
  let data = try JSONSerialization.data(withJSONObject: [dynamicKey: ["field": true]])

  let paths = try SanitizedJSONShape.fieldPaths(from: data)

  #expect(paths.contains("<dynamic-key>"))
  #expect(!paths.contains(where: { $0.contains(dynamicKey) }))
}

@Test
func extractsSafeProviderErrorsButRejectsCredentialLikeValues() throws {
  let safeData = Data("{\"Message\":\"No Auth Method Provided\"}".utf8)
  let unsafeData = Data("{\"message\":\"session-token=secret-value\"}".utf8)
  let reflectedFilterData = Data(
    "{\"message\":\"Invalid filter name:private-photo.jpg Cannot be parsed\"}".utf8
  )

  #expect(SanitizedJSONShape.safeProviderError(from: safeData) == "No Auth Method Provided")
  #expect(SanitizedJSONShape.safeProviderError(from: unsafeData) == nil)
  #expect(
    SanitizedJSONShape.safeProviderError(from: reflectedFilterData) == "Invalid filter syntax."
  )
  #expect(
    SanitizedJSONShape.safeProviderError(from: reflectedFilterData)?.contains("private-photo")
      == false
  )
}
