import Foundation
import GRDB

enum UsageStatus: String, CaseIterable, Codable {
    case unreviewed = "unreviewed"
    case usedBefore = "used_before"
    case neverUsed = "never_used"

    var label: String {
        switch self {
        case .unreviewed:
            "Unreviewed"
        case .usedBefore:
            "Used Before"
        case .neverUsed:
            "Never Used"
        }
    }
}

enum RecommendationFeedbackDecision: String, CaseIterable, Codable {
    case accepted = "accepted"
    case rejected = "rejected"

    var label: String {
        switch self {
        case .accepted:
            return "Accepted"
        case .rejected:
            return "Rejected"
        }
    }
}

struct ImportPreview: Equatable {
    let sourceURL: URL
    let sheetName: String
    let headers: [String]
    let rowCount: Int
    let sampleRows: [[String: String]]
}

struct ParsedCatalogRow: Sendable {
    let sourceRow: Int
    let category: String
    let selector: String
    let description: String
    let unit: String
    let details: String
    let rawFields: [String: String]
}

struct CatalogCode: Codable, Hashable, Sendable, Comparable {
    let category: String
    let selector: String

    init(category: String, selector: String) {
        self.category = Self.normalize(category)
        self.selector = Self.normalize(selector)
    }

    var displayCode: String {
        let left = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if !left.isEmpty && !right.isEmpty {
            return "\(left)/\(right)"
        }
        return right.isEmpty ? left : right
    }

    static func < (lhs: CatalogCode, rhs: CatalogCode) -> Bool {
        if lhs.category == rhs.category {
            return lhs.selector < rhs.selector
        }
        return lhs.category < rhs.category
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }
}

struct ImportResultSummary: Equatable {
    let importedCount: Int
    let insertedCount: Int
    let updatedCount: Int
    let sheetName: String
    let databaseURL: URL
}

struct CurationStats: Equatable {
    let totalItems: Int
    let unreviewedItems: Int
    let usedItems: Int
    let neverUsedItems: Int
    let usageNoteCount: Int

    static let empty = CurationStats(totalItems: 0, unreviewedItems: 0, usedItems: 0, neverUsedItems: 0, usageNoteCount: 0)

    var reviewedItems: Int { totalItems - unreviewedItems }
}

enum PhotoScanStatus: String, Equatable {
    case pending
    case scanning
    case completed
    case failed

    var label: String {
        switch self {
        case .pending:
            return "Pending"
        case .scanning:
            return "Scanning"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }
}

struct PhotoScanEntry: Identifiable, Equatable {
    let id: String
    let fileURL: URL
    var status: PhotoScanStatus
    var detectedCodes: [CatalogCode]
    var note: String
    var errorMessage: String

    init(
        fileURL: URL,
        status: PhotoScanStatus = .pending,
        detectedCodes: [CatalogCode] = [],
        note: String = "",
        errorMessage: String = ""
    ) {
        id = fileURL.path(percentEncoded: false)
        self.fileURL = fileURL
        self.status = status
        self.detectedCodes = detectedCodes
        self.note = note
        self.errorMessage = errorMessage
    }
}

struct PhotoScanSummary: Equatable {
    let totalPhotos: Int
    let processedPhotos: Int
    let completedPhotos: Int
    let failedPhotos: Int
    let uniqueCodes: [CatalogCode]
    let matchedItems: Int
    let newlyMarkedItems: Int
    let alreadyUsedItems: Int
    let unmatchedCodes: [CatalogCode]

    static let empty = PhotoScanSummary(
        totalPhotos: 0,
        processedPhotos: 0,
        completedPhotos: 0,
        failedPhotos: 0,
        uniqueCodes: [],
        matchedItems: 0,
        newlyMarkedItems: 0,
        alreadyUsedItems: 0,
        unmatchedCodes: []
    )
}

struct EstimatePhotoExtraction: Codable, Equatable {
    let detectedCodes: [CatalogCode]
    let note: String

    enum CodingKeys: String, CodingKey {
        case detectedCodes = "detected_codes"
        case note
    }
}

struct BulkUsageUpdateSummary: Equatable {
    let matchedItems: Int
    let newlyMarkedItems: Int
    let alreadyUsedItems: Int
    let unmatchedCodes: [CatalogCode]
}

struct CatalogItemSummary: Identifiable, FetchableRecord, Decodable, Hashable {
    let id: Int64
    let category: String
    let selector: String
    let description: String
    let unit: String
    let details: String
    let usageStatus: String
    let usageNoteCount: Int
    let sourceRow: Int

    var displayCode: String {
        let left = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if !left.isEmpty && !right.isEmpty {
            return "\(left)/\(right)"
        }
        return right.isEmpty ? left : right
    }
}

struct CatalogItemDetail: Identifiable, FetchableRecord, Decodable, Hashable {
    let id: Int64
    let category: String
    let selector: String
    let description: String
    let unit: String
    let details: String
    let usageStatus: String
    let sourceFile: String
    let sourceSheet: String
    let sourceRow: Int
    let decisionAt: String
    let rawJSON: String

    var displayCode: String {
        let left = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if !left.isEmpty && !right.isEmpty {
            return "\(left)/\(right)"
        }
        return right.isEmpty ? left : right
    }
}

struct UsageScenarioRecord: Identifiable, FetchableRecord, Decodable, Hashable {
    let id: Int64
    let itemId: Int64
    let title: String
    let tags: String
    let whenToUse: String
    let whenNotToUse: String
    let room: String
    let surface: String
    let damageType: String
    let keywords: String
    let synonyms: String
    let voiceNotes: String
    let aiHint: String
    let createdAt: String
    let updatedAt: String
}

struct LLMSettings: Codable, Equatable {
    var baseURL: String = "https://api.openai.com/v1"
    var apiKey: String = ""
    var geminiAPIKey: String = ""
    var estimatePhotoModel: String = "gemini-3-flash-preview"
    var transcriptionModel: String = "whisper-1"
    var cleanupModel: String = ""
    var estimatePhotoPrompt: String = Self.defaultEstimatePhotoPrompt
    var systemPrompt: String = Self.defaultPrompt

    static let defaultsKey = "llm-settings"

    static let defaultPrompt = """
    You clean up a user's spoken transcript about when a Xactimate line item is used.
    Return JSON only with keys:
    - title
    - tags
    - cleaned_description
    - when_not_to_use
    - room
    - surface
    - damage_type
    - keywords
    - synonyms
    - ai_hint

    Rules:
    - cleaned_description should be a concise, practical summary of when and why the item is used.
    - when_not_to_use should briefly explain when this line item would be the wrong choice.
    - room should be the most likely room or area if the transcript implies one.
    - surface should be the affected surface or component if the transcript implies one.
    - damage_type should summarize the repair or damage pattern if present.
    - keywords should be a comma-separated list of short matching terms.
    - synonyms should be a comma-separated list of alternate phrases an estimator might say.
    - tags should be a short comma-separated list.
    - ai_hint should help a later estimating model choose this item appropriately.
    - Do not invent facts that are not supported by the transcript or line-item context.
    """

    static let defaultEstimatePhotoPrompt = """
    You are reading a photo of an already-written Xactimate estimate.
    Extract only exact Xactimate CAT/SEL pairs that are clearly visible in the image.

    Rules:
    - Return only CAT/SEL pairs that are explicitly visible. Do not guess from descriptions.
    - Normalize category and selector to uppercase.
    - If a code is partially obscured, uncertain, or ambiguous, leave it out.
    - Deduplicate codes within the image.
    - The note should briefly describe what was visible, or say that no clear CAT/SEL pairs were found.
    """

    var hasVisionConfiguration: Bool {
        !geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !estimatePhotoModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasTranscriptionConfiguration: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCleanupConfiguration: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !cleanupModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isConfigured: Bool {
        hasTranscriptionConfiguration && hasCleanupConfiguration
    }

    static func load() -> LLMSettings {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let settings = try? JSONDecoder().decode(LLMSettings.self, from: data)
        else {
            return LLMSettings()
        }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

struct CleanedUsageNoteResult: Codable, Equatable {
    let title: String
    let tags: String
    let cleanedDescription: String
    let whenNotToUse: String
    let room: String
    let surface: String
    let damageType: String
    let keywords: String
    let synonyms: String
    let aiHint: String

    enum CodingKeys: String, CodingKey {
        case title
        case tags
        case cleanedDescription = "cleaned_description"
        case whenNotToUse = "when_not_to_use"
        case room
        case surface
        case damageType = "damage_type"
        case keywords
        case synonyms
        case aiHint = "ai_hint"
    }
}

struct ScenarioDraft: Equatable {
    var id: Int64?
    var title: String = ""
    var tags: String = ""
    var whenToUse: String = ""
    var whenNotToUse: String = ""
    var room: String = ""
    var surface: String = ""
    var damageType: String = ""
    var keywords: String = ""
    var synonyms: String = ""
    var voiceNotes: String = ""
    var aiHint: String = ""

    static let empty = ScenarioDraft()

    init() {}

    init(
        id: Int64?,
        title: String,
        tags: String,
        whenToUse: String,
        whenNotToUse: String,
        room: String,
        surface: String,
        damageType: String,
        keywords: String,
        synonyms: String,
        voiceNotes: String,
        aiHint: String
    ) {
        self.id = id
        self.title = title
        self.tags = tags
        self.whenToUse = whenToUse
        self.whenNotToUse = whenNotToUse
        self.room = room
        self.surface = surface
        self.damageType = damageType
        self.keywords = keywords
        self.synonyms = synonyms
        self.voiceNotes = voiceNotes
        self.aiHint = aiHint
    }

    init(record: UsageScenarioRecord) {
        id = record.id
        title = record.title
        tags = record.tags
        whenToUse = record.whenToUse
        whenNotToUse = record.whenNotToUse
        room = record.room
        surface = record.surface
        damageType = record.damageType
        keywords = record.keywords
        synonyms = record.synonyms
        voiceNotes = record.voiceNotes
        aiHint = record.aiHint
    }

    var transcript: String {
        get { voiceNotes }
        set { voiceNotes = newValue }
    }

    var cleanedDescription: String {
        get { whenToUse }
        set { whenToUse = newValue }
    }
}

struct RecommendationQuery: Equatable {
    var narrative: String = ""
    var room: String = ""
    var surface: String = ""
    var damageType: String = ""
    var keywords: String = ""
    var maxResults: Int = 5

    static let empty = RecommendationQuery()

    var combinedText: String {
        [narrative, room, surface, damageType, keywords]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum RecommendationConfidence: String, Equatable {
    case high
    case medium
    case low

    var label: String {
        rawValue.capitalized
    }
}

struct RecommendationScenarioHighlight: Identifiable, Equatable {
    let id: Int64
    let title: String
    let whenToUse: String
    let whenNotToUse: String
    let room: String
    let surface: String
    let damageType: String
    let keywords: String
    let synonyms: String
    let aiHint: String
    let matchedTerms: [String]
    let score: Double
}

struct RecommendationCandidate: Identifiable, Equatable {
    let id: Int64
    let item: CatalogItemDetail
    let score: Double
    let confidence: RecommendationConfidence
    let matchedTerms: [String]
    let reasons: [String]
    let highlights: [RecommendationScenarioHighlight]
    let acceptedCount: Int
    let rejectedCount: Int
}

struct CuratedExportEnvelope: Codable {
    let exportedAt: String
    let itemCount: Int
    let usageNoteCount: Int
    let items: [CuratedExportItem]
}

struct CuratedExportItem: Codable {
    let code: String
    let category: String
    let selector: String
    let description: String
    let unit: String
    let details: String
    let usageNotes: [CuratedUsageNote]
}

struct CuratedUsageNote: Codable {
    let title: String
    let tags: String
    let whenToUse: String
    let whenNotToUse: String
    let room: String
    let surface: String
    let damageType: String
    let keywords: String
    let synonyms: String
    let voiceNotes: String
    let aiHint: String
}
