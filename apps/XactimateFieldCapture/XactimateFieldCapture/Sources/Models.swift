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
    let activity: String
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
        case activity
        case surface
        case damageType = "damage_type"
        case keywords
        case status
        case source
        case rationale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        room = try container.decodeIfPresent(String.self, forKey: .room) ?? "General"
        section = try container.decodeIfPresent(String.self, forKey: .section) ?? "Scope"
        approvedCode = try container.decodeIfPresent(String.self, forKey: .approvedCode) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        quantity = try container.decodeIfPresent(String.self, forKey: .quantity) ?? ""
        activity = try container.decodeIfPresent(String.self, forKey: .activity) ?? ""
        surface = try container.decodeIfPresent(String.self, forKey: .surface) ?? ""
        damageType = try container.decodeIfPresent(String.self, forKey: .damageType) ?? ""
        keywords = try container.decodeIfPresent(String.self, forKey: .keywords) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "pending_review"
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "agent"
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale) ?? ""
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
    let roomStates: [RoomStatePayload]
    let claimStatus: String
    let operations: [ClaimOperationPayload]

    enum CodingKeys: String, CodingKey {
        case status
        case draft
        case groupedSections = "grouped_sections"
        case roomStates = "room_states"
        case claimStatus = "claim_status"
        case operations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "ok"
        draft = try container.decode(DraftPayload.self, forKey: .draft)
        groupedSections = try container.decodeIfPresent([DraftSectionPayload].self, forKey: .groupedSections) ?? []
        roomStates = try container.decodeIfPresent([RoomStatePayload].self, forKey: .roomStates) ?? []
        claimStatus = try container.decodeIfPresent(String.self, forKey: .claimStatus) ?? "new"
        operations = try container.decodeIfPresent([ClaimOperationPayload].self, forKey: .operations) ?? []
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

struct RoomStatePayload: Codable, Equatable, Identifiable {
    let room: String
    let roomType: String
    let lossType: String
    let status: String
    let summary: String
    let verification: [String: String]
    let updatedAt: String

    var id: String { room }

    enum CodingKeys: String, CodingKey {
        case room
        case roomType = "room_type"
        case lossType = "loss_type"
        case status
        case summary
        case verification
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        room = try container.decodeIfPresent(String.self, forKey: .room) ?? "General"
        roomType = try container.decodeIfPresent(String.self, forKey: .roomType) ?? "generic"
        lossType = try container.decodeIfPresent(String.self, forKey: .lossType) ?? "generic"
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "new"
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        verification = (try? container.decode([String: String].self, forKey: .verification)) ?? [:]
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

struct ClaimOperationPayload: Codable, Equatable, Identifiable {
    let id: String
    let jobId: String
    let bridgeId: String
    let kind: String
    let status: String
    let progress: Int
    let currentRoom: String
    let statusMessage: String
    let submittedText: String
    let transcript: String
    let assistantReply: String
    let errorMessage: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case jobId = "job_id"
        case bridgeId = "bridge_id"
        case kind
        case status
        case progress
        case currentRoom = "current_room"
        case statusMessage = "status_message"
        case submittedText = "submitted_text"
        case transcript
        case assistantReply = "assistant_reply"
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        jobId = try container.decodeIfPresent(String.self, forKey: .jobId) ?? "job"
        bridgeId = try container.decodeIfPresent(String.self, forKey: .bridgeId) ?? "default"
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "message"
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "queued"
        progress = try container.decodeIfPresent(Int.self, forKey: .progress) ?? 0
        currentRoom = try container.decodeIfPresent(String.self, forKey: .currentRoom) ?? ""
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage) ?? "Queued"
        submittedText = try container.decodeIfPresent(String.self, forKey: .submittedText) ?? ""
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        assistantReply = try container.decodeIfPresent(String.self, forKey: .assistantReply) ?? ""
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

struct OperationEventPayload: Codable, Equatable, Identifiable {
    let id: Int
    let eventType: String
    let payload: [String: String]
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case eventType = "event_type"
        case payload
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        eventType = try container.decodeIfPresent(String.self, forKey: .eventType) ?? ""
        payload = (try? container.decode([String: String].self, forKey: .payload)) ?? [:]
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

struct ToolTracePayload: Codable, Equatable, Identifiable {
    let id: Int
    let room: String
    let toolName: String
    let request: [String: String]
    let response: [String: String]
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case room
        case toolName = "tool_name"
        case request
        case response
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        room = try container.decodeIfPresent(String.self, forKey: .room) ?? ""
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName) ?? ""
        request = (try? container.decode([String: String].self, forKey: .request)) ?? [:]
        response = (try? container.decode([String: String].self, forKey: .response)) ?? [:]
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

struct DraftOperationResponse: Decodable, Equatable {
    let status: String
    let operation: ClaimOperationPayload
    let draft: DraftPayload?
    let groupedSections: [DraftSectionPayload]
    let roomStates: [RoomStatePayload]
    let claimStatus: String
    let events: [OperationEventPayload]
    let toolTraces: [ToolTracePayload]

    enum CodingKeys: String, CodingKey {
        case status
        case operation
        case draft
        case groupedSections = "grouped_sections"
        case roomStates = "room_states"
        case claimStatus = "claim_status"
        case events
        case toolTraces = "tool_traces"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "ok"
        operation = try container.decode(ClaimOperationPayload.self, forKey: .operation)
        draft = try container.decodeIfPresent(DraftPayload.self, forKey: .draft)
        groupedSections = try container.decodeIfPresent([DraftSectionPayload].self, forKey: .groupedSections) ?? []
        roomStates = try container.decodeIfPresent([RoomStatePayload].self, forKey: .roomStates) ?? []
        claimStatus = try container.decodeIfPresent(String.self, forKey: .claimStatus) ?? "new"
        events = try container.decodeIfPresent([OperationEventPayload].self, forKey: .events) ?? []
        toolTraces = try container.decodeIfPresent([ToolTracePayload].self, forKey: .toolTraces) ?? []
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
    let activity: String
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
        case activity
        case note
        case approvedCode = "approved_code"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try container.decodeIfPresent(String.self, forKey: .itemId) ?? UUID().uuidString
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        itemType = try container.decodeIfPresent(String.self, forKey: .itemType) ?? "line_item"
        room = try container.decodeIfPresent(String.self, forKey: .room) ?? "General"
        section = try container.decodeIfPresent(String.self, forKey: .section) ?? "Scope"
        surface = try container.decodeIfPresent(String.self, forKey: .surface) ?? ""
        damageType = try container.decodeIfPresent(String.self, forKey: .damageType) ?? ""
        keywords = try container.decodeIfPresent(String.self, forKey: .keywords) ?? ""
        quantity = try container.decodeIfPresent(String.self, forKey: .quantity) ?? ""
        activity = try container.decodeIfPresent(String.self, forKey: .activity) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        approvedCode = try container.decodeIfPresent(String.self, forKey: .approvedCode) ?? ""
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

struct DirectComposeResponse: Decodable, Equatable {
    let status: String
    let bridgeId: String
    let title: String
    let assistantReply: String
    let prompt: String
    let transcript: String
    let text: String
    let sendEnter: Bool
    let commandCountPreview: Int
    let characterCount: Int
    let lineCount: Int
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case status
        case bridgeId = "bridge_id"
        case title
        case assistantReply = "assistant_reply"
        case prompt
        case transcript
        case text
        case sendEnter = "send_enter"
        case commandCountPreview = "command_count_preview"
        case characterCount = "character_count"
        case lineCount = "line_count"
        case warnings
    }
}

struct DirectPublishResponse: Decodable, Equatable {
    let status: String
    let publish: PublishResponse
    let title: String
    let text: String
    let sendEnter: Bool
    let characterCount: Int
    let lineCount: Int

    enum CodingKeys: String, CodingKey {
        case status
        case publish
        case title
        case text
        case sendEnter = "send_enter"
        case characterCount = "character_count"
        case lineCount = "line_count"
    }
}

struct EstimateExportRowDraft: Identifiable, Equatable {
    let id: UUID
    var cat: String
    var sel: String
    var quantity: String

    init(id: UUID = UUID(), cat: String = "", sel: String = "", quantity: String = "") {
        self.id = id
        self.cat = cat
        self.sel = sel
        self.quantity = quantity
    }

    var isEmpty: Bool {
        cat.trimmed.isEmpty && sel.trimmed.isEmpty && quantity.trimmed.isEmpty
    }

    var isComplete: Bool {
        !cat.trimmed.isEmpty && !sel.trimmed.isEmpty && !quantity.trimmed.isEmpty
    }

    var normalized: EstimateExportRowDraft {
        EstimateExportRowDraft(
            id: id,
            cat: cat.trimmed.uppercased(),
            sel: sel.trimmed.uppercased(),
            quantity: quantity.trimmed
        )
    }
}

struct EstimateExportRowPayload: Decodable, Equatable {
    let cat: String
    let sel: String
    let catSel: String
    let quantity: String

    enum CodingKeys: String, CodingKey {
        case cat
        case sel
        case catSel = "cat_sel"
        case quantity
    }
}

struct EstimateExportPublishResponse: Decodable, Equatable {
    let status: String
    let publish: PublishResponse
    let bridgeId: String
    let title: String
    let rows: [EstimateExportRowPayload]
    let rowCount: Int
    let commandCountPreview: Int

    enum CodingKeys: String, CodingKey {
        case status
        case publish
        case bridgeId = "bridge_id"
        case title
        case rows
        case rowCount = "row_count"
        case commandCountPreview = "command_count_preview"
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
