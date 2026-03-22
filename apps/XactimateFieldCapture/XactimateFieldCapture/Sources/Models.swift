import Foundation

struct BackendConfiguration {
    var baseURL: String
    var apiKey: String
}

struct DraftMessagePayload: Codable, Identifiable, Equatable {
    let id: String
    let role: String
    let text: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case createdAt = "created_at"
    }
}

struct DraftLineItemPayload: Codable, Identifiable, Equatable {
    let id: String
    let room: String
    let section: String
    let approvedCode: String
    let description: String
    let quantity: String
    let surface: String
    let damageType: String
    let keywords: String
    let status: String
    let source: String
    let rationale: String

    enum CodingKeys: String, CodingKey {
        case id
        case room
        case section
        case approvedCode = "approved_code"
        case description
        case quantity
        case surface
        case damageType = "damage_type"
        case keywords
        case status
        case source
        case rationale
    }
}

struct DraftPayload: Codable, Equatable {
    let jobId: String
    let bridgeId: String
    let roomOrder: [String]
    let messages: [DraftMessagePayload]
    let items: [DraftLineItemPayload]
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case bridgeId = "bridge_id"
        case roomOrder = "room_order"
        case messages
        case items
        case updatedAt = "updated_at"
    }
}

struct ClaimSummaryPayload: Codable, Identifiable, Equatable {
    let jobId: String
    let bridgeId: String
    let updatedAt: String
    let roomCount: Int
    let itemCount: Int
    let acceptedCount: Int
    let messageCount: Int
    let latestMessagePreview: String

    var id: String { jobId }

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case bridgeId = "bridge_id"
        case updatedAt = "updated_at"
        case roomCount = "room_count"
        case itemCount = "item_count"
        case acceptedCount = "accepted_count"
        case messageCount = "message_count"
        case latestMessagePreview = "latest_message_preview"
    }
}

struct DraftSectionPayload: Codable, Identifiable, Equatable {
    let room: String
    let section: String
    let note: String
    let items: [DraftLineItemPayload]

    var id: String { "\(room)|\(section)" }
}

struct OpenDraftResponse: Decodable, Equatable {
    let status: String
    let draft: DraftPayload
    let groupedSections: [DraftSectionPayload]

    enum CodingKeys: String, CodingKey {
        case status
        case draft
        case groupedSections = "grouped_sections"
    }
}

struct DraftListResponse: Decodable, Equatable {
    let status: String
    let drafts: [ClaimSummaryPayload]
}

struct DraftTurnResponse: Decodable, Equatable {
    let status: String
    let draft: DraftPayload
    let groupedSections: [DraftSectionPayload]
    let assistantReply: String
    let transcript: String
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case status
        case draft
        case groupedSections = "grouped_sections"
        case assistantReply = "assistant_reply"
        case transcript
        case warnings
    }
}

struct PlanResponse: Decodable, Equatable {
    let approvedCount: Int
    let needsReviewCount: Int
    let unresolvedCount: Int
    let items: [PlannedScopeItem]

    enum CodingKeys: String, CodingKey {
        case approvedCount = "approved_count"
        case needsReviewCount = "needs_review_count"
        case unresolvedCount = "unresolved_count"
        case items
    }
}

struct EstimateScopeItemPayload: Codable, Identifiable, Equatable {
    let itemId: String
    let description: String
    let itemType: String
    let room: String
    let section: String
    let surface: String
    let damageType: String
    let keywords: String
    let quantity: String
    let note: String
    let approvedCode: String

    var id: String { itemId }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case description
        case itemType = "item_type"
        case room
        case section
        case surface
        case damageType = "damage_type"
        case keywords
        case quantity
        case note
        case approvedCode = "approved_code"
    }
}

struct PlannedScopeItem: Decodable, Equatable, Identifiable {
    let source: EstimateScopeItemPayload
    let candidates: [RecommendationCandidateSummary]
    let approvedCandidate: RecommendationCandidateSummary?
    let status: String
    let reviewReason: String

    var id: String { source.itemId }

    enum CodingKeys: String, CodingKey {
        case source
        case candidates
        case approvedCandidate = "approved_candidate"
        case status
        case reviewReason = "review_reason"
    }
}

struct RecommendationCandidateSummary: Decodable, Equatable {
    let item: CatalogLineItemSummary
    let score: Double
    let confidence: String
    let reasons: [String]
}

struct CatalogLineItemSummary: Decodable, Equatable {
    let code: String
    let category: String
    let selector: String
    let description: String
    let unit: String
    let details: String
}

struct PublishResponse: Decodable, Equatable {
    let jobId: String
    let bridgeId: String
    let commandCount: Int
    let startingSeq: Int
    let endingSeq: Int
    let approvedCodes: [String]

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case bridgeId = "bridge_id"
        case commandCount = "command_count"
        case startingSeq = "starting_seq"
        case endingSeq = "ending_seq"
        case approvedCodes = "approved_codes"
    }
}

struct DraftPlanResponse: Decodable, Equatable {
    let status: String
    let draft: DraftPayload
    let groupedSections: [DraftSectionPayload]
    let plan: PlanResponse

    enum CodingKeys: String, CodingKey {
        case status
        case draft
        case groupedSections = "grouped_sections"
        case plan
    }
}

struct DraftPublishResponse: Decodable, Equatable {
    let status: String
    let draft: DraftPayload
    let groupedSections: [DraftSectionPayload]
    let publish: PublishResponse

    enum CodingKeys: String, CodingKey {
        case status
        case draft
        case groupedSections = "grouped_sections"
        case publish
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
