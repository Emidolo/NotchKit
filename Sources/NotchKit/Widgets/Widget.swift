import SwiftUI

/// One tool in the expanded notch. Each feature defines its own `static let` in an extension,
/// next to its view and view model, and is listed in `widgets` below.
struct Widget: Identifiable {
    let id: String
    let title: String
    /// SF Symbol name for the tab.
    let icon: String
    let view: () -> AnyView
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

/// The central widget list. Order here is tab order.
@MainActor let widgets: [Widget] = [.music, .converter, .youtube, .wallpaper, .keepAwake]
