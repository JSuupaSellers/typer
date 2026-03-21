import Foundation

enum LLMCleaningError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case missingChoice
    case missingContent

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The LLM endpoint URL is invalid."
        case .invalidResponse:
            return "The LLM response could not be parsed."
        case .missingChoice:
            return "The LLM response did not contain a usable message."
        case .missingContent:
            return "The LLM response message was empty."
        }
    }
}

struct LLMCleaningService {
    func cleanTranscript(
        transcript: String,
        item: CatalogItemDetail,
        settings: LLMSettings
    ) async throws -> CleanedUsageNoteResult {
        guard let endpoint = URL(string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .appending(path: "chat/completions")
        else { throw LLMCleaningError.invalidEndpoint }

        let prompt = """
        Xactimate item:
        Code: \(item.displayCode)
        Description: \(item.description)
        Unit: \(item.unit)
        Details: \(item.details)

        User voice transcript:
        \(transcript)
        """

        let payload = ChatCompletionsRequest(
            model: settings.cleanupModel.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: [
                .init(role: "system", content: settings.systemPrompt),
                .init(role: "user", content: prompt),
            ],
            temperature: 0.2
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            let body = String(decoding: data, as: UTF8.self)
            throw NSError(domain: "LLMCleaningService", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: body.isEmpty ? "The LLM API returned status \(http.statusCode)." : body
            ])
        }

        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw LLMCleaningError.missingChoice
        }
        return try Self.parseCleanedResult(from: content)
    }

    static func parseCleanedResult(from content: String) throws -> CleanedUsageNoteResult {
        let stripped = stripMarkdownFences(from: content)
        guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMCleaningError.missingContent
        }
        guard let data = stripped.data(using: .utf8) else {
            throw LLMCleaningError.invalidResponse
        }
        return try JSONDecoder().decode(CleanedUsageNoteResult.self, from: data)
    }

    private static func stripMarkdownFences(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3 else { return trimmed }
        let withoutFirst = lines.dropFirst()
        let withoutLast = withoutFirst.dropLast()
        return withoutLast.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
}

private struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}
