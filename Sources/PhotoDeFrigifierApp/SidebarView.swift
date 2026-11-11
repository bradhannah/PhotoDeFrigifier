import QuickFixCore
import SwiftUI

struct SidebarView: View {
  @Environment(ReviewModel.self) private var model
  @Environment(PhotoLibrary.self) private var library

  private let findQueues: [SmartQueue] = [.notReviewed, .undated, .screenshots, .shortVideos, .lowResolution, .noLocation]
  private let markQueues: [SmartQueue] = [.lookLater, .toDelete, .blurry, .toRecords]

  var body: some View {
    let selection = Binding<Scope?>(
      get: { model.scope },
      set: { if let s = $0, s != model.scope { model.select(s) } })
    List(selection: selection) {
      Section("Library") {
        row("All Photos", "photo.on.rectangle", library.summaries.count)
          .tag(Scope.library)
      }
      Section("Needs a Look") {
        ForEach(findQueues, id: \.self) { q in
          row(q.title, q.systemImage, model.queueCounts[q] ?? 0).tag(Scope.queue(q))
        }
      }
      Section("Marked") {
        ForEach(markQueues, id: \.self) { q in
          row(q.title, q.systemImage, model.queueCounts[q] ?? 0).tag(Scope.queue(q))
        }
      }
      Section("Albums") {
        OutlineGroup(library.albums, children: \.children) { node in
          row(node.title, node.isFolder ? "folder" : "rectangle.stack", node.count)
            .tag(Scope.album(id: node.id, title: node.title))
        }
      }
    }
    .listStyle(.sidebar)
    .overlay {
      if library.isLoading { ProgressView().controlSize(.small) }
    }
  }

  private func row(_ title: String, _ icon: String, _ count: Int?) -> some View {
    HStack {
      Label(title, systemImage: icon)
        .lineLimit(1)
      Spacer()
      if let count {
        Text(count, format: .number)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
  }
}
