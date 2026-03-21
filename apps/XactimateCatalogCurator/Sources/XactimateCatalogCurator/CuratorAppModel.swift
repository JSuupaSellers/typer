import AppKit
import Foundation
import SwiftUI

enum CuratorStage: Hashable {
    case importData
    case quickReview
    case usageNotes
    case estimatePhotos
}

@MainActor
final class CuratorAppModel: ObservableObject {
    @Published var selectedStage: CuratorStage = .importData
    @Published var preview: ImportPreview?
    @Published var importSummary: ImportResultSummary?
    @Published var stats: CurationStats = .empty
    @Published var currentReviewItem: CatalogItemDetail?
    @Published var usedItems: [CatalogItemSummary] = []
    @Published var selectedUsedItemID: Int64?
    @Published var selectedUsedItem: CatalogItemDetail?
    @Published var usageNotes: [UsageScenarioRecord] = []
    @Published var selectedUsageNoteID: Int64?
    @Published var scenarioDraft: ScenarioDraft = .empty
    @Published var noteSearchText: String = ""
    @Published var estimatePhotoURLs: [URL] = []
    @Published var photoScanEntries: [PhotoScanEntry] = []
    @Published var photoScanSummary: PhotoScanSummary = .empty
    @Published var llmSettings: LLMSettings = .load()
    @Published var lastError: String = ""
    @Published var isBusy = false
    @Published var isRecordingTranscript = false
    @Published var isScanningEstimatePhotos = false

    private let importer = WorkbookImporter()
    private let audioRecorder = AudioRecorder()
    private let llmCleaningService = LLMCleaningService()
    private let transcriptionService = OpenAITranscriptionService()
    private let store: CatalogStore?
    private var preparedWorkbook: WorkbookImporter.PreparedWorkbook?
    private var skippedReviewIDs: Set<Int64> = []

    init() {
        let resolvedStore: CatalogStore?
        do {
            let databaseURL = try AppSupport.databaseURL()
            resolvedStore = try CatalogStore(databaseURL: databaseURL)
        } catch {
            resolvedStore = nil
            lastError = error.localizedDescription
        }
        store = resolvedStore
        if resolvedStore != nil {
            do {
                try reloadEverything()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    var databaseLocation: String {
        store?.databaseURL.path(percentEncoded: false) ?? "Unavailable"
    }

    var reviewProgressText: String {
        guard stats.totalItems > 0 else { return "No imported items yet." }
        return "\(stats.reviewedItems) of \(stats.totalItems) reviewed"
    }

    func chooseWorkbook(_ url: URL) {
        guard startWork() else { return }
        defer { finishWork() }
        do {
            let workbook = try importer.prepareWorkbook(at: url)
            preparedWorkbook = workbook
            preview = workbook.preview
            importSummary = nil
            selectedStage = .importData
        } catch {
            preparedWorkbook = nil
            lastError = error.localizedDescription
        }
    }

    func importSelectedWorkbook() {
        guard let preview, let store, startWork() else { return }
        defer { finishWork() }
        do {
            let workbook: WorkbookImporter.PreparedWorkbook
            if let preparedWorkbook, preparedWorkbook.sourceURL == preview.sourceURL {
                workbook = preparedWorkbook
            } else {
                workbook = try importer.prepareWorkbook(at: preview.sourceURL)
                self.preparedWorkbook = workbook
            }
            let (resolvedPreview, rows) = try importer.parseCatalogRows(from: workbook)
            let summary = try store.importRows(rows, preview: resolvedPreview)
            importSummary = summary
            skippedReviewIDs.removeAll()
            try reloadEverything()
            selectedStage = .quickReview
        } catch {
            lastError = error.localizedDescription
        }
    }

    func markCurrentReviewItem(as status: UsageStatus) {
        guard selectedStage == .quickReview, let item = currentReviewItem, let store, startWork() else { return }
        defer { finishWork() }
        do {
            try store.mark(itemID: item.id, status: status)
            skippedReviewIDs.remove(item.id)
            try reloadStatsAndReview()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func skipCurrentReviewItem() {
        guard selectedStage == .quickReview, let item = currentReviewItem, startWork() else { return }
        skippedReviewIDs.insert(item.id)
        finishWork()
        do {
            try loadNextReviewItem()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshUsedItems() {
        guard let store, startWork() else { return }
        defer { finishWork() }
        do {
            usedItems = try store.usedItems(search: noteSearchText)
            if let selectedUsedItemID, usedItems.contains(where: { $0.id == selectedUsedItemID }) {
                try loadUsedItem(id: selectedUsedItemID)
            } else if let first = usedItems.first {
                try loadUsedItem(id: first.id)
            } else {
                selectedUsedItemID = nil
                selectedUsedItem = nil
                usageNotes = []
                selectedUsageNoteID = nil
                scenarioDraft = .empty
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func selectUsedItem(id: Int64) {
        guard startWork() else { return }
        defer { finishWork() }
        do {
            try loadUsedItem(id: id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startNewUsageNote() {
        selectedUsageNoteID = nil
        scenarioDraft = .empty
    }

    func selectUsageNote(id: Int64) {
        guard let note = usageNotes.first(where: { $0.id == id }) else { return }
        selectedUsageNoteID = id
        scenarioDraft = ScenarioDraft(record: note)
    }

    func saveCurrentUsageNote() {
        guard let store, let selectedUsedItemID, startWork() else { return }
        defer { finishWork() }
        let title = scenarioDraft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            lastError = "Give this usage note a short title."
            return
        }
        do {
            let savedID = try store.saveUsageNote(for: selectedUsedItemID, draft: scenarioDraft)
            try loadUsedItem(id: selectedUsedItemID)
            selectedUsageNoteID = savedID
            if let note = usageNotes.first(where: { $0.id == savedID }) {
                scenarioDraft = ScenarioDraft(record: note)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveLLMSettings(_ settings: LLMSettings) {
        llmSettings = settings
        llmSettings.save()
    }

    func chooseEstimatePhotos(_ urls: [URL]) {
        let sortedURLs = urls.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        estimatePhotoURLs = sortedURLs
        photoScanEntries = sortedURLs.map { PhotoScanEntry(fileURL: $0) }
        photoScanSummary = PhotoScanSummary(
            totalPhotos: sortedURLs.count,
            processedPhotos: 0,
            completedPhotos: 0,
            failedPhotos: 0,
            uniqueCodes: [],
            matchedItems: 0,
            newlyMarkedItems: 0,
            alreadyUsedItems: 0,
            unmatchedCodes: []
        )
        selectedStage = .estimatePhotos
    }

    func clearEstimatePhotoSelection() {
        guard !isScanningEstimatePhotos else { return }
        estimatePhotoURLs = []
        photoScanEntries = []
        photoScanSummary = .empty
    }

    func analyzeSelectedEstimatePhotos() {
        guard let store else {
            lastError = "The catalog database is unavailable."
            return
        }
        guard !estimatePhotoURLs.isEmpty else {
            lastError = "Choose one or more estimate photos first."
            return
        }
        guard llmSettings.hasVisionConfiguration else {
            lastError = "Configure the OpenAI API key and vision model first."
            return
        }

        let urls = estimatePhotoURLs
        let settings = llmSettings
        isScanningEstimatePhotos = true
        photoScanEntries = urls.map { PhotoScanEntry(fileURL: $0) }
        photoScanSummary = PhotoScanSummary(
            totalPhotos: urls.count,
            processedPhotos: 0,
            completedPhotos: 0,
            failedPhotos: 0,
            uniqueCodes: [],
            matchedItems: 0,
            newlyMarkedItems: 0,
            alreadyUsedItems: 0,
            unmatchedCodes: []
        )

        Task {
            let outcomes = await Self.runEstimatePhotoBatch(
                urls: urls,
                settings: settings
            ) { [weak self] outcome in
                await self?.applyPhotoOutcome(outcome)
            }

            do {
                let uniqueCodes = Set(outcomes.flatMap { $0.extraction?.detectedCodes ?? [] })
                let updateSummary = try store.markItemsUsed(matching: uniqueCodes)
                try reloadEverything()
                photoScanSummary = PhotoScanSummary(
                    totalPhotos: urls.count,
                    processedPhotos: outcomes.count,
                    completedPhotos: outcomes.filter { $0.extraction != nil }.count,
                    failedPhotos: outcomes.filter { $0.errorMessage != nil }.count,
                    uniqueCodes: Array(uniqueCodes).sorted(),
                    matchedItems: updateSummary.matchedItems,
                    newlyMarkedItems: updateSummary.newlyMarkedItems,
                    alreadyUsedItems: updateSummary.alreadyUsedItems,
                    unmatchedCodes: updateSummary.unmatchedCodes
                )
                isScanningEstimatePhotos = false
            } catch {
                lastError = error.localizedDescription
                isScanningEstimatePhotos = false
            }
        }
    }

    func toggleTranscriptRecording() {
        if isRecordingTranscript {
            stopRecordingAndTranscribe()
        } else {
            startRecordingTranscript()
        }
    }

    func cleanTranscriptWithLLM() {
        guard let item = selectedUsedItem else {
            lastError = "Choose a used item before cleaning a transcript."
            return
        }
        let transcript = scenarioDraft.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            lastError = "Add or dictate a raw transcript first."
            return
        }
        guard llmSettings.hasCleanupConfiguration else {
            lastError = "Configure the OpenAI API key and cleanup model first."
            return
        }
        guard startWork() else { return }
        let settings = llmSettings
        Task {
            do {
                let cleaned = try await llmCleaningService.cleanTranscript(
                    transcript: transcript,
                    item: item,
                    settings: settings
                )
                await MainActor.run {
                    scenarioDraft.title = cleaned.title
                    scenarioDraft.tags = cleaned.tags
                    scenarioDraft.cleanedDescription = cleaned.cleanedDescription
                    scenarioDraft.aiHint = cleaned.aiHint
                    finishWork()
                }
            } catch {
                await MainActor.run {
                    lastError = error.localizedDescription
                    finishWork()
                }
            }
        }
    }

    private func startRecordingTranscript() {
        guard selectedUsedItem != nil else {
            lastError = "Choose a used item before recording."
            return
        }
        guard llmSettings.hasTranscriptionConfiguration else {
            lastError = "Configure the OpenAI API key and transcription model first."
            return
        }
        guard startWork() else { return }
        Task {
            do {
                _ = try await audioRecorder.startRecording()
                await MainActor.run {
                    isRecordingTranscript = true
                    finishWork()
                }
            } catch {
                await MainActor.run {
                    lastError = error.localizedDescription
                    isRecordingTranscript = false
                    finishWork()
                }
            }
        }
    }

    private func stopRecordingAndTranscribe() {
        guard let item = selectedUsedItem else {
            lastError = "Choose a used item before transcribing."
            return
        }
        guard llmSettings.hasTranscriptionConfiguration else {
            lastError = "Configure the OpenAI API key and transcription model first."
            return
        }
        guard startWork() else { return }
        Task {
            do {
                let audioURL = try await MainActor.run { try audioRecorder.stopRecording() }
                let transcript = try await transcriptionService.transcribeAudio(
                    fileURL: audioURL,
                    item: item,
                    settings: llmSettings
                )
                try? FileManager.default.removeItem(at: audioURL)
                await MainActor.run {
                    isRecordingTranscript = false
                    scenarioDraft.transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    finishWork()
                }
            } catch {
                await MainActor.run {
                    isRecordingTranscript = false
                    lastError = error.localizedDescription
                    finishWork()
                }
            }
        }
    }

    func deleteSelectedUsageNote() {
        guard let store, let selectedUsageNoteID, let selectedUsedItemID, startWork() else { return }
        defer { finishWork() }
        do {
            try store.deleteUsageNote(id: selectedUsageNoteID)
            try loadUsedItem(id: selectedUsedItemID)
            if let first = usageNotes.first {
                self.selectedUsageNoteID = first.id
                scenarioDraft = ScenarioDraft(record: first)
            } else {
                self.selectedUsageNoteID = nil
                scenarioDraft = .empty
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func exportCuratedJSON() {
        guard let store, startWork() else { return }
        defer { finishWork() }
        do {
            let envelope = try store.exportCuratedJSON()
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.json]
            savePanel.nameFieldStringValue = "xactimate-curated-export.json"
            if savePanel.runModal() == .OK, let url = savePanel.url {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(envelope)
                try data.write(to: url, options: .atomic)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearError() {
        lastError = ""
    }

    private func reloadEverything() throws {
        try reloadStatsAndReview()
        guard let store else { throw CatalogStoreError.databaseUnavailable }
        usedItems = try store.usedItems(search: noteSearchText)
        if let selectedUsedItemID, usedItems.contains(where: { $0.id == selectedUsedItemID }) {
            try loadUsedItem(id: selectedUsedItemID)
        } else if let first = usedItems.first {
            try loadUsedItem(id: first.id)
        } else {
            selectedUsedItemID = nil
            selectedUsedItem = nil
            usageNotes = []
            selectedUsageNoteID = nil
            scenarioDraft = .empty
        }
    }

    private func reloadStatsAndReview() throws {
        guard let store else { throw CatalogStoreError.databaseUnavailable }
        stats = try store.stats()
        try loadNextReviewItem()
    }

    private func loadNextReviewItem() throws {
        guard let store else { throw CatalogStoreError.databaseUnavailable }
        if let next = try store.nextUnreviewedItem(excluding: skippedReviewIDs) {
            currentReviewItem = next
            return
        }
        if !skippedReviewIDs.isEmpty {
            skippedReviewIDs.removeAll()
            currentReviewItem = try store.nextUnreviewedItem(excluding: [])
        } else {
            currentReviewItem = nil
        }
    }

    private func loadUsedItem(id: Int64) throws {
        guard let store else { throw CatalogStoreError.databaseUnavailable }
        selectedUsedItemID = id
        selectedUsedItem = try store.loadItem(id: id)
        usageNotes = try store.usageNotes(for: id)
        if let selectedUsageNoteID, usageNotes.contains(where: { $0.id == selectedUsageNoteID }) {
            if let selected = usageNotes.first(where: { $0.id == selectedUsageNoteID }) {
                scenarioDraft = ScenarioDraft(record: selected)
            }
        } else if let first = usageNotes.first {
            selectedUsageNoteID = first.id
            scenarioDraft = ScenarioDraft(record: first)
        } else {
            selectedUsageNoteID = nil
            scenarioDraft = .empty
        }
    }

    private func startWork() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    private func finishWork() {
        isBusy = false
    }

    private func applyPhotoOutcome(_ outcome: EstimatePhotoBatchOutcome) {
        if let index = photoScanEntries.firstIndex(where: { $0.id == outcome.fileURL.path(percentEncoded: false) }) {
            photoScanEntries[index].status = outcome.extraction == nil ? .failed : .completed
            photoScanEntries[index].detectedCodes = outcome.extraction?.detectedCodes ?? []
            photoScanEntries[index].note = outcome.extraction?.note ?? ""
            photoScanEntries[index].errorMessage = outcome.errorMessage ?? ""
        }

        let processedPhotos = photoScanEntries.filter { $0.status == .completed || $0.status == .failed }.count
        let completedPhotos = photoScanEntries.filter { $0.status == .completed }.count
        let failedPhotos = photoScanEntries.filter { $0.status == .failed }.count
        let uniqueCodes = Array(Set(photoScanEntries.flatMap(\.detectedCodes))).sorted()

        photoScanSummary = PhotoScanSummary(
            totalPhotos: photoScanEntries.count,
            processedPhotos: processedPhotos,
            completedPhotos: completedPhotos,
            failedPhotos: failedPhotos,
            uniqueCodes: uniqueCodes,
            matchedItems: photoScanSummary.matchedItems,
            newlyMarkedItems: photoScanSummary.newlyMarkedItems,
            alreadyUsedItems: photoScanSummary.alreadyUsedItems,
            unmatchedCodes: photoScanSummary.unmatchedCodes
        )
    }

    nonisolated private static func runEstimatePhotoBatch(
        urls: [URL],
        settings: LLMSettings,
        onProgress: @escaping @Sendable (EstimatePhotoBatchOutcome) async -> Void
    ) async -> [EstimatePhotoBatchOutcome] {
        let orderedURLs = urls.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
        let maxConcurrent = min(3, max(1, orderedURLs.count))

        return await withTaskGroup(of: EstimatePhotoBatchOutcome.self) { group in
            var iterator = orderedURLs.makeIterator()

            func enqueue(_ url: URL) {
                group.addTask {
                    do {
                        let extraction = try await OpenAIEstimatePhotoAnalysisService().analyzePhoto(
                            fileURL: url,
                            settings: settings
                        )
                        return EstimatePhotoBatchOutcome(fileURL: url, extraction: extraction, errorMessage: nil)
                    } catch {
                        return EstimatePhotoBatchOutcome(fileURL: url, extraction: nil, errorMessage: error.localizedDescription)
                    }
                }
            }

            for _ in 0 ..< maxConcurrent {
                if let url = iterator.next() {
                    enqueue(url)
                }
            }

            var outcomes: [EstimatePhotoBatchOutcome] = []
            while let outcome = await group.next() {
                outcomes.append(outcome)
                await onProgress(outcome)
                if let nextURL = iterator.next() {
                    enqueue(nextURL)
                }
            }
            return outcomes.sorted { $0.fileURL.path(percentEncoded: false) < $1.fileURL.path(percentEncoded: false) }
        }
    }
}

private struct EstimatePhotoBatchOutcome: Sendable {
    let fileURL: URL
    let extraction: EstimatePhotoExtraction?
    let errorMessage: String?
}
