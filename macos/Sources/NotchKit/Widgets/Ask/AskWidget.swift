import SwiftUI
import Security

enum Ask {
    static let defaultModel = "gpt-5.6-luna"

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta
        }
        let choices: [Choice]
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    /// The text carried by one line of the streamed response; nil for blank lines, keep-alives and `[DONE]`.
    static func delta(in line: String) -> String? {
        guard line.hasPrefix("data:"),
              let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(line.dropFirst(5).utf8)) else { return nil }
        return chunk.choices.first?.delta.content
    }

    /// OpenAI's own explanation from an error response, when it has one.
    static func errorMessage(in body: String, status: Int) -> String {
        if let parsed = try? JSONDecoder().decode(ErrorBody.self, from: Data(body.utf8)) { return parsed.error.message }
        return "OpenAI answered with status \(status)"
    }

    private static let keychainItem: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "NotchKit OpenAI API key"]

    /// Kept in the login keychain, never in UserDefaults. Empty when none is saved.
    static var apiKey: String {
        get {
            var query = keychainItem
            query[kSecReturnData] = true
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            SecItemDelete(keychainItem as CFDictionary)
            guard !newValue.isEmpty else { return }
            var item = keychainItem
            item[kSecValueData] = Data(newValue.utf8)
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

@MainActor @Observable
final class AskModel {
    static let shared = AskModel()

    var question = ""
    private(set) var answer = ""
    private(set) var error: String?
    private(set) var task: Task<Void, Never>?
    var model: String = UserDefaults.standard.string(forKey: "askModel") ?? Ask.defaultModel {
        didSet { UserDefaults.standard.set(model, forKey: "askModel") }
    }

    /// One question, one answer: asking again replaces what was there.
    func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stop()
        answer = ""
        error = nil
        let key = Ask.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            error = "Add your OpenAI API key in Settings → General."
            return
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let name = model.trimmingCharacters(in: .whitespaces)
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": name.isEmpty ? Ask.defaultModel : name,
            "stream": true,
            "messages": [["role": "user", "content": text]],
        ] as [String: Any])

        task = Task {
            defer { task = nil }
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    var body = ""
                    for try await line in bytes.lines { body += line }
                    error = Ask.errorMessage(in: body, status: status)
                    return
                }
                for try await line in bytes.lines {
                    if let piece = Ask.delta(in: line) { answer += piece }
                }
            } catch is CancellationError {
            } catch let failure as URLError where failure.code == .cancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

extension Widget {
    static let ask = Widget(id: "ask", title: "Ask", icon: "sparkles") { AnyView(AskView()) }
}

private struct AskView: View {
    @Bindable private var model = AskModel.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Ask anything", text: $model.question)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { model.ask() }
                if model.task != nil {
                    ProgressView().controlSize(.small)
                    iconButton("stop.fill", "Stop") { model.stop() }
                } else if !model.answer.isEmpty {
                    iconButton("doc.on.doc", "Copy answer") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.answer, forType: .string)
                    }
                }
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).help(error)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if model.answer.isEmpty {
                Text(model.task == nil ? "Type a question and press Return." : "Thinking…")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(model.answer).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .controlSize(.small)
        .onAppear { focused = true }
    }
}

/// The Ask rows in Settings → General.
struct AskSettings: View {
    @Bindable private var model = AskModel.shared
    @State private var key = ""

    var body: some View {
        SecureField("OpenAI API key", text: $key, prompt: Text("sk-…"))
            .onAppear { key = Ask.apiKey }
            .onChange(of: key) { Ask.apiKey = $1 }
        TextField("Model", text: $model.model, prompt: Text(Ask.defaultModel))
        Text("The key is stored in your login keychain and sent only to api.openai.com.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
