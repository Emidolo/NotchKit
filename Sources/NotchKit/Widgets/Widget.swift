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

/// The central widget list. Order here is tab order.
@MainActor let widgets: [Widget] = [.converter, .youtube, .wallpaper, .keepAwake]
