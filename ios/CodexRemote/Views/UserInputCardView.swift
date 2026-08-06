import SwiftUI

struct UserInputCardView: View {
    @Environment(UserInputStore.self) private var userInputs
    let card: UserInputCard
    @State private var drafts: [String: UserInputDraft] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("userInput.title", systemImage: "questionmark.bubble")
                .font(.headline)
            if card.awaitingRecovery {
                Label("userInput.awaitingRecovery", systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(card.questions) { question in
                questionView(question)
            }

            HStack {
                Button(role: .cancel) {
                    Task { await userInputs.cancel(card: card) }
                } label: {
                    Label("userInput.cancel", systemImage: "xmark")
                }
                Spacer()
                Button {
                    Task { await userInputs.submit(card: card, drafts: drafts) }
                } label: {
                    Label("userInput.submit", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!card.isSubmittable(drafts: drafts))
            }
            .disabled(card.awaitingRecovery)
        }
        .padding()
        .background(Color.accentColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            for question in card.questions where drafts[question.id] == nil {
                drafts[question.id] = UserInputDraft()
            }
        }
    }

    @ViewBuilder
    private func questionView(_ question: ToolRequestUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.header)
                .font(.subheadline.bold())
            Text(question.question)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let options = question.options, !options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options, id: \.label) { option in
                        Button {
                            select(option.label, for: question.id)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: drafts[question.id]?.selectedOption == option.label
                                      ? "largecircle.fill.circle" : "circle")
                                    .frame(width: 20, height: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).font(.callout.weight(.medium))
                                    if !option.description.isEmpty {
                                        Text(option.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(option.label). \(option.description)")
                    }
                }
            }

            if question.options == nil || question.isOther {
                if question.isSecret {
                    SecureField("userInput.answerPlaceholder", text: freeformBinding(for: question.id))
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField(
                        question.options == nil ? "userInput.answerPlaceholder" : "userInput.otherPlaceholder",
                        text: freeformBinding(for: question.id),
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func select(_ option: String, for questionId: String) {
        userInputs.userInteracted(with: card.id)
        drafts[questionId] = UserInputDraft(selectedOption: option, freeform: "")
    }

    private func freeformBinding(for questionId: String) -> Binding<String> {
        Binding(
            get: { drafts[questionId]?.freeform ?? "" },
            set: { value in
                userInputs.userInteracted(with: card.id)
                drafts[questionId] = UserInputDraft(selectedOption: nil, freeform: value)
            }
        )
    }
}
