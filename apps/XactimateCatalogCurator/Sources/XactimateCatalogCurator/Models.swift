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
