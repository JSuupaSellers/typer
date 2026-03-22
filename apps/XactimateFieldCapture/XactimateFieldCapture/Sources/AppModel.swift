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
    @Published var messageDraft: String = ""
    @Published var audioFileURL: URL?
    @Published var busyMessage: String = ""
    @Published var errorMessage: String?
    @Published var transcript: String = ""
    @Published var draft: DraftPayload?
    @Published var groupedSections: [DraftSectionPayload] = []
    @Published var planResponse: PlanResponse?
    @Published var publishResponse: PublishResponse?
    @Published var selectedRoom: String = "All Rooms"
    @Published var claimSummaries: [ClaimSummaryPayload] = []
    @Published var showingClaims: Bool = false

    private let client = BackendClient()
    private let recorder = FieldAudioRecorder()

    init() {
        backendBaseURL = UserDefaults.standard.string(forKey: Keys.backendBaseURL) ?? "http://127.0.0.1:8790"
        backendAPIKey = UserDefaults.standard.string(forKey: Keys.backendAPIKey) ?? ""
        jobID = "claim-\(Int(Date().timeIntervalSince1970))"
        bridgeID = "default"
    }

    var isRecording: Bool {
        recorder.isRecording
    }

    var canOpenDraft: Bool {
        !backendBaseURL.trimmed.isEmpty && !jobID.trimmed.isEmpty
    }

    var canSendText: Bool {
        draft != nil && !messageDraft.trimmed.isEmpty
    }

    var canSendVoice: Bool {
        draft != nil && audioFileURL != nil
    }

    var canPlan: Bool {
        draft?.items.contains(where: { $0.status == "accepted" }) == true
    }

    var canPublish: Bool {
        guard let planResponse else { return false }
        return planResponse.needsReviewCount == 0 && planResponse.unresolvedCount == 0 && planResponse.approvedCount > 0
    }

    var rooms: [String] {
        let draftRooms = draft?.roomOrder ?? []
        let groupedRooms = groupedSections.map(\.room)
        let merged = Array(Set(draftRooms + groupedRooms)).sorted {
            let leftIndex = draftRooms.firstIndex(of: $0) ?? Int.max
            let rightIndex = draftRooms.firstIndex(of: $1) ?? Int.max
            if leftIndex == rightIndex {
                return $0 < $1
            }
            return leftIndex < rightIndex
        }
        return ["All Rooms"] + merged
    }

    var filteredSections: [DraftSectionPayload] {
        guard selectedRoom != "All Rooms" else { return groupedSections }
        return groupedSections.filter { $0.room == selectedRoom }
    }

    var currentClaimSummary: ClaimSummaryPayload? {
        claimSummaries.first(where: { $0.jobId == jobID.trimmed })
    }

    func openDraft() async {
        await runBusy("Opening claim draft...") { [self] in
            let response = try await self.client.openDraft(
                jobID: self.jobID.trimmed,
                bridgeID: self.bridgeID.trimmed.isEmpty ? "default" : self.bridgeID.trimmed,
                configuration: self.backendConfiguration
            )
            self.applyDraftResponse(response)
            self.messageDraft = ""
            self.transcript = ""
            self.planResponse = nil
            self.publishResponse = nil
            try await self.reloadClaimSummaries()
        }
    }

    func refreshDraft() async {
        await runBusy("Refreshing claim draft...") { [self] in
            let response = try await self.client.fetchDraft(
                jobID: self.jobID.trimmed,
                configuration: self.backendConfiguration
            )
            self.applyDraftResponse(response)
            try await self.reloadClaimSummaries()
        }
    }

    func sendTextTurn() async {
        let outgoing = messageDraft.trimmed
        guard !outgoing.isEmpty else { return }
        await runBusy("Sending note to the claim agent...") { [self] in
            let response = try await self.client.sendChatTurn(
                jobID: self.jobID.trimmed,
                bridgeID: self.bridgeID.trimmed.isEmpty ? "default" : self.bridgeID.trimmed,
                text: outgoing,
                configuration: self.backendConfiguration
            )
            self.applyTurnResponse(response)
            self.messageDraft = ""
            self.audioFileURL = nil
            self.planResponse = nil
            self.publishResponse = nil
            try await self.reloadClaimSummaries()
        }
    }

    func sendVoiceTurn() async {
        guard let audioFileURL else { return }
        let draftText = messageDraft.trimmed
        await runBusy("Transcribing and applying voice turn...") { [self] in
            let response = try await self.client.sendVoiceTurn(
                jobID: self.jobID.trimmed,
                bridgeID: self.bridgeID.trimmed.isEmpty ? "default" : self.bridgeID.trimmed,
                text: draftText,
                audioFileURL: audioFileURL,
                configuration: self.backendConfiguration
            )
            self.applyTurnResponse(response)
            self.messageDraft = ""
            self.audioFileURL = nil
            self.planResponse = nil
            self.publishResponse = nil
            try await self.reloadClaimSummaries()
        }
    }

    func setItemStatus(_ itemID: String, status: String) async {
        await runBusy("Updating line item status...") { [self] in
            let response = try await self.client.setDraftItemStatus(
                jobID: self.jobID.trimmed,
                itemID: itemID,
                status: status,
                configuration: self.backendConfiguration
            )
            self.applyDraftResponse(response)
            self.planResponse = nil
            self.publishResponse = nil
            try await self.reloadClaimSummaries()
        }
    }

    func acceptAll() async {
        await runBusy("Accepting drafted items...") { [self] in
            let response = try await self.client.acceptAll(
                jobID: self.jobID.trimmed,
                configuration: self.backendConfiguration
            )
            self.applyDraftResponse(response)
            self.planResponse = nil
            self.publishResponse = nil
            try await self.reloadClaimSummaries()
        }
    }

    func planDraft() async {
        await runBusy("Planning room draft for the Pi...") { [self] in
            let response = try await self.client.planDraft(
                jobID: self.jobID.trimmed,
                configuration: self.backendConfiguration
            )
            self.draft = response.draft
            self.groupedSections = response.groupedSections
            self.planResponse = response.plan
            self.publishResponse = nil
            self.syncSelectedRoom()
            try await self.reloadClaimSummaries()
        }
    }

    func publishDraft() async {
        await runBusy("Publishing approved rooms to the bridge...") { [self] in
            let response = try await self.client.publishDraft(
                jobID: self.jobID.trimmed,
                configuration: self.backendConfiguration
            )
            self.draft = response.draft
            self.groupedSections = response.groupedSections
            self.publishResponse = response.publish
            self.syncSelectedRoom()
            try await self.reloadClaimSummaries()
        }
    }

    func loadClaims(silently: Bool = false) async {
        if silently {
            do {
                try await reloadClaimSummaries()
            } catch {
                // Ignore startup refresh failures until the user interacts with the backend controls.
            }
            return
        }

        await runBusy("Loading claims...") { [self] in
            try await self.reloadClaimSummaries()
        }
    }

    func switchToClaim(_ summary: ClaimSummaryPayload) async {
        jobID = summary.jobId
        bridgeID = summary.bridgeId
        showingClaims = false
        await openDraft()
    }

    func startNewClaim() async {
        let newID = "claim-\(Int(Date().timeIntervalSince1970))"
        jobID = newID
        bridgeID = bridgeID.trimmed.isEmpty ? "default" : bridgeID.trimmed
        selectedRoom = "All Rooms"
        transcript = ""
        messageDraft = ""
        await openDraft()
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

    private func applyDraftResponse(_ response: OpenDraftResponse) {
        draft = response.draft
        groupedSections = response.groupedSections
        syncSelectedRoom()
    }

    private func applyTurnResponse(_ response: DraftTurnResponse) {
        draft = response.draft
        groupedSections = response.groupedSections
        transcript = response.transcript
        syncSelectedRoom()
    }

    private func syncSelectedRoom() {
        if !rooms.contains(selectedRoom) {
            selectedRoom = "All Rooms"
        }
    }

    private func reloadClaimSummaries() async throws {
        let response = try await client.listDrafts(configuration: backendConfiguration)
        claimSummaries = response.drafts
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
