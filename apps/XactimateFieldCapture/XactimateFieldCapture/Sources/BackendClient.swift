import Foundation

enum BackendClientError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case missingRoute(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The backend URL is invalid."
        case .invalidResponse:
            return "The backend response could not be parsed."
        case let .missingRoute(path):
            return "The backend is missing \(path). Restart the laptop backend with the latest code."
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

    func sendDraftMessage(
        jobID: String,
        bridgeID: String,
        text: String,
        configuration: BackendConfiguration
    ) async throws -> DraftOperationResponse {
        try await postJSON(
            path: "drafts/\(jobID)/messages",
            payload: ["bridge_id": bridgeID, "text": text],
            configuration: configuration,
            as: DraftOperationResponse.self
        )
    }

    func fetchOperation(
        operationID: String,
        configuration: BackendConfiguration
    ) async throws -> DraftOperationResponse {
        guard let endpoint = URL(string: configuration.baseURL.trimmed)?.appending(path: "operations/\(operationID)") else {
            throw BackendClientError.invalidBaseURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        if !configuration.apiKey.trimmed.isEmpty {
            request.setValue(configuration.apiKey.trimmed, forHTTPHeaderField: "X-API-Key")
        }
        return try await execute(request, as: DraftOperationResponse.self)
    }

    func sendVoiceMessage(
        jobID: String,
        bridgeID: String,
        text: String,
        audioFileURL: URL,
        configuration: BackendConfiguration
    ) async throws -> DraftOperationResponse {
        guard let endpoint = URL(string: configuration.baseURL.trimmed)?.appending(path: "drafts/\(jobID)/voice-messages") else {
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
        return try await execute(request, as: DraftOperationResponse.self)
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

    func composeDirectText(
        bridgeID: String,
        prompt: String,
        configuration: BackendConfiguration
    ) async throws -> DirectComposeResponse {
        try await postJSON(
            path: "direct/compose",
            payload: ["bridge_id": bridgeID, "prompt": prompt],
            configuration: configuration,
            as: DirectComposeResponse.self
        )
    }

    func composeDirectVoice(
        bridgeID: String,
        prompt: String,
        audioFileURL: URL,
        configuration: BackendConfiguration
    ) async throws -> DirectComposeResponse {
        guard let endpoint = URL(string: configuration.baseURL.trimmed)?.appending(path: "direct/voice-compose") else {
            throw BackendClientError.invalidBaseURL
        }

        var form = MultipartFormData()
        form.addField(named: "bridge_id", value: bridgeID)
        form.addField(named: "prompt", value: prompt)
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
        return try await execute(request, as: DirectComposeResponse.self)
    }

    func publishDirectText(
        bridgeID: String,
        title: String,
        text: String,
        sendEnter: Bool,
        configuration: BackendConfiguration
    ) async throws -> DirectPublishResponse {
        struct DirectPublishRequest: Encodable {
            let bridge_id: String
            let title: String
            let text: String
            let send_enter: Bool
        }
        return try await postJSON(
            path: "direct/publish",
            payload: DirectPublishRequest(
                bridge_id: bridgeID,
                title: title,
                text: text,
                send_enter: sendEnter
            ),
            configuration: configuration,
            as: DirectPublishResponse.self
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
            if http.statusCode == 404, body.contains("\"detail\":\"Not Found\""), let path = request.url?.path {
                throw BackendClientError.missingRoute(path)
            }
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
