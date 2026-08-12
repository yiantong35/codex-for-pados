import Foundation

enum UserInputRequestLimits {
    static let questionCount = 1...3
    static let optionCount = 2...3
    static let autoResolutionMs: ClosedRange<UInt64> = 60_000...240_000
    static let maximumIdentifierBytes = 256
    static let maximumHeaderBytes = 64
    static let maximumQuestionBytes = 1_024
    static let maximumOptionLabelBytes = 128
    static let maximumOptionDescriptionBytes = 512
    static let maximumAnswerBytes = 16 * 1_024
    static let answerPrefix = "user_note: "
    static let maximumFreeformBytes = maximumAnswerBytes - answerPrefix.utf8.count

    static func freeformIsTooLarge(_ value: String) -> Bool {
        value.utf8.count > maximumFreeformBytes
    }
}

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
        guard Self.validIdentifier(decoded.threadId),
              Self.validIdentifier(decoded.turnId),
              Self.validIdentifier(decoded.itemId),
              UserInputRequestLimits.questionCount.contains(decoded.questions.count),
              Set(decoded.questions.map(\.id)).count == decoded.questions.count,
              decoded.questions.allSatisfy(Self.validQuestion),
              decoded.autoResolutionMs.map(UserInputRequestLimits.autoResolutionMs.contains) ?? true
        else { throw UserInputError.invalidQuestions }

        id = request.id
        threadId = decoded.threadId
        turnId = decoded.turnId
        itemId = decoded.itemId
        questions = decoded.questions
        autoResolutionMs = decoded.autoResolutionMs
    }

    private static func validQuestion(_ question: ToolRequestUserInputQuestion) -> Bool {
        guard validIdentifier(question.id),
              validString(question.header, maximumBytes: UserInputRequestLimits.maximumHeaderBytes),
              validString(question.question, maximumBytes: UserInputRequestLimits.maximumQuestionBytes)
        else { return false }
        guard let options = question.options else { return true }
        return UserInputRequestLimits.optionCount.contains(options.count)
            && Set(options.map(\.label)).count == options.count
            && options.allSatisfy {
                validString($0.label, maximumBytes: UserInputRequestLimits.maximumOptionLabelBytes)
                    && validString($0.description,
                                   maximumBytes: UserInputRequestLimits.maximumOptionDescriptionBytes,
                                   allowEmpty: true)
            }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        validString(value, maximumBytes: UserInputRequestLimits.maximumIdentifierBytes)
    }

    private static func validString(_ value: String, maximumBytes: Int, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !value.isEmpty) && value.utf8.count <= maximumBytes
    }

    func isSubmittable(drafts: [String: UserInputDraft]) -> Bool {
        questions.allSatisfy { (try? answer(for: $0, draft: drafts[$0.id])) != nil }
    }

    func response(drafts: [String: UserInputDraft]) throws -> ToolRequestUserInputResponse {
        var answers: [String: ToolRequestUserInputAnswer] = [:]
        for question in questions {
            guard let value = try answer(for: question, draft: drafts[question.id]) else {
                throw UserInputError.unansweredQuestion(question.id)
            }
            answers[question.id] = ToolRequestUserInputAnswer(answers: [value])
        }
        return ToolRequestUserInputResponse(answers: answers)
    }

    private func answer(for question: ToolRequestUserInputQuestion,
                        draft: UserInputDraft?) throws -> String? {
        guard let draft else { return nil }
        if let selected = draft.selectedOption,
           question.options?.contains(where: { $0.label == selected }) == true {
            return selected
        }
        let text = draft.freeform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, question.options == nil || question.isOther else { return nil }
        let answer = UserInputRequestLimits.answerPrefix + text
        guard answer.utf8.count <= UserInputRequestLimits.maximumAnswerBytes else {
            throw UserInputError.answerTooLarge(question.id)
        }
        return answer
    }
}

enum UserInputError: Error, Equatable {
    case invalidRequest
    case invalidParams(String)
    case invalidQuestions
    case unansweredQuestion(String)
    case answerTooLarge(String)
}
