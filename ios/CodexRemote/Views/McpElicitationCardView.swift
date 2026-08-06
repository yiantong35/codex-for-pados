import SwiftUI

struct McpElicitationCardView: View {
    @Environment(McpElicitationStore.self) private var elicitations
    let card: McpElicitationCard
    @State private var drafts: [String: McpFormDraft] = [:]
    @State private var showValidationErrors = false

    private var submissionState: DecisionSubmissionState {
        elicitations.submissionState(for: card.id)
    }

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
            decisionFeedback

            switch card.mode {
            case .url(let url, _):
                Link(destination: url) {
                    Label(url.host() ?? url.absoluteString, systemImage: "arrow.up.right.square")
                }
                .minimumHitTarget44()
                actionRow
            case .form(let fields):
                ForEach(fields) { field in fieldView(field) }
                actionRow
            }
        }
        .padding()
        .background(Color.teal.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .disabled(card.awaitingRecovery || submissionState == .submitting)
        .onAppear { drafts = card.defaultDrafts() }
    }

    @ViewBuilder
    private var decisionFeedback: some View {
        switch submissionState {
        case .idle: EmptyView()
        case .submitting:
            Label("decision.submitting", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Label("decision.failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack {
            Button(role: .cancel) {
                Task { await elicitations.resolve(card: card, action: .cancel) }
            } label: { Label("mcpElicitation.cancel", systemImage: "xmark") }
                .minimumHitTarget44()
            Button {
                Task { await elicitations.resolve(card: card, action: .decline) }
            } label: { Label("mcpElicitation.decline", systemImage: "hand.raised") }
                .minimumHitTarget44()
            Spacer()
            Button {
                Task {
                    if case .url = card.mode {
                        await elicitations.resolve(card: card, action: .accept)
                    } else if card.validationErrors(drafts: drafts).isEmpty {
                        await elicitations.accept(card: card, drafts: drafts)
                    } else {
                        showValidationErrors = true
                    }
                }
            } label: { Label("mcpElicitation.accept", systemImage: "checkmark") }
                .buttonStyle(.borderedProminent)
                .minimumHitTarget44()
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
                        .minimumHitTarget44()
                    }
                }
            }
            fieldConstraint(field)
            if showValidationErrors, let error = card.validationErrors(drafts: drafts)[field.name] {
                Label(validationMessage(error), systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func fieldConstraint(_ field: McpFormField) -> some View {
        Group {
            switch field.kind {
            case .string(let format, let minimum, let maximum):
                if let minimum, let maximum {
                    Text("mcpElicitation.constraint.lengthRange \(minimum) \(maximum)")
                } else if let minimum {
                    Text("mcpElicitation.constraint.minLength \(minimum)")
                } else if let maximum {
                    Text("mcpElicitation.constraint.maxLength \(maximum)")
                }
                if let format {
                    Text(formatConstraintKey(format))
                }
            case .number(let integer, let minimum, let maximum):
                if integer { Text("mcpElicitation.constraint.integer") }
                if let minimum, let maximum {
                    Text("mcpElicitation.constraint.numberRange \(minimum.formatted()) \(maximum.formatted())")
                } else if let minimum {
                    Text("mcpElicitation.constraint.minimum \(minimum.formatted())")
                } else if let maximum {
                    Text("mcpElicitation.constraint.maximum \(maximum.formatted())")
                }
            case .multiple(_, let minimum, let maximum):
                if let minimum, let maximum {
                    Text("mcpElicitation.constraint.selectionRange \(minimum) \(maximum)")
                } else if let minimum {
                    Text("mcpElicitation.constraint.minSelections \(minimum)")
                } else if let maximum {
                    Text("mcpElicitation.constraint.maxSelections \(maximum)")
                }
            case .boolean, .single:
                EmptyView()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func validationMessage(_ error: McpElicitationError) -> LocalizedStringKey {
        switch error {
        case .missingValue: "mcpElicitation.error.required"
        default: "mcpElicitation.error.invalid"
        }
    }

    private func formatConstraintKey(_ format: String) -> LocalizedStringKey {
        switch format {
        case "uri": "mcpElicitation.constraint.url"
        case "email": "mcpElicitation.constraint.email"
        case "date": "mcpElicitation.constraint.date"
        default: "mcpElicitation.constraint.dateTime"
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
