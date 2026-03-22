import Foundation

enum BackendClientError: LocalizedError {
    case invalidBaseURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The backend URL is invalid."
        case .invalidResponse:
            return "The backend response could not be parsed."
        }
    }
}

struct BackendClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    func listDrafts(
        configuration: BackendConfiguration
    ) async throws -> DraftListResponse {
        guard let endpoint = URL(string: configuration.baseURL.trimmed)?.appending(path: "drafts") else {
            throw BackendClientError.invalidBaseURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        if !configuration.apiKey.trimmed.isEmpty {
            request.setValue(configuration.apiKey.trimmed, forHTTPHeaderField: "X-API-Key")
        }
        return try await execute(request, as: DraftListResponse.self)
    }

    func openDraft(
        jobID: String,
        bridgeID: String,
        configuration: BackendConfiguration
    ) async throws -> OpenDraftResponse {
        try await postJSON(
            path: "drafts/open",
            payload: ["job_id": jobID, "bridge_id": bridgeID],
            configuration: configuration,
            as: OpenDraftResponse.self
        )
    }

    func fetchDraft(
        jobID: String,
        configuration: BackendConfiguration
    ) async throws -> OpenDraftResponse {
        guard let endpoint = URL(string: configuration.baseURL.trimmed)?.appending(path: "drafts/\(jobID)") else {
            throw BackendClientError.invalidBaseURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        if !configuration.apiKey.trimmed.isEmpty {
            request.setValue(configuration.apiKey.trimmed, forHTTPHeaderField: "X-API-Key")
        }
        return try await execute(request, as: OpenDraftResponse.self)
    }

    func sendChatTurn(
        jobID: String,
        bridgeID: String,
        text: String,
        configuration: BackendConfiguration
    ) async throws -> DraftTurnResponse {
        try await postJSON(
            path: "drafts/\(jobID)/chat",
            payload: ["bridge_id": bridgeID, "text": text],
            configuration: configuration,
            as: DraftTurnResponse.self
        )
    }

    func sendVoiceTurn(
        jobID: String,
        bridgeID: String,
        text: String,
        audioFileURL: URL,
        configuration: BackendConfiguration
    ) async throws -> DraftTurnResponse {
        guard let endpoint = URL(string: configuration.baseURL.trimmed)?.appending(path: "drafts/\(jobID)/voice-turn") else {
            throw BackendClientError.invalidBaseURL
        }

        var form = MultipartFormData()
        form.addField(named: "bridge_id", value: bridgeID)
        form.addField(named: "text", value: text)
        try form.addFile(
            named: "audio",
            filename: audioFileURL.lastPathComponent,
            mimeType: mimeType(forAudioFileAt: audioFileURL),
            fileURL: audioFileURL
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.trimmed.isEmpty {
            request.setValue(configuration.apiKey.trimmed, forHTTPHeaderField: "X-API-Key")
        }
        request.httpBody = form.bodyData
        return try await execute(request, as: DraftTurnResponse.self)
    }

    func setDraftItemStatus(
        jobID: String,
        itemID: String,
        status: String,
        configuration: BackendConfiguration
    ) async throws -> OpenDraftResponse {
        try await postJSON(
            path: "drafts/\(jobID)/items/\(itemID)/status",
            payload: ["status": status],
            configuration: configuration,
            as: OpenDraftResponse.self
        )
    }

    func acceptAll(
        jobID: String,
        configuration: BackendConfiguration
    ) async throws -> OpenDraftResponse {
        try await postJSON(
            path: "drafts/\(jobID)/accept-all",
            payload: [:] as [String: String],
            configuration: configuration,
            as: OpenDraftResponse.self
        )
    }

    func planDraft(
        jobID: String,
        configuration: BackendConfiguration
    ) async throws -> DraftPlanResponse {
        try await postJSON(
            path: "drafts/\(jobID)/plan",
            payload: [:] as [String: String],
            configuration: configuration,
            as: DraftPlanResponse.self
        )
    }

    func publishDraft(
        jobID: String,
        configuration: BackendConfiguration
    ) async throws -> DraftPublishResponse {
        try await postJSON(
            path: "drafts/\(jobID)/publish",
            payload: [:] as [String: String],
            configuration: configuration,
            as: DraftPublishResponse.self
        )
    }

    private func postJSON<T: Encodable, U: Decodable>(
        path: String,
        payload: T,
        configuration: BackendConfiguration,
        as type: U.Type
    ) async throws -> U {
        guard let endpoint = URL(string: configuration.baseURL.trimmed)?.appending(path: path) else {
            throw BackendClientError.invalidBaseURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.trimmed.isEmpty {
            request.setValue(configuration.apiKey.trimmed, forHTTPHeaderField: "X-API-Key")
        }
        request.httpBody = try JSONEncoder().encode(payload)
        return try await execute(request, as: type)
    }

    private func execute<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        var request = request
        if request.timeoutInterval <= 0 {
            request.timeoutInterval = 180
        }
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            let body = String(decoding: data, as: UTF8.self)
            throw NSError(
                domain: "BackendClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: body.isEmpty ? "The backend returned status \(http.statusCode)." : body]
            )
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw BackendClientError.invalidResponse
        }
    }

    private func mimeType(forAudioFileAt url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        default:
            return "audio/mp4"
        }
    }
}

private struct MultipartFormData {
    let boundary = "Boundary-\(UUID().uuidString)"
    private(set) var storage = Data()

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    mutating func addField(named name: String, value: String) {
        var field = ""
        field += "--\(boundary)\r\n"
        field += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        field += "\(value)\r\n"
        storage.append(Data(field.utf8))
    }

    mutating func addFile(named name: String, filename: String, mimeType: String, fileURL: URL) throws {
        try addFileData(
            named: name,
            filename: filename,
            mimeType: mimeType,
            data: Data(contentsOf: fileURL)
        )
    }

    mutating func addFileData(named name: String, filename: String, mimeType: String, data: Data) {
        var field = ""
        field += "--\(boundary)\r\n"
        field += "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
        field += "Content-Type: \(mimeType)\r\n\r\n"
        storage.append(Data(field.utf8))
        storage.append(data)
        storage.append(Data("\r\n".utf8))
    }

    mutating func finalize() {
        storage.append(Data("--\(boundary)--\r\n".utf8))
    }

    init() {
    }
}

extension MultipartFormData {
    var bodyData: Data {
        var copy = self
        copy.finalize()
        return copy.storage
    }
}
