import SwiftUI

struct UserInputCardView: View {
    @Environment(UserInputStore.self) private var userInputs
    let card: UserInputCard
    @State private var drafts: [String: UserInputDraft] = [:]
    @State private var countdownExpired = false
    @FocusState private var focusedQuestionId: String?

    private var submissionState: DecisionSubmissionState {
        userInputs.submissionState(for: card.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("userInput.title", systemImage: "questionmark.bubble")
                .font(.headline)
            if card.awaitingRecovery {
                Label("userInput.awaitingRecovery", systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            autoResolutionStatus
            decisionFeedback

            ForEach(card.questions) { question in
                questionView(question)
            }

            HStack {
                Button(role: .cancel) {
                    Task { await userInputs.cancel(card: card) }
                } label: {
                    Label("userInput.cancel", systemImage: "xmark")
                }
                .minimumHitTarget44()
                Spacer()
                Button {
                    Task { await userInputs.submit(card: card, drafts: drafts) }
                } label: {
                    Label("userInput.submit", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .minimumHitTarget44()
                .disabled(!card.isSubmittable(drafts: drafts))
            }
            .disabled(card.awaitingRecovery || submissionState == .submitting)
        }
        .padding()
        .background(Color.accentColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            for question in card.questions where drafts[question.id] == nil {
                drafts[question.id] = UserInputDraft()
            }
        }
        .onChange(of: focusedQuestionId) { _, newValue in
            if newValue != nil { userInputs.userInteracted(with: card.id) }
        }
    }

    @ViewBuilder
    private var autoResolutionStatus: some View {
        if userInputs.isAutoResolutionPaused(card.id) {
            HStack(spacing: 8) {
                Label("userInput.autoPaused", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Button("userInput.autoResume") {
                    userInputs.resumeAutoResolution(for: card.id)
                }
                .font(.caption)
                .minimumHitTarget44()
            }
        } else if userInputs.autoResolutionDeadline(for: card.id) != nil, countdownExpired {
            Label("userInput.autoCountdown 0", systemImage: "timer")
                .font(.caption).foregroundStyle(.secondary)
        } else if let deadline = userInputs.autoResolutionDeadline(for: card.id) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(ceil(deadline.timeIntervalSince(context.date))))
                Label("userInput.autoCountdown \(seconds)", systemImage: "timer")
                    .font(.caption).foregroundStyle(.secondary)
                    .onChange(of: seconds) { _, value in
                        if value == 0 { countdownExpired = true }
                    }
            }
        }
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
    private func questionView(_ question: ToolRequestUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UntrustedDisplayText.sanitize(question.header))
                .font(.subheadline.bold())
            Text(UntrustedDisplayText.sanitize(question.question))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let options = question.options, !options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options, id: \.label) { option in
                        let isSelected = drafts[question.id]?.selectedOption == option.label
                        Button {
                            select(option.label, for: question.id)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                    .frame(width: 20, height: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(UntrustedDisplayText.sanitize(option.label))
                                        .font(.callout.weight(.medium))
                                    if !option.description.isEmpty {
                                        Text(UntrustedDisplayText.sanitize(option.description))
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
                        .minimumHitTarget44()
                        .accessibilityLabel(UntrustedDisplayText.sanitize(
                            "\(option.label). \(option.description)"
                        ))
                        .accessibilityValue(Text(isSelected ? "accessibility.selected" : "accessibility.notSelected"))
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    }
                }
            }

            if question.options == nil || question.isOther {
                if question.isSecret {
                    SecureField("userInput.answerPlaceholder", text: freeformBinding(for: question.id))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedQuestionId, equals: question.id)
                        .accessibilityLabel(Text(UntrustedDisplayText.sanitize(question.header)))
                        .accessibilityHint(Text(UntrustedDisplayText.sanitize(question.question)))
                } else {
                    TextField(
                        question.options == nil ? "userInput.answerPlaceholder" : "userInput.otherPlaceholder",
                        text: freeformBinding(for: question.id),
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedQuestionId, equals: question.id)
                    .accessibilityLabel(Text(UntrustedDisplayText.sanitize(question.header)))
                    .accessibilityHint(Text(UntrustedDisplayText.sanitize(question.question)))
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
                drafts[questionId] = UserInputDraft(
                    selectedOption: nil,
                    freeform: UserInputRequestLimits.boundedFreeform(value)
                )
            }
        )
    }
}
