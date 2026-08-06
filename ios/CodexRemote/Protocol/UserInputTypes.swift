import Foundation

struct ToolRequestUserInputOption: Codable, Sendable, Equatable {
    let label: String
    let description: String
}

struct ToolRequestUserInputQuestion: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let header: String
    let question: String
    var isOther: Bool = false
    var isSecret: Bool = false
    let options: [ToolRequestUserInputOption]?
}

struct ToolRequestUserInputParams: Codable, Sendable, Equatable {
    let threadId: String
    let turnId: String
    let itemId: String
    let questions: [ToolRequestUserInputQuestion]
    let autoResolutionMs: UInt64?
}

struct ToolRequestUserInputAnswer: Codable, Sendable, Equatable {
    let answers: [String]
}

struct ToolRequestUserInputResponse: Codable, Sendable, Equatable {
    let answers: [String: ToolRequestUserInputAnswer]
}

struct UserInputDraft: Sendable, Equatable {
    var selectedOption: String?
    var freeform: String

    init(selectedOption: String? = nil, freeform: String = "") {
        self.selectedOption = selectedOption
        self.freeform = freeform
    }
}

struct UserInputCard: Identifiable, Sendable, Equatable {
    let id: RequestId
    let threadId: String
    let turnId: String
    let itemId: String
    let questions: [ToolRequestUserInputQuestion]
    let autoResolutionMs: UInt64?
    var awaitingRecovery = false

    init(request: JSONRPCRequest) throws {
        guard request.method == ServerRequestMethod.userInput, let params = request.params else {
            throw UserInputError.invalidRequest
        }
        let data = try JSONEncoder().encode(params)
        let decoded: ToolRequestUserInputParams
        do {
            decoded = try JSONDecoder().decode(ToolRequestUserInputParams.self, from: data)
        } catch {
            throw UserInputError.invalidParams(String(describing: error))
        }
        guard !decoded.questions.isEmpty,
              Set(decoded.questions.map(\.id)).count == decoded.questions.count,
              decoded.questions.allSatisfy({ !$0.id.isEmpty })
        else { throw UserInputError.invalidQuestions }

        id = request.id
        threadId = decoded.threadId
        turnId = decoded.turnId
        itemId = decoded.itemId
        questions = decoded.questions
        autoResolutionMs = decoded.autoResolutionMs
    }

    func isSubmittable(drafts: [String: UserInputDraft]) -> Bool {
        questions.allSatisfy { answer(for: $0, draft: drafts[$0.id]) != nil }
    }

    func response(drafts: [String: UserInputDraft]) throws -> ToolRequestUserInputResponse {
        var answers: [String: ToolRequestUserInputAnswer] = [:]
        for question in questions {
            guard let value = answer(for: question, draft: drafts[question.id]) else {
                throw UserInputError.unansweredQuestion(question.id)
            }
            answers[question.id] = ToolRequestUserInputAnswer(answers: [value])
        }
        return ToolRequestUserInputResponse(answers: answers)
    }

    private func answer(for question: ToolRequestUserInputQuestion, draft: UserInputDraft?) -> String? {
        guard let draft else { return nil }
        if let selected = draft.selectedOption,
           question.options?.contains(where: { $0.label == selected }) == true {
            return selected
        }
        let text = draft.freeform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, question.options == nil || question.isOther else { return nil }
        return "user_note: \(text)"
    }
}

enum UserInputError: Error, Equatable {
    case invalidRequest
    case invalidParams(String)
    case invalidQuestions
    case unansweredQuestion(String)
}
