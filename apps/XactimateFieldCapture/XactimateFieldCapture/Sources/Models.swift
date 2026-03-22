import Foundation
import UIKit

struct BackendConfiguration {
    var baseURL: String
    var apiKey: String
}

struct PickedPhoto: Identifiable, Equatable {
    let id = UUID()
    let filename: String
    let mimeType: String
    let data: Data

    var image: UIImage? {
        UIImage(data: data)
    }
}

struct EstimateScopeItemPayload: Codable, Identifiable, Equatable {
    let itemId: String
    let description: String
    let room: String
    let surface: String
    let damageType: String
    let keywords: String
    let quantity: String

    var id: String { itemId }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case description
        case room
        case surface
        case damageType = "damage_type"
        case keywords
        case quantity
    }
}

struct EstimateJobPayload: Codable, Equatable {
    let jobId: String
    let bridgeId: String
    let items: [EstimateScopeItemPayload]

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case bridgeId = "bridge_id"
        case items
    }
}

struct CaptureDraftResponse: Decodable, Equatable {
    let status: String
    let message: String
    let transcript: String
    let audioFilename: String
    let photoCount: Int
    let photoFilenames: [String]
    let job: EstimateJobPayload

    enum CodingKeys: String, CodingKey {
        case status
        case message
        case transcript
        case audioFilename = "audio_filename"
        case photoCount = "photo_count"
        case photoFilenames = "photo_filenames"
        case job
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

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
