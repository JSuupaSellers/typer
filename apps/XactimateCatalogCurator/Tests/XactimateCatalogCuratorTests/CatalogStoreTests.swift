import Foundation
import Testing
@testable import XactimateCatalogCurator

@Test
func storeImportsRowsAndExportsUsedItems() throws {
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
            voiceNotes: "Often paired with patch work.",
            aiHint: "Mention whether the full ceiling or patch area is painted."
        )
    )
    let export = try store.exportCuratedJSON()
    #expect(export.itemCount == 1)
    #expect(export.usageNoteCount == 1)
    #expect(export.items.first?.code == "DRY/PCH" || export.items.first?.code == "PNT/SP")
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
