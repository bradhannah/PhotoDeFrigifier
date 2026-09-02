import PhotoCatalogCore
import SwiftUI

@main
struct PhotoDeFrigifierApp: App {
  @State private var session = LibraryProjectSession()

  var body: some Scene {
    WindowGroup {
      Group {
        if session.project == nil {
          WelcomeView(session: session)
        } else {
          ProjectWorkspace(session: session)
        }
      }
      .tint(.orange)
      .onOpenURL { session.openProject(at: $0) }
      .alert(item: $session.notice) { notice in
        Alert(
          title: Text(notice.title),
          message: Text(notice.message),
          dismissButton: .default(Text("OK"))
        )
      }
    }
    .defaultSize(width: 1_180, height: 760)
    .windowResizability(.contentMinSize)
  }
}

private struct WelcomeView: View {
  let session: LibraryProjectSession

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(nsColor: .windowBackgroundColor),
          Color.orange.opacity(0.055),
          Color(nsColor: .windowBackgroundColor),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 0) {
        Text("PHOTO DEFRIGIFIER")
          .font(.system(size: 12, weight: .semibold, design: .monospaced))
          .tracking(2.2)
          .foregroundStyle(.orange)

        Spacer()

        Text("Bring the scattered library\nback into focus.")
          .font(.system(size: 46, weight: .medium, design: .rounded))
          .tracking(-1.2)

        Text(
          "Gather an evidence-first catalog from every source. Nothing moves, uploads, or "
            + "changes until you review a plan."
        )
        .font(.system(size: 17))
        .foregroundStyle(.secondary)
        .lineSpacing(4)
        .frame(maxWidth: 610, alignment: .leading)
        .padding(.top, 20)

        HStack(spacing: 12) {
          Button("Start a Library Project") {
            session.chooseAndCreateProject()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)

          Button("Open Existing Project") {
            session.chooseAndOpenProject()
          }
          .buttonStyle(.bordered)
          .controlSize(.large)
        }
        .padding(.top, 32)

        Spacer()

        HStack(spacing: 22) {
          assurance("lock.shield", "Private local catalog")
          assurance("hand.raised", "Sources stay untouched")
          assurance("checkmark.seal", "Exact matches require measured bytes")
        }
        .foregroundStyle(.secondary)
      }
      .padding(56)
      .frame(maxWidth: 940, maxHeight: 700, alignment: .leading)
    }
    .frame(minWidth: 780, minHeight: 600)
  }

  private func assurance(_ icon: String, _ label: String) -> some View {
    Label(label, systemImage: icon)
      .font(.system(size: 12, weight: .medium))
  }
}

private enum WorkspaceSection: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case sources = "Sources"
  case matches = "Matches"
  case people = "People"
  case destinations = "Destinations"
  case review = "Review"
  case verify = "Verify"
  case advanced = "Advanced"

  var id: Self { self }

  var icon: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .sources: "externaldrive"
    case .matches: "link"
    case .people: "person.2"
    case .destinations: "arrow.triangle.branch"
    case .review: "checklist"
    case .verify: "checkmark.seal"
    case .advanced: "slider.horizontal.3"
    }
  }
}

private struct ProjectWorkspace: View {
  let session: LibraryProjectSession
  @State private var selection: WorkspaceSection? = .overview
  @State private var showsAddSource = false

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Section {
          ForEach(WorkspaceSection.allCases.dropLast()) { section in
            Label(section.rawValue, systemImage: section.icon)
              .tag(section)
          }
        }
        Section {
          Label(WorkspaceSection.advanced.rawValue, systemImage: WorkspaceSection.advanced.icon)
            .tag(WorkspaceSection.advanced)
        }
      }
      .navigationTitle(session.projectName)
      .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
      .safeAreaInset(edge: .bottom) {
        VStack(alignment: .leading, spacing: 5) {
          Text("PRIVATE PROJECT")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.orange)
          Text("Sources remain unchanged")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
      }
    } detail: {
      detail
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button {
              showsAddSource = true
            } label: {
              Label("Add Source", systemImage: "plus")
            }
            .disabled(session.isImporting)
          }
        }
    }
    .sheet(isPresented: $showsAddSource) {
      AddSourceView(session: session)
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch selection ?? .overview {
    case .overview:
      OverviewView(session: session, showsAddSource: $showsAddSource)
    case .sources:
      SourcesView(session: session, showsAddSource: $showsAddSource)
    case .matches:
      MatchesView(session: session)
    case .people:
      PeopleView(session: session)
    case .destinations:
      StageView(
        eyebrow: "04 / ROUTE",
        title: "Destinations",
        description:
          "Choose what belongs in Apple Photos, Google Photos, or two encrypted archive copies.",
        icon: "arrow.triangle.branch"
      )
    case .review:
      StageView(
        eyebrow: "05 / DECIDE",
        title: "Review",
        description:
          "Every migration, privacy rule, and later cleanup action remains reviewable before execution.",
        icon: "checklist"
      )
    case .verify:
      StageView(
        eyebrow: "06 / PROVE",
        title: "Verify",
        description:
          "Confirm copied bytes and required archive redundancy before considering any source cleanup.",
        icon: "checkmark.seal"
      )
    case .advanced:
      AdvancedView(session: session)
    }
  }
}

private struct OverviewView: View {
  let session: LibraryProjectSession
  @Binding var showsAddSource: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        PageHeader(
          eyebrow: "01 / GATHER",
          title: "Library overview",
          description: "Account for every original before deciding where anything should go."
        )

        StageRail(active: session.project?.sources.isEmpty == false ? 1 : 0)

        if session.isImporting {
          ImportingCard(message: session.importProgressMessage)
        }

        if let sources = session.project?.sources, sources.isEmpty {
          EmptySourcesCard(showsAddSource: $showsAddSource)
        } else {
          MetricsRow(
            assets: session.currentOccurrenceCount,
            verifiedFiles: session.currentMeasuredResourceCount,
            exactMatches: session.identityIndex.automaticMatches.count,
            people: session.currentSourcePersonCount
          )

          SectionHeader(title: "Sources", action: "Add Source") {
            showsAddSource = true
          }
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280), spacing: 14)],
            alignment: .leading,
            spacing: 14
          ) {
            ForEach(session.project?.sources ?? []) { source in
              SourceCard(
                source: source,
                isImporting: session.isImporting,
                refresh: { session.refresh(source) },
                replaceFolder: source.kind == .folder
                  ? { session.chooseReplacementFolder(for: source) }
                  : nil
              )
            }
          }
        }
      }
      .padding(36)
      .frame(maxWidth: 1_100, alignment: .leading)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct SourcesView: View {
  let session: LibraryProjectSession
  @Binding var showsAddSource: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        PageHeader(
          eyebrow: "01 / GATHER",
          title: "Sources",
          description:
            "Each source is inventoried independently and can be refreshed without moving media."
        )
        if session.isImporting {
          ImportingCard(message: session.importProgressMessage)
        }
        if let sources = session.project?.sources, sources.isEmpty {
          EmptySourcesCard(showsAddSource: $showsAddSource)
        } else {
          LazyVStack(spacing: 14) {
            ForEach(session.project?.sources ?? []) { source in
              SourceCard(
                source: source,
                isImporting: session.isImporting,
                refresh: { session.refresh(source) },
                replaceFolder: source.kind == .folder
                  ? { session.chooseReplacementFolder(for: source) }
                  : nil
              )
            }
          }
        }
      }
      .padding(36)
      .frame(maxWidth: 900, alignment: .leading)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct AddSourceView: View {
  let session: LibraryProjectSession
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Add a source")
          .font(.system(size: 28, weight: .semibold, design: .rounded))
        Text("Gather evidence now. Nothing is moved, uploaded, or deleted.")
          .foregroundStyle(.secondary)
      }

      VStack(spacing: 10) {
        sourceOption(
          icon: "folder",
          title: "Folder on Disk",
          description: "Recursively hash photos and videos; embedded metadata is optional.",
          actionTitle: "Choose Folder"
        ) {
          dismissThen { session.chooseFolderSource() }
        }
        sourceOption(
          icon: "shippingbox",
          title: "Amazon Photos",
          description: "Import a completed private metadata inventory.",
          actionTitle: "Choose Inventory"
        ) {
          dismissThen { session.chooseAmazonInventory() }
        }
        sourceOption(
          icon: "photo.on.rectangle.angled",
          title: "Apple Photos",
          description:
            "Add the current system library with PhotoKit. Use Rescan for an existing source.",
          actionTitle: "Add Photos Library"
        ) {
          dismissThen { session.connectApplePhotos() }
        }
        sourceOption(
          icon: "archivebox",
          title: "Google Photos",
          description: "Import an expanded Takeout folder with media and sidecars.",
          actionTitle: "Adapter Next",
          enabled: false,
          action: {}
        )
      }

      HStack {
        Label("Source files remain read-only", systemImage: "lock.shield")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(28)
    .frame(width: 620)
  }

  private func sourceOption(
    icon: String,
    title: String,
    description: String,
    actionTitle: String,
    enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 16) {
      Image(systemName: icon)
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(enabled ? Color.orange : Color.secondary)
        .frame(width: 34)
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
        Text(description)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button(actionTitle, action: action)
        .buttonStyle(.bordered)
        .disabled(!enabled)
    }
    .padding(16)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
  }

  private func dismissThen(_ action: @escaping @MainActor () -> Void) {
    dismiss()
    Task { @MainActor in
      await Task.yield()
      action()
    }
  }
}

private struct SourceCard: View {
  let source: LibraryProjectSource
  let isImporting: Bool
  let refresh: () -> Void
  let replaceFolder: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top) {
        Image(systemName: sourceIcon)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.orange)
          .frame(width: 32, height: 32)
          .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 3) {
          Text(source.displayName)
            .font(.headline)
            .lineLimit(1)
          Text(sourceTypeName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        HStack(spacing: 10) {
          if let replaceFolder {
            Button("Replace Folder", action: replaceFolder)
              .buttonStyle(.borderless)
              .disabled(isImporting)
          }
          Button("Rescan", action: refresh)
            .buttonStyle(.borderless)
            .disabled(isImporting)
        }
      }

      Divider()

      if let measured = source.measuredResourceCount {
        HStack(spacing: 14) {
          Label("\(measured.formatted()) local resources", systemImage: "checkmark.circle")
          if let cloud = source.networkRequiredResourceCount, cloud > 0 {
            Label("\(cloud.formatted()) need iCloud", systemImage: "icloud.and.arrow.down")
          }
          if let unavailable = source.unavailableResourceCount, unavailable > 0 {
            Label("\(unavailable.formatted()) unreadable", systemImage: "exclamationmark.triangle")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(source.itemCount.formatted())
            .font(.system(size: 22, weight: .semibold, design: .rounded))
          Text("items observed")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 3) {
          Text(source.lastImportedAt, style: .relative)
            .font(.subheadline.weight(.medium))
          Text("last scanned")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(18)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    }
  }

  private var sourceIcon: String {
    switch source.kind {
    case .amazonInventory: "shippingbox"
    case .applePhotos: "photo.on.rectangle.angled"
    case .folder: "folder"
    }
  }

  private var sourceTypeName: String {
    switch source.kind {
    case .amazonInventory: "Amazon Photos inventory"
    case .applePhotos: "System Photo Library"
    case .folder: "Folder on Disk"
    }
  }
}

private struct PageHeader: View {
  let eyebrow: String
  let title: String
  let description: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(eyebrow)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .tracking(1.7)
        .foregroundStyle(.orange)
      Text(title)
        .font(.system(size: 34, weight: .semibold, design: .rounded))
        .tracking(-0.5)
      Text(description)
        .font(.system(size: 16))
        .foregroundStyle(.secondary)
    }
  }
}

private struct StageRail: View {
  let active: Int
  private let stages = ["Gather", "Match", "People", "Route", "Review", "Verify"]

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
        VStack(alignment: .leading, spacing: 9) {
          Text(String(format: "%02d", index + 1))
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(index <= active ? Color.orange : Color.secondary)
          Text(stage)
            .font(.system(size: 13, weight: index == active ? .semibold : .regular))
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(index == active ? Color.orange.opacity(0.09) : Color.primary.opacity(0.025))
        if index < stages.count - 1 {
          Divider()
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    }
  }
}

private struct MetricsRow: View {
  let assets: Int
  let verifiedFiles: Int
  let exactMatches: Int
  let people: Int

  var body: some View {
    HStack(spacing: 12) {
      metric(assets, "current occurrences")
      metric(verifiedFiles, "measured files")
      metric(exactMatches, "exact matches")
      metric(people, "source people")
    }
  }

  private func metric(_ value: Int, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(value.formatted())
        .font(.system(size: 25, weight: .semibold, design: .rounded))
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct SectionHeader: View {
  let title: String
  let action: String
  let perform: () -> Void

  var body: some View {
    HStack {
      Text(title)
        .font(.title3.weight(.semibold))
      Spacer()
      Button(action, action: perform)
        .buttonStyle(.borderless)
    }
  }
}

private struct EmptySourcesCard: View {
  @Binding var showsAddSource: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Image(systemName: "square.stack.3d.up")
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(.orange)
      Text("Start with what you can reach")
        .font(.title3.weight(.semibold))
      Text(
        "Choose an ordinary folder or a completed Amazon inventory. The first scan builds "
          + "the evidence layer for later matching and routing."
      )
      .foregroundStyle(.secondary)
      .frame(maxWidth: 560, alignment: .leading)
      Button("Add First Source") { showsAddSource = true }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .stroke(Color.orange.opacity(0.18), lineWidth: 1)
    }
  }
}

private struct ImportingCard: View {
  let message: String?

  var body: some View {
    HStack(spacing: 14) {
      ProgressView()
        .controlSize(.small)
      VStack(alignment: .leading, spacing: 3) {
        Text(message ?? "Reading source")
          .font(.headline)
        Text("Measuring local files and validating the private catalog. This may take a while.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct MatchesView: View {
  let session: LibraryProjectSession
  @State private var showsBulkConfirmation = false

  var body: some View {
    let identity = session.identityIndex
    let decisions = Dictionary(
      uniqueKeysWithValues: session.reviewState.duplicateDecisions.map {
        ($0.candidateID, $0.disposition)
      }
    )
    let resourceNames = Dictionary(
      uniqueKeysWithValues: session.catalog.sourceResources.map {
        ($0.id, $0.originalFilename ?? "Unnamed resource")
      })
    let currentDispositions = identity.amazonMD5ReviewCandidates.compactMap {
      decisions[$0.id]
    }
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        PageHeader(
          eyebrow: "02 / RECONCILE",
          title: "Matches",
          description:
            "Measured SHA-256 matches are exact. Amazon MD5 links stay separate until you confirm them."
        )

        MatchMetrics(
          exact: identity.automaticMatches.count,
          candidates: identity.amazonMD5ReviewCandidates.count,
          confirmed: currentDispositions.count { $0 == .confirmedDuplicate },
          rejected: currentDispositions.count { $0 == .rejected }
        )

        if !identity.amazonMD5ReviewCandidates.isEmpty {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Amazon MD5 review")
                .font(.title3.weight(.semibold))
              Text(
                "MD5 and byte length agree with locally measured media. This is not a SHA-256 proof."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Confirm All…") { showsBulkConfirmation = true }
              .buttonStyle(.bordered)
          }

          ForEach(identity.amazonMD5ReviewCandidates) { candidate in
            AmazonMD5CandidateCard(
              candidate: candidate,
              resourceNames: resourceNames,
              disposition: decisions[candidate.id],
              setDisposition: { disposition in
                session.setDuplicateDisposition(disposition, for: candidate.id)
              }
            )
          }
        }

        if !identity.automaticMatches.isEmpty {
          Text("Exact local matches")
            .font(.title3.weight(.semibold))
          ForEach(identity.automaticMatches) { match in
            VStack(alignment: .leading, spacing: 8) {
              Label("SHA-256 verified", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
              Text(
                "\(match.sourceResourceIDs.count.formatted()) resources · "
                  + ByteCountFormatter.string(fromByteCount: match.byteCount, countStyle: .file)
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              ResourceNames(resourceIDs: match.sourceResourceIDs, names: resourceNames)
            }
            .reviewCard()
          }
        }

        if identity.automaticMatches.isEmpty && identity.amazonMD5ReviewCandidates.isEmpty {
          ReviewEmptyState(
            icon: "link",
            title: "No cross-source matches yet",
            message: "Scan local media and provider inventories to build reconciliation evidence."
          )
        }
      }
      .padding(36)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .confirmationDialog(
      "Confirm every Amazon MD5 candidate?",
      isPresented: $showsBulkConfirmation
    ) {
      Button("Confirm All Candidates") {
        session.setAllAmazonCandidates(.confirmedDuplicate)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This records one explicit review decision for each current MD5-and-size candidate. "
          + "It does not turn Amazon-reported MD5 into SHA-256 evidence."
      )
    }
  }
}

private struct MatchMetrics: View {
  let exact: Int
  let candidates: Int
  let confirmed: Int
  let rejected: Int

  var body: some View {
    HStack(spacing: 12) {
      metric(exact, "exact groups")
      metric(candidates, "MD5 candidates")
      metric(confirmed, "confirmed")
      metric(rejected, "rejected")
    }
  }

  private func metric(_ value: Int, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(value.formatted())
        .font(.system(size: 25, weight: .semibold, design: .rounded))
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct AmazonMD5CandidateCard: View {
  let candidate: AmazonMD5ReviewCandidate
  let resourceNames: [String: String]
  let disposition: DuplicateReviewDisposition?
  let setDisposition: (DuplicateReviewDisposition?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(statusLabel, systemImage: statusIcon)
          .font(.headline)
          .foregroundStyle(statusColor)
        Spacer()
        Text(ByteCountFormatter.string(fromByteCount: candidate.byteCount, countStyle: .file))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      HStack(alignment: .top, spacing: 24) {
        resourceColumn("LOCAL MEASUREMENT", candidate.localSourceResourceIDs)
        resourceColumn("AMAZON REPORT", candidate.amazonSourceResourceIDs)
      }
      HStack {
        Button("Confirm Duplicate") { setDisposition(.confirmedDuplicate) }
          .buttonStyle(.borderedProminent)
        Button("Not the Same") { setDisposition(.rejected) }
          .buttonStyle(.bordered)
        if disposition != nil {
          Button("Clear Decision") { setDisposition(nil) }
            .buttonStyle(.borderless)
        }
      }
    }
    .reviewCard()
  }

  private func resourceColumn(_ title: String, _ resourceIDs: [String]) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(.secondary)
      ResourceNames(resourceIDs: resourceIDs, names: resourceNames)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statusLabel: String {
    switch disposition {
    case .confirmedDuplicate: "Confirmed duplicate"
    case .rejected: "Rejected"
    case nil: "Needs review"
    }
  }

  private var statusIcon: String {
    switch disposition {
    case .confirmedDuplicate: "checkmark.circle.fill"
    case .rejected: "xmark.circle.fill"
    case nil: "questionmark.circle"
    }
  }

  private var statusColor: Color {
    switch disposition {
    case .confirmedDuplicate: .green
    case .rejected: .red
    case nil: .orange
    }
  }
}

private struct ResourceNames: View {
  let resourceIDs: [String]
  let names: [String: String]

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      ForEach(resourceIDs, id: \.self) { resourceID in
        Text(names[resourceID] ?? "Unnamed resource")
          .font(.subheadline)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
  }
}

private struct PeopleView: View {
  let session: LibraryProjectSession

  private var peopleIndex: CatalogPeopleIndex {
    CatalogPeopleIndex(
      snapshot: session.catalog,
      reviewState: session.reviewState,
      identityIndex: session.identityIndex
    )
  }

  private var assignedSourcePersonIDs: Set<String> {
    Set(session.reviewState.canonicalPeople.flatMap(\.sourcePersonIDs))
  }

  private var currentSourcePeople: [SourcePerson] {
    let libraries = Dictionary(
      uniqueKeysWithValues: session.catalog.sourceLibraries.map { ($0.id, $0) })
    let observations = Dictionary(
      uniqueKeysWithValues: session.catalog.sourceObservations.map { ($0.id, $0) })
    return session.catalog.sourcePeople.filter { person in
      observations[person.observationID]?.importRunID
        == libraries[person.sourceLibraryID]?.latestImportRunID
    }.sorted { sourceName(for: $0.id) < sourceName(for: $1.id) }
  }

  var body: some View {
    let index = peopleIndex
    let sourcePeople = currentSourcePeople
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        PageHeader(
          eyebrow: "03 / PEOPLE",
          title: "People",
          description:
            "Provider names remain evidence. Create your own identities, then assign privacy routing."
        )

        if !session.reviewState.canonicalPeople.isEmpty {
          Text("Your people")
            .font(.title3.weight(.semibold))
          ForEach(session.reviewState.canonicalPeople) { person in
            let memberships = index.memberships.filter {
              $0.canonicalPersonID == person.id
            }
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                VStack(alignment: .leading, spacing: 3) {
                  Text(person.preferredName)
                    .font(.headline)
                  Text(
                    "\(memberships.count.formatted()) photos · "
                      + "\(memberships.count(where: \.isPropagated).formatted()) propagated"
                  )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                }
                Spacer()
                Picker(
                  "Privacy",
                  selection: Binding(
                    get: { person.privacyCategory },
                    set: { session.setPrivacyCategory($0, for: person.id) }
                  )
                ) {
                  ForEach(PersonPrivacyCategory.allCases, id: \.self) { category in
                    Text(category.label).tag(category)
                  }
                }
                .labelsHidden()
                .frame(width: 190)
              }
            }
            .reviewCard()
          }
        }

        let unassigned = sourcePeople.filter { !assignedSourcePersonIDs.contains($0.id) }
        if !unassigned.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("Source identities")
              .font(.title3.weight(.semibold))
            Text("Create a PhotoDeFrigifier identity without changing the provider’s People data.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          ForEach(unassigned, id: \.id) { sourcePerson in
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text(sourceName(for: sourcePerson.id))
                  .font(.headline)
                Text(sourcePersonProvider(sourcePerson))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button("Create Person") {
                session.createCanonicalPerson(
                  from: sourcePerson.id,
                  preferredName: sourceName(for: sourcePerson.id)
                )
              }
              .buttonStyle(.borderedProminent)
            }
            .reviewCard()
          }
        }

        if sourcePeople.isEmpty && session.reviewState.canonicalPeople.isEmpty {
          ReviewEmptyState(
            icon: "person.2",
            title: "No source identities yet",
            message: "Import a provider inventory containing People claims to begin categorization."
          )
        }
      }
      .padding(36)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func sourceName(for sourcePersonID: String) -> String {
    session.catalog.personNameClaims
      .filter { $0.sourcePersonID == sourcePersonID }
      .max { $0.observedAt < $1.observedAt }?.displayName ?? "Unnamed person"
  }

  private func sourcePersonProvider(_ person: SourcePerson) -> String {
    session.catalog.sourceLibraries.first { $0.id == person.sourceLibraryID }?.provider.rawValue
      .capitalized ?? "Provider"
  }
}

private struct ReviewEmptyState: View {
  let icon: String
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(.orange)
      Text(title)
        .font(.headline)
      Text(message)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 240)
  }
}

extension View {
  fileprivate func reviewCard() -> some View {
    padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.primary.opacity(0.08), lineWidth: 1)
      }
  }
}

extension PersonPrivacyCategory {
  fileprivate var label: String {
    switch self {
    case .standard: "Standard"
    case .privateCloudAcceptable: "Private Cloud OK"
    case .neverCloud: "Never Cloud"
    }
  }
}

private struct StageView: View {
  let eyebrow: String
  let title: String
  let description: String
  let icon: String
  var metric: Int?
  var metricLabel: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 32) {
      PageHeader(eyebrow: eyebrow, title: title, description: description)
      Spacer()
      VStack(spacing: 16) {
        Image(systemName: icon)
          .font(.system(size: 34, weight: .medium))
          .foregroundStyle(.orange)
        if let metric, let metricLabel {
          Text(metric.formatted())
            .font(.system(size: 34, weight: .semibold, design: .rounded))
          Text(metricLabel)
            .foregroundStyle(.secondary)
        } else {
          Text("This stage unlocks after source gathering and reconciliation.")
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      Spacer()
    }
    .padding(36)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct AdvancedView: View {
  let session: LibraryProjectSession

  var body: some View {
    VStack(alignment: .leading, spacing: 28) {
      PageHeader(
        eyebrow: "ADVANCED",
        title: "Diagnostics",
        description:
          "Provider experiments and implementation notes stay separate from the migration workflow."
      )
      VStack(alignment: .leading, spacing: 14) {
        Button("Open Provider Access Lab") {
          session.openProviderAccessLab()
        }
        .buttonStyle(.bordered)
        Button("Read Plan Details") {
          session.openPlanDetails()
        }
        .buttonStyle(.bordered)
      }
      Spacer()
    }
    .padding(36)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}
