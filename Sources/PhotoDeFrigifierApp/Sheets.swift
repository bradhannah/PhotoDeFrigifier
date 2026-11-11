import QuickFixCore
import SwiftUI

// MARK: Redate

struct RedateSheet: View {
  @Environment(ReviewModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  enum Mode: String, CaseIterable { case approximate = "Year or month only", exact = "Exact date and time" }

  @State private var mode: Mode = .approximate
  @State private var yearText = ""
  @State private var month = 0
  @State private var day = 0
  @State private var exact = Date()

  var body: some View {
    let current = model.current?.creationDate
    VStack(alignment: .leading, spacing: 16) {
      Text("Set the date").font(.title2.bold())
      HStack {
        Text("Now:").foregroundStyle(.secondary)
        Text(current.map { $0.formatted(date: .long, time: .shortened) } ?? "No date")
        if model.current?.isUndated == true { Text("(undated)").foregroundStyle(.red) }
      }
      Picker("", selection: $mode) {
        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if mode == .approximate {
        HStack(spacing: 12) {
          TextField("Year", text: $yearText)
            .frame(width: 80)
            .textFieldStyle(.roundedBorder)
          Picker("Month", selection: $month) {
            Text("Unknown").tag(0)
            ForEach(1...12, id: \.self) { Text(Calendar.current.monthSymbols[$0 - 1]).tag($0) }
          }
          .frame(width: 180)
          Picker("Day", selection: $day) {
            Text("Unknown").tag(0)
            ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
          }
          .frame(width: 130)
          .disabled(month == 0)
        }
        Text("Year only sets 1 July at noon; a known month sets the 15th. The photo is noted as “date approximate”.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        DatePicker("Date and time", selection: $exact)
          .datePickerStyle(.field)
      }

      if let last = model.lastAppliedDate {
        Button("Use the last date I set: \(last.formatted(date: .abbreviated, time: .shortened))") {
          mode = .exact
          exact = last
        }
        .buttonStyle(.link)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Set Date") {
          if let (date, approx) = chosen {
            model.applyDate(date, approximate: approx)
            dismiss()
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(chosen == nil)
      }
    }
    .padding(24)
    .frame(width: 520)
    .onAppear {
      if let d = current, !(model.current?.isUndated ?? true) {
        exact = d
        yearText = String(Calendar.current.component(.year, from: d))
      }
    }
  }

  private var chosen: (Date, Bool)? {
    switch mode {
    case .exact:
      return (exact, false)
    case .approximate:
      guard let year = Int(yearText.trimmingCharacters(in: .whitespaces)), (1826...2100).contains(year) else {
        return nil
      }
      let m = month == 0 ? nil : month
      let d = (month == 0 || day == 0) ? nil : day
      guard let date = DateRules.placeholder(year: year, month: m, day: d) else { return nil }
      return (date, DateRules.isApproximate(month: m, day: d))
    }
  }
}

// MARK: Thumbnails

struct Thumbnail: View {
  let id: String
  var size: CGFloat = 150
  @Environment(PhotoLibrary.self) private var library
  @State private var image: NSImage?

  var body: some View {
    ZStack {
      Rectangle().fill(.quaternary)
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
      }
    }
    .frame(width: size, height: size)
    .clipped()
    .task(id: id) {
      image = await library.image(for: id, size: CGSize(width: size * 2, height: size * 2), fast: false)
    }
  }
}

// MARK: Delete review

struct DeleteReviewSheet: View {
  @Environment(ReviewModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var selected: Set<String> = []
  @State private var ids: [String] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Photos marked To Delete").font(.title2.bold())
      Text(
        "Click a photo to leave it out. “Move to Recently Deleted” asks macOS for confirmation first, and Photos keeps them for 30 days."
      )
      .foregroundStyle(.secondary)
      if ids.isEmpty {
        ContentUnavailableView("Nothing marked for deletion", systemImage: "trash.slash")
          .frame(maxWidth: .infinity, minHeight: 300)
      } else {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            ForEach(ids, id: \.self) { id in
              Thumbnail(id: id)
                .overlay(alignment: .topTrailing) {
                  Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected.contains(id) ? .red : .white)
                    .shadow(radius: 2)
                    .padding(6)
                }
                .opacity(selected.contains(id) ? 1 : 0.45)
                .onTapGesture {
                  if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
                }
                .help(model.store.record(id)?.filename ?? id)
            }
          }
        }
        .frame(minHeight: 360)
      }
      HStack {
        Text("\(selected.count) of \(ids.count) selected").foregroundStyle(.secondary)
        Spacer()
        Button("Close") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Unmark Unselected") {
          model.unflag(ids.filter { !selected.contains($0) }, .delete)
          reload()
        }
        .disabled(selected.count == ids.count)
        Button("Move \(selected.count) to Recently Deleted…") {
          let chosen = ids.filter { selected.contains($0) }
          Task {
            if await model.deleteFlagged(chosen) { reload() }
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(selected.isEmpty || model.busy)
      }
    }
    .padding(24)
    .frame(width: 860, height: 640)
    .onAppear(perform: reload)
  }

  private func reload() {
    ids = model.flaggedForDeletion
    selected = Set(ids)
  }
}

// MARK: Records export

struct RecordsSheet: View {
  @Environment(ReviewModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var ids: [String] = []
  @State private var done = 0
  @State private var total = 0
  @State private var result: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Photos marked To Records").font(.title2.bold())
      Text(
        "Each original is copied into your records folder and checked. Once saved, it's marked To Delete so you can remove it from Photos in the delete review. Nothing is removed here."
      )
      .foregroundStyle(.secondary)
      HStack {
        Text("Records folder:")
        Text(model.recordsFolder?.path ?? "Not chosen")
          .foregroundStyle(model.recordsFolder == nil ? .red : .primary)
          .lineLimit(1).truncationMode(.middle)
        Spacer()
        Button("Choose…", action: chooseFolder)
      }
      if ids.isEmpty {
        ContentUnavailableView("Nothing marked for records", systemImage: "folder")
          .frame(maxWidth: .infinity, minHeight: 260)
      } else {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
            ForEach(ids, id: \.self) { id in
              VStack(spacing: 4) {
                Thumbnail(id: id, size: 130)
                Text(model.store.record(id)?.filename ?? "")
                  .font(.caption2).lineLimit(1)
                if model.store.record(id)?.exportedTo != nil {
                  Label("Saved", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                }
              }
            }
          }
        }
        .frame(minHeight: 300)
      }
      if total > 0 && done < total {
        ProgressView(value: Double(done), total: Double(total))
      }
      if let result { Text(result).foregroundStyle(.secondary) }
      HStack {
        Spacer()
        Button("Close") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save \(pending.count) to Records") {
          Task {
            let outcome = await model.exportRecords(pending) { d, t in
              done = d
              total = t
            }
            result =
              "Saved \(outcome.saved)."
              + (outcome.failed.isEmpty ? "" : " Couldn't save: \(outcome.failed.joined(separator: ", ")).")
            ids = model.flaggedForRecords
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(pending.isEmpty || model.recordsFolder == nil || model.busy)
      }
    }
    .padding(24)
    .frame(width: 820, height: 600)
    .onAppear { ids = model.flaggedForRecords }
  }

  private var pending: [String] { ids.filter { model.store.record($0)?.exportedTo == nil } }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Use This Folder"
    panel.directoryURL = model.recordsFolder
    if panel.runModal() == .OK { model.recordsFolder = panel.url }
  }
}

// MARK: Settings

struct SettingsView: View {
  @Environment(ReviewModel.self) private var model

  var body: some View {
    @Bindable var model = model
    Form {
      Picker("Order", selection: $model.order) {
        ForEach(ReviewOrder.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      Picker("Session goal", selection: $model.sessionGoal) {
        ForEach([5, 20, 50, 100, 500, 0], id: \.self) { n in Text(n == 0 ? "No goal" : "\(n) photos").tag(n) }
      }
      Toggle("Leave out photos already marked “Everything is in Order!” in new passes", isOn: $model.skipInOrder)
      Toggle("Mirror markers to albums in a “Quick Fix” folder in Photos", isOn: $model.mirrorToAlbums)
      LabeledContent("Records folder") {
        Text(model.recordsFolder?.path ?? "Not chosen").lineLimit(1).truncationMode(.middle)
      }
      LabeledContent("Review store") {
        Button("Show in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([model.store.fileURL])
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 560)
    .padding()
  }
}
