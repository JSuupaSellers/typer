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
    var cleanupModel: String = "gpt-5.4"
    var estimatePhotoPrompt: String = Self.defaultEstimatePhotoPrompt
    var systemPrompt: String = Self.defaultPrompt
    var recommendationPrompt: String = Self.defaultRecommendationPrompt

    static let defaultsKey = "llm-settings"

    enum CodingKeys: String, CodingKey {
        case baseURL
        case apiKey
        case geminiAPIKey
        case estimatePhotoModel
        case transcriptionModel
        case cleanupModel
        case estimatePhotoPrompt
        case systemPrompt
        case recommendationPrompt
    }

    static let defaultPrompt = """
    You convert a user's spoken context about when a Xactimate line item is used into a compact structured note.
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
    - Minimize context debt. Prefer terse, information-dense phrasing over long prose.
    - title should be 2-6 words and describe the scenario plainly.
    - cleaned_description should be one short sentence, ideally 8-20 words, focused on when to use the item.
    - when_not_to_use should be empty if unnecessary, otherwise one short sentence under 16 words.
    - room should be the most likely room or area if the transcript implies one, otherwise empty.
    - surface should be the affected surface or component if the transcript implies one, otherwise empty.
    - damage_type should summarize the repair or damage pattern in a few words if present, otherwise empty.
    - keywords should be a comma-separated list of up to 6 short matching terms.
    - synonyms should be a comma-separated list of up to 4 alternate phrases an estimator might say.
    - tags should be a comma-separated list of up to 4 short tags.
    - ai_hint should be empty unless it materially improves later model selection, and must stay under 18 words.
    - Do not repeat the same idea across multiple fields.
    - Omit weak or speculative details by returning empty strings.
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

    static let defaultRecommendationPrompt = """
    You convert an adjuster's spoken room description into a structured recommendation query for Xactimate line-item lookup.
    Return JSON only with keys:
    - narrative
    - room
    - surface
    - damage_type
    - keywords

    Rules:
    - narrative should be a cleaned version of the spoken scope description.
    - room should be the most likely room or area if one is stated, otherwise an empty string.
    - surface should be the main affected surface or component if one is stated, otherwise an empty string.
    - damage_type should summarize the repair or condition being described if one is stated, otherwise an empty string.
    - keywords should be a short comma-separated list of search-friendly terms an estimator would use.
    - Do not invent details that are not supported by the transcript.
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

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        geminiAPIKey = try container.decodeIfPresent(String.self, forKey: .geminiAPIKey) ?? ""
        estimatePhotoModel = try container.decodeIfPresent(String.self, forKey: .estimatePhotoModel) ?? "gemini-3-flash-preview"
        transcriptionModel = try container.decodeIfPresent(String.self, forKey: .transcriptionModel) ?? "whisper-1"
        let decodedCleanupModel = try container.decodeIfPresent(String.self, forKey: .cleanupModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cleanupModel = decodedCleanupModel.isEmpty ? "gpt-5.4" : decodedCleanupModel
        estimatePhotoPrompt = try container.decodeIfPresent(String.self, forKey: .estimatePhotoPrompt) ?? Self.defaultEstimatePhotoPrompt
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? Self.defaultPrompt
        recommendationPrompt = try container.decodeIfPresent(String.self, forKey: .recommendationPrompt) ?? Self.defaultRecommendationPrompt
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

enum UsageNoteCompactor {
    static func compact(_ result: CleanedUsageNoteResult) -> CleanedUsageNoteResult {
        CleanedUsageNoteResult(
            title: compactPhrase(result.title, maxWords: 6, maxCharacters: 54),
            tags: compactList(result.tags, maxItems: 4, maxWordsPerItem: 2, maxItemCharacters: 20),
            cleanedDescription: compactText(result.cleanedDescription, maxWords: 20, maxCharacters: 150),
            whenNotToUse: compactText(result.whenNotToUse, maxWords: 16, maxCharacters: 110),
            room: compactPhrase(result.room, maxWords: 4, maxCharacters: 32),
            surface: compactPhrase(result.surface, maxWords: 4, maxCharacters: 32),
            damageType: compactPhrase(result.damageType, maxWords: 5, maxCharacters: 40),
            keywords: compactList(result.keywords, maxItems: 6, maxWordsPerItem: 3, maxItemCharacters: 28),
            synonyms: compactList(result.synonyms, maxItems: 4, maxWordsPerItem: 4, maxItemCharacters: 32),
            aiHint: compactText(result.aiHint, maxWords: 18, maxCharacters: 120)
        )
    }

    static func compact(_ draft: ScenarioDraft) -> ScenarioDraft {
        var compacted = draft
        compacted.title = compactPhrase(draft.title, maxWords: 6, maxCharacters: 54)
        compacted.tags = compactList(draft.tags, maxItems: 4, maxWordsPerItem: 2, maxItemCharacters: 20)
        compacted.whenToUse = compactText(draft.whenToUse, maxWords: 20, maxCharacters: 150)
        compacted.whenNotToUse = compactText(draft.whenNotToUse, maxWords: 16, maxCharacters: 110)
        compacted.room = compactPhrase(draft.room, maxWords: 4, maxCharacters: 32)
        compacted.surface = compactPhrase(draft.surface, maxWords: 4, maxCharacters: 32)
        compacted.damageType = compactPhrase(draft.damageType, maxWords: 5, maxCharacters: 40)
        compacted.keywords = compactList(draft.keywords, maxItems: 6, maxWordsPerItem: 3, maxItemCharacters: 28)
        compacted.synonyms = compactList(draft.synonyms, maxItems: 4, maxWordsPerItem: 4, maxItemCharacters: 32)
        compacted.voiceNotes = compactText(draft.voiceNotes, maxWords: 32, maxCharacters: 220)
        compacted.aiHint = compactText(draft.aiHint, maxWords: 18, maxCharacters: 120)
        return compacted
    }

    private static func compactPhrase(_ value: String, maxWords: Int, maxCharacters: Int) -> String {
        compactText(value, maxWords: maxWords, maxCharacters: maxCharacters, stripSentencePunctuation: true)
    }

    private static func compactText(
        _ value: String,
        maxWords: Int,
        maxCharacters: Int,
        stripSentencePunctuation: Bool = false
    ) -> String {
        let normalized = normalizeWhitespace(value)
        guard !normalized.isEmpty else { return "" }

        let limitedWords = normalized
            .split(separator: " ")
            .prefix(maxWords)
            .joined(separator: " ")
        let limitedCharacters = truncate(limitedWords, maxCharacters: maxCharacters)
        let cleaned = stripSentencePunctuation ? trimTrailingSentencePunctuation(limitedCharacters) : limitedCharacters
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactList(
        _ value: String,
        maxItems: Int,
        maxWordsPerItem: Int,
        maxItemCharacters: Int
    ) -> String {
        let separatorsPattern = #"[,\n;|]+"#
        let normalized = value.replacingOccurrences(
            of: separatorsPattern,
            with: ",",
            options: .regularExpression
        )
        let rawItems = normalized.split(separator: ",")

        var items: [String] = []
        var seen = Set<String>()

        for rawItem in rawItems {
            let item = compactPhrase(String(rawItem), maxWords: maxWordsPerItem, maxCharacters: maxItemCharacters)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,:;-"))
            guard !item.isEmpty else { continue }

            let key = item.lowercased()
            guard seen.insert(key).inserted else { continue }

            items.append(item)
            if items.count == maxItems {
                break
            }
        }

        return items.joined(separator: ", ")
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"^(?:(?:[•\-\*])|(?:\d+[\.\)]))\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }

        let prefix = String(value.prefix(maxCharacters))
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimTrailingSentencePunctuation(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;-"))
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

struct StructuredRecommendationQueryResult: Codable, Equatable {
    let narrative: String
    let room: String
    let surface: String
    let damageType: String
    let keywords: String

    enum CodingKeys: String, CodingKey {
        case narrative
        case room
        case surface
        case damageType = "damage_type"
        case keywords
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
    let usageStatus: String
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
    let aiHint: String
}
