import AppKit
import ProviderAccessCore
import SwiftUI

private enum LabSection: String, CaseIterable, Identifiable {
  case apple
  case google
  case amazon
  case reports

  var id: String { rawValue }

  var title: String {
    switch self {
    case .apple: "Apple Photos"
    case .google: "Google Photos"
    case .amazon: "Amazon Photos"
    case .reports: "Probe Reports"
    }
  }

  var symbol: String {
    switch self {
    case .apple: "apple.logo"
    case .google: "arrow.up.forward.app"
    case .amazon: "shippingbox"
    case .reports: "doc.text.magnifyingglass"
    }
  }
}

struct ProviderAccessLabView: View {
  @State private var model = LabModel()
  @State private var selection: LabSection? = .apple

  var body: some View {
    NavigationSplitView {
      List(LabSection.allCases, selection: $selection) { section in
        Label(section.title, systemImage: section.symbol)
          .tag(section)
      }
      .navigationTitle("Access Lab")
      .navigationSplitViewColumnWidth(min: 210, ideal: 230)
    } detail: {
      ZStack {
        Color(red: 0.055, green: 0.07, blue: 0.078)
          .ignoresSafeArea()
        detail
          .frame(maxWidth: 840, maxHeight: .infinity, alignment: .topLeading)
          .padding(38)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if let operation = model.activeOperation {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text(operation)
            .font(.system(size: 12, design: .monospaced))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .padding(20)
      }
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch selection ?? .apple {
    case .apple:
      AppleProbePanel(model: model)
    case .google:
      GoogleProbePanel(model: model)
    case .amazon:
      AmazonProbePanel(model: model)
    case .reports:
      ReportsPanel(model: model)
    }
  }
}

private struct AppleProbePanel: View {
  let model: LabModel

  var body: some View {
    LabPage(
      eyebrow: "SUPPORTED LOCAL ACCESS",
      title: "Apple Photos",
      summary:
        "PhotoKit permission is the authorization that actually grants local library access. No Apple login or OIDC token is involved."
    ) {
      LabCard(title: "Read-only inventory", symbol: "photo.on.rectangle.angled") {
        Text(
          "Counts normal and hidden-inclusive assets, media types, favorites, albums, and a bounded sample of resource roles. Filenames and identifiers are not retained."
        )
        .foregroundStyle(.secondary)

        Button("Request Access and Run Inventory") {
          model.runAppleInventory()
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(model.isRunning)
      }

      if let report = model.latestReport(for: .apple) {
        ProbeSummary(report: report)
      }
    }
  }
}

private struct GoogleProbePanel: View {
  let model: LabModel

  var body: some View {
    LabPage(
      eyebrow: "REGISTRATION-FREE BROWSER WORKFLOW",
      title: "Google Photos",
      summary:
        "The lab opens official Google workflows in your system browser. It receives no Google cookies or API token."
    ) {
      LabCard(title: "Official browser handoffs", symbol: "safari") {
        Text(
          "Request a complete Takeout archive or ask Google to transfer supported media directly to iCloud Photos."
        )
        .foregroundStyle(.secondary)

        HStack {
          Button("Open Google Takeout") {
            model.openGoogleTakeout()
          }
          Button("Open iCloud Transfer") {
            model.openGoogleICloudTransfer()
          }
        }
        .buttonStyle(.bordered)
      }

      LabCard(title: "Inspect an expanded Takeout", symbol: "externaldrive") {
        Text(
          "Select a Takeout directory on the external disk. The report contains aggregate media/JSON counts and JSON field names only."
        )
        .foregroundStyle(.secondary)

        Button("Choose Takeout Directory") {
          model.chooseAndInspectGoogleTakeout()
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(model.isRunning)
      }

      if let report = model.latestReport(for: .google) {
        ProbeSummary(report: report)
      }
    }
  }
}

private struct AmazonProbePanel: View {
  let model: LabModel
  @State private var cookieHeader = ""
  @State private var cookieFileStatus: String?
  @State private var includeNamedPeople = true
  @State private var personName = ""
  @State private var region: AmazonRegion = .unitedStates

  var body: some View {
    LabPage(
      eyebrow: "EXPERIMENTAL AND READ-ONLY",
      title: "Amazon Photos",
      summary:
        "Amazon exposes no supported consumer Photos API. This bounded probe uses temporary website-session cookies and may stop working without notice."
    ) {
      LabCard(title: "Temporary session", symbol: "lock.shield") {
        Text(
          "Paste the Cookie request header from an authenticated Amazon Photos browser request. The lab keeps only Amazon authentication/session cookies in memory, auto-detects regional at-acb cookies, and clears this field before sending requests."
        )
        .foregroundStyle(.secondary)

        Picker("Fallback account region", selection: $region) {
          ForEach(AmazonRegion.allCases) { region in
            Text(region.displayName).tag(region)
          }
        }
        .pickerStyle(.menu)

        SecureField("Cookie header", text: $cookieHeader)
          .textFieldStyle(.roundedBorder)

        HStack {
          Button("1. Load Cookie Header File") {
            if let loadedHeader = chooseCookieHeaderFile() {
              cookieHeader = loadedHeader
            }
          }
          .buttonStyle(.bordered)
          .disabled(model.isRunning)

          if let cookieFileStatus {
            Text(cookieFileStatus)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(.secondary)
          }
        }

        TextField("Exact person name (blank selects the first named person)", text: $personName)
          .textFieldStyle(.roundedBorder)

        HStack {
          Button("Run Read-only Metadata Probe") {
            let input = cookieHeader
            cookieHeader = ""
            model.runAmazon(cookieHeader: input, region: region)
          }
          .buttonStyle(.borderedProminent)
          .tint(.orange)
          .disabled(model.isRunning || cookieHeader.isEmpty)

          Button("People on Latest Photo") {
            let input = cookieHeader
            cookieHeader = ""
            model.runAmazonPeopleProbe(cookieHeader: input, region: region)
          }
          .buttonStyle(.bordered)
          .disabled(model.isRunning || cookieHeader.isEmpty)

          Button("Find Recognized Photo") {
            let input = cookieHeader
            cookieHeader = ""
            model.runAmazonRecognizedPeopleProbe(
              cookieHeader: input,
              region: region,
              personName: personName
            )
          }
          .buttonStyle(.bordered)
          .disabled(model.isRunning || cookieHeader.isEmpty)
        }

        Text("Bounded allowlisted GET requests; no downloads or mutations")
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.tertiary)
      }

      LabCard(title: "Complete private metadata export", symbol: "externaldrive.badge.lock") {
        Text(
          "Streams every raw Amazon photo node to atomic JSONL, verifies unique IDs against the reported count, and can add named People-to-photo memberships. No image bytes are downloaded."
        )
        .foregroundStyle(.secondary)

        Text(
          "PRIVATE OUTPUT: filenames, dates, hashes, IDs, locations, device details, labels, and People metadata may be included. Choose an encrypted destination."
        )
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .foregroundStyle(.yellow)

        Toggle("Include named People membership index", isOn: $includeNamedPeople)

        Button("2. Choose Export Folder and Export All Photos") {
          let input = cookieHeader
          cookieHeader = ""
          cookieFileStatus = nil
          model.chooseAndExportAmazonInventory(
            cookieHeader: input,
            region: region,
            includeNamedPeople: includeNamedPeople
          )
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(model.isRunning || cookieHeader.isEmpty)

        Text(
          cookieHeader.isEmpty
            ? "Step 2 is enabled after you load a Cookie header file above or paste a header into the masked field."
            : "Step 2 asks for a folder and creates a timestamped JSONL file inside it."
        )
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)

        if let progress = model.amazonInventoryProgress {
          VStack(alignment: .leading, spacing: 6) {
            ProgressView(
              value: Double(progress.completed),
              total: Double(max(progress.total, 1))
            )
            Text(
              "\(progress.phase.rawValue.uppercased())  \(progress.completed) / \(progress.total)"
            )
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
          }
        }
      }

      if let metadata = model.amazonPrivatePhotoMetadata {
        LabCard(
          title: "Local-only metadata from probed photo", symbol: "person.crop.rectangle.stack"
        ) {
          Text(
            "These values stay in memory and are excluded from Copy Result JSON and exported reports."
          )
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.yellow)

          VStack(alignment: .leading, spacing: 8) {
            Text("PEOPLE")
              .font(.system(size: 10, weight: .bold, design: .monospaced))
              .foregroundStyle(.tertiary)
            Text(
              metadata.peopleNames.isEmpty
                ? "No named people returned" : metadata.peopleNames.joined(separator: "\n")
            )
            .textSelection(.enabled)

            Text("KEYWORDS")
              .font(.system(size: 10, weight: .bold, design: .monospaced))
              .foregroundStyle(.tertiary)
              .padding(.top, 6)
            Text(
              metadata.keywords.isEmpty
                ? "No keywords returned" : metadata.keywords.joined(separator: "\n")
            )
            .textSelection(.enabled)
          }

          Button("Clear Local Metadata") {
            model.clearAmazonPrivatePhotoMetadata()
          }
          .buttonStyle(.bordered)
        }
      }

      ForEach(model.reports(for: .amazon)) { report in
        ProbeSummary(report: report)
      }
    }
  }

  private func chooseCookieHeaderFile() -> String? {
    let panel = NSOpenPanel()
    panel.title = "Choose a temporary Amazon Cookie header file"
    panel.message = "The file is read into memory, validated, and never copied into the export."
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return nil }

    do {
      let header = try AmazonCookieHeaderFile.load(from: url)
      cookieFileStatus = "Cookie header ready"
      return header
    } catch {
      cookieFileStatus = "Cookie file rejected"
      return nil
    }
  }
}

private struct ReportsPanel: View {
  let model: LabModel

  var body: some View {
    LabPage(
      eyebrow: "SANITIZED OUTPUT",
      title: "Probe Reports",
      summary:
        "Reports contain capability status, field paths, aggregate counts, and timing. They never contain credentials or provider object values."
    ) {
      HStack {
        Button("Export JSON") {
          model.exportSanitizedReports()
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(model.reports.isEmpty)

        Button("Clear") {
          model.clearReports()
        }
        .disabled(model.reports.isEmpty)
      }

      if model.reports.isEmpty {
        ContentUnavailableView(
          "No Reports Yet",
          systemImage: "waveform.path.ecg",
          description: Text("Run a provider probe to record sanitized results.")
        )
        .frame(maxWidth: .infinity, minHeight: 300)
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            ForEach(model.reports) { report in
              ProbeSummary(report: report)
            }
          }
        }
      }
    }
  }
}

private struct LabPage<Content: View>: View {
  let eyebrow: String
  let title: String
  let summary: String
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 10) {
          Text(eyebrow)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(1.8)
            .foregroundStyle(.orange)
          Text(title)
            .font(.system(size: 36, weight: .semibold, design: .rounded))
          Text(summary)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 720, alignment: .leading)
        }

        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct LabCard<Content: View>: View {
  let title: String
  let symbol: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label(title, systemImage: symbol)
        .font(.system(size: 17, weight: .semibold))
      content
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.white.opacity(0.055))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.white.opacity(0.07), lineWidth: 1)
    }
  }
}

private struct ProbeSummary: View {
  let report: ProbeResult

  var body: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        Button("Copy Result JSON", systemImage: "doc.on.doc") {
          copyResult()
        }
        .buttonStyle(.bordered)

        if let count = report.aggregateCount {
          LabeledContent("Aggregate count", value: count.formatted())
        }
        if let httpStatus = report.httpStatus {
          LabeledContent("HTTP status", value: httpStatus.formatted())
        }
        if let duration = report.durationMilliseconds {
          LabeledContent("Duration", value: "\(duration) ms")
        }
        ForEach(report.notes, id: \.self) { note in
          Text(note)
            .textSelection(.enabled)
            .foregroundStyle(.secondary)
        }
        if !report.responseFieldPaths.isEmpty {
          Text("FIELD PATHS")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.tertiary)
          Text(report.responseFieldPaths.joined(separator: "\n"))
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.top, 12)
      .textSelection(.enabled)
    } label: {
      HStack {
        Circle()
          .fill(statusColor)
          .frame(width: 8, height: 8)
        VStack(alignment: .leading, spacing: 3) {
          Text(report.operation)
            .font(.system(size: 14, weight: .medium))
          Text("\(report.provider.rawValue) / \(report.mechanism.rawValue)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(18)
    .background(Color.white.opacity(0.04))
    .clipShape(RoundedRectangle(cornerRadius: 7))
  }

  private var statusColor: Color {
    switch report.status {
    case .success: .green
    case .failure: .red
    case .blocked: .yellow
    }
  }

  private func copyResult() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard
      let data = try? encoder.encode(report),
      let json = String(data: data, encoding: .utf8)
    else {
      return
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(json, forType: .string)
  }
}
