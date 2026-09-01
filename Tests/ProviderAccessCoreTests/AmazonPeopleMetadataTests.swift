import Foundation
import Testing

@testable import ProviderAccessCore

@Test func latestPhotoLookupAcceptsOnlyValidatedFields() throws {
  let valid = try #require(
    """
    {
      "data": [
        {
          "id": "node_ID-123",
          "name": "My-Photo_01.jpg",
          "createdDate": "2026-08-31T10:20:30.000Z",
          "contentProperties": {
            "md5": "0123456789ABCDEF0123456789ABCDEF"
          }
        }
      ]
    }
    """.data(using: .utf8)
  )
  let invalid = try #require(
    """
    {
      "data": [
        {
          "id": "node_ID-123",
          "name": "My-Photo_01.jpg",
          "createdDate": "2026-08-31T10:20:30.000Z",
          "contentProperties": {
            "md5": "not-a-digest"
          }
        }
      ]
    }
    """.data(using: .utf8)
  )

  let lookup = try #require(AmazonPeopleMetadataParser.latestPhotoLookup(from: valid))
  #expect(lookup.id == "node_ID-123")
  #expect(lookup.name == "My-Photo_01.jpg")
  #expect(lookup.createdDate == "2026-08-31T10:20:30.000Z")
  #expect(lookup.md5 == "0123456789abcdef0123456789abcdef")
  #expect(AmazonPeopleMetadataParser.latestPhotoLookup(from: invalid) == nil)
}

@Test func exactPhotoFiltersUseDocumentedSingleFieldGrammar() {
  let lookup = AmazonPrivatePhotoLookup(
    id: "node-123",
    name: "2026-08-29_12-16-16_701.heic",
    createdDate: "2026-08-31T10:20:30.000Z",
    md5: "0123456789abcdef0123456789abcdef"
  )

  let filters = AmazonPeopleMetadataParser.exactSearchFilters(for: lookup)

  #expect(filters.count == 2)
  #expect(
    filters[0].value
      == "type:(PHOTOS) AND createdDate:2026-08-31T10:20:30.000Z"
  )
  #expect(filters[1].value == "type:(PHOTOS) AND name:2026-08-29_12-16-16_701.heic")
}

@Test func privatePhotoMetadataParsesNamesAndKeywordsWithoutDuplicates() throws {
  let data = try #require(
    """
    {
      "aggregations": {
        "people": [
          {"searchData": {"clusterName": "Taylor"}},
          {"searchData": {"clusterName": "Alex"}},
          {"searchData": {"clusterName": "Taylor"}},
          {"searchData": {"clusterName": ""}}
        ],
        "allPeople": [
          {"searchData": {"clusterName": "Morgan"}}
        ],
        "clusterId": [
          {"searchData": {"clusterName": "Alex"}}
        ]
      },
      "data": [
        {"keywords": ["vacation", "beach", "vacation"]}
      ]
    }
    """.data(using: .utf8)
  )

  let metadata = AmazonPeopleMetadataParser.privateMetadata(from: data)

  #expect(metadata.peopleNames == ["Alex", "Morgan", "Taylor"])
  #expect(metadata.keywords == ["beach", "vacation"])
}

@Test func namedPersonFacetProducesAQuerySafePeopleFilter() throws {
  let data = try #require(
    """
    {
      "aggregations": {
        "people": [
          {
            "match": "cluster_ID-123",
            "searchData": {"clusterName": "Alex"}
          }
        ]
      }
    }
    """.data(using: .utf8)
  )

  let person = try #require(
    AmazonPeopleMetadataParser.namedPerson(from: data, requestedName: "alex")
  )

  #expect(person == AmazonPrivatePersonLookup(name: "Alex", match: "cluster_ID-123"))
  #expect(
    AmazonPeopleMetadataParser.recognizedPersonSearchFilter(for: person)
      == "type:(PHOTOS) AND people:(cluster_ID-123)"
  )
  #expect(
    AmazonPeopleMetadataParser.namedPerson(from: data, requestedName: "Not Present") == nil
  )
}

@Test func duplicatePersonNamesRequireAnUnambiguousSelection() throws {
  let data = try #require(
    """
    {
      "aggregations": {
        "people": [
          {"match": "cluster-1", "searchData": {"clusterName": "Alex"}},
          {"match": "cluster-2", "searchData": {"clusterName": "Alex"}}
        ]
      }
    }
    """.data(using: .utf8)
  )

  #expect(AmazonPeopleMetadataParser.namedPerson(from: data, requestedName: "Alex") == nil)
  #expect(
    AmazonPeopleMetadataParser.namedPerson(
      from: data,
      requestedName: String(repeating: "a", count: 201)
    ) == nil
  )
}

@Test func filteredResponseMustContainTheRequestedDigest() throws {
  let lookup = AmazonPrivatePhotoLookup(
    id: "node-123",
    name: "My Photo.jpg",
    createdDate: "2026-08-31T10:20:30.000Z",
    md5: "0123456789abcdef0123456789abcdef"
  )
  let data = try #require(
    """
    {
      "count": 1,
      "data": [
        {
          "id": "node-123",
          "contentProperties": {
            "md5": "0123456789ABCDEF0123456789ABCDEF"
          }
        }
      ]
    }
    """.data(using: .utf8)
  )

  #expect(AmazonPeopleMetadataParser.isExactSinglePhoto(lookup, in: data))
  #expect(AmazonPeopleMetadataParser.containsPhoto(in: data))
  let differentLookup = AmazonPrivatePhotoLookup(
    id: "different-node",
    name: lookup.name,
    createdDate: lookup.createdDate,
    md5: lookup.md5
  )
  #expect(!AmazonPeopleMetadataParser.isExactSinglePhoto(differentLookup, in: data))
}

@Test func paginationValuesRemainValidatedAndInMemory() throws {
  let data = try #require(
    """
    {
      "nextToken": "opaque-token_123=",
      "data": [
        {"id": "node-1"},
        {"id": "node_2"},
        {"id": "invalid/id"}
      ]
    }
    """.data(using: .utf8)
  )

  #expect(AmazonPeopleMetadataParser.nextToken(from: data) == "opaque-token_123=")
  #expect(AmazonPeopleMetadataParser.nodeIDs(from: data, limit: 10) == ["node-1", "node_2"])
}

@Test func sanitizedProbeReportDoesNotContainPrivatePhotoMetadata() throws {
  let output = AmazonPhotoPeopleProbeOutput(
    report: ProbeResult(
      provider: .amazon,
      mechanism: .sessionCookie,
      operation: "Amazon People metadata on latest photo",
      status: .success,
      httpStatus: 200,
      aggregateCount: 1,
      responseFieldPaths: ["$.aggregations.people[].searchData.clusterName"]
    ),
    privateMetadata: AmazonPrivatePhotoMetadata(
      peopleNames: ["Sensitive Person Name"],
      keywords: ["Sensitive Keyword"]
    )
  )

  let reportData = try JSONEncoder().encode(output.report)
  let report = try #require(String(data: reportData, encoding: .utf8))

  #expect(!report.contains("Sensitive Person Name"))
  #expect(!report.contains("Sensitive Keyword"))
  #expect(report.contains("clusterName"))
}
