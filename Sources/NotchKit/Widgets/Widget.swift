import SwiftUI

/// One tool in the expanded notch. Each feature defines its own `static let` in an extension,
/// next to its view and view model, and is listed in `WidgetStore.registry` below.
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

/// Which widgets exist, which are switched on, and in what order.
@MainActor @Observable
final class WidgetStore {
    static let shared = WidgetStore()
    /// The central widget list: everything the app has, in default order. A new widget is added here.
    static let registry: [Widget] = [.music, .converter, .youTube, .wallpaper, .keepAwake]

    private(set) var order: [String] { didSet { UserDefaults.standard.set(order, forKey: "widgetOrder") } }
    private(set) var disabled: Set<String> { didSet { UserDefaults.standard.set(Array(disabled), forKey: "disabledWidgets") } }

    private init() {
        order = WidgetStore.resolve(saved: UserDefaults.standard.stringArray(forKey: "widgetOrder") ?? [], known: WidgetStore.registry.map(\.id))
        disabled = Set(UserDefaults.standard.stringArray(forKey: "disabledWidgets") ?? [])
    }

    /// The saved order, minus widgets that no longer exist, plus new ones at the end.
    nonisolated static func resolve(saved: [String], known: [String]) -> [String] {
        var kept: [String] = []
        for id in saved where known.contains(id) && !kept.contains(id) { kept.append(id) }
        return kept + known.filter { !kept.contains($0) }
    }

    /// Every widget in the user's order, for Settings.
    var all: [Widget] { order.compactMap { id in WidgetStore.registry.first { $0.id == id } } }
    /// The widgets shown as tabs.
    var visible: [Widget] { all.filter { !disabled.contains($0.id) } }

    func isEnabled(_ id: String) -> Bool { !disabled.contains(id) }

    /// A switched-off widget also stops working in the background (no keep-awake, no clipboard prompts).
    func setEnabled(_ id: String, _ on: Bool) {
        if on { disabled.remove(id) } else { disabled.insert(id) }
        KeepAwake.shared.evaluate()
    }

    func move(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
    }
}
