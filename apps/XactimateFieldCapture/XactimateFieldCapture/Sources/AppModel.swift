import Foundation

struct PendingTurnState: Equatable {
    let jobID: String
    let operationID: String
    let submittedText: String
    let statusText: String
}

struct PendingDirectComposeState: Equatable {
    let submittedPrompt: String
    let statusText: String
}

struct PendingEstimateExportState: Equatable {
    let title: String
    let statusText: String
}

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
    @Published var pendingTurn: PendingTurnState?
    @Published var directPromptDraft: String = ""
    @Published var directAudioFileURL: URL?
    @Published var directTranscript: String = ""
    @Published var directCompose: DirectComposeResponse?
    @Published var directOutputText: String = ""
    @Published var directSendEnter: Bool = false
    @Published var directPublishResponse: DirectPublishResponse?
    @Published var pendingDirectCompose: PendingDirectComposeState?
    @Published var exportTitle: String = "Estimate Export"
    @Published var exportRows: [EstimateExportRowDraft] = [EstimateExportRowDraft()]
    @Published var estimateExportPublishResponse: EstimateExportPublishResponse?
    @Published var pendingEstimateExport: PendingEstimateExportState?

    private let client = BackendClient()
    private let recorder = FieldAudioRecorder()
    private var pollingOperationIDs: Set<String> = []

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
        draft != nil && !messageDraft.trimmed.isEmpty && activePendingTurn == nil
    }

    var canSendVoice: Bool {
        draft != nil && audioFileURL != nil && activePendingTurn == nil
    }

    var canAcceptAll: Bool {
        draft != nil && activePendingTurn == nil
    }

    var canPlan: Bool {
        activePendingTurn == nil && draft?.items.contains(where: { $0.status == "accepted" }) == true
    }

    var canPublish: Bool {
        activePendingTurn == nil && draft?.items.contains(where: { $0.status == "accepted" }) == true
    }

    var publishStatusMessage: String? {
        guard canPublish else {
            if activePendingTurn != nil {
                return "Wait for the current claim update to finish."
            }
            return "Accept at least one line item to publish."
        }
        guard let planResponse else {
            return "Publish will run a plan check first."
        }
        if planResponse.unresolvedCount > 0 {
            return "\(planResponse.unresolvedCount) item\(planResponse.unresolvedCount == 1 ? "" : "s") still unresolved."
        }
        if planResponse.needsReviewCount > 0 {
            return "\(planResponse.needsReviewCount) item\(planResponse.needsReviewCount == 1 ? "" : "s") still need review."
        }
        return "Ready to publish."
    }

    var canComposeDirectText: Bool {
        !backendBaseURL.trimmed.isEmpty &&
        !directPromptDraft.trimmed.isEmpty &&
        pendingDirectCompose == nil &&
        pendingEstimateExport == nil
    }

    var canComposeDirectVoice: Bool {
        !backendBaseURL.trimmed.isEmpty &&
        directAudioFileURL != nil &&
        pendingDirectCompose == nil &&
        pendingEstimateExport == nil
    }

    var canPublishDirectOutput: Bool {
        !backendBaseURL.trimmed.isEmpty &&
        !directOutputText.trimmed.isEmpty &&
        pendingDirectCompose == nil &&
        pendingEstimateExport == nil
    }

    var filledExportRows: [EstimateExportRowDraft] {
        exportRows
            .map(\.normalized)
            .filter { !$0.isEmpty }
    }

    var exportHasIncompleteRows: Bool {
        filledExportRows.contains(where: { !$0.isComplete })
    }

    var canPublishEstimateExport: Bool {
        !backendBaseURL.trimmed.isEmpty &&
        !filledExportRows.isEmpty &&
        !exportHasIncompleteRows &&
        pendingEstimateExport == nil &&
        pendingDirectCompose == nil
    }

    var activePendingTurn: PendingTurnState? {
        guard let pendingTurn, pendingTurn.jobID == jobID.trimmed else {
            return nil
        }
        return pendingTurn
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
        let requestJobID = jobID.trimmed
        let requestBridgeID = bridgeID.trimmed.isEmpty ? "default" : bridgeID.trimmed
        let originalDraft = messageDraft
        errorMessage = nil
        pendingTurn = PendingTurnState(jobID: requestJobID, operationID: "", submittedText: outgoing, statusText: "Submitting...")
        messageDraft = ""
        audioFileURL = nil
        planResponse = nil
        publishResponse = nil

        do {
            let response = try await self.client.sendDraftMessage(
                jobID: requestJobID,
                bridgeID: requestBridgeID,
                text: outgoing,
                configuration: self.backendConfiguration
            )
            try await self.reloadClaimSummaries()
            if self.jobID.trimmed == requestJobID {
                self.applyOperationResponse(response, restoreText: originalDraft)
            } else {
                self.beginPolling(response.operation, restoreText: originalDraft)
            }
        } catch {
            if self.jobID.trimmed == requestJobID {
                if self.messageDraft.isEmpty {
                    self.messageDraft = originalDraft
                }
                self.errorMessage = error.localizedDescription
                if self.pendingTurn?.jobID == requestJobID {
                    self.pendingTurn = nil
                }
            }
        }
    }

    func sendVoiceTurn() async {
        guard let audioFileURL else { return }
        let draftText = messageDraft.trimmed
        let requestJobID = jobID.trimmed
        let requestBridgeID = bridgeID.trimmed.isEmpty ? "default" : bridgeID.trimmed
        let originalDraftText = messageDraft
        let originalAudioURL = audioFileURL
        let pendingPreview = draftText.isEmpty ? "Voice note sent" : draftText
        errorMessage = nil
        pendingTurn = PendingTurnState(jobID: requestJobID, operationID: "", submittedText: pendingPreview, statusText: "Submitting...")
        messageDraft = ""
        self.audioFileURL = nil
        planResponse = nil
        publishResponse = nil

        do {
            let response = try await self.client.sendVoiceMessage(
                jobID: requestJobID,
                bridgeID: requestBridgeID,
                text: draftText,
                audioFileURL: originalAudioURL,
                configuration: self.backendConfiguration
            )
            try await self.reloadClaimSummaries()
            if self.jobID.trimmed == requestJobID {
                self.applyOperationResponse(response, restoreText: originalDraftText, restoreAudioURL: originalAudioURL)
            } else {
                self.beginPolling(response.operation, restoreText: originalDraftText, restoreAudioURL: originalAudioURL)
            }
        } catch {
            if self.jobID.trimmed == requestJobID {
                if self.messageDraft.isEmpty {
                    self.messageDraft = originalDraftText
                }
                if self.audioFileURL == nil {
                    self.audioFileURL = originalAudioURL
                }
                self.errorMessage = error.localizedDescription
                if self.pendingTurn?.jobID == requestJobID {
                    self.pendingTurn = nil
                }
            }
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

    func preparePublish() async -> Bool {
        guard canPublish else {
            errorMessage = publishStatusMessage ?? "This claim is not ready to publish yet."
            return false
        }

        if planResponse == nil {
            await planDraft()
        }

        guard let planResponse else {
            errorMessage = "The claim could not be planned for publish."
            return false
        }

        if planResponse.unresolvedCount > 0 {
            errorMessage = "\(planResponse.unresolvedCount) item\(planResponse.unresolvedCount == 1 ? "" : "s") still unresolved. Review the scope before publishing."
            return false
        }

        if planResponse.needsReviewCount > 0 {
            errorMessage = "\(planResponse.needsReviewCount) item\(planResponse.needsReviewCount == 1 ? "" : "s") still need review before publishing."
            return false
        }

        if planResponse.approvedCount <= 0 {
            errorMessage = "There are no approved items ready to publish."
            return false
        }

        return true
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

    func toggleDirectRecording() async {
        do {
            if recorder.isRecording {
                directAudioFileURL = try recorder.stopRecording()
            } else {
                directAudioFileURL = try await recorder.startRecording()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendDirectTextPrompt() async {
        let outgoing = directPromptDraft.trimmed
        guard !outgoing.isEmpty else { return }
        let requestBridgeID = bridgeID.trimmed.isEmpty ? "default" : bridgeID.trimmed
        let originalDraft = directPromptDraft
        errorMessage = nil
        pendingDirectCompose = PendingDirectComposeState(submittedPrompt: outgoing, statusText: "Drafting...")
        directPromptDraft = ""
        directAudioFileURL = nil
        directPublishResponse = nil

        do {
            let response = try await client.composeDirectText(
                bridgeID: requestBridgeID,
                prompt: outgoing,
                configuration: backendConfiguration
            )
            applyDirectCompose(response)
        } catch {
            if directPromptDraft.isEmpty {
                directPromptDraft = originalDraft
            }
            errorMessage = error.localizedDescription
            pendingDirectCompose = nil
        }
    }

    func sendDirectVoicePrompt() async {
        guard let directAudioFileURL else { return }
        let promptHint = directPromptDraft.trimmed
        let originalPrompt = directPromptDraft
        let originalAudioURL = directAudioFileURL
        let requestBridgeID = bridgeID.trimmed.isEmpty ? "default" : bridgeID.trimmed
        let pendingPreview = promptHint.isEmpty ? "Voice prompt sent" : promptHint
        errorMessage = nil
        pendingDirectCompose = PendingDirectComposeState(submittedPrompt: pendingPreview, statusText: "Drafting...")
        directPromptDraft = ""
        self.directAudioFileURL = nil
        directPublishResponse = nil

        do {
            let response = try await client.composeDirectVoice(
                bridgeID: requestBridgeID,
                prompt: promptHint,
                audioFileURL: originalAudioURL,
                configuration: backendConfiguration
            )
            applyDirectCompose(response)
        } catch {
            if directPromptDraft.isEmpty {
                directPromptDraft = originalPrompt
            }
            if self.directAudioFileURL == nil {
                self.directAudioFileURL = originalAudioURL
            }
            errorMessage = error.localizedDescription
            pendingDirectCompose = nil
        }
    }

    func publishDirectOutput() async {
        let requestBridgeID = bridgeID.trimmed.isEmpty ? "default" : bridgeID.trimmed
        let text = directOutputText.trimmed
        guard !text.isEmpty else { return }
        pendingDirectCompose = PendingDirectComposeState(submittedPrompt: directCompose?.title ?? "Typed output", statusText: "Sending to Pi...")
        errorMessage = nil

        do {
            let response = try await client.publishDirectText(
                bridgeID: requestBridgeID,
                title: directCompose?.title ?? "Typed Output",
                text: text,
                sendEnter: directSendEnter,
                configuration: backendConfiguration
            )
            directPublishResponse = response
            pendingDirectCompose = nil
        } catch {
            errorMessage = error.localizedDescription
            pendingDirectCompose = nil
        }
    }

    func addEstimateExportRow() {
        exportRows.append(EstimateExportRowDraft())
    }

    func removeEstimateExportRows(at offsets: IndexSet) {
        exportRows.remove(atOffsets: offsets)
        if exportRows.isEmpty {
            exportRows = [EstimateExportRowDraft()]
        }
    }

    func clearEstimateExportRows() {
        exportRows = [EstimateExportRowDraft()]
        estimateExportPublishResponse = nil
    }

    func publishEstimateExport() async {
        let requestBridgeID = bridgeID.trimmed.isEmpty ? "default" : bridgeID.trimmed
        let normalizedRows = filledExportRows
        guard !normalizedRows.isEmpty else { return }
        guard !exportHasIncompleteRows else {
            errorMessage = "Every export row needs CAT, SEL, and quantity before sending."
            return
        }

        pendingEstimateExport = PendingEstimateExportState(
            title: exportTitle.trimmed.isEmpty ? "Estimate Export" : exportTitle.trimmed,
            statusText: "Sending estimate rows to Pi..."
        )
        errorMessage = nil

        do {
            let response = try await client.publishEstimateExport(
                bridgeID: requestBridgeID,
                title: exportTitle.trimmed.isEmpty ? "Estimate Export" : exportTitle.trimmed,
                rows: normalizedRows,
                configuration: backendConfiguration
            )
            exportRows = response.rows.map {
                EstimateExportRowDraft(cat: $0.cat, sel: $0.sel, quantity: $0.quantity)
            }
            if exportRows.isEmpty {
                exportRows = [EstimateExportRowDraft()]
            }
            estimateExportPublishResponse = response
            pendingEstimateExport = nil
        } catch {
            errorMessage = error.localizedDescription
            pendingEstimateExport = nil
        }
    }

    private func applyDraftResponse(_ response: OpenDraftResponse) {
        draft = response.draft
        groupedSections = response.groupedSections
        syncSelectedRoom()
        adoptCurrentOperation(from: response.operations)
    }

    private func applyOperationResponse(
        _ response: DraftOperationResponse,
        restoreText: String? = nil,
        restoreAudioURL: URL? = nil
    ) {
        if let latestDraft = response.draft {
            draft = latestDraft
        }
        groupedSections = response.groupedSections
        transcript = response.operation.transcript
        syncSelectedRoom()
        synchronizePendingTurn(with: response.operation, restoreText: restoreText, restoreAudioURL: restoreAudioURL)
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

    private func applyDirectCompose(_ response: DirectComposeResponse) {
        directCompose = response
        directTranscript = response.transcript
        directOutputText = response.text
        directSendEnter = response.sendEnter
        directPublishResponse = nil
        pendingDirectCompose = nil
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

    private func adoptCurrentOperation(from operations: [ClaimOperationPayload]) {
        guard let current = operations.first(where: isActiveOperation) else {
            if activePendingTurn != nil {
                pendingTurn = nil
            }
            return
        }
        synchronizePendingTurn(with: current)
    }

    private func synchronizePendingTurn(
        with operation: ClaimOperationPayload,
        restoreText: String? = nil,
        restoreAudioURL: URL? = nil
    ) {
        guard isActiveOperation(operation) else {
            if pendingTurn?.operationID == operation.id {
                pendingTurn = nil
            }
            return
        }

        let preview = operation.submittedText.trimmed.isEmpty
            ? (operation.kind == "voice_turn" ? "Voice note sent" : "Updating draft")
            : operation.submittedText
        let statusText = operation.statusMessage.trimmed.isEmpty ? "Thinking..." : operation.statusMessage
        pendingTurn = PendingTurnState(
            jobID: operation.jobId,
            operationID: operation.id,
            submittedText: preview,
            statusText: statusText
        )
        beginPolling(operation, restoreText: restoreText, restoreAudioURL: restoreAudioURL)
    }

    private func beginPolling(_ operation: ClaimOperationPayload, restoreText: String? = nil, restoreAudioURL: URL? = nil) {
        guard !pollingOperationIDs.contains(operation.id) else { return }
        pollingOperationIDs.insert(operation.id)
        Task { [weak self] in
            await self?.pollOperation(
                operationID: operation.id,
                jobID: operation.jobId,
                restoreText: restoreText,
                restoreAudioURL: restoreAudioURL
            )
        }
    }

    private func pollOperation(
        operationID: String,
        jobID: String,
        restoreText: String?,
        restoreAudioURL: URL?
    ) async {
        defer { pollingOperationIDs.remove(operationID) }

        var failureCount = 0
        while !Task.isCancelled {
            do {
                let response = try await client.fetchOperation(
                    operationID: operationID,
                    configuration: backendConfiguration
                )
                failureCount = 0
                if self.jobID.trimmed == response.operation.jobId {
                    applyOperationResponse(response)
                }
                try? await reloadClaimSummaries()

                switch response.operation.status {
                case "completed":
                    if pendingTurn?.operationID == operationID {
                        pendingTurn = nil
                    }
                    return
                case "failed":
                    if self.jobID.trimmed == jobID {
                        if let restoreText, self.messageDraft.isEmpty {
                            self.messageDraft = restoreText
                        }
                        if let restoreAudioURL, self.audioFileURL == nil {
                            self.audioFileURL = restoreAudioURL
                        }
                        self.errorMessage = response.operation.errorMessage.isEmpty
                            ? "The claim workflow failed."
                            : response.operation.errorMessage
                    }
                    if pendingTurn?.operationID == operationID {
                        pendingTurn = nil
                    }
                    return
                default:
                    break
                }
            } catch {
                failureCount += 1
                if failureCount >= 3 {
                    if self.jobID.trimmed == jobID {
                        self.errorMessage = error.localizedDescription
                    }
                    return
                }
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func isActiveOperation(_ operation: ClaimOperationPayload) -> Bool {
        operation.status == "queued" || operation.status == "running"
    }
}

private enum Keys {
    static let backendBaseURL = "field_capture_backend_base_url"
    static let backendAPIKey = "field_capture_backend_api_key"
}
