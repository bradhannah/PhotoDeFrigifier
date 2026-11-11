import QuickFixCore
import SwiftUI

struct ContentView: View {
  @Environment(ReviewModel.self) private var model
  @Environment(PhotoLibrary.self) private var library
  @State private var showInspector = true

  var body: some View {
    @Bindable var model = model
    Group {
      switch library.access {
      case .unknown:
        ProgressView("Opening your Photos library…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .denied, .limited:
        AccessView(limited: library.access == .limited)
      case .granted:
        NavigationSplitView {
          SidebarView()
            .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        } detail: {
          ReviewView()
            .inspector(isPresented: $showInspector) {
              InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
        }
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Menu {
          Picker("Order", selection: $model.order) {
            ForEach(ReviewOrder.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          Picker("Session goal", selection: $model.sessionGoal) {
            ForEach([5, 20, 50, 100, 500, 0], id: \.self) { n in
              Text(n == 0 ? "No goal" : "\(n) photos").tag(n)
            }
          }
          Toggle("Skip photos already “in order”", isOn: $model.skipInOrder)
          Toggle("Mirror markers to Photos albums", isOn: $model.mirrorToAlbums)
          Toggle("Show health panel (H)", isOn: $model.showHealth)
        } label: {
          Label("Options", systemImage: "slider.horizontal.3")
        }
        Button {
          Task { await model.hideArchived() }
        } label: {
          Label("Hide Archived (\(model.archivedToHide.count))", systemImage: "eye.slash")
        }
        .disabled(model.archivedToHide.isEmpty || model.busy)
        .help("Hide every archived photo in one go. macOS asks once for the whole batch.")
        Button {
          model.showRecords = true
        } label: {
          Label("Records (\(model.flaggedForRecords.count))", systemImage: "folder.badge.person.crop")
        }
        .help("Save photos marked “To Records” to your records folder")
        Button {
          model.showDeleteReview = true
        } label: {
          Label("Deletions (\(model.flaggedForDeletion.count))", systemImage: "trash")
        }
        .help("Review photos marked “To Delete” and move them to Recently Deleted")
        Button {
          showInspector.toggle()
        } label: {
          Label("Info", systemImage: "info.circle")
        }
      }
    }
    .sheet(isPresented: $model.showRedate) { RedateSheet() }
    .sheet(isPresented: $model.showDeleteReview) { DeleteReviewSheet() }
    .sheet(isPresented: $model.showRecords) { RecordsSheet() }
    .sheet(isPresented: $model.showAlbumPicker) { AlbumPickerSheet() }
    .background(WindowAccessor { model.reviewWindow = $0 })
    .task {
      model.installKeyMonitor()
      await model.start()
    }
  }
}

struct AccessView: View {
  let limited: Bool

  var body: some View {
    ContentUnavailableView {
      Label("PhotoDeFrigifier needs your Photos library", systemImage: "photo.on.rectangle.angled")
    } description: {
      Text(
        limited
          ? "Access is limited to selected photos. Allow full access to review the whole library."
          : "Allow access in System Settings › Privacy & Security › Photos, then reopen the app.")
    } actions: {
      Button("Open Privacy Settings") {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
      }
    }
  }
}

/// Hands the hosting NSWindow to the model so keyboard shortcuts only act on the review window.
struct WindowAccessor: NSViewRepresentable {
  let onWindow: (NSWindow) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    if let w = view.window { onWindow(w) }
  }
}
