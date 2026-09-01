import Foundation

private final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public actor AmazonPhotosProbe {
  struct Endpoint: Sendable {
    let operation: String
    let path: String
    let queryItems: [URLQueryItem]
  }

  private struct ExactPhotoMatch {
    let data: Data
    let response: HTTPURLResponse
    let duration: Int
    let strategy: String
  }

  private enum ExactPhotoLookup {
    case matched(ExactPhotoMatch)
    case failed(ProbeResult)
  }

  private static let allowedPaths: Set<String> = [
    "/drive/v1/account/usage",
    "/drive/v1/nodes",
    "/drive/v1/search",
  ]

  let region: AmazonRegion
  private let cookies: AmazonSessionCookies
  private let redirectDelegate: RedirectRejectingDelegate
  private let session: URLSession

  public init(region: AmazonRegion, cookies: AmazonSessionCookies) {
    self.region = region
    self.cookies = cookies

    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 45
    let redirectDelegate = RedirectRejectingDelegate()
    self.redirectDelegate = redirectDelegate
    session = URLSession(
      configuration: configuration,
      delegate: redirectDelegate,
      delegateQueue: nil
    )
  }

  public func runMetadataProbe() async -> [ProbeResult] {
    let endpoints = [
      Endpoint(
        operation: "Amazon one-item media search",
        path: "/drive/v1/search",
        queryItems: commonQueryItems + [
          URLQueryItem(name: "limit", value: "1"),
          URLQueryItem(name: "offset", value: "0"),
          URLQueryItem(name: "filters", value: "type:(PHOTOS OR VIDEOS)"),
          URLQueryItem(name: "lowResThumbnail", value: "false"),
          URLQueryItem(name: "searchContext", value: "customer"),
          URLQueryItem(name: "sort", value: "['createdDate DESC']"),
        ]
      ),
      Endpoint(
        operation: "Amazon account usage",
        path: "/drive/v1/account/usage",
        queryItems: commonQueryItems
      ),
      Endpoint(
        operation: "Amazon root metadata",
        path: "/drive/v1/nodes",
        queryItems: commonQueryItems + [URLQueryItem(name: "filters", value: "isRoot:true")]
      ),
      Endpoint(
        operation: "Amazon available aggregation shapes",
        path: "/drive/v1/search",
        queryItems: commonQueryItems + [
          URLQueryItem(name: "limit", value: "1"),
          URLQueryItem(name: "lowResThumbnail", value: "true"),
          URLQueryItem(name: "searchContext", value: "all"),
          URLQueryItem(name: "groupByForTime", value: "year"),
        ]
      ),
    ]

    var results: [ProbeResult] = []
    for (index, endpoint) in endpoints.enumerated() {
      let result = await execute(endpoint)
      results.append(result)

      // Authentication failures should not generate additional requests. A 400
      // can mean only that an undocumented request shape changed.
      if index == 0, result.httpStatus == 401 || result.httpStatus == 403 {
        break
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return results
  }

  public func probePeopleOnLatestPhoto() async -> AmazonPhotoPeopleProbeOutput {
    let operation = "Amazon People metadata on latest photo"
    let emptyMetadata = AmazonPrivatePhotoMetadata(peopleNames: [], keywords: [])
    let start = Date()

    do {
      let latestPhotoEndpoint = Endpoint(
        operation: operation,
        path: "/drive/v1/search",
        queryItems: commonQueryItems + [
          URLQueryItem(name: "limit", value: "1"),
          URLQueryItem(name: "offset", value: "0"),
          URLQueryItem(name: "filters", value: "type:(PHOTOS)"),
          URLQueryItem(name: "lowResThumbnail", value: "false"),
          URLQueryItem(name: "searchContext", value: "customer"),
          URLQueryItem(name: "sort", value: "['createdDate DESC']"),
        ]
      )
      let latestResponse = try await perform(latestPhotoEndpoint)
      guard (200...299).contains(latestResponse.response.statusCode) else {
        return AmazonPhotoPeopleProbeOutput(
          report: httpFailureResult(
            for: latestPhotoEndpoint,
            response: latestResponse.response,
            data: latestResponse.data,
            duration: latestResponse.duration
          ),
          privateMetadata: emptyMetadata
        )
      }
      guard let photo = AmazonPeopleMetadataParser.latestPhotoLookup(from: latestResponse.data)
      else {
        return AmazonPhotoPeopleProbeOutput(
          report: ProbeResult(
            provider: .amazon,
            mechanism: .sessionCookie,
            operation: operation,
            status: .failure,
            httpStatus: latestResponse.response.statusCode,
            durationMilliseconds: latestResponse.duration,
            responseFieldPaths: (try? SanitizedJSONShape.fieldPaths(from: latestResponse.data))
              ?? [],
            notes: [
              "Request host: \(region.host)",
              "The latest photo response lacked the fields needed for a narrow follow-up query, so no second request was sent.",
            ]
          ),
          privateMetadata: emptyMetadata
        )
      }

      let exactLookup = try await exactPhotoLookup(for: photo, operation: operation)
      guard case .matched(let filteredResponse) = exactLookup else {
        let failure: ProbeResult
        if case .failed(let report) = exactLookup {
          failure = report
        } else {
          failure = failureResult(
            for: operation,
            start: start,
            note: "No supported single-field lookup produced one exact media match."
          )
        }
        return AmazonPhotoPeopleProbeOutput(
          report: failure,
          privateMetadata: emptyMetadata
        )
      }

      let privateMetadata = AmazonPeopleMetadataParser.privateMetadata(
        from: filteredResponse.data
      )
      var notes = [
        "Request host: \(region.host)",
        "The latest photo was narrowed by \(filteredResponse.strategy), then verified by ID and MD5 in memory.",
        "The filename, creation date, provider ID, and hash were discarded after the request.",
        "People names and keywords are displayed only in memory and are excluded from copied/exported reports.",
      ]
      if privateMetadata.peopleNames.isEmpty {
        notes.append("No named People aggregation was returned for the latest photo.")
      }

      return AmazonPhotoPeopleProbeOutput(
        report: ProbeResult(
          provider: .amazon,
          mechanism: .sessionCookie,
          operation: operation,
          status: .success,
          httpStatus: filteredResponse.response.statusCode,
          durationMilliseconds: filteredResponse.duration,
          aggregateCount: privateMetadata.peopleNames.count,
          responseFieldPaths: try SanitizedJSONShape.fieldPaths(from: filteredResponse.data),
          notes: notes
        ),
        privateMetadata: privateMetadata
      )
    } catch let error as ProviderProbeError {
      return AmazonPhotoPeopleProbeOutput(
        report: failureResult(for: operation, start: start, note: error.localizedDescription),
        privateMetadata: emptyMetadata
      )
    } catch let error as URLError {
      return AmazonPhotoPeopleProbeOutput(
        report: failureResult(
          for: operation,
          start: start,
          note: "Network request failed with URL error code \(error.errorCode)."
        ),
        privateMetadata: emptyMetadata
      )
    } catch {
      return AmazonPhotoPeopleProbeOutput(
        report: failureResult(
          for: operation,
          start: start,
          note: "The per-photo request failed; provider response values were discarded."
        ),
        privateMetadata: emptyMetadata
      )
    }
  }

  public func probeNamedPersonOnRecognizedPhoto(
    personName: String? = nil
  ) async -> AmazonPhotoPeopleProbeOutput {
    let operation = "Amazon named person on recognized photo"
    let emptyMetadata = AmazonPrivatePhotoMetadata(peopleNames: [], keywords: [])
    let usedExactName =
      !(personName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ?? true)
    let start = Date()

    do {
      let peopleEndpoint = Endpoint(
        operation: operation,
        path: "/drive/v1/search",
        queryItems: commonQueryItems + [
          URLQueryItem(name: "limit", value: "1"),
          URLQueryItem(name: "lowResThumbnail", value: "false"),
          URLQueryItem(name: "searchContext", value: "all"),
          URLQueryItem(name: "groupByForTime", value: "year"),
        ]
      )
      let peopleResponse = try await perform(peopleEndpoint)
      guard (200...299).contains(peopleResponse.response.statusCode) else {
        return AmazonPhotoPeopleProbeOutput(
          report: httpFailureResult(
            for: peopleEndpoint,
            response: peopleResponse.response,
            data: peopleResponse.data,
            duration: peopleResponse.duration
          ),
          privateMetadata: emptyMetadata
        )
      }
      guard
        let person = AmazonPeopleMetadataParser.namedPerson(
          from: peopleResponse.data,
          requestedName: personName
        )
      else {
        return AmazonPhotoPeopleProbeOutput(
          report: ProbeResult(
            provider: .amazon,
            mechanism: .sessionCookie,
            operation: operation,
            status: .failure,
            httpStatus: peopleResponse.response.statusCode,
            durationMilliseconds: peopleResponse.duration,
            responseFieldPaths: (try? SanitizedJSONShape.fieldPaths(from: peopleResponse.data))
              ?? [],
            notes: [
              "Request host: \(region.host)",
              "The global aggregation response did not contain one query-safe People facet matching the local selection.",
            ]
          ),
          privateMetadata: emptyMetadata
        )
      }

      try? await Task.sleep(for: .milliseconds(250))
      let photoEndpoint = Endpoint(
        operation: operation,
        path: "/drive/v1/search",
        queryItems: commonQueryItems + [
          URLQueryItem(name: "limit", value: "1"),
          URLQueryItem(name: "offset", value: "0"),
          URLQueryItem(
            name: "filters",
            value: AmazonPeopleMetadataParser.recognizedPersonSearchFilter(for: person)
          ),
          URLQueryItem(name: "lowResThumbnail", value: "false"),
          URLQueryItem(name: "searchContext", value: "customer"),
          URLQueryItem(name: "sort", value: "['contentProperties.contentDate DESC']"),
        ]
      )
      let photoResponse = try await perform(photoEndpoint)
      guard (200...299).contains(photoResponse.response.statusCode) else {
        return AmazonPhotoPeopleProbeOutput(
          report: httpFailureResult(
            for: photoEndpoint,
            response: photoResponse.response,
            data: photoResponse.data,
            duration: peopleResponse.duration + photoResponse.duration
          ),
          privateMetadata: emptyMetadata
        )
      }
      guard AmazonPeopleMetadataParser.containsPhoto(in: photoResponse.data) else {
        return AmazonPhotoPeopleProbeOutput(
          report: ProbeResult(
            provider: .amazon,
            mechanism: .sessionCookie,
            operation: operation,
            status: .failure,
            httpStatus: photoResponse.response.statusCode,
            durationMilliseconds: peopleResponse.duration + photoResponse.duration,
            responseFieldPaths: (try? SanitizedJSONShape.fieldPaths(from: photoResponse.data))
              ?? [],
            notes: [
              "Request host: \(region.host)",
              "The named People filter did not return a verifiable photo; private values were discarded.",
            ]
          ),
          privateMetadata: emptyMetadata
        )
      }

      let matchingPhotoCount = SanitizedJSONShape.topLevelInteger(
        named: "count", from: photoResponse.data)
      var metadataData = photoResponse.data
      var additionalDuration = 0
      var additionalFieldPaths: [String] = []
      var exactLookupNote =
        "The sampled photo could not be narrowed for a co-People facet check."
      if let photo = AmazonPeopleMetadataParser.latestPhotoLookup(from: photoResponse.data) {
        try? await Task.sleep(for: .milliseconds(250))
        switch try await exactPhotoLookup(for: photo, operation: operation) {
        case .matched(let exactResponse):
          metadataData = exactResponse.data
          additionalDuration = exactResponse.duration
          additionalFieldPaths = try SanitizedJSONShape.fieldPaths(from: exactResponse.data)
          exactLookupNote =
            "The sampled photo was narrowed by \(exactResponse.strategy) to inspect co-People facets."
        case .failed(let report):
          additionalDuration = report.durationMilliseconds ?? 0
          additionalFieldPaths = report.responseFieldPaths
        }
      }

      let responseMetadata = AmazonPeopleMetadataParser.privateMetadata(from: metadataData)
      let privateMetadata = AmazonPrivatePhotoMetadata(
        peopleNames: Array(Set(responseMetadata.peopleNames + [person.name])).sorted(),
        keywords: responseMetadata.keywords
      )
      let responseFieldPaths = try Set(
        SanitizedJSONShape.fieldPaths(from: peopleResponse.data)
          + SanitizedJSONShape.fieldPaths(from: photoResponse.data)
          + additionalFieldPaths
      ).sorted()
      return AmazonPhotoPeopleProbeOutput(
        report: ProbeResult(
          provider: .amazon,
          mechanism: .sessionCookie,
          operation: operation,
          status: .success,
          httpStatus: photoResponse.response.statusCode,
          durationMilliseconds: peopleResponse.duration + photoResponse.duration
            + additionalDuration,
          aggregateCount: matchingPhotoCount,
          responseFieldPaths: responseFieldPaths,
          notes: [
            "Request host: \(region.host)",
            usedExactName
              ? "The supplied local person name matched exactly one People facet; the value was omitted."
              : "No local person name was supplied, so the first query-safe named People facet was selected.",
            "One named People facet selected one matching photo through the documented people filter.",
            "The People filter reported \(matchingPhotoCount ?? 0) matching photos for that person.",
            exactLookupNote,
            "The exact response exposed \(responseMetadata.peopleNames.count) named People facets for the sampled photo.",
            "The confirmed name is displayed only in memory; its cluster ID and photo identifiers were discarded.",
            "Any names beyond the selected person remain experimental co-People metadata.",
          ]
        ),
        privateMetadata: privateMetadata
      )
    } catch let error as ProviderProbeError {
      return AmazonPhotoPeopleProbeOutput(
        report: failureResult(for: operation, start: start, note: error.localizedDescription),
        privateMetadata: emptyMetadata
      )
    } catch let error as URLError {
      return AmazonPhotoPeopleProbeOutput(
        report: failureResult(
          for: operation,
          start: start,
          note: "Network request failed with URL error code \(error.errorCode)."
        ),
        privateMetadata: emptyMetadata
      )
    } catch {
      return AmazonPhotoPeopleProbeOutput(
        report: failureResult(
          for: operation,
          start: start,
          note: "The recognized-photo request failed; provider response values were discarded."
        ),
        privateMetadata: emptyMetadata
      )
    }
  }

  public func probeNamedPersonPagination(
    personName: String? = nil,
    pageSize requestedPageSize: Int = 25
  ) async -> ProbeResult {
    let operation = "Amazon named-person pagination"
    let start = Date()
    let pageSize = min(max(requestedPageSize, 1), 50)
    let usedExactName =
      !(personName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ?? true)

    do {
      let peopleEndpoint = Endpoint(
        operation: operation,
        path: "/drive/v1/search",
        queryItems: commonQueryItems + [
          URLQueryItem(name: "limit", value: "1"),
          URLQueryItem(name: "lowResThumbnail", value: "false"),
          URLQueryItem(name: "searchContext", value: "all"),
          URLQueryItem(name: "groupByForTime", value: "year"),
        ]
      )
      let peopleResponse = try await perform(peopleEndpoint)
      guard (200...299).contains(peopleResponse.response.statusCode) else {
        return httpFailureResult(
          for: peopleEndpoint,
          response: peopleResponse.response,
          data: peopleResponse.data,
          duration: peopleResponse.duration
        )
      }
      guard
        let person = AmazonPeopleMetadataParser.namedPerson(
          from: peopleResponse.data,
          requestedName: personName
        )
      else {
        return failureResult(
          for: operation,
          start: start,
          note: "The local person-name selection did not match exactly one query-safe People facet."
        )
      }

      let basePageItems =
        commonQueryItems + [
          URLQueryItem(name: "limit", value: String(pageSize)),
          URLQueryItem(
            name: "filters",
            value: AmazonPeopleMetadataParser.recognizedPersonSearchFilter(for: person)
          ),
          URLQueryItem(name: "lowResThumbnail", value: "false"),
          URLQueryItem(name: "searchContext", value: "customer"),
          URLQueryItem(name: "sort", value: "['contentProperties.contentDate DESC']"),
        ]

      try? await Task.sleep(for: .milliseconds(250))
      let firstEndpoint = Endpoint(
        operation: operation,
        path: "/drive/v1/search",
        queryItems: basePageItems + [URLQueryItem(name: "offset", value: "0")]
      )
      let firstResponse = try await perform(firstEndpoint)
      guard (200...299).contains(firstResponse.response.statusCode) else {
        return httpFailureResult(
          for: firstEndpoint,
          response: firstResponse.response,
          data: firstResponse.data,
          duration: peopleResponse.duration + firstResponse.duration
        )
      }
      let firstIDs = AmazonPeopleMetadataParser.nodeIDs(
        from: firstResponse.data,
        limit: pageSize
      )
      guard !firstIDs.isEmpty else {
        return ProbeResult(
          provider: .amazon,
          mechanism: .sessionCookie,
          operation: operation,
          status: .failure,
          httpStatus: firstResponse.response.statusCode,
          durationMilliseconds: peopleResponse.duration + firstResponse.duration,
          aggregateCount: SanitizedJSONShape.topLevelInteger(
            named: "count", from: firstResponse.data),
          responseFieldPaths: try SanitizedJSONShape.fieldPaths(from: firstResponse.data),
          notes: [
            "Request host: \(region.host)",
            "The first page did not contain verifiable node IDs.",
          ]
        )
      }

      try? await Task.sleep(for: .milliseconds(250))
      let nextToken = AmazonPeopleMetadataParser.nextToken(from: firstResponse.data)
      let continuationItem =
        nextToken.map { URLQueryItem(name: "nextToken", value: $0) }
        ?? URLQueryItem(name: "offset", value: String(pageSize))
      let paginationStrategy = nextToken == nil ? "offset" : "continuation token"
      let secondEndpoint = Endpoint(
        operation: operation,
        path: "/drive/v1/search",
        queryItems: basePageItems + [continuationItem]
      )
      let secondResponse = try await perform(secondEndpoint)
      guard (200...299).contains(secondResponse.response.statusCode) else {
        return httpFailureResult(
          for: secondEndpoint,
          response: secondResponse.response,
          data: secondResponse.data,
          duration: peopleResponse.duration + firstResponse.duration + secondResponse.duration
        )
      }
      let secondIDs = AmazonPeopleMetadataParser.nodeIDs(
        from: secondResponse.data,
        limit: pageSize
      )
      let overlapCount = firstIDs.intersection(secondIDs).count
      let fields = try Set(
        SanitizedJSONShape.fieldPaths(from: firstResponse.data)
          + SanitizedJSONShape.fieldPaths(from: secondResponse.data)
      ).sorted()
      guard !secondIDs.isEmpty, overlapCount == 0 else {
        return ProbeResult(
          provider: .amazon,
          mechanism: .sessionCookie,
          operation: operation,
          status: .failure,
          httpStatus: secondResponse.response.statusCode,
          durationMilliseconds: peopleResponse.duration + firstResponse.duration
            + secondResponse.duration,
          aggregateCount: SanitizedJSONShape.topLevelInteger(
            named: "count", from: firstResponse.data),
          responseFieldPaths: fields,
          notes: [
            "Request host: \(region.host)",
            "The continuation page was empty or overlapped the first page; identifiers and token were discarded.",
          ]
        )
      }

      return ProbeResult(
        provider: .amazon,
        mechanism: .sessionCookie,
        operation: operation,
        status: .success,
        httpStatus: secondResponse.response.statusCode,
        durationMilliseconds: peopleResponse.duration + firstResponse.duration
          + secondResponse.duration,
        aggregateCount: SanitizedJSONShape.topLevelInteger(
          named: "count", from: firstResponse.data),
        responseFieldPaths: fields,
        notes: [
          "Request host: \(region.host)",
          usedExactName
            ? "The exact local person name matched one People facet; the value was omitted."
            : "The first query-safe named People facet was selected; its value was omitted.",
          "Page 2 used \(paginationStrategy) pagination.",
          "Page 1 returned \(firstIDs.count) unique nodes and page 2 returned \(secondIDs.count).",
          "The two pages had zero overlapping node IDs.",
          "Any continuation token and all node IDs were discarded after comparison.",
        ]
      )
    } catch let error as ProviderProbeError {
      return failureResult(for: operation, start: start, note: error.localizedDescription)
    } catch let error as URLError {
      return failureResult(
        for: operation,
        start: start,
        note: "Network request failed with URL error code \(error.errorCode)."
      )
    } catch {
      return failureResult(
        for: operation,
        start: start,
        note: "The pagination request failed; provider response values were discarded."
      )
    }
  }

  var commonQueryItems: [URLQueryItem] {
    [
      URLQueryItem(name: "asset", value: "ALL"),
      URLQueryItem(name: "tempLink", value: "false"),
      URLQueryItem(name: "resourceVersion", value: "V2"),
      URLQueryItem(name: "ContentType", value: "JSON"),
    ]
  }

  private func exactPhotoLookup(
    for photo: AmazonPrivatePhotoLookup,
    operation: String
  ) async throws -> ExactPhotoLookup {
    var lastFailure: ProbeResult?
    let filters = AmazonPeopleMetadataParser.exactSearchFilters(for: photo)

    for (index, filter) in filters.enumerated() {
      let endpoint = Endpoint(
        operation: operation,
        path: "/drive/v1/search",
        queryItems: commonQueryItems + [
          URLQueryItem(name: "limit", value: "1"),
          URLQueryItem(name: "offset", value: "0"),
          URLQueryItem(name: "filters", value: filter.value),
          URLQueryItem(name: "lowResThumbnail", value: "false"),
          URLQueryItem(name: "searchContext", value: "all"),
          URLQueryItem(name: "groupByForTime", value: "year"),
        ]
      )
      let response = try await perform(endpoint)
      if (200...299).contains(response.response.statusCode) {
        if AmazonPeopleMetadataParser.isExactSinglePhoto(photo, in: response.data) {
          return .matched(
            ExactPhotoMatch(
              data: response.data,
              response: response.response,
              duration: response.duration,
              strategy: filter.label
            ))
        }
        lastFailure = ProbeResult(
          provider: .amazon,
          mechanism: .sessionCookie,
          operation: operation,
          status: .failure,
          httpStatus: response.response.statusCode,
          durationMilliseconds: response.duration,
          responseFieldPaths: (try? SanitizedJSONShape.fieldPaths(from: response.data)) ?? [],
          notes: [
            "Request host: \(region.host)",
            "The \(filter.label) lookup was not one exact ID-and-digest match; private metadata was discarded.",
          ]
        )
      } else {
        lastFailure = httpFailureResult(
          for: endpoint,
          response: response.response,
          data: response.data,
          duration: response.duration
        )
        if response.response.statusCode == 401 || response.response.statusCode == 403 {
          break
        }
      }
      if index < filters.count - 1 {
        try? await Task.sleep(for: .milliseconds(250))
      }
    }

    return .failed(
      lastFailure
        ?? failureResult(
          for: operation,
          start: Date(),
          note: "No supported single-field lookup produced one exact media match."
        ))
  }

  private func execute(_ endpoint: Endpoint) async -> ProbeResult {
    let start = Date()
    do {
      let providerResponse = try await perform(endpoint)
      let data = providerResponse.data
      let httpResponse = providerResponse.response
      let duration = providerResponse.duration
      guard (200...299).contains(httpResponse.statusCode) else {
        return httpFailureResult(
          for: endpoint,
          response: httpResponse,
          data: data,
          duration: duration
        )
      }

      let fields = try SanitizedJSONShape.fieldPaths(from: data)
      return ProbeResult(
        provider: .amazon,
        mechanism: .sessionCookie,
        operation: endpoint.operation,
        status: .success,
        httpStatus: httpResponse.statusCode,
        durationMilliseconds: duration,
        aggregateCount: SanitizedJSONShape.topLevelInteger(named: "count", from: data),
        responseFieldPaths: fields,
        notes: [
          "Request host: \(region.host)",
          "Only response field names and aggregate counts were retained.",
        ]
      )
    } catch let error as ProviderProbeError {
      return failureResult(for: endpoint, start: start, note: error.localizedDescription)
    } catch let error as URLError {
      return failureResult(
        for: endpoint,
        start: start,
        note: "Network request failed with URL error code \(error.errorCode)."
      )
    } catch {
      return failureResult(
        for: endpoint,
        start: start,
        note: "The request failed; provider response values were discarded."
      )
    }
  }

  func perform(_ endpoint: Endpoint) async throws -> (
    data: Data, response: HTTPURLResponse, duration: Int
  ) {
    let start = Date()
    let request = try makeRequest(endpoint)
    let (data, response) = try await session.data(for: request)
    guard data.count <= 2_000_000 else {
      throw ProviderProbeError.responseTooLarge
    }
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ProviderProbeError.invalidResponse
    }
    return (data, httpResponse, Int(Date().timeIntervalSince(start) * 1_000))
  }

  private func makeRequest(_ endpoint: Endpoint) throws -> URLRequest {
    guard Self.allowedPaths.contains(endpoint.path) else {
      throw ProviderProbeError.disallowedRequest
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = region.host
    components.path = endpoint.path
    components.queryItems = endpoint.queryItems

    guard
      let url = components.url,
      url.scheme == "https",
      url.host == region.host,
      Self.allowedPaths.contains(url.path)
    else {
      throw ProviderProbeError.disallowedRequest
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(cookies.normalizedHeader, forHTTPHeaderField: "Cookie")
    request.setValue(cookies.sessionID, forHTTPHeaderField: "x-amzn-sessionid")
    request.setValue("PhotoDeFrigifier-ProviderAccessLab/0.1", forHTTPHeaderField: "User-Agent")
    return request
  }

  private func failureResult(for endpoint: Endpoint, start: Date, note: String) -> ProbeResult {
    failureResult(for: endpoint.operation, start: start, note: note)
  }

  private func failureResult(for operation: String, start: Date, note: String) -> ProbeResult {
    ProbeResult(
      provider: .amazon,
      mechanism: .sessionCookie,
      operation: operation,
      status: .failure,
      durationMilliseconds: Int(Date().timeIntervalSince(start) * 1_000),
      notes: ["Request host: \(region.host)", note]
    )
  }

  private func httpFailureResult(
    for endpoint: Endpoint,
    response: HTTPURLResponse,
    data: Data,
    duration: Int
  ) -> ProbeResult {
    let fields = (try? SanitizedJSONShape.fieldPaths(from: data)) ?? []
    var notes = [
      "Request host: \(region.host)",
      httpFailureNote(status: response.statusCode),
    ]
    if let providerError = SanitizedJSONShape.safeProviderError(from: data) {
      notes.append("Provider error: \(providerError)")
    }
    return ProbeResult(
      provider: .amazon,
      mechanism: .sessionCookie,
      operation: endpoint.operation,
      status: .failure,
      httpStatus: response.statusCode,
      durationMilliseconds: duration,
      responseFieldPaths: fields,
      notes: notes
    )
  }

  private func httpFailureNote(status: Int) -> String {
    switch status {
    case 300...399:
      "Amazon returned a redirect, which the lab blocked to protect session cookies."
    case 400:
      "Amazon rejected this undocumented request shape with HTTP 400."
    case 401, 403:
      "Amazon rejected the temporary session credentials."
    default:
      "Amazon returned unsuccessful HTTP status \(status)."
    }
  }
}
