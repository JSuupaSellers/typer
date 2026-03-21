import Foundation

enum OpenAITranscriptionError: LocalizedError {
    case invalidBaseURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The OpenAI base URL is invalid."
        case .invalidResponse:
            return "The transcription response could not be parsed."
        }
    }
}

struct OpenAITranscriptionService {
    func transcribeAudio(
        fileURL: URL,
        item: CatalogItemDetail,
        settings: LLMSettings
    ) async throws -> String {
        try await transcribe(
            fileURL: fileURL,
            settings: settings,
            prompt: prompt(for: settings.transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines), item: item)
        )
    }

    func transcribeRecommendationAudio(
        fileURL: URL,
        settings: LLMSettings
    ) async throws -> String {
        try await transcribe(
            fileURL: fileURL,
            settings: settings,
            prompt: recommendationPrompt(for: settings.transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    private func transcribe(
        fileURL: URL,
        settings: LLMSettings,
        prompt: String
    ) async throws -> String {
        let transcriptionModel = settings.transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .appending(path: "audio/transcriptions")
        else {
            throw OpenAITranscriptionError.invalidBaseURL
        }

        var form = MultipartFormData()
        form.addField(named: "model", value: transcriptionModel)
        form.addField(named: "prompt", value: prompt)
        form.addField(named: "response_format", value: "json")
        try form.addFile(
            named: "file",
            filename: fileURL.lastPathComponent,
            mimeType: "audio/mp4",
            fileURL: fileURL
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            let body = String(decoding: data, as: UTF8.self)
            throw NSError(domain: "OpenAITranscriptionService", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: body.isEmpty ? "The transcription API returned status \(http.statusCode)." : body
            ])
        }

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text
    }

    private func prompt(for transcriptionModel: String, item: CatalogItemDetail) -> String {
        let keywords = [
            item.displayCode,
            item.description,
            item.unit,
            item.category,
            item.selector,
            "Xactimate",
            "restoration",
            "drywall",
            "paint",
            "ceiling",
            "wall",
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if transcriptionModel == "whisper-1" {
            return keywords.joined(separator: ", ")
        }

        return "This audio is about the Xactimate line item \(item.displayCode) \(item.description). Keep line-item terms, measurements, and restoration vocabulary accurate."
    }

    private func recommendationPrompt(for transcriptionModel: String) -> String {
        let keywords = [
            "Xactimate",
            "room",
            "ceiling",
            "wall",
            "baseboard",
            "paint",
            "drywall",
            "patch",
            "picture frame",
            "texture",
            "estimate",
            "category",
            "selector",
        ]

        if transcriptionModel == "whisper-1" {
            return keywords.joined(separator: ", ")
        }

        return "This audio is an adjuster describing room damage and repair scope for Xactimate line-item lookup. Keep room names, surfaces, dimensions, CAT/SEL shorthand, and restoration vocabulary accurate."
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct MultipartFormData {
    let boundary = "Boundary-\(UUID().uuidString)"
    private(set) var bodyData = Data()

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    mutating func addField(named name: String, value: String) {
        var field = ""
        field += "--\(boundary)\r\n"
        field += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        field += "\(value)\r\n"
        bodyData.append(Data(field.utf8))
    }

    mutating func addFile(named name: String, filename: String, mimeType: String, fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        var field = ""
        field += "--\(boundary)\r\n"
        field += "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
        field += "Content-Type: \(mimeType)\r\n\r\n"
        bodyData.append(Data(field.utf8))
        bodyData.append(data)
        bodyData.append(Data("\r\n".utf8))
        bodyData.append(Data("--\(boundary)--\r\n".utf8))
    }
}
