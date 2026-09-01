import AppKit
import Foundation
import Observation
import ProviderAccessCore

@MainActor
@Observable
final class LabModel {
  private(set) var reports: [ProbeResult] = []
  private(set) var isRunning = false
  private(set) var activeOperation: String?
  private(set) var amazonPrivatePhotoMetadata: AmazonPrivatePhotoMetadata?
  private(set) var amazonInventoryProgress: AmazonInventoryProgress?

  func runAppleInventory() {
    run(operation: "Requesting PhotoKit access") {
      [await ApplePhotosProbe.runInventory()]
    }
  }

  func openGoogleTakeout() {
    openGoogleWorkflow(
      url: GoogleBrowserWorkflow.takeoutURL,
      operation: "Open Google Takeout"
    )
  }

  func openGoogleICloudTransfer() {
    openGoogleWorkflow(
      url: GoogleBrowserWorkflow.iCloudTransferURL,
      operation: "Open Google-to-iCloud transfer"
    )
  }

  func chooseAndInspectGoogleTakeout() {
    let panel = NSOpenPanel()
    panel.title = "Choose an expanded Google Takeout directory"
    panel.message =
      "The lab records aggregate counts and JSON field names, not filenames or values."
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false

    guard panel.runModal() == .OK, let directory = panel.url else { return }
    run(operation: "Inspecting Google Takeout") {
      do {
        return [try await GoogleTakeoutInspector.inspect(directory: directory)]
      } catch {
        return [
          ProbeResult(
            provider: .google,
            mechanism: .manualExport,
            operation: "Inspect expanded Google Takeout",
            status: .failure,
            notes: ["The selected directory could not be inspected; no paths were retained."]
          )
        ]
      }
    }
  }

  func runAmazon(cookieHeader: String, region: AmazonRegion) {
    amazonPrivatePhotoMetadata = nil
    run(operation: "Running Amazon read-only metadata probe") {
      do {
        let cookies = try AmazonSessionCookies(cookieHeader: cookieHeader)
        let effectiveRegion = cookies.inferredRegion ?? region
        let probe = AmazonPhotosProbe(region: effectiveRegion, cookies: cookies)
        return await probe.runMetadataProbe()
      } catch let error as ProviderProbeError {
        return [
          ProbeResult(
            provider: .amazon,
            mechanism: .sessionCookie,
            operation: "Validate temporary Amazon cookies",
            status: .failure,
            notes: [error.localizedDescription]
          )
        ]
      } catch {
        return [
          ProbeResult(
            provider: .amazon,
            mechanism: .sessionCookie,
            operation: "Validate temporary Amazon cookies",
            status: .failure,
            notes: ["Cookie validation failed; the input was discarded."]
          )
        ]
      }
    }
  }

  func runAmazonPeopleProbe(cookieHeader: String, region: AmazonRegion) {
    amazonPrivatePhotoMetadata = nil
    run(operation: "Probing People metadata on the latest Amazon photo") {
      do {
        let cookies = try AmazonSessionCookies(cookieHeader: cookieHeader)
        let effectiveRegion = cookies.inferredRegion ?? region
        let probe = AmazonPhotosProbe(region: effectiveRegion, cookies: cookies)
        let output = await probe.probePeopleOnLatestPhoto()
        if output.report.status == .success {
          self.amazonPrivatePhotoMetadata = output.privateMetadata
        }
        return [output.report]
      } catch let error as ProviderProbeError {
        return [
          ProbeResult(
            provider: .amazon,
            mechanism: .sessionCookie,
            operation: "Validate temporary Amazon cookies for People probe",
            status: .failure,
            notes: [error.localizedDescription]
          )
        ]
      } catch {
        return [
          ProbeResult(
            provider: .amazon,
            mechanism: .sessionCookie,
            operation: "Validate temporary Amazon cookies for People probe",
            status: .failure,
            notes: ["Cookie validation failed; the input was discarded."]
          )
        ]
      }
    }
  }

  func runAmazonRecognizedPeopleProbe(
    cookieHeader: String,
    region: AmazonRegion,
    personName: String
  ) {
    amazonPrivatePhotoMetadata = nil
    run(operation: "Finding an Amazon photo through a named People facet") {
      do {
        let cookies = try AmazonSessionCookies(cookieHeader: cookieHeader)
        let effectiveRegion = cookies.inferredRegion ?? region
        let probe = AmazonPhotosProbe(region: effectiveRegion, cookies: cookies)
        let output = await probe.probeNamedPersonOnRecognizedPhoto(personName: personName)
        if output.report.status == .success {
          self.amazonPrivatePhotoMetadata = output.privateMetadata
        }
        return [output.report]
      } catch let error as ProviderProbeError {
        return [
          ProbeResult(
            provider: .amazon,
            mechanism: .sessionCookie,
            operation: "Validate temporary Amazon cookies for recognized People probe",
            status: .failure,
            notes: [error.localizedDescription]
          )
        ]
      } catch {
        return [
          ProbeResult(
            provider: .amazon,
            mechanism: .sessionCookie,
            operation: "Validate temporary Amazon cookies for recognized People probe",
            status: .failure,
            notes: ["Cookie validation failed; the input was discarded."]
          )
        ]
      }
    }
  }

  func chooseAndExportAmazonInventory(
    cookieHeader: String,
    region: AmazonRegion,
    includeNamedPeople: Bool
  ) {
    let panel = NSOpenPanel()
    panel.title = "Choose a folder for private Amazon photo metadata"
    panel.message =
      "Choose an encrypted or otherwise private folder. The app will create a timestamped JSONL file containing filenames, dates, hashes, provider IDs, locations, and optional People metadata."
    panel.prompt = "Choose Export Folder"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let directory = panel.url else { return }
    let timestamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let destination = directory.appendingPathComponent(
      "amazon-private-photo-inventory-\(timestamp).jsonl"
    )

    amazonInventoryProgress = nil
    run(operation: "Exporting complete private Amazon photo metadata") {
      do {
        let cookies = try AmazonSessionCookies(cookieHeader: cookieHeader)
        let effectiveRegion = cookies.inferredRegion ?? region
        let probe = AmazonPhotosProbe(region: effectiveRegion, cookies: cookies)
        let result = await probe.exportPrivatePhotoInventory(
          to: destination,
          includeNamedPeople: includeNamedPeople,
          progress: { [weak self] progress in
            await MainActor.run {
              self?.amazonInventoryProgress = progress
            }
          }
        )
        return [result]
      } catch let error as ProviderProbeError {
        return [
          ProbeResult(
            provider: .amazon,
            mechanism: .sessionCookie,
            operation: "Validate temporary Amazon cookies for private inventory export",
            status: .failure,
            notes: [error.localizedDescription]
          )
        ]
      } catch {
        return [
          ProbeResult(
            provider: .amazon,
            mechanism: .sessionCookie,
            operation: "Validate temporary Amazon cookies for private inventory export",
            status: .failure,
            notes: ["Cookie validation failed; the input was discarded."]
          )
        ]
      }
    }
  }

  func exportSanitizedReports() {
    guard !reports.isEmpty else { return }

    let panel = NSSavePanel()
    panel.title = "Export sanitized provider report"
    panel.nameFieldStringValue = "provider-access-report.json"
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(reports)
      try data.write(to: destination, options: .atomic)
    } catch {
      reports.insert(
        ProbeResult(
          provider: .apple,
          mechanism: .manualExport,
          operation: "Export sanitized report",
          status: .failure,
          notes: ["The report could not be written to the selected destination."]
        ),
        at: 0
      )
    }
  }

  func clearReports() {
    reports.removeAll()
    amazonPrivatePhotoMetadata = nil
    amazonInventoryProgress = nil
  }

  func clearAmazonPrivatePhotoMetadata() {
    amazonPrivatePhotoMetadata = nil
  }

  func latestReport(for provider: ProviderKind) -> ProbeResult? {
    reports.first { $0.provider == provider }
  }

  func reports(for provider: ProviderKind) -> [ProbeResult] {
    reports.filter { $0.provider == provider }
  }

  private func openGoogleWorkflow(url: URL, operation: String) {
    let opened = NSWorkspace.shared.open(url)
    reports.insert(
      ProbeResult(
        provider: .google,
        mechanism: .browserHandoff,
        operation: operation,
        status: opened ? .success : .failure,
        notes: [
          opened
            ? "Opened in the system browser; no browser session data was shared with the lab."
            : "The system browser could not open the provider workflow."
        ]
      ),
      at: 0
    )
  }

  private func run(
    operation: String,
    work: @escaping @MainActor () async -> [ProbeResult]
  ) {
    guard !isRunning else { return }
    isRunning = true
    activeOperation = operation
    Task {
      let newReports = await work()
      reports.insert(contentsOf: newReports.reversed(), at: 0)
      activeOperation = nil
      isRunning = false
    }
  }
}
