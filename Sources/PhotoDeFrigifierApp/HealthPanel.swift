import QuickFixCore
import SwiftUI

extension HealthStatus {
  var color: Color {
    switch self {
    case .good: Color(red: 0.25, green: 0.73, blue: 0.31)
    case .unsure: Color(red: 0.89, green: 0.70, blue: 0.25)
    case .missing: Color(red: 1.0, green: 0.42, blue: 0.38)
    case .notApplicable: Color(white: 0.56)
    }
  }
}

/// Top-right of the photo: the health panel and recent albums, or (hidden with H) a slim strip of health
/// colours. When the window is short, the albums panel steps aside so health still fits.
struct HealthOverlay: View {
  @Environment(ReviewModel.self) private var model

  var body: some View {
    let items = model.health
    VStack {
      HStack(alignment: .top) {
        Spacer()
        if model.showHealth {
          ViewThatFits(in: .vertical) {
            VStack(spacing: 12) {
              HealthPanel(items: items, onDate: { model.showRedate = true }, onHide: { model.showHealth = false })
              RecentAlbumsPanel()
            }
            HealthPanel(items: items, onDate: { model.showRedate = true }, onHide: { model.showHealth = false })
          }
          .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
          HealthStrip(items: items) { model.showHealth = true }
            .transition(.opacity)
        }
      }
      Spacer()
    }
    .padding(14)
    .animation(.easeOut(duration: 0.18), value: model.showHealth)
  }
}

struct HealthPanel: View {
  let items: [HealthItem]
  let onDate: () -> Void
  let onHide: () -> Void

  private var summary: String {
    let counts = Dictionary(grouping: items, by: \.status).mapValues(\.count)
    return [(HealthStatus.good, "good"), (.unsure, "unsure"), (.missing, "missing")]
      .compactMap { status, word in counts[status].map { "\($0) \(word)" } }
      .joined(separator: " · ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text("Health").font(.system(size: 13, weight: .bold))
        Spacer()
        Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
        Button(action: onHide) {
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Hide the health panel (H)")
        .accessibilityLabel("Hide the health panel")
      }
      .padding(.horizontal, 4)
      HStack(spacing: 3) {
        ForEach(items) { RoundedRectangle(cornerRadius: 3).fill($0.status.color).frame(height: 6) }
      }
      .padding(.horizontal, 4)
      .padding(.bottom, 4)
      ForEach(items) { item in
        if item.signal == .date {
          Button(action: onDate) { HealthRow(item: item, actionable: true) }
            .buttonStyle(.plain)
            .help("Set the date (T)")
        } else {
          HealthRow(item: item, actionable: false)
        }
      }
    }
    .padding(10)
    .frame(width: 214)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.12).opacity(0.94)))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    .foregroundStyle(Color(white: 0.93))
    .environment(\.colorScheme, .dark)
  }
}

struct HealthRow: View {
  let item: HealthItem
  let actionable: Bool
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 10) {
      Text(item.status.glyph)
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(Color(white: 0.08))
        .frame(width: 20, height: 20)
        .background(Circle().fill(item.status.color))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(item.signal.title).font(.system(size: 12.5, weight: .semibold))
        Text(item.detail).font(.system(size: 11)).foregroundStyle(item.status.color).lineLimit(1)
      }
      Spacer(minLength: 0)
      if actionable && hovering {
        Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 8).padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(item.status.color.opacity(hovering && actionable ? 0.22 : 0.12)))
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(item.signal.title): \(item.detail)")
  }
}

/// The collapsed form: one coloured segment per signal, top to bottom in panel order.
struct HealthStrip: View {
  let items: [HealthItem]
  let onShow: () -> Void

  var body: some View {
    Button(action: onShow) {
      VStack(spacing: 3) {
        ForEach(items) { RoundedRectangle(cornerRadius: 3).fill($0.status.color).frame(width: 10, height: 22) }
      }
      .padding(4)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.45)))
    }
    .buttonStyle(.plain)
    .help(items.map { "\($0.signal.title): \($0.detail)" }.joined(separator: "\n") + "\n\nShow the health panel (H)")
    .accessibilityLabel("Show the health panel")
  }
}
