import SwiftUI

@MainActor extension Widget {
    static let converter = Widget(id: "converter", title: "Converter", icon: "arrow.triangle.2.circlepath") {
        AnyView(ConverterView())
    }
}

@MainActor @Observable
final class ConverterModel {
    static let shared = ConverterModel()
    var files: [URL] = []

    func add(_ urls: [URL]) {
        files += urls.filter { !files.contains($0) }
    }
}

// Phase 1 stand-in: shows what was dropped. Conversion arrives in Phase 2.
struct ConverterView: View {
    private let model = ConverterModel.shared

    var body: some View {
        if model.files.isEmpty {
            ContentUnavailableView("Drop files on the notch", systemImage: "square.and.arrow.down")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                List(model.files, id: \.self) { Text($0.lastPathComponent).lineLimit(1) }
                    .scrollContentBackground(.hidden)
                Button("Clear") { model.files = [] }
            }
        }
    }
}
