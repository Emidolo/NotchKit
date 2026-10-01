import SwiftUI

/// One tool in the expanded notch. Each feature defines its own `static let` in an extension,
/// next to its view and view model, and is listed in `widgets` below.
struct Widget: Identifiable {
    let id: String
    let title: String
    /// SF Symbol name for the tab.
    let icon: String
    /// Small view shown beside the collapsed notch while the widget has something going on; nil when idle.
    var indicator: (@MainActor () -> AnyView?)? = nil
    let view: () -> AnyView
}

/// The standard indicator: a ring that fills as work completes.
struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.03, min(fraction, 1)))
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        .accessibilityLabel("\(Int(fraction * 100)) percent")
    }
}

/// Compact empty state; the panel is too short for ContentUnavailableView.
struct EmptyHint: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

/// Small borderless icon button used in widget rows and toolbars.
@MainActor func iconButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: icon).frame(width: 18, height: 18).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
}

/// The central widget list. Order here is tab order.
@MainActor let widgets: [Widget] = [.music, .converter, .youTube, .wallpaper, .keepAwake]
