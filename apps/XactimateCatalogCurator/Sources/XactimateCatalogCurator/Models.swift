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
    let voiceNotes: String
    let aiHint: String
    let createdAt: String
    let updatedAt: String
}

struct LLMSettings: Codable, Equatable {
    var baseURL: String = "https://api.openai.com/v1"
    var apiKey: String = ""
    var transcriptionModel: String = "whisper-1"
    var cleanupModel: String = ""
    var systemPrompt: String = Self.defaultPrompt

    static let defaultsKey = "llm-settings"

    static let defaultPrompt = """
    You clean up a user's spoken transcript about when a Xactimate line item is used.
    Return JSON only with keys:
    - title
    - tags
    - cleaned_description
    - ai_hint

    Rules:
    - cleaned_description should be a concise, practical summary of when and why the item is used.
    - tags should be a short comma-separated list.
    - ai_hint should help a later estimating model choose this item appropriately.
    - Do not invent facts that are not supported by the transcript or line-item context.
    """

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
    let aiHint: String

    enum CodingKeys: String, CodingKey {
        case title
        case tags
        case cleanedDescription = "cleaned_description"
        case aiHint = "ai_hint"
    }
}

struct ScenarioDraft: Equatable {
    var id: Int64?
    var title: String = ""
    var tags: String = ""
    var whenToUse: String = ""
    var voiceNotes: String = ""
    var aiHint: String = ""

    static let empty = ScenarioDraft()

    init() {}

    init(
        id: Int64?,
        title: String,
        tags: String,
        whenToUse: String,
        voiceNotes: String,
        aiHint: String
    ) {
        self.id = id
        self.title = title
        self.tags = tags
        self.whenToUse = whenToUse
        self.voiceNotes = voiceNotes
        self.aiHint = aiHint
    }

    init(record: UsageScenarioRecord) {
        id = record.id
        title = record.title
        tags = record.tags
        whenToUse = record.whenToUse
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
    let voiceNotes: String
    let aiHint: String
}
