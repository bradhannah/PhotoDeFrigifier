import AppKit
import PhotoCatalogCore
import SwiftUI

@main
struct PhotoDeFrigifierApp: App {
  var body: some Scene {
    WindowGroup {
      PhotoDeFrigifierHome()
    }
    .defaultSize(width: 980, height: 680)
  }
}

private struct PhotoDeFrigifierHome: View {
  @State private var launchMessage: String?
  @State private var catalogMessage: String?
  @State private var isBuildingCatalog = false

  var body: some View {
    ZStack {
      Color(red: 0.06, green: 0.08, blue: 0.09)
        .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 28) {
        Text("PHOTO DEFRIGIFIER")
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
          .tracking(2.4)
          .foregroundStyle(Color(red: 0.91, green: 0.49, blue: 0.30))

        Text("One library.\nEvery original accounted for.")
          .font(.system(size: 42, weight: .medium, design: .rounded))
          .foregroundStyle(.white)

        Text(
          "Build a private canonical catalog from a completed provider inventory, then use "
            + "the Access Lab to validate additional sources."
        )
        .font(.system(size: 17))
        .foregroundStyle(.secondary)
        .frame(maxWidth: 620, alignment: .leading)

        HStack(spacing: 12) {
          Button("Create or Update Catalog") {
            chooseAndBuildCatalog()
          }
          .buttonStyle(.borderedProminent)
          .tint(.orange)
          .disabled(isBuildingCatalog)

          Button("Open Provider Access Lab") {
            openProviderAccessLab()
          }
          .buttonStyle(.bordered)

          Button("Read Plan Details") {
            openPlanDetails()
          }
          .buttonStyle(.bordered)
        }

        VStack(alignment: .leading, spacing: 8) {
          Text(
            "PRIVATE OUTPUT: the catalog retains raw source metadata, filenames, dates, "
              + "hashes, locations, and People claims. Choose encrypted storage."
          )
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(.yellow)

          Text(
            "Amazon MD5 matches are indexed for review only. Automatic matches require "
              + "locally measured SHA-256 and byte length."
          )
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)

          if isBuildingCatalog {
            HStack(spacing: 9) {
              ProgressView()
                .controlSize(.small)
              Text("IMPORTING AND VALIDATING CATALOG")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            }
          } else if let catalogMessage {
            Text(catalogMessage)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: 720, alignment: .leading)

        if let launchMessage {
          Text(launchMessage)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.yellow)
        }

        HStack(spacing: 12) {
          phase("01", "Inventory", active: true)
          phase("02", "Reconcile", active: false)
          phase("03", "Migrate", active: false)
          phase("04", "Verify", active: false)
        }

        Spacer()

        Text("Inventory catalog foundation active")
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.tertiary)
      }
      .padding(52)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
  }

  private func chooseAndBuildCatalog() {
    let sourcePanel = NSOpenPanel()
    sourcePanel.title = "Choose a completed Amazon private inventory"
    sourcePanel.message = "The JSONL inventory is read locally and is never uploaded."
    sourcePanel.prompt = "Choose Inventory"
    sourcePanel.canChooseDirectories = false
    sourcePanel.canChooseFiles = true
    sourcePanel.allowsMultipleSelection = false
    guard sourcePanel.runModal() == .OK, let source = sourcePanel.url else { return }

    let destinationPanel = NSSavePanel()
    destinationPanel.title = "Create or update a private canonical catalog"
    destinationPanel.message =
      "Choose encrypted storage. Selecting an existing PhotoDeFrigifier catalog merges a new observation run without discarding earlier claims."
    destinationPanel.prompt = "Create or Update Catalog"
    destinationPanel.nameFieldStringValue = "photo-defrigifier-catalog.jsonl"
    guard destinationPanel.runModal() == .OK, let destination = destinationPanel.url else { return }

    isBuildingCatalog = true
    catalogMessage = nil
    Task {
      do {
        let result = try await Task.detached {
          let sourceAccess = source.startAccessingSecurityScopedResource()
          let destinationAccess = destination.startAccessingSecurityScopedResource()
          defer {
            if sourceAccess { source.stopAccessingSecurityScopedResource() }
            if destinationAccess { destination.stopAccessingSecurityScopedResource() }
          }

          let incoming = try AmazonCatalogImporter().importCatalog(from: source)
          let catalog = try CatalogJSONLStore.update(at: destination, importing: incoming)
          let identity = CatalogIdentityIndex(snapshot: catalog)
          return CatalogBuildResult(
            assets: catalog.assets.count,
            claims: catalog.metadataClaims.count,
            sourceRuns: catalog.importRuns.count,
            automaticMatches: identity.automaticMatches.count,
            reviewCandidates: identity.reportedDigestCandidates.count
          )
        }.value
        catalogMessage =
          "CATALOG READY  \(result.assets) assets  \(result.claims) claims  "
          + "\(result.sourceRuns) source runs  \(result.automaticMatches) exact matches  "
          + "\(result.reviewCandidates) digest candidates"
      } catch {
        catalogMessage =
          "CATALOG FAILED  The selected inventory or catalog could not be validated and written; existing source data was not changed."
      }
      isBuildingCatalog = false
    }
  }

  private func phase(_ number: String, _ title: String, active: Bool) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(number)
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .foregroundStyle(active ? Color.orange : Color.secondary)
      Text(title)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(active ? Color.white : Color.secondary)
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 18)
    .frame(width: 132, alignment: .leading)
    .background(active ? Color.white.opacity(0.09) : Color.white.opacity(0.035))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private func openProviderAccessLab() {
    let labURL = Bundle.main.bundleURL
      .deletingLastPathComponent()
      .appending(path: "Provider Access Lab.app", directoryHint: .isDirectory)

    guard FileManager.default.fileExists(atPath: labURL.path) else {
      launchMessage = "Provider Access Lab is missing. Run `make package` and try again."
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.openApplication(at: labURL, configuration: configuration) { _, error in
      Task { @MainActor in
        launchMessage = error == nil ? nil : "Provider Access Lab could not be opened."
      }
    }
  }

  private func openPlanDetails() {
    guard let planURL = Bundle.main.url(forResource: "PLAN_DETAILS", withExtension: "md") else {
      launchMessage = "The bundled plan document could not be found."
      return
    }
    launchMessage =
      NSWorkspace.shared.open(planURL) ? nil : "The plan document could not be opened."
  }
}

private struct CatalogBuildResult: Sendable {
  let assets: Int
  let claims: Int
  let sourceRuns: Int
  let automaticMatches: Int
  let reviewCandidates: Int
}
