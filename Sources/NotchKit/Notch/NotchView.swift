import SwiftUI

struct NotchView: View {
    let notch: NotchController
    @State private var dropTargeted = false

    var body: some View {
        // Reading the indicators here makes this view follow the widgets' progress.
        // ponytail: first indicator left of the notch, the rest share the right; widen the ears if that gets crowded.
        let indicators = widgets.compactMap { $0.indicator?() }
        let ears = !indicators.isEmpty && !notch.notch.isEmpty
        let collapsed = CGSize(width: notch.notch.width + (ears ? 2 * NotchGeometry.earWidth : 0), height: notch.notch.height)
        let size = notch.expanded ? NotchGeometry.expandedSize : collapsed
        let radius: CGFloat = notch.expanded ? 24 : 10
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
                .fill(.black)
            if notch.expanded {
                ExpandedView(notch: notch).transition(.opacity)
            } else if ears {
                HStack(spacing: 6) {
                    indicators[0]
                    Spacer(minLength: notch.notch.width)
                    ForEach(indicators.indices.dropFirst(), id: \.self) { indicators[$0] }
                }
                .padding(.horizontal, 11)
                .frame(height: notch.notch.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onHover { notch.hover($0) }
        .onTapGesture { notch.expand() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            notch.drop(providers)
            return true
        }
        .onChange(of: dropTargeted) { notch.hover($1) }
        .onChange(of: ears, initial: true) { notch.setEars($1) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

private struct ExpandedView: View {
    let notch: NotchController

    var body: some View {
        let current = widgets.first { $0.id == notch.selected } ?? widgets[0]
        VStack(spacing: 0) {
            // Tabs sit left of the physical notch, the title right of it.
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(widgets) { widget in
                        Button { notch.selected = widget.id } label: {
                            Image(systemName: widget.icon)
                                .frame(width: 28, height: 24)
                                .background(widget.id == current.id ? Color.white.opacity(0.15) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(widget.title)
                        .accessibilityLabel(widget.title)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: notch.notch.width)
                Text(current.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: notch.stripHeight)
            .padding(.horizontal, 16)

            current.view()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding([.horizontal, .bottom], 16)
                .padding(.top, 8)
        }
    }
}
