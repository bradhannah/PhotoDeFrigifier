import Photos
import Testing
import UniformTypeIdentifiers

@testable import ApplePhotosAdapter

@Test func appleResourceRolesRemainConservative() {
  #expect(AppleResourceMapper.role(for: .photo, contentType: .jpeg) == .primary)
  #expect(AppleResourceMapper.role(for: .photo, contentType: .rawImage) == .raw)
  #expect(AppleResourceMapper.role(for: .video, contentType: .movie) == .video)
  #expect(AppleResourceMapper.role(for: .audio, contentType: .audio) == .audio)
  #expect(AppleResourceMapper.role(for: .alternatePhoto, contentType: .jpeg) == .original)
  #expect(AppleResourceMapper.role(for: .alternatePhoto, contentType: .rawImage) == .raw)
  #expect(AppleResourceMapper.role(for: .pairedVideo, contentType: .quickTimeMovie) == .pairedVideo)
  #expect(AppleResourceMapper.role(for: .fullSizePhoto, contentType: .jpeg) == .edited)
  #expect(AppleResourceMapper.role(for: .fullSizeVideo, contentType: .movie) == .video)
  #expect(
    AppleResourceMapper.role(for: .fullSizePairedVideo, contentType: .quickTimeMovie)
      == .pairedVideo)
  #expect(AppleResourceMapper.role(for: .adjustmentBasePhoto, contentType: .jpeg) == .original)
  #expect(AppleResourceMapper.role(for: .adjustmentBasePhoto, contentType: .rawImage) == .raw)
  #expect(AppleResourceMapper.role(for: .adjustmentBaseVideo, contentType: .movie) == .video)
  #expect(
    AppleResourceMapper.role(for: .adjustmentBasePairedVideo, contentType: .quickTimeMovie)
      == .pairedVideo)
  #expect(AppleResourceMapper.role(for: .photoProxy, contentType: .jpeg) == .edited)
  #expect(AppleResourceMapper.role(for: .adjustmentData, contentType: .data) == .sidecar)
  #expect(!AppleResourceMapper.shouldMeasure(.adjustmentData))
  #expect(AppleResourceMapper.shouldMeasure(.photo))
}
