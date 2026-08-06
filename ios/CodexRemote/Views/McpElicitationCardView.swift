import SwiftUI

struct McpElicitationCardView: View {
    @Environment(McpElicitationStore.self) private var elicitations
    let card: McpElicitationCard
    @State private var drafts: [String: McpFormDraft] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("mcpElicitation.title", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.headline)
                Spacer()
                Text(card.serverName).font(.caption).foregroundStyle(.secondary)
            }
            Text(card.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            if card.awaitingRecovery {
                Label("mcpElicitation.awaitingRecovery", systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            }

            switch card.mode {
            case .url(let url, _):
                Link(destination: url) {
                    Label(url.host() ?? url.absoluteString, systemImage: "arrow.up.right.square")
                }
                actionRow(canAccept: true)
            case .form(let fields):
                ForEach(fields) { field in fieldView(field) }
                actionRow(canAccept: card.isSubmittable(drafts: drafts))
            }
        }
        .padding()
        .background(Color.teal.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .disabled(card.awaitingRecovery)
        .onAppear { drafts = card.defaultDrafts() }
    }

    @ViewBuilder
    private func actionRow(canAccept: Bool) -> some View {
        HStack {
            Button(role: .cancel) {
                Task { await elicitations.resolve(card: card, action: .cancel) }
            } label: { Label("mcpElicitation.cancel", systemImage: "xmark") }
            Button {
                Task { await elicitations.resolve(card: card, action: .decline) }
            } label: { Label("mcpElicitation.decline", systemImage: "hand.raised") }
            Spacer()
            Button {
                Task {
                    if case .url = card.mode {
                        await elicitations.resolve(card: card, action: .accept)
                    } else {
                        await elicitations.accept(card: card, drafts: drafts)
                    }
                }
            } label: { Label("mcpElicitation.accept", systemImage: "checkmark") }
                .buttonStyle(.borderedProminent)
                .disabled(!canAccept)
        }
    }

    @ViewBuilder
    private func fieldView(_ field: McpFormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(field.title).font(.subheadline.bold())
                if field.required { Text("*").foregroundStyle(.red).accessibilityLabel("mcpElicitation.required") }
            }
            if let description = field.description {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            switch field.kind {
            case .string(let format, _, _):
                TextField("mcpElicitation.value", text: textBinding(field.name))
                    .textFieldStyle(.roundedBorder)
                    .textContentType(format == "email" ? .emailAddress : format == "uri" ? .URL : nil)
                    .keyboardType(format == "email" ? .emailAddress : format == "uri" ? .URL : .default)
            case .number:
                TextField("mcpElicitation.value", text: textBinding(field.name))
                    .textFieldStyle(.roundedBorder).keyboardType(.decimalPad)
            case .boolean:
                Toggle("mcpElicitation.enabled", isOn: boolBinding(field.name))
            case .single(let options):
                Picker(field.title, selection: textBinding(field.name)) {
                    Text("mcpElicitation.choose").tag("")
                    ForEach(options) { Text($0.title).tag($0.value) }
                }
                .pickerStyle(.menu)
            case .multiple(let options, _, _):
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options) { option in
                        Button { toggle(option.value, field: field.name) } label: {
                            Label(option.title, systemImage: selected(option.value, field: field.name) ? "checkmark.square.fill" : "square")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func textBinding(_ name: String) -> Binding<String> {
        Binding(get: {
            if case .text(let value) = drafts[name] { return value }
            return ""
        }, set: { drafts[name] = $0.isEmpty ? .unset : .text($0) })
    }

    private func boolBinding(_ name: String) -> Binding<Bool> {
        Binding(get: {
            if case .boolean(let value) = drafts[name] { return value }
            return false
        }, set: { drafts[name] = .boolean($0) })
    }

    private func selected(_ option: String, field: String) -> Bool {
        if case .multiple(let values) = drafts[field] { return values.contains(option) }
        return false
    }

    private func toggle(_ option: String, field: String) {
        var values: Set<String> = []
        if case .multiple(let current) = drafts[field] { values = current }
        if !values.insert(option).inserted { values.remove(option) }
        drafts[field] = .multiple(values)
    }
}
