import AppKit
import QuickFixCore
import SwiftUI

@main
struct PhotoDeFrigifierApp: App {
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
  @State private var model = ReviewModel()

  var body: some Scene {
    Window("PhotoDeFrigifier", id: "review") {
      ContentView()
        .environment(model)
        .environment(model.library)
        .frame(minWidth: 820, minHeight: 600)
    }
    .defaultSize(width: 1440, height: 920)
    .commands {
      CommandMenu("Review") {
        Button("Review Deletions…") { model.showDeleteReview = true }
          .keyboardShortcut("d", modifiers: [.command, .shift])
        Button("Save Records…") { model.showRecords = true }
          .keyboardShortcut("r", modifiers: [.command, .shift])
        Button("Hide Archived Photos (\(model.archivedToHide.count))") { Task { await model.hideArchived() } }
          .keyboardShortcut("h", modifiers: [.command, .shift])
          .disabled(model.archivedToHide.isEmpty)
        Divider()
        Button("Undo Last Action") { model.undo() }
          .disabled(!model.canUndo)
        Button("Start Another Pass") { model.startNextPass() }
        Divider()
        Button("Show Review Store in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([model.store.fileURL])
        }
      }
    }

    Settings {
      SettingsView()
        .environment(model)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Launched as a bare executable (swift run), macOS would treat it as a background tool.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
