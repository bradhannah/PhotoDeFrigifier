import Foundation

public struct AmazonInventoryProgress: Equatable, Sendable {
  public enum Phase: String, Sendable {
    case preparing
    case photos
    case people
    case finalizing
  }

  public let phase: Phase
  public let completed: Int
  public let total: Int

  public init(phase: Phase, completed: Int, total: Int) {
    self.phase = phase
    self.completed = completed
    self.total = total
  }
}

private enum AmazonInventoryExportError: Error {
  case invalidDestination
  case invalidJSON
  case httpStatus(Int)
  case malformedResponse
  case countChanged
  case incompletePhotoInventory
  case incompletePeopleInventory
}

final class AmazonPrivateJSONLWriter {
  private let destination: URL
  private let temporaryURL: URL
  private let handle: FileHandle
  private var isClosed = false
  private var isFinalized = false

  init(destination: URL) throws {
    guard destination.isFileURL else { throw AmazonInventoryExportError.invalidDestination }
    self.destination = destination
    temporaryURL = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).partial"
    )

    let fileManager = FileManager.default
    guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
      throw AmazonInventoryExportError.invalidDestination
    }
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: temporaryURL.path
    )
    handle = try FileHandle(forWritingTo: temporaryURL)
  }

  deinit {
    try? close()
    if !isFinalized {
      try? FileManager.default.removeItem(at: temporaryURL)
    }
  }

  func write(_ object: [String: Any]) throws {
    guard JSONSerialization.isValidJSONObject(object) else {
      throw AmazonInventoryExportError.invalidJSON
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try handle.write(contentsOf: data)
    try handle.write(contentsOf: Data([0x0A]))
  }

  func finalize() throws {
    try handle.synchronize()
    try close()

    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
    } else {
      try fileManager.moveItem(at: temporaryURL, to: destination)
    }
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destination.path
    )
    isFinalized = true
  }

  private func close() throws {
    guard !isClosed else { return }
    try handle.close()
    isClosed = true
  }
}

extension AmazonPhotosProbe {
  public func exportPrivatePhotoInventory(
    to destination: URL,
    includeNamedPeople: Bool = true,
    progress: (@Sendable (AmazonInventoryProgress) async -> Void)? = nil
  ) async -> ProbeResult {
    let operation = "Export private Amazon photo metadata inventory"
    let start = Date()
    let pageSize = 100
    var httpStatus: Int?

    do {
      let writer = try AmazonPrivateJSONLWriter(destination: destination)
      let capturedAt = ISO8601DateFormatter().string(from: start)
      try writer.write([
        "recordType": "manifest",
        "schemaVersion": 1,
        "provider": "amazon",
        "capturedAt": capturedAt,
        "scope": "customer photos",
        "containsPrivateMetadata": true,
      ])
      await progress?(AmazonInventoryProgress(phase: .preparing, completed: 0, total: 3))

      var fieldPaths = Set<String>()
      let usageEndpoint = Endpoint(
        operation: operation,
        path: "/drive/v1/account/usage",
        queryItems: commonQueryItems
      )
      let usageResponse = try await perform(usageEndpoint)
      httpStatus = usageResponse.response.statusCode
      guard (200...299).contains(usageResponse.response.statusCode) else {
        throw AmazonInventoryExportError.httpStatus(usageResponse.response.statusCode)
      }
      let usage = try jsonObject(from: usageResponse.data)
      try writer.write(["recordType": "accountUsage", "value": usage])
      fieldPaths.formUnion(try SanitizedJSONShape.fieldPaths(from: usageResponse.data))
      await progress?(AmazonInventoryProgress(phase: .preparing, completed: 1, total: 3))

      try? await Task.sleep(for: .milliseconds(200))
      let rootEndpoint = Endpoint(
        operation: operation,
        path: "/drive/v1/nodes",
        queryItems: commonQueryItems + [URLQueryItem(name: "filters", value: "isRoot:true")]
      )
      let rootResponse = try await perform(rootEndpoint)
      httpStatus = rootResponse.response.statusCode
      guard (200...299).contains(rootResponse.response.statusCode) else {
        throw AmazonInventoryExportError.httpStatus(rootResponse.response.statusCode)
      }
      let root = try jsonObject(from: rootResponse.data)
      try writer.write(["recordType": "rootMetadata", "value": root])
      fieldPaths.formUnion(try SanitizedJSONShape.fieldPaths(from: rootResponse.data))
      await progress?(AmazonInventoryProgress(phase: .preparing, completed: 2, total: 3))

      try? await Task.sleep(for: .milliseconds(200))
      let aggregationEndpoint = Endpoint(
        operation: operation,
        path: "/drive/v1/search",
        queryItems: commonQueryItems + [
          URLQueryItem(name: "limit", value: "1"),
          URLQueryItem(name: "lowResThumbnail", value: "false"),
          URLQueryItem(name: "searchContext", value: "all"),
          URLQueryItem(name: "groupByForTime", value: "year"),
        ]
      )
      let aggregationResponse = try await perform(aggregationEndpoint)
      httpStatus = aggregationResponse.response.statusCode
      guard (200...299).contains(aggregationResponse.response.statusCode) else {
        throw AmazonInventoryExportError.httpStatus(aggregationResponse.response.statusCode)
      }
      let aggregationRoot = try jsonObject(from: aggregationResponse.data)
      guard let aggregations = aggregationRoot["aggregations"] else {
        throw AmazonInventoryExportError.malformedResponse
      }
      try writer.write(["recordType": "aggregations", "value": aggregations])
      fieldPaths.formUnion(try SanitizedJSONShape.fieldPaths(from: aggregationResponse.data))
      let namedPeople = AmazonPeopleMetadataParser.namedPeople(from: aggregationResponse.data)
      await progress?(AmazonInventoryProgress(phase: .preparing, completed: 3, total: 3))

      var expectedPhotoCount: Int?
      var photoIDs = Set<String>()
      var duplicatePhotoCount = 0
      var offset = 0
      var photoPageCount = 0

      while expectedPhotoCount == nil || offset < expectedPhotoCount! {
        try Task.checkCancellation()
        let endpoint = searchEndpoint(
          operation: operation,
          filter: "type:(PHOTOS)",
          limit: pageSize,
          offset: offset
        )
        let response = try await perform(endpoint)
        httpStatus = response.response.statusCode
        guard (200...299).contains(response.response.statusCode) else {
          throw AmazonInventoryExportError.httpStatus(response.response.statusCode)
        }
        let root = try jsonObject(from: response.data)
        guard
          let pageCount = (root["count"] as? NSNumber)?.intValue,
          let nodes = root["data"] as? [[String: Any]]
        else {
          throw AmazonInventoryExportError.malformedResponse
        }
        if let expectedPhotoCount, pageCount != expectedPhotoCount {
          throw AmazonInventoryExportError.countChanged
        }
        expectedPhotoCount = pageCount
        guard !nodes.isEmpty || offset >= pageCount else {
          throw AmazonInventoryExportError.incompletePhotoInventory
        }

        for node in nodes {
          guard
            let nodeID = AmazonPeopleMetadataParser.validatedNodeID(node["id"] as? String)
          else {
            throw AmazonInventoryExportError.malformedResponse
          }
          if photoIDs.insert(nodeID).inserted {
            try writer.write(["recordType": "photoNode", "value": node])
          } else {
            duplicatePhotoCount += 1
          }
        }
        fieldPaths.formUnion(try SanitizedJSONShape.fieldPaths(from: response.data))
        photoPageCount += 1
        offset += pageSize
        await progress?(
          AmazonInventoryProgress(
            phase: .photos,
            completed: min(photoIDs.count, pageCount),
            total: pageCount
          ))
        if offset < pageCount {
          try? await Task.sleep(for: .milliseconds(200))
        }
      }

      guard let expectedPhotoCount, photoIDs.count == expectedPhotoCount else {
        throw AmazonInventoryExportError.incompletePhotoInventory
      }

      var membershipCount = 0
      var peoplePageCount = 0
      if includeNamedPeople {
        for (personIndex, person) in namedPeople.enumerated() {
          try Task.checkCancellation()
          var personOffset = 0
          var expectedPersonCount: Int?
          var personPhotoIDs = Set<String>()
          try writer.write([
            "recordType": "person",
            "personKey": person.match,
            "name": person.name,
          ])

          while expectedPersonCount == nil || personOffset < expectedPersonCount! {
            let endpoint = searchEndpoint(
              operation: operation,
              filter: AmazonPeopleMetadataParser.recognizedPersonSearchFilter(for: person),
              limit: pageSize,
              offset: personOffset
            )
            let response = try await perform(endpoint)
            httpStatus = response.response.statusCode
            guard (200...299).contains(response.response.statusCode) else {
              throw AmazonInventoryExportError.httpStatus(response.response.statusCode)
            }
            let root = try jsonObject(from: response.data)
            guard
              let pageCount = (root["count"] as? NSNumber)?.intValue,
              let nodes = root["data"] as? [[String: Any]]
            else {
              throw AmazonInventoryExportError.malformedResponse
            }
            if let expectedPersonCount, pageCount != expectedPersonCount {
              throw AmazonInventoryExportError.countChanged
            }
            expectedPersonCount = pageCount

            for node in nodes {
              guard
                let nodeID = AmazonPeopleMetadataParser.validatedNodeID(node["id"] as? String),
                photoIDs.contains(nodeID)
              else {
                throw AmazonInventoryExportError.incompletePeopleInventory
              }
              if personPhotoIDs.insert(nodeID).inserted {
                try writer.write([
                  "recordType": "personMembership",
                  "personKey": person.match,
                  "photoNodeId": nodeID,
                ])
                membershipCount += 1
              }
            }
            fieldPaths.formUnion(try SanitizedJSONShape.fieldPaths(from: response.data))
            peoplePageCount += 1
            personOffset += pageSize
            if personOffset < pageCount {
              try? await Task.sleep(for: .milliseconds(200))
            }
          }

          guard personPhotoIDs.count == expectedPersonCount else {
            throw AmazonInventoryExportError.incompletePeopleInventory
          }
          await progress?(
            AmazonInventoryProgress(
              phase: .people,
              completed: personIndex + 1,
              total: namedPeople.count
            ))
        }
      }

      await progress?(AmazonInventoryProgress(phase: .finalizing, completed: 0, total: 1))
      try writer.write([
        "recordType": "summary",
        "expectedPhotoCount": expectedPhotoCount,
        "uniquePhotoCount": photoIDs.count,
        "duplicatePhotoCount": duplicatePhotoCount,
        "photoPageCount": photoPageCount,
        "namedPersonCount": includeNamedPeople ? namedPeople.count : 0,
        "personMembershipCount": membershipCount,
        "peoplePageCount": peoplePageCount,
        "complete": true,
      ])
      try writer.finalize()
      await progress?(AmazonInventoryProgress(phase: .finalizing, completed: 1, total: 1))

      return ProbeResult(
        provider: .amazon,
        mechanism: .sessionCookie,
        operation: operation,
        status: .success,
        httpStatus: httpStatus,
        durationMilliseconds: Int(Date().timeIntervalSince(start) * 1_000),
        aggregateCount: photoIDs.count,
        responseFieldPaths: fieldPaths.sorted(),
        notes: [
          "Request host: \(region.host)",
          "A private mode-0600 JSONL inventory was written to the user-selected destination.",
          "Exported \(photoIDs.count) unique raw photo nodes across \(photoPageCount) pages.",
          "Observed \(duplicatePhotoCount) duplicate page entries while enforcing unique node IDs.",
          includeNamedPeople
            ? "Indexed \(membershipCount) memberships across \(namedPeople.count) named People clusters."
            : "Named People membership indexing was disabled.",
          "Cookies, continuation tokens, and request URLs were not written.",
        ]
      )
    } catch let error as AmazonInventoryExportError {
      let note: String
      switch error {
      case .invalidDestination:
        note = "The private export destination could not be prepared."
      case .invalidJSON, .malformedResponse:
        note = "Amazon returned metadata that could not be preserved as valid JSONL."
      case .httpStatus(let status):
        note =
          status == 401 || status == 403
          ? "Amazon rejected the temporary session credentials."
          : "Amazon rejected one inventory request with HTTP \(status)."
      case .countChanged:
        note = "The provider count changed during pagination; the incomplete export was discarded."
      case .incompletePhotoInventory:
        note =
          "Unique photo nodes did not match the reported count; the incomplete export was discarded."
      case .incompletePeopleInventory:
        note =
          "A People membership page was incomplete or referenced an unknown photo; the export was discarded."
      }
      return inventoryFailureResult(
        operation: operation,
        start: start,
        httpStatus: httpStatus,
        note: note
      )
    } catch is CancellationError {
      return inventoryFailureResult(
        operation: operation,
        start: start,
        httpStatus: httpStatus,
        note: "The private inventory was cancelled and its partial file was discarded."
      )
    } catch {
      return inventoryFailureResult(
        operation: operation,
        start: start,
        httpStatus: httpStatus,
        note: "The private inventory failed and its partial file was discarded."
      )
    }
  }

  private func searchEndpoint(
    operation: String,
    filter: String,
    limit: Int,
    offset: Int
  ) -> Endpoint {
    Endpoint(
      operation: operation,
      path: "/drive/v1/search",
      queryItems: commonQueryItems + [
        URLQueryItem(name: "limit", value: String(limit)),
        URLQueryItem(name: "offset", value: String(offset)),
        URLQueryItem(name: "filters", value: filter),
        URLQueryItem(name: "lowResThumbnail", value: "false"),
        URLQueryItem(name: "searchContext", value: "customer"),
        URLQueryItem(name: "sort", value: "['createdDate DESC']"),
      ]
    )
  }

  private func jsonObject(from data: Data) throws -> [String: Any] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AmazonInventoryExportError.malformedResponse
    }
    return root
  }

  private func inventoryFailureResult(
    operation: String,
    start: Date,
    httpStatus: Int?,
    note: String
  ) -> ProbeResult {
    ProbeResult(
      provider: .amazon,
      mechanism: .sessionCookie,
      operation: operation,
      status: .failure,
      httpStatus: httpStatus,
      durationMilliseconds: Int(Date().timeIntervalSince(start) * 1_000),
      notes: ["Request host: \(region.host)", note]
    )
  }
}
