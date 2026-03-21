import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: CuratorAppModel
    @State private var isImporterPresented = false

    var body: some View {
        TabView(selection: $model.selectedStage) {
            ImportStageView(isImporterPresented: $isImporterPresented)
                .tabItem { Label("Import", systemImage: "square.and.arrow.down") }
                .tag(CuratorStage.importData)

            QuickReviewStageView()
                .tabItem { Label("Review", systemImage: "hand.tap") }
                .tag(CuratorStage.quickReview)

            UsageNotesStageView()
                .tabItem { Label("Usage Notes", systemImage: "mic.badge.plus") }
                .tag(CuratorStage.usageNotes)
        }
        .padding(18)
        .frame(minWidth: 1180, minHeight: 760)
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Xactimate Catalog Curator")
                        .font(.title3.weight(.semibold))
                    Text("Database: \(model.databaseLocation)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ToolbarItemGroup(placement: .automatic) {
                Button("Choose Workbook") {
                    isImporterPresented = true
                }
                .disabled(model.isBusy)

                Button("Export Curated JSON") {
                    model.exportCuratedJSON()
                }
                .disabled(model.isBusy || model.stats.usedItems == 0)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.spreadsheet],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first {
                    model.chooseWorkbook(url)
                }
            case let .failure(error):
                model.lastError = error.localizedDescription
            }
        }
        .alert("Something needs attention", isPresented: .constant(!model.lastError.isEmpty)) {
            Button("OK") {
                model.clearError()
            }
        } message: {
            Text(model.lastError)
        }
        .overlay {
            if model.isBusy {
                ZStack {
                    Rectangle()
                        .fill(.black.opacity(0.08))
                        .ignoresSafeArea()
                    ProgressView("Working...")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }
}

private struct ImportStageView: View {
    @EnvironmentObject private var model: CuratorAppModel
    @Binding var isImporterPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Stage 1: Import Excel and Prep SQLite") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Import your Xactimate workbook, preview the detected sheet and headers, then load it into the curator database.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Choose Excel File") {
                            isImporterPresented = true
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Prep and Import") {
                            model.importSelectedWorkbook()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.preview == nil)
                    }

                    if let preview = model.preview {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(preview.sourceURL.path(percentEncoded: false))
                                .font(.callout.monospaced())
                            Text("Sheet: \(preview.sheetName) | Rows: \(preview.rowCount)")
                                .font(.callout)
                            Text("Headers: \(preview.headers.joined(separator: ", "))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ContentUnavailableView("No workbook selected", systemImage: "tablecells", description: Text("Choose the Excel export you want to curate."))
                    }

                    if let summary = model.importSummary {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Imported \(summary.importedCount) rows from \(summary.sheetName).")
                            Text("Inserted \(summary.insertedCount), updated \(summary.updatedCount).")
                                .foregroundStyle(.secondary)
                            Text("Database saved at \(summary.databaseURL.path(percentEncoded: false))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Preview") {
                if let preview = model.preview {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(preview.sampleRows.enumerated()), id: \.offset) { index, row in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Row \(index + 2)")
                                        .font(.headline)
                                    ForEach(preview.headers, id: \.self) { header in
                                        HStack(alignment: .top) {
                                            Text(header)
                                                .font(.caption.weight(.semibold))
                                                .frame(width: 120, alignment: .leading)
                                            Text(row[header] ?? "")
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .padding(12)
                                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Preview will appear here", systemImage: "doc.text.magnifyingglass", description: Text("After choosing a workbook, the first few rows will be shown here."))
                }
            }
        }
    }
}

private struct QuickReviewStageView: View {
    @EnvironmentObject private var model: CuratorAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Stage 2: Fast Used / Never Used Pass") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Review one line item at a time. Use the big buttons or the shortcuts: `Space` for used before, `N` for never used, `S` to skip for now.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 20) {
                        StatPill(title: "Total", value: "\(model.stats.totalItems)")
                        StatPill(title: "Reviewed", value: "\(model.stats.reviewedItems)")
                        StatPill(title: "Unreviewed", value: "\(model.stats.unreviewedItems)")
                        StatPill(title: "Used", value: "\(model.stats.usedItems)")
                    }
                    Text(model.reviewProgressText)
                        .font(.headline)
                }
            }

            if let item = model.currentReviewItem {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.displayCode)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text(item.description)
                            .font(.title3)
                        HStack {
                            Text("Unit: \(item.unit)")
                            Text("Sheet row: \(item.sourceRow)")
                        }
                        .foregroundStyle(.secondary)
                    }

                    GroupBox("Details") {
                        ScrollView {
                            Text(item.details.isEmpty ? "No details in source row." : item.details)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 220)
                    }

                    HStack(spacing: 12) {
                        Button("Used Before") {
                            model.markCurrentReviewItem(as: .usedBefore)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.space, modifiers: [])

                        Button("Never Used") {
                            model.markCurrentReviewItem(as: .neverUsed)
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("n", modifiers: [])

                        Button("Skip") {
                            model.skipCurrentReviewItem()
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("s", modifiers: [])
                    }
                }
                .padding(26)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    LinearGradient(
                        colors: [Color(NSColor.windowBackgroundColor), Color(NSColor.controlBackgroundColor)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 22)
                )
            } else {
                ContentUnavailableView("Quick review is caught up", systemImage: "checkmark.circle", description: Text("There are no unreviewed items left right now."))
            }
        }
    }
}

private struct UsageNotesStageView: View {
    @EnvironmentObject private var model: CuratorAppModel

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Stage 3: Usage Notes")
                        .font(.headline)
                    Spacer()
                }

                TextField("Search used items", text: $model.noteSearchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.refreshUsedItems()
                    }

                Button("Refresh Used Items") {
                    model.refreshUsedItems()
                }
                .buttonStyle(.bordered)

                List(selection: Binding(get: {
                    model.selectedUsedItemID
                }, set: { newValue in
                    if let newValue {
                        model.selectUsedItem(id: newValue)
                    }
                })) {
                    ForEach(model.usedItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.displayCode)
                                    .font(.headline)
                                if item.usageNoteCount > 0 {
                                    Text("\(item.usageNoteCount) note\(item.usageNoteCount == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(item.description)
                                .lineLimit(2)
                            Text(item.details)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .tag(item.id)
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 340)

            VStack(alignment: .leading, spacing: 12) {
                if let item = model.selectedUsedItem {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.displayCode)
                            .font(.title2.weight(.semibold))
                        Text(item.description)
                            .font(.headline)
                        Text("Use macOS Dictation in the text fields below if you want voice-driven note entry.")
                            .foregroundStyle(.secondary)
                    }

                    HSplitView {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Saved Notes")
                                    .font(.headline)
                                Spacer()
                                Button("New Note") {
                                    model.startNewUsageNote()
                                }
                            }

                            List(selection: Binding(get: {
                                model.selectedUsageNoteID
                            }, set: { newValue in
                                if let newValue {
                                    model.selectUsageNote(id: newValue)
                                } else {
                                    model.startNewUsageNote()
                                }
                            })) {
                                ForEach(model.usageNotes) { note in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(note.title)
                                            .font(.headline)
                                        if !note.tags.isEmpty {
                                            Text(note.tags)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .tag(note.id)
                                }
                            }
                        }
                        .frame(minWidth: 220, idealWidth: 260)

                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Note title", text: $model.scenarioDraft.title)
                                .textFieldStyle(.roundedBorder)
                            TextField("Tags", text: $model.scenarioDraft.tags)
                                .textFieldStyle(.roundedBorder)

                            LabeledEditor(title: "When I use it", text: $model.scenarioDraft.whenToUse)
                            LabeledEditor(title: "Voice transcript / notes", text: $model.scenarioDraft.voiceNotes)
                            LabeledEditor(title: "AI hint", text: $model.scenarioDraft.aiHint)

                            HStack {
                                Button("Save Note") {
                                    model.saveCurrentUsageNote()
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Delete Note") {
                                    model.deleteSelectedUsageNote()
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.selectedUsageNoteID == nil)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No used item selected", systemImage: "note.text", description: Text("After your quick review pass, used items will appear here for a second note-taking pass."))
                }
            }
            .frame(minWidth: 720)
        }
    }
}

private struct StatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct LabeledEditor: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 120)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

