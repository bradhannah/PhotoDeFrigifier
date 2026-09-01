import Testing

@testable import ProviderAccessCore

@Test
func parsesOnlyAmazonAuthenticationCookieNames() throws {
  let cookies = try AmazonSessionCookies(
    cookieHeader:
      "session-id=session123; ubid_main=ubid123; at_main=token123; session-token=sessionToken; sess-at-main=sessToken; sst-main=sstToken; unrelated=discard-me"
  )

  #expect(
    cookies.cookieNames == [
      "at_main", "sess-at-main", "session-id", "session-token", "sst-main", "ubid_main",
    ]
  )
  #expect(!cookies.normalizedHeader.contains("unrelated"))
  #expect(cookies.sessionID == "session123")
  #expect(cookies.inferredRegion == .unitedStates)
}

@Test
func infersCanadaAndPreservesRegionalSessionCookies() throws {
  let cookies = try AmazonSessionCookies(
    cookieHeader:
      "session-id=session123; ubid-acbca=ubid123; at-acbca=token123; sess-at-acbca=sessToken; sst-acbca=sstToken; x-acbca=xToken; i18n-prefs=CAD"
  )

  #expect(cookies.inferredRegion == .canada)
  #expect(cookies.cookieNames.contains("sess-at-acbca"))
  #expect(cookies.cookieNames.contains("sst-acbca"))
  #expect(cookies.cookieNames.contains("x-acbca"))
  #expect(!cookies.cookieNames.contains("i18n-prefs"))
}

@Test
func preservesEqualsCharactersInsideCookieValues() throws {
  let cookies = try AmazonSessionCookies(
    cookieHeader: "session-id=session123; ubid-main=ubid==; at-main=token=="
  )

  #expect(cookies.normalizedHeader.contains("at-main=token=="))
  #expect(cookies.normalizedHeader.contains("ubid-main=ubid=="))
}

@Test
func rejectsCookieInputWithoutAuthenticationCookie() {
  #expect(throws: ProviderProbeError.missingRequiredCookie("at/at-acb")) {
    try AmazonSessionCookies(cookieHeader: "session-id=session123; ubid_main=ubid123")
  }
}

@Test
func rejectsHeaderInjectionCharacters() {
  #expect(throws: ProviderProbeError.invalidCookieInput) {
    try AmazonSessionCookies(
      cookieHeader: "session-id=session123; ubid_main=ubid123; at_main=token\r\nInjected: true"
    )
  }
}

@Test
func mapsAmazonRegionsToFixedHosts() {
  #expect(AmazonRegion.unitedStates.host == "www.amazon.com")
  #expect(AmazonRegion.unitedKingdom.host == "www.amazon.co.uk")
  #expect(AmazonRegion.japan.host == "www.amazon.co.jp")
}
