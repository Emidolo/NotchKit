import SwiftUI

// Stand-ins so the tab bar is real from Phase 1. Each moves to its own folder when its phase lands.
@MainActor extension Widget {
    static let wallpaper = placeholder("wallpaper", "Wallpaper", "photo", phase: 4)
    static let keepAwake = placeholder("keepAwake", "Keep Awake", "cup.and.saucer", phase: 5)

    private static func placeholder(_ id: String, _ title: String, _ icon: String, phase: Int) -> Widget {
        Widget(id: id, title: title, icon: icon) {
            AnyView(EmptyHint(icon: icon, title: title, detail: "Coming in Phase \(phase)"))
        }
    }
}
