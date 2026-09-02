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
      DestinationsView(session: session)
    case .review:
      ReviewView(session: session)
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
                  : nil,
                attachDownloads: source.kind == .amazonInventory
                  ? { session.chooseAmazonDownloads(for: source) }
                  : nil,
                attachedFolderCount: session.project?.sources.count {
                  $0.attachedToSourceID == source.id
                } ?? 0
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
                  : nil,
                attachDownloads: source.kind == .amazonInventory
                  ? { session.chooseAmazonDownloads(for: source) }
                  : nil,
                attachedFolderCount: session.project?.sources.count {
                  $0.attachedToSourceID == source.id
                } ?? 0
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
  let attachDownloads: (() -> Void)?
  let attachedFolderCount: Int

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
          if let attachDownloads {
            Button("Attach Downloads", action: attachDownloads)
              .buttonStyle(.borderless)
              .disabled(isImporting)
          }
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

      if source.kind == .amazonInventory {
        Label(
          "\(attachedFolderCount.formatted()) download folders attached",
          systemImage: "folder.badge.plus"
        )
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
    case .folder:
      source.attachedToSourceID == nil ? "Folder on Disk" : "Amazon download folder"
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
  @State private var selectedGroupID: String?

  var body: some View {
    let groups = session.duplicateIndex.groups
    VStack(alignment: .leading, spacing: 20) {
      PageHeader(
        eyebrow: "02 / RECONCILE",
        title: "Matches",
        description:
          "Compare actual media where bytes are available. Filename evidence always requires review."
      )
      MatchMetrics(duplicateIndex: session.duplicateIndex, reviewState: session.reviewState)

      if groups.isEmpty {
        ReviewEmptyState(
          icon: "link",
          title: "No duplicate candidates yet",
          message: "Scan media sources or attach Amazon download folders to build match evidence."
        )
      } else {
        HSplitView {
          ScrollView {
            LazyVStack(spacing: 6) {
              ForEach(groups) { group in
                DuplicateGroupRow(
                  group: group,
                  isSelected: selectedGroupID == group.id
                ) {
                  selectedGroupID = group.id
                }
              }
            }
            .padding(8)
          }
          .frame(minWidth: 245, idealWidth: 290, maxWidth: 340)
          .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))

          if let group = groups.first(where: { $0.id == selectedGroupID }) ?? groups.first {
            if session.duplicateIndex.oversizedGroupIDs.contains(group.id) {
              ReviewEmptyState(
                icon: "exclamationmark.triangle",
                title: "Candidate group too broad",
                message:
                  "Pair generation is paused because this group exceeds the safe review budget. Narrow the source scope or naming before review."
              )
            } else {
              DuplicateComparisonView(group: group, session: session)
                .id(group.id)
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
    .padding(30)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      if selectedGroupID == nil { selectedGroupID = groups.first?.id }
    }
  }
}

private struct MatchMetrics: View {
  let duplicateIndex: CatalogDuplicateIndex
  let reviewState: LibraryProjectReviewState

  private var groups: [DuplicateCandidateGroup] { duplicateIndex.groups }

  private var reviewPairIDs: Set<String> {
    Set(duplicateIndex.pairs.filter { !$0.isAutomatic }.map(\.id))
  }

  var body: some View {
    let resolutions = CatalogDuplicateResolutionIndex(
      duplicateIndex: duplicateIndex,
      reviewState: reviewState
    )
    HStack(spacing: 12) {
      metric(groups.count { $0.isAutomatic }, "exact groups")
      metric(groups.count { $0.evidence.contains(.amazonMD5) }, "MD5 groups")
      metric(groups.count { $0.evidence.contains(.exactFilename) }, "exact names")
      metric(
        reviewPairIDs.count { pairID in
          resolutions.resolutionByPairID[pairID] == .unresolved
        },
        "pairs to review"
      )
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

private struct DuplicateGroupRow: View {
  let group: DuplicateCandidateGroup
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack {
        Image(systemName: group.evidence.first?.icon ?? "questionmark")
          .foregroundStyle(group.evidence.first?.color ?? .secondary)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 3) {
          Text(group.occurrences.first?.filename ?? "Unnamed group")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
          Text(
            "\(group.occurrences.count.formatted()) occurrences · "
              + (group.evidence.first?.label ?? "Candidate")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption.weight(.bold))
          .foregroundStyle(.tertiary)
      }
      .padding(10)
      .contentShape(Rectangle())
      .background(
        isSelected ? Color.orange.opacity(0.12) : Color.clear,
        in: RoundedRectangle(cornerRadius: 9)
      )
    }
    .buttonStyle(.plain)
  }
}

private struct DuplicateComparisonView: View {
  let group: DuplicateCandidateGroup
  let session: LibraryProjectSession
  @State private var anchorOccurrenceID: String?
  @State private var selectedOccurrenceID: String?

  private var anchor: DuplicateOccurrence {
    group.occurrences.first { $0.id == anchorOccurrenceID } ?? group.occurrences[0]
  }

  private var alternatives: [DuplicateOccurrence] {
    group.occurrences.filter { $0.id != anchor.id }
  }

  private var selected: DuplicateOccurrence? {
    alternatives.first { $0.id == selectedOccurrenceID } ?? alternatives.first
  }

  private var selectedPair: DuplicateCandidatePair? {
    guard let selected else { return nil }
    return session.duplicateIndex.pair(
      between: anchor.sourceResourceID,
      and: selected.sourceResourceID
    )
  }

  private var groupPairs: [DuplicateCandidatePair] {
    let occurrenceIDs = Set(group.occurrences.map(\.sourceResourceID))
    return session.duplicateIndex.pairs.filter { pair in
      occurrenceIDs.contains(pair.first.sourceResourceID)
        && occurrenceIDs.contains(pair.second.sourceResourceID)
    }
  }

  var body: some View {
    let pairResolutions = CatalogDuplicateResolutionIndex(
      duplicateIndex: session.duplicateIndex,
      reviewState: session.reviewState
    )
    let nextUnresolvedPair = groupPairs.first {
      pairResolutions.resolution(for: $0) == .unresolved
    }
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 8) {
          ForEach(selectedPair?.evidence ?? group.evidence, id: \.self) { evidence in
            Label(evidence.label, systemImage: evidence.icon)
              .font(.caption.weight(.semibold))
              .foregroundStyle(evidence.color)
              .padding(.horizontal, 9)
              .padding(.vertical, 5)
              .background(evidence.color.opacity(0.1), in: Capsule())
          }
          Spacer()
          Text("\(group.occurrences.count.formatted()) occurrences")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        if let nextUnresolvedPair {
          Button("Next Unresolved Pair") {
            select(nextUnresolvedPair)
          }
          .buttonStyle(.borderedProminent)
        }

        if let selected, let selectedPair {
          HStack(alignment: .top, spacing: 16) {
            ComparisonPane(
              occurrence: anchor,
              reference: session.previewIndex?.reference(forSourceResourceID: anchor.id),
              previewStore: session.previewStore,
              heading: "LEFT · ANCHOR"
            )
            ComparisonPane(
              occurrence: selected,
              reference: session.previewIndex?.reference(forSourceResourceID: selected.id),
              previewStore: session.previewStore,
              heading: "RIGHT · CANDIDATE"
            )
          }

          if selectedPair.isAutomatic {
            Label("Byte-identical SHA-256 match", systemImage: "checkmark.seal.fill")
              .font(.headline)
              .foregroundStyle(.green)
          } else {
            PairDecisionControls(
              pair: selectedPair,
              first: anchor,
              second: selected,
              session: session
            )
          }

          if group.occurrences.count > 2 && !group.isAutomatic {
            Button("Use Right as Left") {
              anchorOccurrenceID = selected.id
              selectedOccurrenceID = group.occurrences.first { $0.id != selected.id }?.id
            }
            .buttonStyle(.bordered)
            .help("Move this occurrence to the left so every pair can be compared.")
          }
        }

        if alternatives.count > 1 {
          VStack(alignment: .leading, spacing: 8) {
            Text("OTHER OCCURRENCES")
              .font(.system(size: 10, weight: .semibold, design: .monospaced))
              .tracking(1.2)
              .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
              LazyHStack(spacing: 10) {
                ForEach(alternatives) { occurrence in
                  Button {
                    selectedOccurrenceID = occurrence.id
                  } label: {
                    VStack(alignment: .leading, spacing: 5) {
                      MediaThumbnail(
                        reference: session.previewIndex?.reference(
                          forSourceResourceID: occurrence.id
                        ),
                        previewStore: session.previewStore,
                        maximumPixelSize: 260
                      )
                      Text(occurrence.filename)
                        .font(.caption)
                        .lineLimit(1)
                      if let pair = session.duplicateIndex.pair(
                        between: anchor.sourceResourceID,
                        and: occurrence.sourceResourceID
                      ) {
                        Label(
                          pairResolutions.resolution(for: pair).label,
                          systemImage: pairResolutions.resolution(for: pair).icon
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(pairResolutions.resolution(for: pair).color)
                      }
                    }
                    .padding(6)
                    .frame(width: 145)
                    .background(
                      selected?.id == occurrence.id
                        ? Color.orange.opacity(0.14) : Color.primary.opacity(0.03),
                      in: RoundedRectangle(cornerRadius: 10)
                    )
                  }
                  .buttonStyle(.plain)
                }
              }
            }
          }
        }
      }
      .padding(20)
    }
    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      anchorOccurrenceID = group.occurrences.first?.id
      selectedOccurrenceID = alternatives.first?.id
    }
  }

  private func select(_ pair: DuplicateCandidatePair) {
    anchorOccurrenceID = pair.first.id
    selectedOccurrenceID = pair.second.id
  }
}

private struct ComparisonPane: View {
  let occurrence: DuplicateOccurrence
  let reference: CatalogPreviewReference?
  let previewStore: MediaPreviewStore
  let heading: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(heading)
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .tracking(1.2)
        .foregroundStyle(.secondary)
      MediaThumbnail(
        reference: reference,
        previewStore: previewStore,
        maximumPixelSize: 900,
        label: previewLabel
      )
      Text(occurrence.filename)
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.middle)
      HStack(spacing: 10) {
        Label(occurrence.provider.displayName, systemImage: occurrence.provider.icon)
        if let dimensions {
          Text(dimensions)
        }
        if let byteCount = occurrence.byteCount {
          Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var dimensions: String? {
    guard let width = occurrence.width, let height = occurrence.height else { return nil }
    return "\(width) × \(height)"
  }

  private var previewLabel: String {
    switch reference?.provenance {
    case .amazonReviewCandidate:
      "AMAZON · MD5 CANDIDATE PROXY"
    case .appleAssetRendition:
      "APPLE · ASSET RENDITION"
    case .direct:
      occurrence.provider.displayName.uppercased()
    case nil:
      occurrence.provider == .amazon ? "AMAZON · NOT DOWNLOADED" : occurrence.provider.displayName
    }
  }
}

private struct PairDecisionControls: View {
  let pair: DuplicateCandidatePair
  let first: DuplicateOccurrence
  let second: DuplicateOccurrence
  let session: LibraryProjectSession

  private var disposition: DuplicateReviewDisposition? {
    if let decision = session.reviewState.duplicatePairDecisions.first(where: { $0.id == pair.id })
    {
      return decision.disposition
    }
    return nil
  }

  var body: some View {
    HStack(spacing: 10) {
      Button("Same Media") { set(.confirmedDuplicate) }
        .buttonStyle(.borderedProminent)
      Button("Different") { set(.rejected) }
        .buttonStyle(.bordered)
      if let disposition {
        Label(disposition.label, systemImage: disposition.icon)
          .font(.caption.weight(.semibold))
          .foregroundStyle(disposition.color)
        Button("Clear") { set(nil) }
          .buttonStyle(.borderless)
      } else {
        Text("Review required before this relationship can affect People or routing.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func set(_ disposition: DuplicateReviewDisposition?) {
    session.setDuplicatePairDisposition(
      disposition,
      first: first,
      second: second
    )
  }
}

extension DuplicateEvidenceKind {
  fileprivate var label: String {
    switch self {
    case .exactSHA256: "Exact SHA-256"
    case .amazonMD5: "Amazon MD5 + type"
    case .exactFilename: "Exact filename"
    case .matchingFilenameStem: "Matching filename stem"
    }
  }

  fileprivate var icon: String {
    switch self {
    case .exactSHA256: "checkmark.seal.fill"
    case .amazonMD5: "number"
    case .exactFilename: "doc.on.doc"
    case .matchingFilenameStem: "text.magnifyingglass"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .exactSHA256: .green
    case .amazonMD5: .blue
    case .exactFilename: .orange
    case .matchingFilenameStem: .purple
    }
  }
}

extension DuplicateReviewDisposition {
  fileprivate var label: String {
    switch self {
    case .confirmedDuplicate: "Confirmed same"
    case .rejected: "Marked different"
    }
  }

  fileprivate var icon: String {
    switch self {
    case .confirmedDuplicate: "checkmark.circle.fill"
    case .rejected: "xmark.circle.fill"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .confirmedDuplicate: .green
    case .rejected: .red
    }
  }
}

extension DuplicatePairResolution {
  fileprivate var label: String {
    switch self {
    case .automatic: "Exact"
    case .confirmed: "Same Media"
    case .rejected: "Different"
    case .unresolved: "Needs Review"
    }
  }

  fileprivate var icon: String {
    switch self {
    case .automatic: "checkmark.seal.fill"
    case .confirmed: "checkmark.circle.fill"
    case .rejected: "xmark.circle.fill"
    case .unresolved: "circle.dashed"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .automatic, .confirmed: .green
    case .rejected: .red
    case .unresolved: .orange
    }
  }
}

extension CatalogProvider {
  fileprivate var displayName: String {
    switch self {
    case .amazon: "Amazon"
    case .applePhotos: "Apple Photos"
    case .filesystem: "Folder"
    case .googlePhotos: "Google Photos"
    }
  }

  fileprivate var icon: String {
    switch self {
    case .amazon: "shippingbox"
    case .applePhotos: "photo.on.rectangle.angled"
    case .filesystem: "folder"
    case .googlePhotos: "g.circle"
    }
  }
}

private struct PeopleView: View {
  let session: LibraryProjectSession

  private var peopleIndex: CatalogPeopleIndex {
    CatalogPeopleIndex(
      snapshot: session.catalog,
      reviewState: session.reviewState,
      identityIndex: session.identityIndex,
      duplicateIndex: session.duplicateIndex
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
            "Provider names remain evidence. Choose explicit Apple and Google routing for each person."
        )
        Text(
          "For photos containing several people, the most restrictive destination choice wins. "
            + "Archive protection remains required for every retained original."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if !session.reviewState.canonicalPeople.isEmpty {
          Text("Your people")
            .font(.title3.weight(.semibold))
          ForEach(session.reviewState.canonicalPeople) { person in
            let memberships = index.memberships.filter {
              $0.canonicalPersonID == person.id
            }
            VStack(alignment: .leading, spacing: 12) {
              HStack(alignment: .top) {
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
                VStack(alignment: .leading, spacing: 8) {
                  LabeledContent("Apple Photos") {
                    Picker(
                      "Apple Photos",
                      selection: Binding<ApplePersonRoute?>(
                        get: { person.routing.apple },
                        set: { session.setAppleRoute($0, for: person.id) }
                      )
                    ) {
                      Text("Choose").tag(nil as ApplePersonRoute?)
                      ForEach(ApplePersonRoute.allCases, id: \.self) { route in
                        Text(route.label).tag(route as ApplePersonRoute?)
                      }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                  }
                  LabeledContent("Google Photos") {
                    Picker(
                      "Google Photos",
                      selection: Binding<GooglePersonRoute?>(
                        get: { person.routing.google },
                        set: { session.setGoogleRoute($0, for: person.id) }
                      )
                    ) {
                      Text("Choose").tag(nil as GooglePersonRoute?)
                      ForEach(GooglePersonRoute.allCases, id: \.self) { route in
                        Text(route.label).tag(route as GooglePersonRoute?)
                      }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                  }
                }
                .frame(width: 270)
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

private struct DestinationsView: View {
  let session: LibraryProjectSession

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeader(
          eyebrow: "04 / ROUTE",
          title: "Destinations",
          description:
            "Configure where reviewed media may go. Choosing locations does not copy or upload anything."
        )

        VStack(alignment: .leading, spacing: 12) {
          HStack {
            destinationIcon("photo.on.rectangle.angled", color: .orange)
            VStack(alignment: .leading, spacing: 3) {
              Text("Apple Photos")
                .font(.headline)
              Text(appleSourceStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Label(
              hasAppleSource ? "Connected" : "Not connected",
              systemImage: hasAppleSource ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            .foregroundStyle(hasAppleSource ? Color.green : Color.orange)
          }
          Text(
            "Visible and Hidden routing use the current system library. Hidden items still sync through iCloud Photos."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .reviewCard()

        DestinationDirectoryCard(
          slot: .googleReadyExport,
          destination: session.project?.destinations.googleReadyExport,
          session: session
        )

        HStack(alignment: .top, spacing: 14) {
          DestinationDirectoryCard(
            slot: .archiveOne,
            destination: session.project?.destinations.archiveOne,
            session: session
          )
          DestinationDirectoryCard(
            slot: .archiveTwo,
            destination: session.project?.destinations.archiveTwo,
            session: session
          )
        }

        archiveSafetyCard
      }
      .padding(36)
      .frame(maxWidth: 980, alignment: .leading)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var hasAppleSource: Bool {
    session.project?.sources.contains { $0.kind == .applePhotos } == true
  }

  private var appleSourceStatus: String {
    guard let source = session.project?.sources.first(where: { $0.kind == .applePhotos }) else {
      return "Add the current system Photos library from Sources."
    }
    return
      "\(source.itemCount.formatted()) items inventoried; PhotoKit remains the only access path."
  }

  private var archiveSafetyCard: some View {
    let firstVolume = session.project?.destinations.archiveOne?.volumeUUID
    let secondVolume = session.project?.destinations.archiveTwo?.volumeUUID
    let independent = firstVolume != nil && secondVolume != nil && firstVolume != secondVolume
    return VStack(alignment: .leading, spacing: 8) {
      Label(
        independent
          ? "Archive locations are on distinct volumes" : "Archive independence not established",
        systemImage: independent ? "checkmark.shield.fill" : "exclamationmark.shield"
      )
      .font(.headline)
      .foregroundStyle(independent ? Color.green : Color.orange)
      Text(
        "Every retained original is planned for both archives. Actual protection requires completed writes, repository checks, and representative restores; bookmarks alone never count as verification."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .reviewCard()
  }

  private func destinationIcon(_ name: String, color: Color) -> some View {
    Image(systemName: name)
      .font(.system(size: 18, weight: .semibold))
      .foregroundStyle(color)
      .frame(width: 34, height: 34)
      .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct DestinationDirectoryCard: View {
  let slot: LibraryProjectDestinationSlot
  let destination: ProjectDirectoryDestination?
  let session: LibraryProjectSession

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: slot.icon)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(slot.color)
          .frame(width: 34, height: 34)
          .background(slot.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 3) {
          Text(slot.label)
            .font(.headline)
          Text(slot.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      Divider()
      if let destination {
        Label(destination.displayName, systemImage: "folder.fill")
          .lineLimit(1)
          .truncationMode(.middle)
        Text(destination.volumeUUID == nil ? "Volume identity unavailable" : "Volume identified")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("Not configured")
          .foregroundStyle(.secondary)
      }
      HStack {
        Button(destination == nil ? "Choose Directory" : "Replace") {
          session.chooseDestination(slot)
        }
        .buttonStyle(.borderedProminent)
        if destination != nil {
          Button("Clear") { session.clearDestination(slot) }
            .buttonStyle(.borderless)
        }
      }
    }
    .reviewCard()
  }
}

private struct ReviewView: View {
  let session: LibraryProjectSession

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeader(
          eyebrow: "05 / DECIDE",
          title: "Review",
          description:
            "Inspect the derived routing plan and every blocker. This version performs no migration or cleanup."
        )

        if let plan = session.reviewPlan {
          readiness(plan)
          if !plan.blockers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              Text("Blockers")
                .font(.title3.weight(.semibold))
              ForEach(Array(plan.blockers.enumerated()), id: \.offset) { _, blocker in
                HStack(alignment: .top, spacing: 10) {
                  Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(blocker.title)
                      .font(.headline)
                    Text(blocker.detail)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
                .reviewCard()
              }
            }
          }

          HStack(alignment: .top, spacing: 14) {
            routeSummary(
              title: "Apple Photos",
              icon: "photo.on.rectangle.angled",
              rows: [
                ("Visible", plan.apple.visibleAssetIDs.count),
                ("Hidden", plan.apple.hiddenAssetIDs.count),
                ("Excluded", plan.apple.excludedAssetIDs.count),
                ("Unresolved", plan.apple.unresolvedAssetIDs.count),
              ]
            )
            routeSummary(
              title: "Google-ready export",
              icon: "g.circle",
              rows: [
                ("Included", plan.google.includedAssetIDs.count),
                ("Excluded", plan.google.excludedAssetIDs.count),
                ("Unresolved", plan.google.unresolvedAssetIDs.count),
              ]
            )
            routeSummary(
              title: "Encrypted archives",
              icon: "externaldrive.badge.timemachine",
              rows: [
                ("Planned originals", plan.archives.assetIDs.count),
                ("Locations", plan.archives.configuredSlots.count),
                ("Verified copies", 0),
              ]
            )
          }

          VStack(alignment: .leading, spacing: 8) {
            Label("Cleanup unavailable", systemImage: "hand.raised.fill")
              .font(.headline)
              .foregroundStyle(.orange)
            Text(
              "No delete, move, upload, PhotoKit write, or archive command exists in this plan. Cleanup remains blocked until two independent archive receipts are implemented and verified."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .reviewCard()
        }
      }
      .padding(36)
      .frame(maxWidth: 1_050, alignment: .leading)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func readiness(_ plan: LibraryProjectPlan) -> some View {
    HStack(spacing: 14) {
      Image(
        systemName: plan.isConfigurationComplete ? "checkmark.seal.fill" : "checklist.unchecked"
      )
      .font(.system(size: 30, weight: .medium))
      .foregroundStyle(plan.isConfigurationComplete ? Color.green : Color.orange)
      VStack(alignment: .leading, spacing: 3) {
        Text(plan.isConfigurationComplete ? "Configuration complete" : "Review is open")
          .font(.title3.weight(.semibold))
        Text(
          plan.isConfigurationComplete
            ? "The non-destructive routing configuration has no unresolved blockers."
            : "\(plan.blockers.count.formatted()) blockers remain; every section stays available while you resolve them."
        )
        .foregroundStyle(.secondary)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      (plan.isConfigurationComplete ? Color.green : Color.orange).opacity(0.08),
      in: RoundedRectangle(cornerRadius: 14)
    )
  }

  private func routeSummary(
    title: String,
    icon: String,
    rows: [(String, Int)]
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: icon)
        .font(.headline)
      Divider()
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        HStack {
          Text(row.0)
            .foregroundStyle(.secondary)
          Spacer()
          Text(row.1.formatted())
            .font(.body.monospacedDigit().weight(.semibold))
        }
      }
    }
    .reviewCard()
  }
}

extension LibraryProjectDestinationSlot {
  fileprivate var label: String {
    switch self {
    case .googleReadyExport: "Google-ready export"
    case .archiveOne: "Archive location 1"
    case .archiveTwo: "Archive location 2"
    }
  }

  fileprivate var detail: String {
    switch self {
    case .googleReadyExport: "Local reviewed output for manual upload"
    case .archiveOne: "First encrypted repository or staging root"
    case .archiveTwo: "Second independent encrypted location"
    }
  }

  fileprivate var icon: String {
    switch self {
    case .googleReadyExport: "square.and.arrow.up"
    case .archiveOne, .archiveTwo: "externaldrive"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .googleReadyExport: .blue
    case .archiveOne, .archiveTwo: .orange
    }
  }
}

extension LibraryProjectPlanBlocker {
  fileprivate var title: String {
    switch self {
    case .noCurrentAssets: "No current media"
    case .unresolvedDuplicatePairs: "Duplicate review incomplete"
    case .contradictoryDuplicatePairs: "Duplicate decisions conflict"
    case .duplicateGroupsTooLarge: "Duplicate group is too broad"
    case .unassignedSourcePeople: "Source people need identities"
    case .incompletePersonRouting: "Person routing incomplete"
    case .applePhotosNotConnected: "Apple Photos not connected"
    case .destinationNotConfigured(let slot): "\(slot.label) not configured"
    case .archiveIndependenceUnverified: "Archive independence unverified"
    case .amazonItemsMissingDownloads: "Amazon media missing locally"
    }
  }

  fileprivate var detail: String {
    switch self {
    case .noCurrentAssets:
      "Add or rescan a media source before generating a route."
    case .unresolvedDuplicatePairs(let ids):
      "\(ids.count.formatted()) candidate pairs still need Same Media or Different decisions."
    case .contradictoryDuplicatePairs(let ids):
      "\(ids.count.formatted()) Different decisions conflict with a chain of Same Media decisions."
    case .duplicateGroupsTooLarge(let ids):
      "\(ids.count.formatted()) candidate groups exceed the safe pair-review budget. Narrow the source scope or naming before review."
    case .unassignedSourcePeople(let ids):
      "\(ids.count.formatted()) current provider identities have not been made into your people."
    case .incompletePersonRouting(let ids):
      "\(ids.count.formatted()) people affecting current photos still need Apple or Google choices."
    case .applePhotosNotConnected:
      "Visible or Hidden routes require the current system Photos library in Sources."
    case .destinationNotConfigured(let slot):
      "Choose the \(slot.label.lowercased()) directory in Destinations."
    case .archiveIndependenceUnverified:
      "Both archive locations need identifiable, distinct volumes. Configuration is not protection."
    case .amazonItemsMissingDownloads(let ids):
      "\(ids.count.formatted()) Amazon inventory items have no MD5-matched file in attached download folders."
    }
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

extension ApplePersonRoute {
  fileprivate var label: String {
    switch self {
    case .visible: "Visible"
    case .hidden: "Hidden"
    case .exclude: "Exclude"
    }
  }
}

extension GooglePersonRoute {
  fileprivate var label: String {
    switch self {
    case .include: "Include"
    case .exclude: "Exclude"
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
