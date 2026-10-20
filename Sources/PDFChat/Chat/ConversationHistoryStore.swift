import Foundation
import CryptoKit
import SwiftUI

/// 可持久化的单条消息.
struct StoredChatMessage: Codable {
    var id: UUID
    var role: String
    var text: String
    var imageDataURLs: [String]
    var promptTokens: Int?
    var completionTokens: Int?
    var costUSD: Double?
    var quote: DocumentQuote?
    var inputMode: String?
    var model: String?
    var status: String?
    var activities: [String]?
}

/// 一段完整对话 (对应对话History列表Medium的一 items).
struct StoredConversation: Codable, Identifiable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [StoredChatMessage]
}

/// 按 PDF File持久化对话History.
/// 每个 PDF 对应 Application Support/PDFChat/History/<sha256(File内容)>.json, 
/// File内为该 PDF 的全部History对话 (按更新时间倒序).
/// 键与File名/路径无关: 重命名或移动File后History仍然保留.
@MainActor
final class ConversationHistoryStore: ObservableObject {
    @Published private(set) var conversations: [StoredConversation] = []
    /// 当前正在进行的会话 id; nil 表示“New conversation”, 首次Save时会创建新条目.
    @Published private(set) var currentConversationID: UUID?

    private(set) var storageKey: String?
    private let writeQueue = HistoryDiskWriter.shared.queue
    @Published var persistenceError: String?

    nonisolated static var historyDirectory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("PDFChat/History", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 由 PDF File内容派生存储键 (无 URL 或File不可读时不持久化).
    /// 分块流式计算, 避免大File一次性载入内存.
    nonisolated static func contentStorageKey(for url: URL?) -> String? {
        guard let url else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do { chunk = try handle.read(upToCount: 1 << 20) ?? Data() } catch { return nil }
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 旧版存储键 (PDF 绝对路径哈希), 仅用于存量数据迁移.
    nonisolated static func legacyPathStorageKey(for url: URL?) -> String? {
        guard let url else { return nil }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard !path.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private var fileURL: URL? {
        guard let key = storageKey, let dir = Self.historyDirectory else { return nil }
        return dir.appendingPathComponent(key + ".json")
    }

    /// 加载指定 PDF 的History对话 (覆盖当前内容).
    /// 若内容哈希键尚无Record, 会尝试把旧版路径哈希键的Record迁移过来.
    func load(for pdfURL: URL?, contentKey: String? = nil) async {
        let loaded: (String?, [StoredConversation]) = await withCheckedContinuation { continuation in
            writeQueue.async {
                let key = contentKey ?? Self.contentStorageKey(for: pdfURL)
                Self.migrateLegacyFile(for: pdfURL, contentKey: key)
                let file = key.flatMap { Self.historyDirectory?.appendingPathComponent($0 + ".json") }
                let list = file.flatMap { try? Data(contentsOf: $0) }
                    .flatMap { try? JSONDecoder().decode([StoredConversation].self, from: $0) } ?? []
                continuation.resume(returning: (key, list))
            }
        }
        storageKey = loaded.0
        conversations = loaded.1.sorted { $0.updatedAt > $1.updatedAt }
        currentConversationID = nil
    }

    /// 把旧版 <sha256(路径)>.json 迁移为 <sha256(内容)>.json.
    /// 目标已存在时不覆盖 (保留两者), 迁移失败静默忽略.
    nonisolated private static func migrateLegacyFile(for pdfURL: URL?, contentKey: String?) {
        guard let pdfURL, let contentKey,
              let legacyKey = legacyPathStorageKey(for: pdfURL),
              legacyKey != contentKey,
              let dir = historyDirectory else { return }
        let legacyFile = dir.appendingPathComponent(legacyKey + ".json")
        let targetFile = dir.appendingPathComponent(contentKey + ".json")
        guard FileManager.default.fileExists(atPath: legacyFile.path),
              !FileManager.default.fileExists(atPath: targetFile.path) else { return }
        try? FileManager.default.moveItem(at: legacyFile, to: targetFile)
    }

    /// 把当前消息列表同步为一条会话并写盘.
    /// currentConversationID 为 nil 时New 条目 (即“New conversation”的Page 一次Save).
    func saveCurrent(messages: [ChatMessage]) {
        guard storageKey != nil else { return }
        let visible = messages.filter { !($0.streaming && $0.text.isEmpty) }
        guard visible.contains(where: { !$0.text.isEmpty || !$0.images.isEmpty }) else { return }
        let stored = visible.map { m in
            StoredChatMessage(
                id: m.id,
                role: m.role,
                text: m.text,
                imageDataURLs: m.images.map(\.dataURL),
                promptTokens: m.usage?.promptTokens,
                completionTokens: m.usage?.completionTokens,
                costUSD: m.costUSD, quote: m.quote, inputMode: m.inputMode, model: m.model, status: m.status, activities: m.activities
            )
        }
        let now = Date()
        if let id = currentConversationID,
           let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].messages = stored
            conversations[idx].title = Self.title(for: stored)
            conversations[idx].updatedAt = now
        } else {
            let conv = StoredConversation(id: UUID(), title: Self.title(for: stored),
                                          createdAt: now, updatedAt: now, messages: stored)
            currentConversationID = conv.id
            conversations.insert(conv, at: 0)
        }
        persist()
    }

    /// “New conversation”: 当前条目保留在HistoryMedium, 后续Save会另起一条.
    func beginNewConversation() {
        currentConversationID = nil
    }

    /// 选Medium一条History对话, 返回可RESTORE的 ChatMessage 列表, 并将其设为当前会话.
    func load(_ conversation: StoredConversation) -> [ChatMessage] {
        currentConversationID = conversation.id
        return conversation.messages.map { m in
            ChatMessage(
                id: m.id,
                role: m.role,
                text: m.text,
                images: m.imageDataURLs.map { ChatImage(dataURL: $0, thumbData: Self.thumbData(fromDataURL: $0)) },
                usage: m.promptTokens.map {
                    ChatUsage(promptTokens: $0, completionTokens: m.completionTokens ?? 0,
                              totalTokens: $0 + (m.completionTokens ?? 0))
                },
                costUSD: m.costUSD,
                streaming: false, quote: m.quote, inputMode: m.inputMode, model: m.model, status: m.status, activities: m.activities
            )
        }
    }

    func delete(_ conversation: StoredConversation) {
        conversations.removeAll { $0.id == conversation.id }
        if currentConversationID == conversation.id { currentConversationID = nil }
        persist()
    }

    private func persist() {
        guard let file = fileURL else { return }
        conversations.sort { $0.updatedAt > $1.updatedAt }
        let snapshot = conversations
        writeQueue.async { [weak self] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: file, options: .atomic)
            } catch {
                let message = "Could not save conversation: " + error.localizedDescription
                Task { @MainActor [weak self] in self?.persistenceError = message }
            }
        }
    }

    private static func title(for messages: [StoredChatMessage]) -> String {
        let t = (messages.first { $0.role == "user" }?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return String(t.prefix(24)) }
        return "Image discussion"
    }

    private static func thumbData(fromDataURL url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }
}

/// Shared serial writes preserve order across windows and can be drained on quit.
final class HistoryDiskWriter: @unchecked Sendable {
    static let shared = HistoryDiskWriter()
    let queue = DispatchQueue(label: "PDFChat.history", qos: .utility)
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }
}
