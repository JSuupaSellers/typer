import Foundation
import Testing
@testable import XactimateCatalogCurator

@Test
func storeImportsRowsAndExportsAllItems() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let databaseURL = tempDirectory.appendingPathComponent("catalog.sqlite")
    let store = try CatalogStore(databaseURL: databaseURL)

    let preview = ImportPreview(
        sourceURL: tempDirectory.appendingPathComponent("Xactimate Line Items.xlsx"),
        sheetName: "Sheet1",
        headers: ["CAT", "SEL", "Discription", "QTY Type", "Details"],
        rowCount: 2,
        sampleRows: []
    )
    let rows = [
        ParsedCatalogRow(
            sourceRow: 2,
            category: "PNT",
            selector: "SP",
            description: "Paint ceiling",
            unit: "SF",
            details: "Paint existing ceiling surface",
            rawFields: ["CAT": "PNT", "SEL": "SP"]
        ),
        ParsedCatalogRow(
            sourceRow: 3,
            category: "DRY",
            selector: "PCH",
            description: "Drywall patch 2x2",
            unit: "EA",
            details: "Patch small ceiling opening",
            rawFields: ["CAT": "DRY", "SEL": "PCH"]
        )
    ]

    let result = try store.importRows(rows, preview: preview)
    #expect(result.importedCount == 2)

    let first = try #require(try store.nextUnreviewedItem(excluding: []))
    try store.mark(itemID: first.id, status: .usedBefore)
    _ = try store.saveUsageNote(
        for: first.id,
        draft: ScenarioDraft(
            id: nil,
            title: "Ceiling touch-up",
            tags: "ceiling,paint",
            whenToUse: "Use when the ceiling needs repaint after a repair.",
            whenNotToUse: "",
            room: "Living room",
            surface: "Ceiling",
            damageType: "Paint after repair",
            keywords: "ceiling paint,touch-up",
            synonyms: "paint ceiling,ceiling repaint",
            voiceNotes: "Often paired with patch work.",
            aiHint: "Mention whether the full ceiling or patch area is painted."
        )
    )
    let export = try store.exportCuratedJSON()
    #expect(export.itemCount == 2)
    #expect(export.usageNoteCount == 1)
    #expect(export.items.contains(where: { $0.code == "DRY/PCH" || $0.code == "PNT/SP" }))
    #expect(export.items.contains(where: { $0.usageStatus == UsageStatus.usedBefore.rawValue }))
    #expect(export.items.contains(where: { $0.usageStatus == UsageStatus.unreviewed.rawValue }))

    let exportJSON = String(decoding: try JSONEncoder().encode(export), as: UTF8.self)
    #expect(!exportJSON.contains("voiceNotes"))
}

@Test
func repeatedImportUsesUpsertAndPreservesDecisions() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let databaseURL = tempDirectory.appendingPathComponent("catalog.sqlite")
    let store = try CatalogStore(databaseURL: databaseURL)

    let preview = ImportPreview(
        sourceURL: tempDirectory.appendingPathComponent("Xactimate Line Items.xlsx"),
        sheetName: "Sheet1",
        headers: ["CAT", "SEL", "Discription", "QTY Type", "Details"],
        rowCount: 2,
        sampleRows: []
    )
    let rows = [
        ParsedCatalogRow(
            sourceRow: 2,
            category: "PNT",
            selector: "SP",
            description: "Paint ceiling",
            unit: "SF",
            details: "Paint existing ceiling surface",
            rawFields: ["CAT": "PNT", "SEL": "SP"]
        ),
        ParsedCatalogRow(
            sourceRow: 3,
            category: "DRY",
            selector: "PCH",
            description: "Drywall patch 2x2",
            unit: "EA",
            details: "Patch small ceiling opening",
            rawFields: ["CAT": "DRY", "SEL": "PCH"]
        )
    ]

    let firstImport = try store.importRows(rows, preview: preview)
    #expect(firstImport.insertedCount == 2)
    #expect(firstImport.updatedCount == 0)

    let firstItem = try #require(try store.nextUnreviewedItem(excluding: []))
    try store.mark(itemID: firstItem.id, status: .usedBefore)

    let secondImport = try store.importRows(rows, preview: preview)
    #expect(secondImport.insertedCount == 0)
    #expect(secondImport.updatedCount == 2)

    let usedItems = try store.usedItems(search: "")
    #expect(usedItems.contains(where: { $0.id == firstItem.id }))
}

@Test
func markItemsUsedMatchesCodesAndReportsUnmatched() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let databaseURL = tempDirectory.appendingPathComponent("catalog.sqlite")
    let store = try CatalogStore(databaseURL: databaseURL)

    let preview = ImportPreview(
        sourceURL: tempDirectory.appendingPathComponent("Xactimate Line Items.xlsx"),
        sheetName: "Sheet1",
        headers: ["CAT", "SEL", "Discription", "QTY Type", "Details"],
        rowCount: 2,
        sampleRows: []
    )
    let rows = [
        ParsedCatalogRow(
            sourceRow: 2,
            category: "PNT",
            selector: "SP",
            description: "Paint ceiling",
            unit: "SF",
            details: "Paint existing ceiling surface",
            rawFields: ["CAT": "PNT", "SEL": "SP"]
        ),
        ParsedCatalogRow(
            sourceRow: 3,
            category: "DRY",
            selector: "PCH",
            description: "Drywall patch 2x2",
            unit: "EA",
            details: "Patch small ceiling opening",
            rawFields: ["CAT": "DRY", "SEL": "PCH"]
        )
    ]

    _ = try store.importRows(rows, preview: preview)

    let summary = try store.markItemsUsed(matching: [
        CatalogCode(category: "pnt", selector: "sp"),
        CatalogCode(category: "xyz", selector: "404"),
    ])

    #expect(summary.matchedItems == 1)
    #expect(summary.newlyMarkedItems == 1)
    #expect(summary.alreadyUsedItems == 0)
    #expect(summary.unmatchedCodes == [CatalogCode(category: "XYZ", selector: "404")])
}

@Test
func workbookPreviewTypeIsEquatable() {
    let url = URL(fileURLWithPath: "/tmp/example.xlsx")
    let left = ImportPreview(sourceURL: url, sheetName: "Sheet1", headers: ["CAT"], rowCount: 1, sampleRows: [])
    let right = ImportPreview(sourceURL: url, sheetName: "Sheet1", headers: ["CAT"], rowCount: 1, sampleRows: [])
    #expect(left == right)
}

@Test
func recommendationsPreferStructuredScenarioMatchesAndTrackFeedback() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let databaseURL = tempDirectory.appendingPathComponent("catalog.sqlite")
    let store = try CatalogStore(databaseURL: databaseURL)

    let preview = ImportPreview(
        sourceURL: tempDirectory.appendingPathComponent("Xactimate Line Items.xlsx"),
        sheetName: "Sheet1",
        headers: ["CAT", "SEL", "Discription", "QTY Type", "Details"],
        rowCount: 3,
        sampleRows: []
    )
    let rows = [
        ParsedCatalogRow(
            sourceRow: 2,
            category: "PNT",
            selector: "SP",
            description: "Paint ceiling",
            unit: "SF",
            details: "Paint and blend existing ceiling finish",
            rawFields: ["CAT": "PNT", "SEL": "SP"]
        ),
        ParsedCatalogRow(
            sourceRow: 3,
            category: "DRY",
            selector: "PCH",
            description: "Drywall patch 2x2",
            unit: "EA",
            details: "Patch a small ceiling opening and finish ready for paint",
            rawFields: ["CAT": "DRY", "SEL": "PCH"]
        ),
        ParsedCatalogRow(
            sourceRow: 4,
            category: "PNT",
            selector: "WL",
            description: "Paint wall",
            unit: "SF",
            details: "Paint an interior wall surface",
            rawFields: ["CAT": "PNT", "SEL": "WL"]
        ),
    ]

    _ = try store.importRows(rows, preview: preview)

    let dryPatch = try #require(try store.loadItem(id: 2))
    let paintCeiling = try #require(try store.loadItem(id: 1))

    try store.mark(itemID: dryPatch.id, status: .usedBefore)
    try store.mark(itemID: paintCeiling.id, status: .usedBefore)

    _ = try store.saveUsageNote(
        for: dryPatch.id,
        draft: ScenarioDraft(
            id: nil,
            title: "Ceiling patch before paint",
            tags: "ceiling,drywall,patch",
            whenToUse: "Use for a 2x2 ceiling opening or picture-framed drywall repair before paint.",
            whenNotToUse: "Not for full drywall replacement.",
            room: "Living room",
            surface: "Ceiling",
            damageType: "Patch",
            keywords: "2x2 patch,picture frame,small opening",
            synonyms: "ceiling patch,picture frame repair",
            voiceNotes: "Use for a localized ceiling cutout repair.",
            aiHint: "Prefer this when the scope is a localized ceiling patch."
        )
    )

    _ = try store.saveUsageNote(
        for: paintCeiling.id,
        draft: ScenarioDraft(
            id: nil,
            title: "Ceiling repaint after repair",
            tags: "ceiling,paint",
            whenToUse: "Use after the ceiling patch is complete and the repair needs paint or blend work.",
            whenNotToUse: "Not for wall-only paint work.",
            room: "Living room",
            surface: "Ceiling",
            damageType: "Paint after patch",
            keywords: "paint ceiling,blend paint",
            synonyms: "ceiling repaint,ceiling touch-up",
            voiceNotes: "Often follows drywall patch work.",
            aiHint: "Pair with a patch item when the scope includes both repair and repaint."
        )
    )

    let query = RecommendationQuery(
        narrative: "2x2 ceiling patch that needs picture frame and then ceiling painted",
        room: "Living room",
        surface: "Ceiling",
        damageType: "Patch",
        keywords: "picture frame",
        maxResults: 5
    )

    let results = try store.recommendations(for: query)
    #expect(results.first?.item.displayCode == "DRY/PCH")
    #expect(results.contains(where: { $0.item.displayCode == "PNT/SP" }))

    try store.recordRecommendationFeedback(for: dryPatch.id, query: query, decision: .accepted)
    let updatedResults = try store.recommendations(for: query)
    #expect(updatedResults.first?.acceptedCount == 1)
}
