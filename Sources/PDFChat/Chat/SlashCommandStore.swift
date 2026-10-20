import Foundation

struct PresetPrompt: Codable, Identifiable, Hashable {
    var id: String { trigger }
    let trigger: String   // For example "summarize" (Without /)
    var content: String
}

@MainActor
final class SlashCommandStore: ObservableObject {
    static let shared = SlashCommandStore()

    @Published var presets: [PresetPrompt]
    private let key = "PresetPrompts.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: "PresetPrompts.v1"),
           let decoded = try? JSONDecoder().decode([PresetPrompt].self, from: data) {
            presets = decoded
        } else {
            presets = [
                .init(trigger: "summarize", content: "Summarize the main points of this passage as a list."),
                .init(trigger: "translate", content: "Translate the following into English. Output only the translation."),
                .init(trigger: "explain", content: "Explain the following in plain language, with examples where helpful."),
                .init(trigger: "extract", content: "Extract key entities, terms and numbers from the following into a table."),
                .init(trigger: "rewrite", content: "Rewrite the following for clarity and concision while preserving its meaning.")
            ]
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Input文本行首为 `/xxx` 时, 返回匹配的预设.
    func matches(for rawText: String) -> [PresetPrompt] {
        let text = rawText
        guard text.hasPrefix("/") else { return [] }
        let query = String(text.dropFirst()).lowercased()
        // 仅在行首、未含空格时触发
        if query.contains(" ") || query.contains("\n") { return [] }
        if query.isEmpty { return presets }
        return presets.filter { $0.trigger.lowercased().hasPrefix(query) }
    }
}