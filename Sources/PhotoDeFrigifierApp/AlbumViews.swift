import QuickFixCore
import SwiftUI

private let albumBlue = Color(red: 0.36, green: 0.55, blue: 1.0)

/// The five most recent albums under the health panel. ⌥1–⌥5 or a click adds the photo (again removes it).
struct RecentAlbumsPanel: View {
  @Environment(ReviewModel.self) private var model

  var body: some View {
    let recent = model.recentAlbums
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Text("Recent albums").font(.system(size: 13, weight: .bold))
        Spacer()
        Text("newest first").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 4)
      .padding(.bottom, 2)
      if recent.isEmpty {
        Text("Albums you add photos to show up here.")
          .font(.system(size: 11.5)).foregroundStyle(.secondary)
          .padding(.horizontal, 4).padding(.vertical, 6)
      }
      ForEach(Array(recent.enumerated()), id: \.element.id) { index, album in
        RecentAlbumRow(
          album: album, key: "⌥\(index + 1)", when: model.recentLabel(album.id), inIt: model.isInAlbum(album.id)
        ) {
          model.toggleAlbum(album)
        }
      }
      Button {
        model.showAlbumPicker = true
      } label: {
        HStack {
          Text("All albums…").font(.system(size: 12.5, weight: .semibold))
          Spacer()
          KeyCap(key: "L")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.top, 3)
      .help("Pick any album, search, or make a new one (L)")
    }
    .padding(10)
    .frame(width: 214)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.12).opacity(0.94)))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    .foregroundStyle(Color(white: 0.93))
    .environment(\.colorScheme, .dark)
    .disabled(model.current == nil || model.busy)
  }
}

struct RecentAlbumRow: View {
  let album: AlbumRef
  let key: String
  let when: String
  let inIt: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) {
        KeyCap(key: key)
        VStack(alignment: .leading, spacing: 1) {
          Text(album.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
          Text(when).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
        MembershipMark(inIt: inIt)
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(inIt ? albumBlue.opacity(0.16) : Color.white.opacity(hovering ? 0.10 : 0.05)))
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(inIt ? albumBlue.opacity(0.6) : Color.clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(inIt ? "In \(album.path). Click or press \(key) to take it out." : "Add to \(album.path) (\(key))")
  }
}

/// A filled blue check when the photo is in the album; an outlined plus when it isn't.
struct MembershipMark: View {
  let inIt: Bool

  var body: some View {
    if inIt {
      Image(systemName: "checkmark")
        .font(.system(size: 10, weight: .heavy))
        .foregroundStyle(Color(red: 0.05, green: 0.08, blue: 0.15))
        .frame(width: 20, height: 20)
        .background(Circle().fill(albumBlue))
        .accessibilityLabel("In this album")
    } else {
      Image(systemName: "plus")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .overlay(Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.3))
        .accessibilityLabel("Not in this album")
    }
  }
}

/// L: every album, recent first, with search and "new album". Keyboard-first: type, ↑↓, ⏎ (⌘⏎ also moves on).
struct AlbumPickerSheet: View {
  @Environment(ReviewModel.self) private var model
  @Environment(PhotoLibrary.self) private var library
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var selected = 0
  @State private var sameDay: [AlbumRef] = []
  @State private var creating = false
  @State private var newName = ""
  @State private var newFolder = ""
  @FocusState private var searchFocused: Bool
  @FocusState private var nameFocused: Bool

  struct Row: Identifiable {
    let id: String
    let album: AlbumRef?
    let section: String
    let key: String?
    let newName: String?
  }

  private var rows: [Row] {
    let recent = model.recentAlbums
    let q = query.trimmingCharacters(in: .whitespaces)
    if q.isEmpty {
      var out = recent.enumerated().map {
        Row(id: "r-\($1.id)", album: $1, section: "Recent · newest first", key: "⌘\($0 + 1)", newName: nil)
      }
      let recentIDs = Set(recent.map(\.id))
      out += sameDay.filter { !recentIDs.contains($0.id) }.prefix(3).map {
        Row(id: "d-\($0.id)", album: $0, section: "Same day as this photo", key: nil, newName: nil)
      }
      out += library.pickableAlbums.map {
        Row(id: "a-\($0.id)", album: $0, section: "All albums · A–Z", key: nil, newName: nil)
      }
      return out
    }
    let matches = AlbumRules.search(library.pickableAlbums, query: q, recentIDs: model.recentAlbumEntries.map(\.id))
    var out = matches.map { Row(id: "m-\($0.id)", album: $0, section: "Matches", key: nil, newName: nil) }
    if !matches.contains(where: { $0.title.localizedCaseInsensitiveCompare(q) == .orderedSame }) {
      out.append(Row(id: "new", album: nil, section: "", key: nil, newName: q))
    }
    return out
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        Text(creating ? "New album" : "Add to album").font(.title3.bold())
        Spacer()
        Text("\(model.currentFilename ?? "This photo") · in \(model.currentAlbums.count) album\(model.currentAlbums.count == 1 ? "" : "s")")
          .font(.caption).foregroundStyle(.secondary)
      }
      .padding([.horizontal, .top], 18)
      .padding(.bottom, 10)

      if creating {
        newAlbumForm
      } else {
        searchField
        list
      }

      Divider()
      HStack(spacing: 16) {
        if creating {
          hint("⏎", "create and add")
          hint("esc", "close")
        } else {
          hint("↑ ↓", "choose")
          hint("⏎", "add or remove")
          hint("⌘⏎", "add and next photo")
          hint("⌘1–5", "recent")
          hint("⌘N", "new album")
          hint("esc", "close")
        }
        Spacer()
      }
      .font(.caption)
      .padding(.horizontal, 18).padding(.vertical, 10)
    }
    .frame(width: 620, height: 640)
    .background(Color(nsColor: .windowBackgroundColor))
    .background(shortcuts)
    .onAppear {
      if let id = model.currentID { sameDay = library.sameDayAlbums(as: id) }
      searchFocused = true
    }
    .onChange(of: query) { selected = 0 }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Search albums, or type a new album name", text: $query)
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .focused($searchFocused)
        .onKeyPress(.downArrow) {
          selected = min(selected + 1, max(rows.count - 1, 0))
          return .handled
        }
        .onKeyPress(.upArrow) {
          selected = max(selected - 1, 0)
          return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
          activate(selected, thenNext: press.modifiers.contains(.command))
          return .handled
        }
    }
    .padding(.horizontal, 12)
    .frame(height: 40)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(albumBlue.opacity(0.8)))
    .padding(.horizontal, 18)
    .padding(.bottom, 8)
  }

  private var list: some View {
    let all = rows
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(Array(all.enumerated()), id: \.element.id) { index, row in
            if !row.section.isEmpty && (index == 0 || all[index - 1].section != row.section) {
              Text(row.section.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, index == 0 ? 4 : 12)
                .padding(.bottom, 4)
            }
            rowView(row, index: index).id(row.id)
          }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
      }
      .onChange(of: selected) {
        if all.indices.contains(selected) { proxy.scrollTo(all[selected].id) }
      }
    }
  }

  @ViewBuilder
  private func rowView(_ row: Row, index: Int) -> some View {
    let isSelected = index == selected
    if let album = row.album {
      let inIt = model.isInAlbum(album.id)
      Button {
        selected = index
        activate(index, thenNext: false)
      } label: {
        HStack(spacing: 10) {
          if let key = row.key { KeyCap(key: key) }
          VStack(alignment: .leading, spacing: 1) {
            Text(album.title).font(.system(size: row.key != nil ? 14 : 13, weight: row.key != nil ? .semibold : .regular))
            Text(row.key != nil ? "\(album.folderPath.isEmpty ? "Top level" : album.folderPath) · \(model.recentLabel(album.id).lowercased())"
                 : (album.folderPath.isEmpty ? "Top level" : album.folderPath))
              .font(.system(size: 11)).foregroundStyle(.secondary)
          }
          Spacer()
          if isSelected {
            Text(inIt ? "⏎ Remove" : "⏎ Add").font(.system(size: 11, weight: .semibold)).foregroundStyle(albumBlue)
          }
          MembershipMark(inIt: inIt)
        }
        .padding(.horizontal, 10).padding(.vertical, row.key != nil ? 8 : 6)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isSelected ? albumBlue.opacity(0.18) : (inIt ? albumBlue.opacity(0.06) : .clear)))
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(isSelected ? albumBlue.opacity(0.7) : .clear))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    } else if let name = row.newName {
      Button {
        selected = index
        activate(index, thenNext: false)
      } label: {
        HStack(spacing: 10) {
          Image(systemName: "plus").foregroundStyle(albumBlue)
          VStack(alignment: .leading, spacing: 1) {
            Text("New album “\(name)”").font(.system(size: 13.5, weight: .semibold))
            Text("Choose its folder next").font(.system(size: 11)).foregroundStyle(.secondary)
          }
          Spacer()
          KeyCap(key: "⌘N")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(isSelected ? albumBlue.opacity(0.18) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.secondary.opacity(0.6)))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.top, 6)
    }
  }

  private var newAlbumForm: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Name").font(.caption).foregroundStyle(.secondary)
        TextField("Album name", text: $newName)
          .textFieldStyle(.roundedBorder)
          .focused($nameFocused)
          .onSubmit(create)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("In folder").font(.caption).foregroundStyle(.secondary)
        Picker("In folder", selection: $newFolder) {
          Text("Top level (no folder)").tag("")
          ForEach(library.folderRefs) { Text($0.path).tag($0.id) }
        }
        .labelsHidden()
      }
      Text("The photo goes straight into the new album, and the album becomes ⌥1 in Recent albums.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Back") { creating = false }
        Button("Create and Add", action: create)
          .keyboardShortcut(.defaultAction)
          .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      Spacer()
    }
    .padding(.horizontal, 18)
    .onAppear { nameFocused = true }
  }

  /// Hidden buttons that carry the sheet's keyboard shortcuts.
  private var shortcuts: some View {
    let recent = model.recentAlbums
    return ZStack {
      ForEach(Array(recent.prefix(5).enumerated()), id: \.offset) { index, album in
        Button("") {
          model.toggleAlbum(album)
          dismiss()
        }
        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
      }
      Button("") { startNewAlbum(named: query) }.keyboardShortcut("n", modifiers: .command)
      Button("") { dismiss() }.keyboardShortcut(.cancelAction)
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  private func activate(_ index: Int, thenNext: Bool) {
    let all = rows
    guard all.indices.contains(index) else { return }
    if let album = all[index].album {
      model.toggleAlbum(album, thenNext: thenNext)
      dismiss()
    } else if let name = all[index].newName {
      startNewAlbum(named: name)
    }
  }

  private func startNewAlbum(named name: String) {
    newName = name.trimmingCharacters(in: .whitespaces)
    // Default to the folder of the album you used most recently.
    newFolder = model.recentAlbums.first.flatMap { library.albumParent[$0.id] } ?? ""
    creating = true
  }

  private func create() {
    let name = newName.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return }
    model.createAlbumAndAdd(title: name, folderID: newFolder.isEmpty ? nil : newFolder)
    dismiss()
  }

  private func hint(_ key: String, _ text: String) -> some View {
    HStack(spacing: 4) {
      Text(key).fontWeight(.semibold)
      Text(text).foregroundStyle(.secondary)
    }
  }
}
