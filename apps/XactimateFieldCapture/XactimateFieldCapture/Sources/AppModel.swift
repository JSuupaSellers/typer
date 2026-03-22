import Foundation

@MainActor
final class FieldCaptureAppModel: ObservableObject {
    @Published var backendBaseURL: String {
        didSet { UserDefaults.standard.set(backendBaseURL, forKey: Keys.backendBaseURL) }
    }
    @Published var backendAPIKey: String {
        didSet { UserDefaults.standard.set(backendAPIKey, forKey: Keys.backendAPIKey) }
    }

    @Published var jobID: String
    @Published var bridgeID: String
    @Published var scopeItemID: String
    @Published var room: String
    @Published var surface: String
    @Published var damageType: String
    @Published var keywords: String
    @Published var quantity: String
    @Published var descriptionText: String
    @Published var transcript: String = ""
    @Published var selectedPhotos: [PickedPhoto] = []
    @Published var audioFileURL: URL?
    @Published var busyMessage: String = ""
    @Published var errorMessage: String?
    @Published var planResponse: PlanResponse?
    @Published var publishResponse: PublishResponse?
    @Published var captureDraft: CaptureDraftResponse?

    private let client = BackendClient()
    private let recorder = FieldAudioRecorder()

    init() {
        backendBaseURL = UserDefaults.standard.string(forKey: Keys.backendBaseURL) ?? "http://127.0.0.1:8790"
        backendAPIKey = UserDefaults.standard.string(forKey: Keys.backendAPIKey) ?? ""
        jobID = "claim-\(Int(Date().timeIntervalSince1970))"
        bridgeID = "default"
        scopeItemID = "scope-1"
        room = ""
        surface = ""
        damageType = ""
        keywords = ""
        quantity = ""
        descriptionText = ""
    }

    var isRecording: Bool {
        recorder.isRecording
    }

    var canPrepareDraft: Bool {
        !backendBaseURL.trimmed.isEmpty
    }

    var canPlan: Bool {
        !backendBaseURL.trimmed.isEmpty && !currentJob().items.first!.description.trimmed.isEmpty
    }

    var canPublish: Bool {
        guard let planResponse else { return false }
        return planResponse.needsReviewCount == 0 && planResponse.unresolvedCount == 0 && planResponse.approvedCount > 0
    }

    func toggleRecording() async {
        do {
            if recorder.isRecording {
                audioFileURL = try recorder.stopRecording()
            } else {
                audioFileURL = try await recorder.startRecording()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSelectedPhotos(_ photos: [PickedPhoto]) {
        let loaded = photos
        selectedPhotos = loaded
    }

    func prepareDraft() async {
        await runBusy("Uploading field note draft...") { [self] in
            let response = try await self.client.captureDraft(
                request: CaptureDraftRequest(
                    jobId: self.jobID,
                    bridgeId: self.bridgeID,
                    itemId: self.scopeItemID,
                    room: self.room,
                    surface: self.surface,
                    damageType: self.damageType,
                    keywords: self.keywords,
                    quantity: self.quantity,
                    description: self.descriptionText
                ),
                audioFileURL: self.audioFileURL,
                photos: self.selectedPhotos,
                configuration: self.backendConfiguration
            )

            self.captureDraft = response
            self.transcript = response.transcript
            if let firstItem = response.job.items.first {
                self.descriptionText = firstItem.description
            }
            self.planResponse = nil
            self.publishResponse = nil
        }
    }

    func planEstimate() async {
        await runBusy("Planning estimate...") { [self] in
            self.planResponse = try await self.client.plan(job: self.currentJob(), configuration: self.backendConfiguration)
            self.publishResponse = nil
        }
    }

    func publishEstimate() async {
        await runBusy("Publishing to bridge...") { [self] in
            self.publishResponse = try await self.client.publish(job: self.currentJob(), configuration: self.backendConfiguration)
        }
    }

    func currentJob() -> EstimateJobPayload {
        EstimateJobPayload(
            jobId: jobID.trimmed.isEmpty ? "job" : jobID.trimmed,
            bridgeId: bridgeID.trimmed.isEmpty ? "default" : bridgeID.trimmed,
            items: [
                EstimateScopeItemPayload(
                    itemId: scopeItemID.trimmed.isEmpty ? "scope-1" : scopeItemID.trimmed,
                    description: descriptionText.trimmed,
                    room: room.trimmed,
                    surface: surface.trimmed,
                    damageType: damageType.trimmed,
                    keywords: keywords.trimmed,
                    quantity: quantity.trimmed
                )
            ]
        )
    }

    private var backendConfiguration: BackendConfiguration {
        BackendConfiguration(baseURL: backendBaseURL, apiKey: backendAPIKey)
    }

    private func runBusy(_ message: String, operation: @escaping () async throws -> Void) async {
        busyMessage = message
        errorMessage = nil
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
        busyMessage = ""
    }
}

private enum Keys {
    static let backendBaseURL = "field_capture_backend_base_url"
    static let backendAPIKey = "field_capture_backend_api_key"
}
