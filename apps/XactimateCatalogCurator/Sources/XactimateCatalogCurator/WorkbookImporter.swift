import CoreXLSX
import Foundation

enum WorkbookImportError: LocalizedError {
    case couldNotOpenWorkbook
    case workbookHasNoSheets
    case worksheetHasNoRows
    case requiredColumnsMissing([String])

    var errorDescription: String? {
        switch self {
        case .couldNotOpenWorkbook:
            return "The workbook could not be opened."
        case .workbookHasNoSheets:
            return "The workbook does not contain any worksheets."
        case .worksheetHasNoRows:
            return "The worksheet does not contain any rows."
        case let .requiredColumnsMissing(columns):
            return "The workbook is missing required columns: \(columns.joined(separator: ", "))."
        }
    }
}

struct WorkbookImporter {
    private enum ColumnKey: String, CaseIterable {
        case category
        case selector
        case description
        case unit
        case details

        var aliases: [String] {
            switch self {
            case .category:
                return ["cat", "category"]
            case .selector:
                return ["sel", "selector", "line item", "line item code", "code"]
            case .description:
                return ["description", "discription", "item description"]
            case .unit:
                return ["qty type", "unit", "uom", "unit of measure"]
            case .details:
                return ["details", "detail", "notes"]
            }
        }
    }

    private struct ParsedSheet {
        let sheetName: String
        let headers: [String]
        let dataRows: [[String]]
    }

    func previewWorkbook(at url: URL) throws -> ImportPreview {
        let parsedSheet = try loadSheet(at: url)
        let samples = parsedSheet.dataRows.prefix(5).map { row in
            Dictionary(uniqueKeysWithValues: zip(parsedSheet.headers, row))
        }
        return ImportPreview(
            sourceURL: url,
            sheetName: parsedSheet.sheetName,
            headers: parsedSheet.headers,
            rowCount: parsedSheet.dataRows.count,
            sampleRows: Array(samples)
        )
    }

    func parseCatalogRows(at url: URL) throws -> (ImportPreview, [ParsedCatalogRow]) {
        let parsedSheet = try loadSheet(at: url)
        let mapping = try inferMapping(headers: parsedSheet.headers)
        let preview = ImportPreview(
            sourceURL: url,
            sheetName: parsedSheet.sheetName,
            headers: parsedSheet.headers,
            rowCount: parsedSheet.dataRows.count,
            sampleRows: Array(parsedSheet.dataRows.prefix(5).map { Dictionary(uniqueKeysWithValues: zip(parsedSheet.headers, $0)) })
        )
        let rows: [ParsedCatalogRow] = parsedSheet.dataRows.enumerated().compactMap { index, row in
            let rowMap = rowMapForRow(headers: parsedSheet.headers, row: row)
            let category = cleaned(rowMap[mapping[.category]!])
            let selector = cleaned(rowMap[mapping[.selector]!])
            let description = cleaned(rowMap[mapping[.description]!])
            let unit = cleaned(rowMap[mapping[.unit]!])
            let details = cleaned(rowMap[mapping[.details]!])
            guard ![category, selector, description, unit, details].allSatisfy(\.isEmpty) else {
                return nil
            }
            return ParsedCatalogRow(
                sourceRow: index + 2,
                category: category,
                selector: selector,
                description: description,
                unit: unit,
                details: details,
                rawFields: rowMap
            )
        }
        return (preview, rows)
    }

    private func loadSheet(at url: URL) throws -> ParsedSheet {
        guard let file = XLSXFile(filepath: url.path(percentEncoded: false)) else {
            throw WorkbookImportError.couldNotOpenWorkbook
        }
        let sharedStrings = try file.parseSharedStrings()
        let workbook = try file.parseWorkbooks().first
        guard let workbook else {
            throw WorkbookImportError.workbookHasNoSheets
        }
        let sheetEntries = try file.parseWorksheetPathsAndNames(workbook: workbook)
        guard let entry = sheetEntries.first else {
            throw WorkbookImportError.workbookHasNoSheets
        }
        let worksheet = try file.parseWorksheet(at: entry.path)
        let rows = worksheet.data?.rows ?? []
        guard !rows.isEmpty else {
            throw WorkbookImportError.worksheetHasNoRows
        }
        let orderedRows = rows.map { row in
            orderedCellValues(for: row, sharedStrings: sharedStrings)
        }
        let trimmedRows = trimTrailingEmptyColumns(orderedRows)
        guard let headerRow = trimmedRows.first else {
            throw WorkbookImportError.worksheetHasNoRows
        }
        let headers = headerRow.map(cleaned)
        let dataRows = trimmedRows.dropFirst().filter { row in
            row.contains { !cleaned($0).isEmpty }
        }
        return ParsedSheet(sheetName: entry.name ?? "Sheet1", headers: headers, dataRows: Array(dataRows))
    }

    private func orderedCellValues(for row: Row, sharedStrings: SharedStrings?) -> [String] {
        let origin = ColumnReference("A")!
        let columnValues = Dictionary(uniqueKeysWithValues: row.cells.map { cell in
            let columnIndex = origin.distance(to: cell.reference.column) + 1
            return (columnIndex, cellString(cell, sharedStrings: sharedStrings))
        })
        let maxIndex = columnValues.keys.max() ?? 0
        guard maxIndex > 0 else { return [] }
        return (1 ... maxIndex).map { cleaned(columnValues[$0] ?? "") }
    }

    private func cellString(_ cell: Cell, sharedStrings: SharedStrings?) -> String {
        if let sharedStrings, let value = cell.stringValue(sharedStrings) {
            return value
        }
        if let inline = cell.inlineString?.text {
            return inline
        }
        return cell.value ?? ""
    }

    private func trimTrailingEmptyColumns(_ rows: [[String]]) -> [[String]] {
        let maxUsedIndex = rows.reduce(0) { runningMax, row in
            let rowLast = row.lastIndex(where: { !cleaned($0).isEmpty }).map { $0 + 1 } ?? 0
            return max(runningMax, rowLast)
        }
        guard maxUsedIndex > 0 else { return rows }
        return rows.map { row in
            Array(row.prefix(maxUsedIndex))
        }
    }

    private func inferMapping(headers: [String]) throws -> [ColumnKey: String] {
        let normalizedHeaders = headers.map { cleaned($0).lowercased() }
        var mapping: [ColumnKey: String] = [:]
        var missing: [String] = []
        for key in ColumnKey.allCases {
            if let matchIndex = normalizedHeaders.firstIndex(where: { header in
                key.aliases.contains(header)
            }) {
                mapping[key] = headers[matchIndex]
            } else {
                missing.append(key.rawValue)
            }
        }
        guard missing.isEmpty else {
            throw WorkbookImportError.requiredColumnsMissing(missing)
        }
        return mapping
    }

    private func rowMapForRow(headers: [String], row: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for (index, header) in headers.enumerated() {
            result[header] = index < row.count ? cleaned(row[index]) : ""
        }
        return result
    }

    private func cleaned(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { line in line.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

