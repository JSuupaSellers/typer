import Foundation

struct RecommendationSourceItem {
    let item: CatalogItemDetail
    let scenarios: [UsageScenarioRecord]
    let acceptedCount: Int
    let rejectedCount: Int
}

struct RecommendationEngine {
    func recommend(
        query: RecommendationQuery,
        sources: [RecommendationSourceItem]
    ) -> [RecommendationCandidate] {
        let normalizedQuery = NormalizedRecommendationQuery(query: query)
        guard !normalizedQuery.isEmpty else { return [] }

        let ranked = sources.compactMap { candidate(for: $0, query: normalizedQuery) }
        let maxResults = min(max(query.maxResults, 1), 20)

        return Array(
            ranked
                .sorted {
                    if $0.score == $1.score {
                        return $0.item.displayCode < $1.item.displayCode
                    }
                    return $0.score > $1.score
                }
                .prefix(maxResults)
        )
    }

    private func candidate(
        for source: RecommendationSourceItem,
        query: NormalizedRecommendationQuery
    ) -> RecommendationCandidate? {
        var totalScore = 0.0
        var reasons: [String] = []
        var matchedTerms = Set<String>()

        let itemTextMatches = query.tokens.intersection(
            SearchTokenizer.tokenize(
                [
                    source.item.displayCode,
                    source.item.description,
                    source.item.details,
                    source.item.unit,
                ].joined(separator: " ")
            )
        )
        if !itemTextMatches.isEmpty {
            totalScore += Double(itemTextMatches.count) * 5.0
            matchedTerms.formUnion(itemTextMatches)
            reasons.append("Item text matches: \(itemTextMatches.sorted().joined(separator: ", "))")
        }

        let scoredScenarios = source.scenarios
            .compactMap { scoreScenario($0, query: query) }
            .sorted { $0.highlight.score > $1.highlight.score }

        if let bestScenario = scoredScenarios.first {
            totalScore += bestScenario.highlight.score
            matchedTerms.formUnion(bestScenario.highlight.matchedTerms)
            reasons.append(contentsOf: bestScenario.reasons)
        }

        if source.scenarios.count > 1 {
            let depthBonus = min(Double(source.scenarios.count - 1) * 1.5, 6.0)
            totalScore += depthBonus
            reasons.append("Multiple saved scenarios support this line item.")
        }

        let feedbackBoost = min(Double(source.acceptedCount) * 3.0, 18.0) - min(Double(source.rejectedCount) * 2.5, 12.0)
        if feedbackBoost != 0 {
            totalScore += feedbackBoost
            if feedbackBoost > 0 {
                reasons.append("Past accepts boost this item (\(source.acceptedCount)).")
            } else {
                reasons.append("Past rejects lower confidence (\(source.rejectedCount)).")
            }
        }

        guard totalScore > 0 else { return nil }

        let highlights = Array(scoredScenarios.prefix(3).map(\.highlight))
        matchedTerms.formUnion(highlights.flatMap(\.matchedTerms))

        let confidence = confidenceLevel(for: totalScore, highlights: highlights)
        let trimmedReasons = Array(NSOrderedSet(array: reasons).array as? [String] ?? reasons).prefix(4)

        return RecommendationCandidate(
            id: source.item.id,
            item: source.item,
            score: totalScore,
            confidence: confidence,
            matchedTerms: Array(matchedTerms).sorted(),
            reasons: Array(trimmedReasons),
            highlights: highlights,
            acceptedCount: source.acceptedCount,
            rejectedCount: source.rejectedCount
        )
    }

    private func scoreScenario(
        _ scenario: UsageScenarioRecord,
        query: NormalizedRecommendationQuery
    ) -> ScoredScenario? {
        var score = 0.0
        var reasons: [String] = []
        var matchedTerms = Set<String>()

        if let reason = structuredFieldReason(
            queryValue: query.room,
            scenarioValue: scenario.room,
            label: "Room",
            weight: 18.0
        ) {
            score += reason.weight
            reasons.append(reason.text)
            matchedTerms.formUnion(reason.terms)
        }

        if let reason = structuredFieldReason(
            queryValue: query.surface,
            scenarioValue: scenario.surface,
            label: "Surface",
            weight: 16.0
        ) {
            score += reason.weight
            reasons.append(reason.text)
            matchedTerms.formUnion(reason.terms)
        }

        if let reason = structuredFieldReason(
            queryValue: query.damageType,
            scenarioValue: scenario.damageType,
            label: "Damage",
            weight: 18.0
        ) {
            score += reason.weight
            reasons.append(reason.text)
            matchedTerms.formUnion(reason.terms)
        }

        let keywordMatches = query.tokens.intersection(
            SearchTokenizer.tokenize(
                [
                    scenario.tags,
                    scenario.keywords,
                    scenario.synonyms,
                ].joined(separator: " ")
            )
        )
        if !keywordMatches.isEmpty {
            score += Double(keywordMatches.count) * 6.0
            reasons.append("Matched playbook keywords: \(keywordMatches.sorted().joined(separator: ", "))")
            matchedTerms.formUnion(keywordMatches)
        }

        let descriptionMatches = query.tokens.intersection(
            SearchTokenizer.tokenize(
                [
                    scenario.title,
                    scenario.whenToUse,
                    scenario.aiHint,
                ].joined(separator: " ")
            )
        )
        if !descriptionMatches.isEmpty {
            score += Double(descriptionMatches.count) * 3.0
            reasons.append("Scenario text overlaps your scope description.")
            matchedTerms.formUnion(descriptionMatches)
        }

        let exclusionMatches = query.tokens.intersection(SearchTokenizer.tokenize(scenario.whenNotToUse))
        if !exclusionMatches.isEmpty {
            score -= Double(exclusionMatches.count) * 4.0
            reasons.append("Caution from exclusions: \(exclusionMatches.sorted().joined(separator: ", "))")
        }

        guard score > 0 else { return nil }

        let highlight = RecommendationScenarioHighlight(
            id: scenario.id,
            title: scenario.title,
            whenToUse: scenario.whenToUse,
            whenNotToUse: scenario.whenNotToUse,
            room: scenario.room,
            surface: scenario.surface,
            damageType: scenario.damageType,
            keywords: scenario.keywords,
            synonyms: scenario.synonyms,
            aiHint: scenario.aiHint,
            matchedTerms: Array(matchedTerms).sorted(),
            score: score
        )
        return ScoredScenario(highlight: highlight, reasons: reasons)
    }

    private func structuredFieldReason(
        queryValue: String,
        scenarioValue: String,
        label: String,
        weight: Double
    ) -> StructuredReason? {
        let normalizedQuery = SearchTokenizer.normalizePhrase(queryValue)
        let normalizedScenario = SearchTokenizer.normalizePhrase(scenarioValue)
        guard !normalizedQuery.isEmpty, !normalizedScenario.isEmpty else { return nil }

        if normalizedQuery == normalizedScenario {
            return StructuredReason(
                text: "\(label) match: \(scenarioValue.trimmingCharacters(in: .whitespacesAndNewlines))",
                terms: Set(SearchTokenizer.tokenize(scenarioValue)),
                weight: weight
            )
        }

        if normalizedScenario.contains(normalizedQuery) || normalizedQuery.contains(normalizedScenario) {
            return StructuredReason(
                text: "\(label) partial match: \(scenarioValue.trimmingCharacters(in: .whitespacesAndNewlines))",
                terms: Set(SearchTokenizer.tokenize(scenarioValue)),
                weight: weight * 0.65
            )
        }

        return nil
    }

    private func confidenceLevel(
        for score: Double,
        highlights: [RecommendationScenarioHighlight]
    ) -> RecommendationConfidence {
        if score >= 42 || (score >= 34 && !highlights.isEmpty) {
            return .high
        }
        if score >= 20 {
            return .medium
        }
        return .low
    }
}

private struct NormalizedRecommendationQuery {
    let room: String
    let surface: String
    let damageType: String
    let tokens: Set<String>

    init(query: RecommendationQuery) {
        room = query.room.trimmingCharacters(in: .whitespacesAndNewlines)
        surface = query.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        damageType = query.damageType.trimmingCharacters(in: .whitespacesAndNewlines)
        tokens = SearchTokenizer.tokenize(query.combinedText)
    }

    var isEmpty: Bool {
        room.isEmpty && surface.isEmpty && damageType.isEmpty && tokens.isEmpty
    }
}

private struct ScoredScenario {
    let highlight: RecommendationScenarioHighlight
    let reasons: [String]
}

private struct StructuredReason {
    let text: String
    let terms: Set<String>
    let weight: Double
}

private enum SearchTokenizer {
    static func tokenize(_ text: String) -> Set<String> {
        Set(
            normalizePhrase(text)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map(stemmed)
                .filter { $0.count >= 2 && !stopWords.contains($0) }
        )
    }

    static func normalizePhrase(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func stemmed(_ token: String) -> String {
        switch token.count {
        case 5... where token.hasSuffix("ing"):
            return String(token.dropLast(3))
        case 4... where token.hasSuffix("ed"):
            return String(token.dropLast(2))
        case 4... where token.hasSuffix("es"):
            return String(token.dropLast(2))
        case 3... where token.hasSuffix("s"):
            return String(token.dropLast())
        default:
            return token
        }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "that", "this", "your", "you",
        "use", "used", "item", "line", "when", "where", "need", "needs", "after", "before",
        "area", "work", "room", "surface", "type", "scope", "small", "large", "full",
    ]
}
