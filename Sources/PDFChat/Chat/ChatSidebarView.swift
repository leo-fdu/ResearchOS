import SwiftUI

struct ChatSidebarView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var contextStore: PDFContextStore
    @ObservedObject var historyStore: ConversationHistoryStore
    @ObservedObject private var settings = AppSettings.shared
    @State private var showHistory = false
    @State private var showStats = false
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle").foregroundStyle(.tint).font(.system(size: 19))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reading assistant").font(.system(size: 14, weight: .semibold))
                    Menu {
                        ForEach(settings.profiles) { profile in
                            Button(profile.name) { settings.select(profile.id) }
                        }
                        Divider()
                        ForEach(settings.config.models, id: \.self) { model in
                            Button { viewModel.switchModel(model) } label: {
                                if model == settings.config.model { Label(model, systemImage: "checkmark") } else { Text(model) }
                            }
                        }
                        Divider()
                        Button("Manage connections…") { openSettings() }
                    } label: {
                        Text(settings.config.model.isEmpty ? "Choose model" : settings.config.model).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true).disabled(viewModel.isStreaming)
                }
                Spacer(minLength: 8)
                Button { showHistory.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }.help("Conversation history for this PDF")
                    .popover(isPresented: $showHistory) {
                        HistoryListView(history: historyStore, model: viewModel, dismiss: { showHistory = false }).frame(width: 340, height: 380)
                    }
                Button { viewModel.newConversation() } label: { Image(systemName: "square.and.pencil") }.help("New conversation (⌘N)")
                Button { openSettings() } label: { Image(systemName: "slider.horizontal.3") }.help("Connections and preferences")
            }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 15)
            Divider().opacity(0.6)
            MessageListView(viewModel: viewModel, contextStore: contextStore)
            if viewModel.isStreaming {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(viewModel.activity).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }.padding(.horizontal, 20).padding(.vertical, 6)
            }
            ChatInputView(viewModel: viewModel, contextStore: contextStore)
                .padding(.horizontal, 14).padding(.bottom, 10)
            HStack(spacing: 8) {
                Menu {
                    Toggle("Allow document tools", isOn: configBinding(\.toolsEnabled, fallback: true))
                    Toggle("Allow web access", isOn: configBinding(\.webEnabled, fallback: false))
                    Toggle("Allow page images", isOn: configBinding(\.visionEnabled, fallback: true))
                    Divider()
                    Button("Configure web search…") { openSettings() }
                } label: {
                    Label(settings.config.webEnabled == true ? "Tools · Web enabled" : "Reading tools", systemImage: settings.config.webEnabled == true ? "globe" : "wrench.and.screwdriver")
                        .font(.system(size: 11))
                }.menuStyle(.borderlessButton).fixedSize().disabled(viewModel.isStreaming)
                Menu {
                    Picker("Reasoning effort", selection: Binding(
                        get: { ReasoningEffort(string: settings.config.reasoningEffort) },
                        set: { settings.config.reasoningEffort = $0 == .unset ? nil : $0.rawValue; settings.save() }
                    )) {
                        ForEach(ReasoningEffort.allCases) { effort in
                            Text(effort.label).tag(effort)
                        }
                    }.pickerStyle(.inline)
                } label: {
                    Text("Thinking · \(ReasoningEffort(string: settings.config.reasoningEffort).label)")
                        .font(.system(size: 11)).lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Set reasoning effort for the next request. Default uses provider settings; other levels require model support.")
                .accessibilityLabel("Reasoning effort")
                .accessibilityValue(ReasoningEffort(string: settings.config.reasoningEffort).label)
                .disabled(viewModel.isStreaming)
                Spacer()
                Button { showStats.toggle() } label: { Image(systemName: "chart.bar.xaxis") }.buttonStyle(.plain).help("Session usage")
                    .popover(isPresented: $showStats) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Session usage").font(.headline)
                            Text("Input \(viewModel.sessionPromptTokens.formatted()) · Output \(viewModel.sessionCompletionTokens.formatted()) tokens")
                            Text(settings.config.pricing[settings.config.model] == nil ? "No pricing for this model" : String(format: "Estimated model cost $%.4f", viewModel.sessionCost))
                            Text("Based on provider-reported usage. Excludes web search and other tool costs.") .font(.caption).foregroundStyle(.secondary)
                        }.padding(18).frame(width: 290)
                    }
            }.padding(.horizontal, 18).padding(.bottom, 12)
            if let error = historyStore.persistenceError { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
        }.background(Color(NSColor.windowBackgroundColor))
    }
    private func configBinding(_ key: WritableKeyPath<APIConfig, Bool?>, fallback: Bool) -> Binding<Bool> {
        Binding(get: { settings.config[keyPath: key] ?? fallback }, set: { settings.config[keyPath: key] = $0; settings.save() })
    }
}
private struct HistoryListView: View {
    @ObservedObject var history: ConversationHistoryStore
    @ObservedObject var model: ChatViewModel
    var dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading) {
            Text("Conversations for this PDF").font(.headline).padding(16)
            if history.conversations.isEmpty {
                ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right", description: Text("Conversations are saved automatically on this Mac."))
            } else {
                List(history.conversations) { conversation in
                    HStack {
                        Button {
                            model.stop()
                            model.restore(messages: history.load(conversation)); dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(conversation.title).lineLimit(2)
                                Text(conversation.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button {
                            if history.currentConversationID == conversation.id { model.newConversation() }
                            history.delete(conversation)
                        } label: { Image(systemName: "trash").foregroundStyle(.secondary) }.buttonStyle(.borderless).help("Delete conversation")
                    }.padding(.vertical, 5)
                }.listStyle(.plain)
            }
        }
    }
}
