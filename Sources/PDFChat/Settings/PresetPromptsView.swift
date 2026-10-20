import SwiftUI

struct PresetPromptsView: View {
    @ObservedObject var store = SlashCommandStore.shared
    @State private var newTrigger = ""
    @State private var newContent = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(store.presets) { p in
                    HStack(alignment: .top) {
                        Text("/\(p.trigger)").bold().foregroundColor(.accentColor)
                            .frame(width: 90, alignment: .leading)
                        TextField("", text: bindContent(for: p), axis: .vertical)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(3...6)
                    }
                }
                .onDelete { store.presets.remove(atOffsets: $0); store.save() }
            }

            Divider()
            VStack(spacing: 6) {
                HStack {
                    TextField("Shortcut (e.g. summarize)", text: $newTrigger)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        add()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                TextField("Prompt text", text: $newContent, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }
            .padding(10)
        }
    }

    private func bindContent(for p: PresetPrompt) -> Binding<String> {
        Binding(
            get: { p.content },
            set: {
                if let idx = store.presets.firstIndex(where: { $0.id == p.id }) {
                    store.presets[idx].content = $0
                    store.save()
                }
            }
        )
    }

    private func add() {
        let t = newTrigger.trimmingCharacters(in: .whitespaces)
        let c = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let idx = store.presets.firstIndex(where: { $0.trigger == t }) {
            store.presets[idx].content = c
        } else {
            store.presets.append(.init(trigger: t, content: c.isEmpty ? " (To be filled in)" : c))
        }
        store.save()
        newTrigger = ""
        newContent = ""
    }
}