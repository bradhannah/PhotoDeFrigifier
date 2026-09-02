import AppKit
import ApplePhotosAdapter
import Observation
import PhotoCatalogCore

@MainActor
@Observable
final class LibraryProjectSession {
  private(set) var projectURL: URL?
  private(set) var project: LibraryProject?
  private(set) var catalog = CatalogSnapshot()
  private(set) var identityIndex = CatalogIdentityIndex(snapshot: CatalogSnapshot())
  private(set) var reviewState = LibraryProjectReviewState()
  private(set) var isImporting = false
  private(set) var importProgressMessage: String?
  var notice: ProjectNotice?

  var projectName: String {
    guard let projectURL else { return "Library Project" }
    return projectURL.deletingPathExtension().lastPathComponent
  }

  var currentOccurrenceCount: Int {
    project?.sources.reduce(0) { $0 + $1.itemCount } ?? 0
  }

  var currentMeasuredResourceCount: Int {
    let libraries = Dictionary(uniqueKeysWithValues: catalog.sourceLibraries.map { ($0.id, $0) })
    let currentItemIDs = Set(
      catalog.sourceItems.compactMap { item in
        item.lastSeenImportRunID == libraries[item.sourceLibraryID]?.latestImportRunID
          ? item.id
          : nil
      })
    let currentResourceIDs = Set(
      catalog.sourceResources.compactMap { resource in
        currentItemIDs.contains(resource.sourceItemID) ? resource.id : nil
      })
    let currentObservationIDs = Set(
      catalog.sourceItems.compactMap { item in
        currentItemIDs.contains(item.id) ? item.latestObservationID : nil
      })
    return catalog.assetResourceLinks.count { link in
      currentResourceIDs.contains(link.sourceResourceID)
        && currentObservationIDs.contains(link.sourceObservationID)
    }
  }

  var currentSourcePersonCount: Int {
    let libraries = Dictionary(uniqueKeysWithValues: catalog.sourceLibraries.map { ($0.id, $0) })
    let observations = Dictionary(
      uniqueKeysWithValues: catalog.sourceObservations.map { ($0.id, $0) })
    return catalog.sourcePeople.count { person in
      observations[person.observationID]?.importRunID
        == libraries[person.sourceLibraryID]?.latestImportRunID
    }
  }

  func chooseAndCreateProject() {
    let panel = NSSavePanel()
    panel.title = "Start a Library Project"
    panel.message =
      "Choose encrypted storage for the private catalog. Photos remain in their source locations."
    panel.prompt = "Create Project"
    panel.nameFieldStringValue = "My Photo Library.photodefrigifier"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let destination =
      url.pathExtension.lowercased() == "photodefrigifier"
      ? url
      : url.appendingPathExtension("photodefrigifier")

    do {
      let project = try LibraryProjectStore.create(at: destination)
      projectURL = destination
      self.project = project
      catalog = CatalogSnapshot()
      identityIndex = CatalogIdentityIndex(snapshot: catalog)
      reviewState = LibraryProjectReviewState()
      notice = nil
    } catch {
      notice = ProjectNotice(
        title: "Project Could Not Be Created",
        message: safeMessage(for: error, fallback: "Choose a different location and try again.")
      )
    }
  }

  func chooseAndOpenProject() {
    let panel = NSOpenPanel()
    panel.title = "Open a Library Project"
    panel.message = "Choose a PhotoDeFrigifier project package."
    panel.prompt = "Open Project"
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    openProject(at: url)
  }

  func openProject(at url: URL) {
    guard !isImporting else {
      notice = ProjectNotice(
        title: "Import In Progress",
        message: "Wait for the current source import to finish before opening another project."
      )
      return
    }
    do {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let contents = try LibraryProjectStore.load(from: url)
      projectURL = url
      project = contents.project
      catalog = contents.catalog
      identityIndex = CatalogIdentityIndex(snapshot: catalog)
      reviewState = contents.reviewState
      notice = nil
    } catch {
      notice = ProjectNotice(
        title: "Project Could Not Be Opened",
        message: safeMessage(
          for: error,
          fallback: "The selected package is incomplete or could not be validated."
        )
      )
    }
  }

  func chooseFolderSource() {
    let panel = NSOpenPanel()
    panel.title = "Add a Folder on Disk"
    panel.message =
      "Photos and videos are read recursively. Hidden files, symlinks, and library packages are skipped."
    panel.prompt = "Add Folder"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    importSource(at: url, kind: .folder)
  }

  func chooseReplacementFolder(for source: LibraryProjectSource) {
    guard source.kind == .folder else { return }
    let panel = NSOpenPanel()
    panel.title = "Replace Folder Source"
    panel.message =
      "The previous scan remains as history. The selected folder becomes the current source scope."
    panel.prompt = "Replace Folder"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    importSource(at: url, kind: .folder, existingSource: source)
  }

  func chooseAmazonInventory() {
    let panel = NSOpenPanel()
    panel.title = "Add an Amazon Photos Inventory"
    panel.message =
      "Choose a completed private JSONL inventory. It is read locally and never uploaded."
    panel.prompt = "Add Inventory"
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    importSource(at: url, kind: .amazonInventory)
  }

  func connectApplePhotos() {
    importApplePhotos(existingSource: nil)
  }

  func refresh(_ source: LibraryProjectSource) {
    if source.kind == .applePhotos {
      importApplePhotos(existingSource: source)
      return
    }
    do {
      guard let bookmarkData = source.bookmarkData else {
        throw ProjectImportError.invalidSource
      }
      var isStale = false
      let url = try URL(
        resolvingBookmarkData: bookmarkData,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      importSource(at: url, kind: source.kind, existingSource: source)
    } catch {
      notice = ProjectNotice(
        title: "Source Access Expired",
        message: "Add the source again to restore access. Existing catalog data is unchanged."
      )
    }
  }

  func setDuplicateDisposition(
    _ disposition: DuplicateReviewDisposition?,
    for candidateID: String
  ) {
    updateReviewState { state in
      state.setDuplicateDisposition(disposition, for: candidateID)
    }
  }

  func setAllAmazonCandidates(_ disposition: DuplicateReviewDisposition?) {
    let candidateIDs = identityIndex.amazonMD5ReviewCandidates.map(\.id)
    updateReviewState { state in
      state.setDuplicateDisposition(disposition, for: candidateIDs)
    }
  }

  func createCanonicalPerson(from sourcePersonID: String, preferredName: String) {
    updateReviewState { state in
      state.createCanonicalPerson(
        preferredName: preferredName,
        sourcePersonID: sourcePersonID
      )
    }
  }

  func setPrivacyCategory(_ category: PersonPrivacyCategory, for personID: String) {
    updateReviewState { state in
      state.setPrivacyCategory(category, for: personID)
    }
  }

  func openProviderAccessLab() {
    let labURL = Bundle.main.bundleURL
      .deletingLastPathComponent()
      .appending(path: "Provider Access Lab.app", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: labURL.path) else {
      notice = ProjectNotice(
        title: "Access Lab Is Missing",
        message: "Run `make package` to assemble both applications."
      )
      return
    }
    NSWorkspace.shared.openApplication(
      at: labURL,
      configuration: NSWorkspace.OpenConfiguration()
    ) { [weak self] _, error in
      guard error != nil else { return }
      Task { @MainActor in
        self?.notice = ProjectNotice(
          title: "Access Lab Could Not Be Opened",
          message: "Rebuild the application bundle and try again."
        )
      }
    }
  }

  func openPlanDetails() {
    guard let planURL = Bundle.main.url(forResource: "PLAN_DETAILS", withExtension: "md") else {
      notice = ProjectNotice(
        title: "Plan Details Are Missing",
        message: "Run `make package` to include the project documentation."
      )
      return
    }
    if !NSWorkspace.shared.open(planURL) {
      notice = ProjectNotice(
        title: "Plan Details Could Not Be Opened",
        message: "No application accepted the bundled Markdown document."
      )
    }
  }

  private func importSource(
    at sourceURL: URL,
    kind: LibraryProjectSourceKind,
    existingSource: LibraryProjectSource? = nil
  ) {
    guard !isImporting, let projectURL, project != nil else { return }
    let bookmarkData: Data
    do {
      bookmarkData = try sourceURL.bookmarkData(
        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    } catch {
      notice = ProjectNotice(
        title: "Source Access Could Not Be Saved",
        message: "Select the source again and confirm that it remains available."
      )
      return
    }

    isImporting = true
    importProgressMessage = kind == .folder ? "Reading folder" : "Reading Amazon inventory"
    notice = nil
    let importedAt = Date()
    Task {
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
          let projectAccess = projectURL.startAccessingSecurityScopedResource()
          defer {
            if sourceAccess { sourceURL.stopAccessingSecurityScopedResource() }
            if projectAccess { projectURL.stopAccessingSecurityScopedResource() }
          }
          let incoming: CatalogSnapshot
          switch kind {
          case .applePhotos:
            throw ProjectImportError.invalidSource
          case .folder:
            if let existingSource, let externalAccountID = existingSource.externalAccountID {
              incoming = try FilesystemCatalogImporter().importCatalog(
                from: sourceURL,
                importedAt: importedAt,
                sourceIdentity: FilesystemSourceIdentity(
                  sourceLibraryID: existingSource.id,
                  externalAccountID: externalAccountID
                )
              )
            } else {
              incoming = try FilesystemCatalogImporter().importCatalog(
                from: sourceURL,
                importedAt: importedAt
              )
            }
          case .amazonInventory:
            incoming = try AmazonCatalogImporter().importCatalog(
              from: sourceURL,
              importedAt: importedAt
            )
          }
          guard let library = incoming.sourceLibraries.only else {
            throw ProjectImportError.invalidSource
          }
          let source = LibraryProjectSource(
            id: library.id,
            provider: library.provider,
            kind: kind,
            externalAccountID: library.externalAccountID,
            displayName: kind.displayName(for: sourceURL),
            bookmarkData: bookmarkData,
            addedAt: importedAt,
            lastImportedAt: importedAt,
            itemCount: incoming.sourceItems.count
          )
          return try LibraryProjectStore.importCatalog(
            incoming,
            source: source,
            into: projectURL,
            importedAt: importedAt
          )
        }.value
        project = result.project
        catalog = result.catalog
        identityIndex = CatalogIdentityIndex(snapshot: catalog)
        reviewState = result.reviewState
      } catch {
        notice = ProjectNotice(
          title: "Source Import Failed",
          message: safeMessage(
            for: error,
            fallback: "The source could not be validated. Existing source files were not changed."
          )
        )
      }
      isImporting = false
      importProgressMessage = nil
    }
  }

  private func importApplePhotos(existingSource: LibraryProjectSource?) {
    guard !isImporting, let projectURL, project != nil else { return }
    let sourceIdentity: ApplePhotosSourceIdentity
    if let existingSource, let externalAccountID = existingSource.externalAccountID {
      sourceIdentity = ApplePhotosSourceIdentity(
        sourceLibraryID: existingSource.id,
        externalAccountID: externalAccountID
      )
    } else {
      sourceIdentity = .make()
    }

    isImporting = true
    importProgressMessage = "Requesting Apple Photos access"
    notice = nil
    let importedAt = Date()
    Task {
      do {
        let capture = try await ApplePhotosCatalogAdapter().capture(
          sourceIdentity: sourceIdentity,
          importedAt: importedAt
        ) { [weak self] progress in
          Task { @MainActor in
            self?.importProgressMessage =
              "Scanning Apple Photos: \(progress.completedAssets.formatted()) of "
              + "\(progress.totalAssets.formatted()) assets, "
              + "\(progress.measuredResources.formatted()) local resources"
          }
        }
        let incomingExternalIDs = capture.snapshot.sourceItems.map(\.externalID)
        if existingSource == nil {
          let incomingSet = Set(incomingExternalIDs)
          let alreadyConnected =
            project?.sources.contains { source in
              guard source.kind == .applePhotos else { return false }
              let anchors =
                source.identityAnchorExternalIDs
                ?? catalog.sourceItems.filter { $0.sourceLibraryID == source.id }.map(\.externalID)
              return anchors.contains(where: incomingSet.contains)
            } == true
          guard !alreadyConnected else {
            throw ApplePhotosCatalogBuildError.sourceLibraryAlreadyConnected
          }
        }
        let previousAnchors =
          existingSource?.identityAnchorExternalIDs
          ?? catalog.sourceItems.filter { $0.sourceLibraryID == sourceIdentity.sourceLibraryID }
          .map(\.externalID)
        let identityAnchors = try ApplePhotosCatalogBuilder.updatedIdentityAnchors(
          previous: previousAnchors,
          incoming: incomingExternalIDs
        )
        let source = LibraryProjectSource(
          id: sourceIdentity.sourceLibraryID,
          provider: .applePhotos,
          kind: .applePhotos,
          externalAccountID: sourceIdentity.externalAccountID,
          displayName: "Apple Photos",
          addedAt: importedAt,
          lastImportedAt: importedAt,
          itemCount: capture.snapshot.sourceItems.count,
          measuredResourceCount: capture.measuredResourceCount,
          networkRequiredResourceCount: capture.networkRequiredResourceCount,
          unavailableResourceCount: capture.unavailableResourceCount,
          identityAnchorExternalIDs: identityAnchors
        )
        importProgressMessage = "Validating Apple Photos catalog"
        let result = try await Task.detached(priority: .userInitiated) {
          let projectAccess = projectURL.startAccessingSecurityScopedResource()
          defer { if projectAccess { projectURL.stopAccessingSecurityScopedResource() } }
          return try LibraryProjectStore.importCatalog(
            capture.snapshot,
            source: source,
            into: projectURL,
            importedAt: importedAt
          )
        }.value
        project = result.project
        catalog = result.catalog
        identityIndex = CatalogIdentityIndex(snapshot: catalog)
        reviewState = result.reviewState
      } catch {
        notice = ProjectNotice(
          title: "Apple Photos Import Failed",
          message: safeMessage(
            for: error,
            fallback: "Apple Photos could not be inventoried. No library content was changed."
          )
        )
      }
      isImporting = false
      importProgressMessage = nil
    }
  }

  private func safeMessage(for error: Error, fallback: String) -> String {
    switch error {
    case let localized as LibraryProjectStoreError:
      localized.errorDescription ?? fallback
    case let localized as CatalogStoreError:
      localized.errorDescription ?? fallback
    case let localized as FilesystemCatalogImportError:
      localized.errorDescription ?? fallback
    case let localized as AmazonCatalogImportError:
      localized.errorDescription ?? fallback
    case let localized as ApplePhotosCatalogAdapterError:
      localized.errorDescription ?? fallback
    case let localized as ApplePhotosCatalogBuildError:
      localized.errorDescription ?? fallback
    default:
      fallback
    }
  }

  private func updateReviewState(
    _ update: (inout LibraryProjectReviewState) throws -> Void
  ) {
    guard let projectURL else { return }
    do {
      reviewState = try LibraryProjectStore.updateReviewState(at: projectURL, update: update)
      notice = nil
    } catch {
      notice = ProjectNotice(
        title: "Review Change Could Not Be Saved",
        message: safeMessage(
          for: error,
          fallback: "The Library Project is unchanged. Try the review action again."
        )
      )
    }
  }
}

struct ProjectNotice: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

private enum ProjectImportError: Error {
  case invalidSource
}

extension Array {
  fileprivate var only: Element? {
    count == 1 ? self[0] : nil
  }
}

extension LibraryProjectSourceKind {
  fileprivate func displayName(for url: URL) -> String {
    switch self {
    case .amazonInventory: "Amazon Photos"
    case .applePhotos: "Apple Photos"
    case .folder: url.lastPathComponent
    }
  }
}
