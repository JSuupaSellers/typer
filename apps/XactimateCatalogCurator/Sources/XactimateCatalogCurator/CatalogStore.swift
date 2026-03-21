import Foundation
import GRDB

enum CatalogStoreError: LocalizedError {
    case databaseUnavailable

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            "The catalog database is unavailable."
        }
    }
}

final class CatalogStore {
    let databaseURL: URL
    private let dbQueue: DatabaseQueue

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try Self.makeMigrator().migrate(dbQueue)
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createCatalogTables") { db in
            try db.create(table: "catalog_items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fingerprint", .text).notNull().unique()
                t.column("source_file", .text).notNull()
                t.column("source_sheet", .text).notNull()
                t.column("source_row", .integer).notNull()
                t.column("category", .text).notNull()
                t.column("selector", .text).notNull()
                t.column("description", .text).notNull()
                t.column("unit", .text).notNull()
                t.column("details", .text).notNull()
                t.column("usage_status", .text).notNull().defaults(to: UsageStatus.unreviewed.rawValue)
                t.column("decision_at", .text).notNull().defaults(to: "")
                t.column("raw_json", .text).notNull()
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "catalog_items_status_idx", on: "catalog_items", columns: ["usage_status"])
            try db.create(index: "catalog_items_sort_idx", on: "catalog_items", columns: ["category", "selector", "description"])

            try db.create(table: "usage_notes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("item_id", .integer).notNull().indexed().references("catalog_items", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("tags", .text).notNull().defaults(to: "")
                t.column("when_to_use", .text).notNull().defaults(to: "")
                t.column("voice_notes", .text).notNull().defaults(to: "")
                t.column("ai_hint", .text).notNull().defaults(to: "")
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
        }
        return migrator
    }

    func stats() throws -> CurationStats {
        try dbQueue.read { db in
            let totalItems = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM catalog_items") ?? 0
            let unreviewedItems = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM catalog_items WHERE usage_status = ?", arguments: [UsageStatus.unreviewed.rawValue]) ?? 0
            let usedItems = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM catalog_items WHERE usage_status = ?", arguments: [UsageStatus.usedBefore.rawValue]) ?? 0
            let neverUsedItems = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM catalog_items WHERE usage_status = ?", arguments: [UsageStatus.neverUsed.rawValue]) ?? 0
            let usageNoteCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_notes") ?? 0
            return CurationStats(
                totalItems: totalItems,
                unreviewedItems: unreviewedItems,
                usedItems: usedItems,
                neverUsedItems: neverUsedItems,
                usageNoteCount: usageNoteCount
            )
        }
    }

    func importRows(_ rows: [ParsedCatalogRow], preview: ImportPreview) throws -> ImportResultSummary {
        var inserted = 0
        var updated = 0
        let timestamp = Self.timestamp()
        let sourceFile = preview.sourceURL.lastPathComponent
        try dbQueue.write { db in
            var existingFingerprints = Set(try String.fetchAll(db, sql: "SELECT fingerprint FROM catalog_items"))
            let upsertStatement = try db.makeStatement(
                sql: """
                INSERT INTO catalog_items (
                    fingerprint, source_file, source_sheet, source_row, category, selector,
                    description, unit, details, usage_status, decision_at, raw_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(fingerprint) DO UPDATE SET
                    source_file = excluded.source_file,
                    source_sheet = excluded.source_sheet,
                    source_row = excluded.source_row,
                    category = excluded.category,
                    selector = excluded.selector,
                    description = excluded.description,
                    unit = excluded.unit,
                    details = excluded.details,
                    raw_json = excluded.raw_json,
                    updated_at = excluded.updated_at
                """
            )

            for row in rows {
                let fingerprint = Self.fingerprint(for: row)
                let rawJSON = try Self.rawJSONString(from: row.rawFields)

                if existingFingerprints.contains(fingerprint) {
                    updated += 1
                } else {
                    inserted += 1
                    existingFingerprints.insert(fingerprint)
                }

                try upsertStatement.execute(
                    arguments: [
                        fingerprint,
                        sourceFile,
                        preview.sheetName,
                        row.sourceRow,
                        row.category,
                        row.selector,
                        row.description,
                        row.unit,
                        row.details,
                        UsageStatus.unreviewed.rawValue,
                        "",
                        rawJSON,
                        timestamp,
                        timestamp,
                    ]
                )
            }
        }
        return ImportResultSummary(
            importedCount: rows.count,
            insertedCount: inserted,
            updatedCount: updated,
            sheetName: preview.sheetName,
            databaseURL: databaseURL
        )
    }

    func nextUnreviewedItem(excluding excludedIDs: Set<Int64>) throws -> CatalogItemDetail? {
        try dbQueue.read { db in
            var sql = """
                SELECT id, category, selector, description, unit, details, usage_status AS usageStatus,
                       source_file AS sourceFile, source_sheet AS sourceSheet, source_row AS sourceRow,
                       decision_at AS decisionAt, raw_json AS rawJSON
                FROM catalog_items
                WHERE usage_status = ?
            """
            var arguments: StatementArguments = [UsageStatus.unreviewed.rawValue]
            if !excludedIDs.isEmpty {
                let placeholders = excludedIDs.map { _ in "?" }.joined(separator: ", ")
                sql += " AND id NOT IN (\(placeholders))"
                for id in excludedIDs {
                    arguments += [id]
                }
            }
            sql += " ORDER BY category, selector, description LIMIT 1"
            return try CatalogItemDetail.fetchOne(db, sql: sql, arguments: arguments)
        }
    }

    func mark(itemID: Int64, status: UsageStatus) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE catalog_items SET usage_status = ?, decision_at = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, Self.timestamp(), Self.timestamp(), itemID]
            )
        }
    }

    func usedItems(search: String) throws -> [CatalogItemSummary] {
        try dbQueue.read { db in
            var sql = """
                SELECT
                    ci.id,
                    ci.category,
                    ci.selector,
                    ci.description,
                    ci.unit,
                    ci.details,
                    ci.usage_status AS usageStatus,
                    ci.source_row AS sourceRow,
                    COUNT(un.id) AS usageNoteCount
                FROM catalog_items ci
                LEFT JOIN usage_notes un ON un.item_id = ci.id
                WHERE ci.usage_status = ?
            """
            var arguments: StatementArguments = [UsageStatus.usedBefore.rawValue]
            let trimmedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSearch.isEmpty {
                sql += " AND (lower(ci.category) LIKE ? OR lower(ci.selector) LIKE ? OR lower(ci.description) LIKE ? OR lower(ci.details) LIKE ?)"
                let wildcard = "%\(trimmedSearch.lowercased())%"
                arguments += [wildcard, wildcard, wildcard, wildcard]
            }
            sql += """
                GROUP BY ci.id, ci.category, ci.selector, ci.description, ci.unit, ci.details, ci.usage_status, ci.source_row
                ORDER BY ci.category, ci.selector, ci.description
            """
            return try CatalogItemSummary.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    func loadItem(id: Int64) throws -> CatalogItemDetail? {
        try dbQueue.read { db in
            try CatalogItemDetail.fetchOne(
                db,
                sql: """
                    SELECT id, category, selector, description, unit, details,
                           usage_status AS usageStatus,
                           source_file AS sourceFile, source_sheet AS sourceSheet, source_row AS sourceRow,
                           decision_at AS decisionAt, raw_json AS rawJSON
                    FROM catalog_items
                    WHERE id = ?
                """,
                arguments: [id]
            )
        }
    }

    func usageNotes(for itemID: Int64) throws -> [UsageScenarioRecord] {
        try dbQueue.read { db in
            try UsageScenarioRecord.fetchAll(
                db,
                sql: """
                    SELECT id, item_id AS itemId, title, tags,
                           when_to_use AS whenToUse,
                           voice_notes AS voiceNotes,
                           ai_hint AS aiHint,
                           created_at AS createdAt,
                           updated_at AS updatedAt
                    FROM usage_notes
                    WHERE item_id = ?
                    ORDER BY updated_at DESC, id DESC
                """,
                arguments: [itemID]
            )
        }
    }

    func saveUsageNote(for itemID: Int64, draft: ScenarioDraft) throws -> Int64 {
        let timestamp = Self.timestamp()
        return try dbQueue.write { db in
            if let id = draft.id {
                try db.execute(
                    sql: """
                        UPDATE usage_notes
                        SET title = ?, tags = ?, when_to_use = ?, voice_notes = ?, ai_hint = ?, updated_at = ?
                        WHERE id = ? AND item_id = ?
                    """,
                    arguments: [draft.title, draft.tags, draft.whenToUse, draft.voiceNotes, draft.aiHint, timestamp, id, itemID]
                )
                return id
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO usage_notes (
                            item_id, title, tags, when_to_use, voice_notes, ai_hint, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [itemID, draft.title, draft.tags, draft.whenToUse, draft.voiceNotes, draft.aiHint, timestamp, timestamp]
                )
                return db.lastInsertedRowID
            }
        }
    }

    func deleteUsageNote(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM usage_notes WHERE id = ?", arguments: [id])
        }
    }

    func exportCuratedJSON() throws -> CuratedExportEnvelope {
        try dbQueue.read { db in
            let itemRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, category, selector, description, unit, details
                    FROM catalog_items
                    WHERE usage_status = ?
                    ORDER BY category, selector, description
                """,
                arguments: [UsageStatus.usedBefore.rawValue]
            )
            let items: [CuratedExportItem] = try itemRows.map { row in
                let itemID: Int64 = row["id"]
                let notes = try UsageScenarioRecord.fetchAll(
                    db,
                    sql: """
                        SELECT id, item_id AS itemId, title, tags,
                               when_to_use AS whenToUse,
                               voice_notes AS voiceNotes,
                               ai_hint AS aiHint,
                               created_at AS createdAt,
                               updated_at AS updatedAt
                        FROM usage_notes
                        WHERE item_id = ?
                        ORDER BY updated_at DESC, id DESC
                    """,
                    arguments: [itemID]
                ).map { note in
                    CuratedUsageNote(
                        title: note.title,
                        tags: note.tags,
                        whenToUse: note.whenToUse,
                        voiceNotes: note.voiceNotes,
                        aiHint: note.aiHint
                    )
                }
                let category: String = row["category"]
                let selector: String = row["selector"]
                return CuratedExportItem(
                    code: [category, selector].filter { !$0.isEmpty }.joined(separator: "/"),
                    category: category,
                    selector: selector,
                    description: row["description"],
                    unit: row["unit"],
                    details: row["details"],
                    usageNotes: notes
                )
            }
            return CuratedExportEnvelope(
                exportedAt: Self.timestamp(),
                itemCount: items.count,
                usageNoteCount: items.reduce(0) { $0 + $1.usageNotes.count },
                items: items
            )
        }
    }

    private static func fingerprint(for row: ParsedCatalogRow) -> String {
        [row.category, row.selector, row.description, row.unit, row.details]
            .joined(separator: "|")
            .lowercased()
    }

    private static func rawJSONString(from rawFields: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: rawFields, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
