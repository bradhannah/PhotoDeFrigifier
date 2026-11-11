import AVKit
import QuickFixCore
import SwiftUI

struct ReviewView: View {
  @Environment(ReviewModel.self) private var model
  @Environment(PhotoLibrary.self) private var library

  var body: some View {
    VStack(spacing: 0) {
      ProgressHeader()
      Divider()
      ZStack {
        Color.black
        if let asset = model.current {
          PhotoStage(asset: asset, revision: library.imageRevision[asset.id] ?? 0)
            // Keep the photo clear of the health panel (or the slim strip when it's hidden).
            .padding(.trailing, model.showHealth ? 236 : 30)
            .animation(.easeOut(duration: 0.18), value: model.showHealth)
            .contextMenu { PhotoContextMenu() }
          StageBadges(asset: asset, record: model.currentRecord)
          HealthOverlay()
        } else if model.currentID != nil {
          if model.currentRecord?.verdict == .archived {
            ContentUnavailableView(
              "Archived", systemImage: "archivebox",
              description: Text("Tagged “Archived” and hidden in Photos. Press → to carry on."))
              .foregroundStyle(.white)
          } else {
            ContentUnavailableView(
              "This photo is no longer in your library", systemImage: "trash",
              description: Text("Press → to carry on."))
              .foregroundStyle(.white)
          }
        } else if model.isPassComplete {
          PassCompleteView()
        } else if model.isScopeEmpty {
          ContentUnavailableView(
            "Nothing here", systemImage: "checkmark.seal",
            description: Text("“\(model.scope.title)” has no photos left to review."))
            .foregroundStyle(.white)
        } else {
          ProgressView().tint(.white)
        }
        if let status = model.status {
          VStack {
            Spacer()
            Text(status)
              .padding(.horizontal, 14).padding(.vertical, 8)
              .background(.thickMaterial, in: Capsule())
              .padding(.bottom, 16)
          }
          .transition(.opacity)
        }
      }
      .animation(.easeInOut(duration: 0.2), value: model.status)
      Divider()
      ActionBar()
    }
    .navigationTitle(model.scope.title)
  }
}

struct ProgressHeader: View {
  @Environment(ReviewModel.self) private var model

  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Pass \(model.passNumber) · \(model.scope.title)")
          .font(.headline)
        Text("\(model.passDone.formatted()) of \(model.passTotal.formatted()) reviewed in this pass")
          .font(.caption).foregroundStyle(.secondary)
      }
      .lineLimit(1)
      .layoutPriority(1)
      ProgressView(value: Double(model.passDone), total: Double(max(model.passTotal, 1)))
        .frame(minWidth: 50, maxWidth: 260)
      Spacer(minLength: 8)
      Group {
        if model.sessionGoal > 0 {
          Text("This session: \(model.sessionCount) of \(model.sessionGoal)")
            .foregroundStyle(model.sessionCount >= model.sessionGoal ? .green : .primary)
        } else {
          Text("This session: \(model.sessionCount)")
        }
      }
      .font(.headline)
      .lineLimit(1)
      .fixedSize()
      .help("Each album and queue remembers where you left off.")
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
  }
}

struct PhotoStage: View {
  let asset: AssetSummary
  let revision: Int
  @Environment(PhotoLibrary.self) private var library
  @State private var image: NSImage?
  @State private var player: AVPlayer?
  @State private var shownID: String?

  var body: some View {
    ZStack {
      if let player {
        VideoPlayer(player: player)
      } else if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .padding(8)
      } else {
        ProgressView().tint(.white)
      }
    }
    .task(id: "\(asset.id)#\(revision)") {
      player = nil
      if shownID != asset.id {
        image = nil
        shownID = asset.id
      }
      image = await library.image(for: asset.id, size: CGSize(width: 800, height: 800), fast: true) ?? image
      if asset.isVideo {
        if let item = await library.playerItem(for: asset.id), !Task.isCancelled {
          player = AVPlayer(playerItem: item)
        }
      } else {
        let full = await library.image(for: asset.id, size: PhotoLibrary.fullImageSize, fast: false)
        if !Task.isCancelled, let full { image = full }
      }
    }
  }
}

struct StageBadges: View {
  let asset: AssetSummary
  let record: AssetRecord?

  var body: some View {
    VStack {
      FlowLayout(spacing: 6, rowSpacing: 6) {
        if asset.isUndated { badge("Undated", .red) }
        if record?.dateApproximate == true { badge("Date approximate", .orange) }
        if asset.isFavorite { badge("♥ Favourite", .pink) }
        ForEach(record?.flags ?? [], id: \.self) { badge($0.title, $0 == .delete ? .red : .orange) }
        if let v = record?.verdict { badge("Last time: \(v.pastTitle)", .gray) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Spacer()
    }
    .padding(12)
    .allowsHitTesting(false)
  }

  private func badge(_ text: String, _ color: Color) -> some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(color.opacity(0.85), in: Capsule())
      .foregroundStyle(.white)
  }
}

struct PassCompleteView: View {
  @Environment(ReviewModel.self) private var model

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(.green)
      Text("You've been through every photo in “\(model.scope.title)”").font(.title2)
      Text("Pass \(model.passNumber) is complete. Another pass starts over in a new order\(model.skipInOrder ? ", leaving out photos marked “Everything is in Order!”" : "").")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)
      Button("Start Pass \(model.passNumber + 1)") { model.startNextPass() }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
    .foregroundStyle(.white)
    .padding()
  }
}

struct ActionBar: View {
  @Environment(ReviewModel.self) private var model

  var body: some View {
    // Widest layout that fits: one row; then tools above full-width decisions; then the same without tool labels.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        tools(labels: true)
        Spacer(minLength: 16)
        decisions(short: false, stretch: false)
      }
      VStack(spacing: 10) {
        tools(labels: true, spread: true)
        decisions(short: false, stretch: true)
      }
      VStack(spacing: 8) {
        tools(labels: false, spread: true)
        decisions(short: true, stretch: true)
      }
    }
    .disabled(model.current == nil || model.busy)
    .padding(.horizontal, 14).padding(.vertical, 10)
  }

  private func tools(labels: Bool, spread: Bool = false) -> some View {
    let record = model.currentRecord
    let asset = model.current
    let canRotate = asset?.kind == .photo
    let favourite = asset?.isFavorite == true
    let toDelete = record?.has(.delete) == true
    let blurry = record?.has(.blurry) == true
    let records = record?.has(.records) == true
    let gap = { () -> AnyView in
      spread
        ? AnyView(HStack(spacing: 0) { Spacer(minLength: 4); ToolDivider(); Spacer(minLength: 4) })
        : AnyView(ToolDivider())
    }
    return HStack(spacing: 4) {
      ToolButton("Back", "chevron.left", "←", labels: labels) { model.goBack() }
        .disabled(!model.canGoBack)
      ToolButton("Skip", "chevron.right", "→", labels: labels, help: "Skip (→ or Space)") { model.skip() }
      ToolButton("Undo", "arrow.uturn.backward", "U", labels: labels, help: "Undo the last action (U or ⌘Z)") {
        model.undo()
      }
      .disabled(!model.canUndo)
      gap()
      ToolButton("Rotate L", "rotate.left", "E", labels: labels, help: "Rotate left (E or [)") {
        model.rotate(clockwise: false)
      }
      .disabled(!canRotate)
      ToolButton("Rotate R", "rotate.right", "R", labels: labels, help: "Rotate right (R or ])") {
        model.rotate(clockwise: true)
      }
      .disabled(!canRotate)
      ToolButton("Favourite", favourite ? "heart.fill" : "heart", "F", labels: labels, active: favourite, tint: .pink) {
        model.toggleFavorite()
      }
      ToolButton("Date", "calendar", "T", labels: labels, help: "Set the date (T)") { model.showRedate = true }
      ToolButton("Album", "rectangle.stack.badge.plus", "L", labels: labels,
                 help: "Add to an album (L). ⌥1–⌥5 add to your recent albums directly.") {
        model.showAlbumPicker = true
      }
      gap()
      ToolButton("Delete", toDelete ? "trash.fill" : "trash", "D", labels: labels, active: toDelete, tint: .red,
                 help: "Mark to delete (D). Deleting happens later, in Review Deletions.") {
        model.toggle(.delete)
      }
      ToolButton("Blurry", "aqi.medium", "B", labels: labels, active: blurry, tint: .orange,
                 help: "Mark as blurry (B)") {
        model.toggle(.blurry)
      }
      ToolButton("Records", records ? "folder.fill.badge.person.crop" : "folder.badge.person.crop", "P",
                 labels: labels, active: records, tint: .blue,
                 help: "Mark to save to your records folder (P)") {
        model.toggle(.records)
      }
    }
    .fixedSize(horizontal: !spread, vertical: true)
  }

  private func decisions(short: Bool, stretch: Bool) -> some View {
    StretchRow(spacing: 8, stretch: stretch) {
      ForEach(Verdict.allCases, id: \.self) { v in
        Button {
          model.setVerdict(v)
        } label: {
          HStack(spacing: 8) {
            Text(short ? v.shortTitle : v.title)
              .font(.system(size: 13, weight: .semibold))
              .lineLimit(1)
            KeyCap(key: String(v.key), onColor: v != .archived)
          }
          .padding(.horizontal, 14)
          .frame(height: 38)
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(DecisionButtonStyle(color: v.color, filled: v != .archived))
        .help(
          v == .archived
            ? "Archive (A): keep it, but out of sight. Adds the “Archived” keyword now; Hide Archived hides the whole batch later."
            : "\(v.title) (\(String(v.key))). Moves to the next photo.")
      }
    }
  }
}

/// A row that gives each child its natural width plus an equal share of any spare width, so long labels never
/// truncate while the row still fills the bar. Without `stretch` it's just the natural widths.
struct StretchRow: Layout {
  var spacing: CGFloat = 8
  var stretch = true

  private func widths(_ subviews: Subviews, available: CGFloat?) -> [CGFloat] {
    let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
    guard stretch, let available, available.isFinite else { return ideal }
    let spare = available - ideal.reduce(0, +) - spacing * CGFloat(max(subviews.count - 1, 0))
    return ideal.map { $0 + max(spare, 0) / CGFloat(max(subviews.count, 1)) }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let w = widths(subviews, available: proposal.width)
    let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
    return CGSize(width: w.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0)), height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    for (view, w) in zip(subviews, widths(subviews, available: bounds.width)) {
      view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: w, height: bounds.height))
      x += w + spacing
    }
  }
}

extension Verdict {
  var color: Color {
    switch self {
    case .goodEnough: Color(hue: 0.52, saturation: 0.78, brightness: 0.60)
    case .lookLater: Color(hue: 0.69, saturation: 0.52, brightness: 0.74)
    case .inOrder: Color(hue: 0.38, saturation: 0.72, brightness: 0.56)
    case .archived: Color(hue: 0.08, saturation: 0.45, brightness: 0.80)
    }
  }
}

/// A small keyboard-key badge.
struct KeyCap: View {
  let key: String
  var onColor = false

  var body: some View {
    Text(key)
      .font(.system(size: 9.5, weight: .semibold, design: .rounded))
      .foregroundStyle(onColor ? Color.white.opacity(0.92) : Color.secondary)
      .frame(minWidth: 15, minHeight: 15)
      .padding(.horizontal, 2)
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .strokeBorder(onColor ? Color.white.opacity(0.55) : Color.secondary.opacity(0.45), lineWidth: 0.8))
  }
}

struct ToolDivider: View {
  var body: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.25))
      .frame(width: 1, height: 30)
      .padding(.horizontal, 6)
  }
}

/// A flat tool tile: icon, optional short label, and its key. Marked tools are tinted.
struct ToolButton: View {
  let title: String
  let icon: String
  let key: String
  var labels = true
  var active = false
  var tint: Color = .accentColor
  var help: String?
  let action: () -> Void

  init(_ title: String, _ icon: String, _ key: String, labels: Bool = true, active: Bool = false,
       tint: Color = .accentColor, help: String? = nil, action: @escaping () -> Void) {
    self.title = title
    self.icon = icon
    self.key = key
    self.labels = labels
    self.active = active
    self.tint = tint
    self.help = help
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Image(systemName: icon)
          .font(.system(size: 15, weight: .medium))
          .frame(height: 18)
        if labels {
          Text(title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
        } else {
          KeyCap(key: key)
        }
      }
      .frame(width: labels ? 66 : 42, height: labels ? 46 : 44)
      .overlay(alignment: .topTrailing) {
        if labels { KeyCap(key: key).scaleEffect(0.78, anchor: .topTrailing).padding(.top, 3).padding(.trailing, 3) }
      }
    }
    .buttonStyle(ToolButtonStyle(active: active, tint: tint))
    .help(help ?? "\(title) (\(key))")
  }
}

struct ToolButtonStyle: ButtonStyle {
  var active = false
  var tint: Color = .accentColor

  func makeBody(configuration: Configuration) -> some View {
    ToolButtonBody(configuration: configuration, active: active, tint: tint)
  }
}

private struct ToolButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let active: Bool
  let tint: Color
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    let base: Double = configuration.isPressed ? 0.16 : (hovering ? 0.10 : 0.045)
    configuration.label
      .foregroundStyle(active ? tint : Color.primary.opacity(0.88))
      .background(shape.fill(active ? tint.opacity(configuration.isPressed ? 0.34 : 0.20) : Color.primary.opacity(base)))
      .overlay(shape.strokeBorder(active ? tint.opacity(0.6) : Color.clear, lineWidth: 1))
      .contentShape(shape)
      .opacity(isEnabled ? 1 : 0.32)
      .onHover { hovering = $0 && isEnabled }
  }
}

struct DecisionButtonStyle: ButtonStyle {
  let color: Color
  let filled: Bool
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    configuration.label
      .foregroundStyle(filled ? Color.white : color)
      .background(
        shape.fill(filled ? color.opacity(configuration.isPressed ? 0.75 : 1) : color.opacity(configuration.isPressed ? 0.3 : 0.14)))
      .overlay(shape.strokeBorder(filled ? Color.white.opacity(0.08) : color.opacity(0.75), lineWidth: 1))
      .contentShape(shape)
      .opacity(isEnabled ? 1 : 0.4)
  }
}

/// Lays children out left to right and starts a new row when the next one won't fit.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  var rowSpacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let limit = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var widest: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0, x + size.width > limit {
        y += rowHeight + rowSpacing
        x = 0
        rowHeight = 0
      }
      widest = max(widest, x + size.width)
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    let width = limit.isFinite ? min(limit, max(widest, 0)) : widest
    return CGSize(width: proposal.width.map { $0.isFinite ? $0 : width } ?? width, height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        y += rowHeight + rowSpacing
        x = bounds.minX
        rowHeight = 0
      }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

/// Right-click on the photo.
struct PhotoContextMenu: View {
  @Environment(ReviewModel.self) private var model

  var body: some View {
    let isVideo = model.current?.isVideo == true
    let favourite = model.current?.isFavorite == true
    Button(isVideo ? "Copy Video" : "Copy Photo") { model.copyCurrent() }
      .keyboardShortcut("c", modifiers: .command)
    Button("Copy File Name") { model.copyFilename() }
      .disabled(model.currentFilename == nil)
    Divider()
    Button("Show in Photos") { model.showInPhotos() }
    Divider()
    Button("Add to Album…") { model.showAlbumPicker = true }
    Button("Set Date…") { model.showRedate = true }
    Button(favourite ? "Unfavourite" : "Favourite") { model.toggleFavorite() }
  }
}
