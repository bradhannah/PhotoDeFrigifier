import QuickFixCore
import SwiftUI

struct InspectorView: View {
  @Environment(ReviewModel.self) private var model
  @Environment(PhotoLibrary.self) private var library

  var body: some View {
    if let asset = model.current {
      Form {
        Section("Photo") {
          LabeledContent("File", value: model.currentFilename ?? "—")
          LabeledContent("Date") {
            VStack(alignment: .trailing) {
              Text(asset.creationDate.map { $0.formatted(date: .long, time: .shortened) } ?? "None")
              if asset.isUndated {
                Text("No real date. Press T to set one.").font(.caption).foregroundStyle(.red)
              }
            }
          }
          LabeledContent("Kind", value: kindText(asset))
          if let keywords = model.currentKeywords {
            LabeledContent("Keywords", value: keywords.isEmpty ? "None" : keywords.joined(separator: ", "))
          }
          LabeledContent("Location", value: asset.hasLocation ? "Yes" : "None")
          LabeledContent("Favourite", value: asset.isFavorite ? "Yes" : "No")
          LabeledContent("Edited", value: asset.hasAdjustments ? "Yes" : "No")
        }
        Section("In albums") {
          if model.currentAlbums.isEmpty {
            Text("Not in any album").foregroundStyle(.secondary)
          }
          ForEach(model.currentAlbums) { album in
            Button {
              model.select(.album(id: album.id, title: album.title))
            } label: {
              Label(album.path, systemImage: "rectangle.stack")
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Review this album")
          }
        }
        Section("Review history") {
          let r = model.currentRecord
          LabeledContent("Last call", value: r?.verdict?.pastTitle ?? "—")
          if let at = r?.verdictAt {
            LabeledContent("When", value: at.formatted(date: .abbreviated, time: .shortened))
          }
          LabeledContent("Times reviewed", value: "\(r?.reviewCount ?? 0)")
          LabeledContent("Marked", value: r.map { $0.flags.map(\.title).joined(separator: ", ") }.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
          if let path = r?.exportedTo {
            LabeledContent("Saved to records") {
              Button((path as NSString).lastPathComponent) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
              }
              .buttonStyle(.link)
            }
          }
        }
        Section("Note") {
          TextField(
            "Anything to remember about this photo",
            text: Binding(get: { model.currentRecord?.note ?? "" }, set: { model.setNote($0) }),
            axis: .vertical
          )
          .lineLimit(3...8)
        }
        Section {
          Text("Keys: 1 Good Enough · 2 Look at Later · 3 In Order · A Archive · H Health · L Album · ⌥1–5 Recent albums · D Delete · B Blurry · P Records · E/R Rotate · F Favourite · T Date · → Skip · ← Back · U Undo · ⌘C Copy · right-click for more")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .onChange(of: library.changeCount) { model.refreshAlbumsForCurrent() }
    } else {
      ContentUnavailableView("No photo", systemImage: "photo")
    }
  }

  private func kindText(_ a: AssetSummary) -> String {
    let size = a.pixelWidth > 0 ? " · \(a.pixelWidth)×\(a.pixelHeight) (\(String(format: "%.1f", a.megapixels)) MP)" : ""
    switch a.kind {
    case .video: return "Video · \(Duration.seconds(a.duration).formatted(.time(pattern: .minuteSecond)))\(size)"
    case .livePhoto: return "Live Photo\(size)"
    case .photo: return (a.isScreenshot ? "Screenshot" : "Photo") + size
    case .other: return "Other"
    }
  }
}
