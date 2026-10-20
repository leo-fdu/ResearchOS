import Foundation

/// 单个 provider 预设 (仅用于设置 pages快速填充 baseURL).
struct ProviderPreset: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let baseURL: String
    let defaultModel: String
}

enum ProviderPresets {
    static let all: [ProviderPreset] = [
        .init(name: "OpenAI",   baseURL: "https://api.openai.com/v1",            defaultModel: "gpt-4o-mini"),
        .init(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1",         defaultModel: "deepseek-chat"),
        .init(name: "Moonshot", baseURL: "https://api.moonshot.cn/v1",          defaultModel: "moonshot-v1-8k"),
        .init(name: "Zhipu GLM",  baseURL: "https://open.bigmodel.cn/api/paas/v4", defaultModel: "glm-4-flash"),
        .init(name: "SiliconFlow", baseURL: "https://api.siliconflow.cn/v1",    defaultModel: "Qwen/Qwen2.5-7B-Instruct")
    ]
}

/// API 与偏OK配置 (单一配置, 通过 UserDefaults 持久化).
struct APIConfig: Codable, Equatable {
    var baseURL: String
    var model: String
    /// 可切换Model列表 (逗号或New line分隔后解析).
    var models: [String]
    /// 每个Model的Input/Output单价 (美元 / 1M tokens).
    var pricing: [String: ModelPrice]
    /// 每个Model的最大上下文 token 数 (用于超限预警).
    var maxContexts: [String: Int]
    /// Reasoning effort (reasoning_effort); nil 表示不发送该参数, 由服务端取Default值.
    var reasoningEffort: String?

    // Optional fields preserve decoding of existing v1 configurations.
    var apiStyle: APIStyle?
    var toolsEnabled: Bool?
    var webEnabled: Bool?
    var visionEnabled: Bool?
    var includeUsage: Bool?
    var resolvedStyle: APIStyle { apiStyle ?? .chatCompletions }

}

struct ModelPrice: Codable, Equatable {
    var inputPerMillion: Double   // $/1M Input tokens
    var outputPerMillion: Double  // $/1M Output tokens
}

extension APIConfig {
    static let `default` = APIConfig(
        baseURL: "https://api.deepseek.com/v1",
        model: "deepseek-chat",
        models: ["deepseek-chat", "deepseek-reasoner"],
        pricing: [:],
        maxContexts: [
            "deepseek-chat": 65536,
            "deepseek-reasoner": 65536
        ],
        reasoningEffort: nil
    )
}

/// Reasoning effort档位 (对应 OpenAI 兼容的 reasoning_effort 参数).
enum ReasoningEffort: String, CaseIterable, Identifiable {
    case unset   // Do not send parameter
    case low
    case medium
    case high
    case max

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unset: return "Default"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .max: return "Maximum"
        }
    }

    /// 从持久化字符串RESTORE; nil / 未知值视为不发送.
    init(string: String?) {
        self = ReasoningEffort(rawValue: string ?? "") ?? .unset
    }
}

enum APIStyle: String, Codable, CaseIterable, Identifiable {
    case chatCompletions, responses
    var id: String { rawValue }
    var label: String { self == .responses ? "Responses" : "Chat Completions (Compatible API)" }
}

struct ConnectionProfile: Codable, Identifiable {
    var id: String
    var name: String
    var config: APIConfig
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var config: APIConfig
    @Published var profiles: [ConnectionProfile]
    @Published var activeProfileID: String
    private let defaults = UserDefaults.standard

    private init() {
        if !UserDefaults.standard.bool(forKey: "ros.imported-api-settings") {
            if let old = UserDefaults.standard.persistentDomain(forName: "com.niqi.pdfchat") {
                for key in ["Connections.v2", "APIConfig.v1", "ActiveConnection.v2"] {
                    if UserDefaults.standard.object(forKey: key) == nil, let value = old[key] { UserDefaults.standard.set(value, forKey: key) }
                }
            }
            UserDefaults.standard.set(true, forKey: "ros.imported-api-settings")
        }
        let saved = UserDefaults.standard.data(forKey: "Connections.v2")
            .flatMap { try? JSONDecoder().decode([ConnectionProfile].self, from: $0) }
        let legacy = UserDefaults.standard.data(forKey: "APIConfig.v1")
            .flatMap { try? JSONDecoder().decode(APIConfig.self, from: $0) } ?? .default
        let loaded = saved?.isEmpty == false ? saved! : [.init(id: "default", name: "Default connection", config: legacy)]
        profiles = loaded
        let wanted = UserDefaults.standard.string(forKey: "ActiveConnection.v2") ?? "default"
        let active = loaded.first { $0.id == wanted } ?? loaded[0]
        activeProfileID = active.id
        config = active.config
    }

    var connectionName: String { profiles.first { $0.id == activeProfileID }?.name ?? "Custom connection" }
    var apiKey: String {
        get { KeychainStore.get(activeProfileID) ?? "" }
        set { KeychainStore.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: activeProfileID) }
    }
    var searchKey: String {
        get { KeychainStore.get("brave-search") ?? "" }
        set { KeychainStore.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: "brave-search") }
    }
    func save() {
        if let i = profiles.firstIndex(where: { $0.id == activeProfileID }) { profiles[i].config = config }
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "Connections.v2") }
        defaults.set(activeProfileID, forKey: "ActiveConnection.v2")
    }
    func select(_ id: String) {
        save()
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        activeProfileID = id
        config = profile.config
        save()
    }
    func addConnection() {
        save()
        let profile = ConnectionProfile(id: UUID().uuidString, name: "New connection", config: .default)
        profiles.append(profile)
        activeProfileID = profile.id
        config = profile.config
        save()
    }
    func rename(_ name: String) {
        if let i = profiles.firstIndex(where: { $0.id == activeProfileID }) { profiles[i].name = name }
        save()
    }
    func removeConnection() {
        guard profiles.count > 1 else { return }
        KeychainStore.remove(activeProfileID)
        profiles.removeAll { $0.id == activeProfileID }
        activeProfileID = profiles[0].id
        config = profiles[0].config
        save()
    }
    func price(for model: String) -> ModelPrice {
        config.pricing[model] ?? .init(inputPerMillion: 0, outputPerMillion: 0)
    }
    func maxContext(for model: String) -> Int { config.maxContexts[model] ?? 128_000 }
}
