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

struct CaptureDraftRequest {
    var jobId: String
    var bridgeId: String
    var itemId: String
    var room: String
    var surface: String
    var damageType: String
    var keywords: String
    var quantity: String
    var description: String
}

struct BackendClient {
    func captureDraft(
        request draft: CaptureDraftRequest,
        audioFileURL: URL?,
        photos: [PickedPhoto],
        configuration: BackendConfiguration
    ) async throws -> CaptureDraftResponse {
        guard let endpoint = URL(string: configuration.baseURL.trimmed)?.appending(path: "capture/intake") else {
            throw BackendClientError.invalidBaseURL
        }

        var form = MultipartFormData()
        form.addField(named: "job_id", value: draft.jobId)
        form.addField(named: "bridge_id", value: draft.bridgeId)
        form.addField(named: "item_id", value: draft.itemId)
        form.addField(named: "room", value: draft.room)
        form.addField(named: "surface", value: draft.surface)
        form.addField(named: "damage_type", value: draft.damageType)
        form.addField(named: "keywords", value: draft.keywords)
        form.addField(named: "quantity", value: draft.quantity)
        form.addField(named: "description", value: draft.description)

        if let audioFileURL {
            try form.addFile(
                named: "audio",
                filename: audioFileURL.lastPathComponent,
                mimeType: mimeType(forAudioFileAt: audioFileURL),
                fileURL: audioFileURL
            )
        }

        for photo in photos {
            form.addFileData(
                named: "photos",
                filename: photo.filename,
                mimeType: photo.mimeType,
                data: photo.data
            )
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.trimmed.isEmpty {
            request.setValue(configuration.apiKey.trimmed, forHTTPHeaderField: "X-API-Key")
        }
        request.httpBody = form.bodyData

        return try await execute(request, as: CaptureDraftResponse.self)
    }

    func plan(
        job: EstimateJobPayload,
        configuration: BackendConfiguration
    ) async throws -> PlanResponse {
        try await postJSON(path: "plan", payload: job, configuration: configuration, as: PlanResponse.self)
    }

    func publish(
        job: EstimateJobPayload,
        configuration: BackendConfiguration
    ) async throws -> PublishResponse {
        try await postJSON(path: "publish", payload: job, configuration: configuration, as: PublishResponse.self)
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
        let (data, response) = try await URLSession.shared.data(for: request)
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
