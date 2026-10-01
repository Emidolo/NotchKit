import SwiftUI

// Stand-in so the tab bar is complete. It moves to its own folder when its phase lands.
@MainActor extension Widget {
    static let keepAwake = Widget(id: "keepAwake", title: "Keep Awake", icon: "cup.and.saucer") {
        AnyView(EmptyHint(icon: "cup.and.saucer", title: "Keep Awake", detail: "Coming in Phase 5"))
    }
}
