import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: CuratorAppModel
    @State private var isImporterPresented = false
    @State private var isLLMSettingsPresented = false

    var body: some View {
        ZStack {
            StageBackdrop(stage: model.selectedStage)

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
            .padding(20)
            .frame(minWidth: 1180, minHeight: 760)
            .animation(.easeInOut(duration: 0.28), value: model.selectedStage)
        }
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Xactimate Catalog Curator")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
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

                Button("OpenAI Settings") {
                    isLLMSettingsPresented = true
                }
                .disabled(model.isBusy)
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
        .sheet(isPresented: $isLLMSettingsPresented) {
            LLMSettingsSheet(
                initialSettings: model.llmSettings,
                onSave: { model.saveLLMSettings($0) }
            )
        }
        .overlay {
            if model.isBusy {
                ZStack {
                    Rectangle()
                        .fill(.black.opacity(0.08))
                        .ignoresSafeArea()

                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Working...")
                            .font(.headline)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: 24, y: 12)
                }
            }
        }
    }
}

private struct ImportStageView: View {
    @EnvironmentObject private var model: CuratorAppModel
    @Binding var isImporterPresented: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StageHeroCard(
                    stage: .importData,
                    eyebrow: "Stage 1",
                    title: "Shape the Raw Catalog",
                    subtitle: "Bring in the Excel export, inspect the workbook shape, and turn that raw spreadsheet into a fast SQLite catalog you can curate in passes.",
                    metrics: [
                        .init(label: "Workbook", value: model.preview?.sheetName ?? "Waiting"),
                        .init(label: "Rows", value: model.preview.map { "\($0.rowCount)" } ?? "0"),
                        .init(label: "Imported", value: model.importSummary.map { "\($0.importedCount)" } ?? "0")
                    ]
                )

                HStack(alignment: .top, spacing: 18) {
                    CuratorPanel(tint: CuratorStage.importData.theme.accent) {
                        VStack(alignment: .leading, spacing: 18) {
                            PanelHeader(
                                eyebrow: "Workbook Intake",
                                title: "Import Excel and prep SQLite",
                                subtitle: "The importer is tuned for your Xactimate export shape and saves the working database in Application Support."
                            )

                            HStack(spacing: 12) {
                                Button {
                                    isImporterPresented = true
                                } label: {
                                    Label("Choose Excel File", systemImage: "doc.badge.plus")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)

                                Button {
                                    model.importSelectedWorkbook()
                                } label: {
                                    Label("Prep and Import", systemImage: "arrow.down.doc")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .disabled(model.preview == nil)
                            }

                            if let preview = model.preview {
                                VStack(alignment: .leading, spacing: 10) {
                                    InfoBadge(title: "Source", value: preview.sourceURL.lastPathComponent, tint: CuratorStage.importData.theme.accent)
                                    InfoBadge(title: "Location", value: preview.sourceURL.path(percentEncoded: false), tint: CuratorStage.importData.theme.secondaryAccent, monospaced: true)
                                    HStack(spacing: 10) {
                                        InfoBadge(title: "Sheet", value: preview.sheetName, tint: CuratorStage.importData.theme.accent)
                                        InfoBadge(title: "Rows", value: "\(preview.rowCount)", tint: CuratorStage.importData.theme.secondaryAccent)
                                    }
                                    InfoBadge(title: "Headers", value: preview.headers.joined(separator: " • "), tint: CuratorStage.importData.theme.secondaryAccent)
                                }
                            } else {
                                ContentUnavailableView(
                                    "No workbook selected",
                                    systemImage: "tablecells",
                                    description: Text("Choose the Excel export you want to curate.")
                                )
                                .frame(maxWidth: .infinity, minHeight: 180)
                            }
                        }
                    }

                    CuratorPanel(tint: CuratorStage.importData.theme.secondaryAccent) {
                        VStack(alignment: .leading, spacing: 18) {
                            PanelHeader(
                                eyebrow: "Import Status",
                                title: model.importSummary == nil ? "Ready for first pass" : "Latest import completed",
                                subtitle: model.importSummary == nil
                                    ? "Once a workbook is chosen, you can preview the columns before the database is updated."
                                    : "Your workbook has been merged into the curator database and is ready for review."
                            )

                            if let summary = model.importSummary {
                                VStack(alignment: .leading, spacing: 10) {
                                    MetricStrip(
                                        title: "Rows imported",
                                        value: "\(summary.importedCount)",
                                        tint: CuratorStage.importData.theme.accent
                                    )
                                    MetricStrip(
                                        title: "Inserted / updated",
                                        value: "\(summary.insertedCount) / \(summary.updatedCount)",
                                        tint: CuratorStage.importData.theme.secondaryAccent
                                    )
                                    InfoBadge(
                                        title: "Database",
                                        value: summary.databaseURL.path(percentEncoded: false),
                                        tint: CuratorStage.importData.theme.secondaryAccent,
                                        monospaced: true
                                    )
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 12) {
                                    ChecklistRow(text: "Load the workbook from disk")
                                    ChecklistRow(text: "Preview the detected worksheet and headers")
                                    ChecklistRow(text: "Import the rows into SQLite")
                                    ChecklistRow(text: "Move into the yes / no curation pass")
                                }
                            }
                        }
                    }
                    .frame(minWidth: 320, maxWidth: 360)
                }

                CuratorPanel(tint: CuratorStage.importData.theme.accent) {
                    VStack(alignment: .leading, spacing: 16) {
                        PanelHeader(
                            eyebrow: "Workbook Preview",
                            title: "Sample rows",
                            subtitle: "A quick confidence check before you commit the workbook into the curator database."
                        )

                        if let preview = model.preview {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(preview.sampleRows.enumerated()), id: \.offset) { index, row in
                                    PreviewRowCard(
                                        index: index + 2,
                                        headers: preview.headers,
                                        row: row,
                                        tint: index.isMultiple(of: 2) ? CuratorStage.importData.theme.accent : CuratorStage.importData.theme.secondaryAccent
                                    )
                                }
                            }
                        } else {
                            ContentUnavailableView(
                                "Preview will appear here",
                                systemImage: "doc.text.magnifyingglass",
                                description: Text("After choosing a workbook, the first few rows will be shown here.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 220)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }
}

private struct QuickReviewStageView: View {
    @EnvironmentObject private var model: CuratorAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StageHeroCard(
                    stage: .quickReview,
                    eyebrow: "Stage 2",
                    title: "Fast Confidence Pass",
                    subtitle: "Move quickly through the catalog and decide whether each line item belongs in your working set. The goal here is speed, not perfect notes.",
                    metrics: [
                        .init(label: "Total", value: "\(model.stats.totalItems)"),
                        .init(label: "Reviewed", value: "\(model.stats.reviewedItems)"),
                        .init(label: "Used", value: "\(model.stats.usedItems)")
                    ]
                )

                HStack(spacing: 14) {
                    MetricCard(title: "Total", value: "\(model.stats.totalItems)", symbol: "square.stack.3d.up", tint: CuratorStage.quickReview.theme.accent)
                    MetricCard(title: "Reviewed", value: "\(model.stats.reviewedItems)", symbol: "checkmark.circle", tint: CuratorStage.quickReview.theme.secondaryAccent)
                    MetricCard(title: "Unreviewed", value: "\(model.stats.unreviewedItems)", symbol: "hourglass", tint: CuratorStage.quickReview.theme.accent)
                    MetricCard(title: "Used Before", value: "\(model.stats.usedItems)", symbol: "star", tint: CuratorStage.quickReview.theme.secondaryAccent)
                }

                if let item = model.currentReviewItem {
                    HStack(alignment: .top, spacing: 18) {
                        CuratorPanel(tint: CuratorStage.quickReview.theme.accent) {
                            VStack(alignment: .leading, spacing: 20) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("Review Queue")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .textCase(.uppercase)
                                        Text(item.displayCode)
                                            .font(.system(size: 38, weight: .black, design: .rounded))
                                        Text(item.description)
                                            .font(.title3.weight(.semibold))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 8) {
                                        CapsuleBadge(text: "Unit: \(item.unit)", tint: CuratorStage.quickReview.theme.accent)
                                        CapsuleBadge(text: "Sheet Row \(item.sourceRow)", tint: CuratorStage.quickReview.theme.secondaryAccent)
                                    }
                                }

                                MetricStrip(
                                    title: "Progress",
                                    value: model.reviewProgressText,
                                    tint: CuratorStage.quickReview.theme.secondaryAccent
                                )

                                DetailSurface(title: "Details", tint: CuratorStage.quickReview.theme.accent) {
                                    Text(item.details.isEmpty ? "No details in source row." : item.details)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                HStack(spacing: 12) {
                                    Button {
                                        model.markCurrentReviewItem(as: .usedBefore)
                                    } label: {
                                        Label("Used Before", systemImage: "checkmark.circle.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.large)
                                    .keyboardShortcut(.space, modifiers: [])

                                    Button {
                                        model.markCurrentReviewItem(as: .neverUsed)
                                    } label: {
                                        Label("Never Used", systemImage: "xmark.circle")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.large)
                                    .keyboardShortcut("n", modifiers: [])

                                    Button {
                                        model.skipCurrentReviewItem()
                                    } label: {
                                        Label("Skip", systemImage: "arrowshape.turn.up.right")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.large)
                                    .keyboardShortcut("s", modifiers: [])
                                }
                            }
                        }

                        CuratorPanel(tint: CuratorStage.quickReview.theme.secondaryAccent) {
                            VStack(alignment: .leading, spacing: 18) {
                                PanelHeader(
                                    eyebrow: "Keyboard Rhythm",
                                    title: "Stay in flow",
                                    subtitle: "This screen is optimized for fast yes / no decisions while keeping the item context visible."
                                )

                                VStack(alignment: .leading, spacing: 12) {
                                    ShortcutBadge(key: "Space", action: "Used Before", tint: CuratorStage.quickReview.theme.accent)
                                    ShortcutBadge(key: "N", action: "Never Used", tint: CuratorStage.quickReview.theme.secondaryAccent)
                                    ShortcutBadge(key: "S", action: "Skip for now", tint: CuratorStage.quickReview.theme.accent)
                                }

                                Divider()

                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Decision rule")
                                        .font(.headline)
                                    Text("If you’ve used the item in the real world, keep it moving into your working set. If it’s irrelevant to your workflow, cut it here and save the deeper thinking for stage 3.")
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(minWidth: 280, maxWidth: 320)
                    }
                } else {
                    CuratorPanel(tint: CuratorStage.quickReview.theme.secondaryAccent) {
                        ContentUnavailableView(
                            "Quick review is caught up",
                            systemImage: "checkmark.circle",
                            description: Text("There are no unreviewed items left right now.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }
}

private struct UsageNotesStageView: View {
    @EnvironmentObject private var model: CuratorAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StageHeroCard(
                stage: .usageNotes,
                eyebrow: "Stage 3",
                title: "Capture the Estimating Playbook",
                subtitle: "Record how you actually use each line item, let OpenAI transcribe the raw explanation, and clean it into guidance that can power later recommendations.",
                metrics: [
                    .init(label: "Used Items", value: "\(model.stats.usedItems)"),
                    .init(label: "Notes", value: "\(model.stats.usageNoteCount)"),
                    .init(label: "Voice", value: model.llmSettings.hasTranscriptionConfiguration ? "Ready" : "Setup")
                ]
            )

            HSplitView {
                CuratorPanel(tint: CuratorStage.usageNotes.theme.accent) {
                    VStack(alignment: .leading, spacing: 14) {
                        PanelHeader(
                            eyebrow: "Working Set",
                            title: "Used items",
                            subtitle: "Search the line items you kept in stage 2, then pick one to start building voice-backed usage notes."
                        )

                        TextField("Search used items", text: $model.noteSearchText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                model.refreshUsedItems()
                            }

                        HStack {
                            CapsuleBadge(text: "\(model.usedItems.count) showing", tint: CuratorStage.usageNotes.theme.accent)
                            Spacer()
                            Button("Refresh Used Items") {
                                model.refreshUsedItems()
                            }
                            .buttonStyle(.bordered)
                        }

                        List(selection: Binding(get: {
                            model.selectedUsedItemID
                        }, set: { newValue in
                            if let newValue {
                                model.selectUsedItem(id: newValue)
                            }
                        })) {
                            ForEach(model.usedItems) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .center) {
                                        Text(item.displayCode)
                                            .font(.headline)
                                        Spacer()
                                        if item.usageNoteCount > 0 {
                                            Text("\(item.usageNoteCount)")
                                                .font(.caption.weight(.semibold))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Capsule().fill(CuratorStage.usageNotes.theme.secondaryAccent.opacity(0.16)))
                                        }
                                    }
                                    Text(item.description)
                                        .lineLimit(2)
                                    if !item.details.isEmpty {
                                        Text(item.details)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 4)
                                .tag(item.id)
                            }
                        }
                        .listStyle(.plain)
                    }
                }
                .frame(minWidth: 320, idealWidth: 360)

                CuratorPanel(tint: CuratorStage.usageNotes.theme.secondaryAccent) {
                    if let item = model.selectedUsedItem {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(item.displayCode)
                                        .font(.system(.title2, design: .rounded, weight: .bold))
                                    Text(item.description)
                                        .font(.headline)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("Record audio here, let OpenAI transcribe it, and then clean that raw transcript into a structured note.")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 8) {
                                    CapsuleBadge(text: "Row \(item.sourceRow)", tint: CuratorStage.usageNotes.theme.secondaryAccent)
                                    CapsuleBadge(text: item.unit.isEmpty ? "No unit" : item.unit, tint: CuratorStage.usageNotes.theme.accent)
                                }
                            }

                            HSplitView {
                                CuratorPanel(tint: CuratorStage.usageNotes.theme.accent) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            PanelHeader(
                                                eyebrow: "Saved Notes",
                                                title: "Usage scenarios",
                                                subtitle: "Capture multiple ways this line item gets used in the field."
                                            )
                                            Spacer()
                                            Button("New Note") {
                                                model.startNewUsageNote()
                                            }
                                            .buttonStyle(.bordered)
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
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text(note.title)
                                                        .font(.headline)
                                                    if !note.tags.isEmpty {
                                                        Text(note.tags)
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    if !note.whenToUse.isEmpty {
                                                        Text(note.whenToUse)
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                            .lineLimit(2)
                                                    }
                                                }
                                                .padding(.vertical, 4)
                                                .tag(note.id)
                                            }
                                        }
                                        .listStyle(.plain)
                                    }
                                }
                                .frame(minWidth: 250, idealWidth: 290)

                                CuratorPanel(tint: CuratorStage.usageNotes.theme.secondaryAccent) {
                                    VStack(alignment: .leading, spacing: 14) {
                                        TextField("Note title", text: $model.scenarioDraft.title)
                                            .textFieldStyle(.roundedBorder)
                                        TextField("Tags", text: $model.scenarioDraft.tags)
                                            .textFieldStyle(.roundedBorder)

                                        HStack {
                                            Label(
                                                model.llmSettings.hasTranscriptionConfiguration ? "Transcription ready" : "Transcription not configured",
                                                systemImage: model.llmSettings.hasTranscriptionConfiguration ? "waveform.badge.mic" : "exclamationmark.triangle"
                                            )
                                            .foregroundStyle(model.llmSettings.hasTranscriptionConfiguration ? CuratorStage.usageNotes.theme.accent : .orange)

                                            Spacer()

                                            if model.isRecordingTranscript {
                                                Button("Stop & Transcribe") {
                                                    model.toggleTranscriptRecording()
                                                }
                                                .buttonStyle(.borderedProminent)
                                            } else {
                                                Button("Record Transcript") {
                                                    model.toggleTranscriptRecording()
                                                }
                                                .buttonStyle(.bordered)
                                            }

                                            Button("Clean Transcript with LLM") {
                                                model.cleanTranscriptWithLLM()
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        SurfaceEditor(title: "Raw voice transcript", text: $model.scenarioDraft.transcript, tint: CuratorStage.usageNotes.theme.accent)
                                        SurfaceEditor(title: "Cleaned usage description", text: $model.scenarioDraft.cleanedDescription, tint: CuratorStage.usageNotes.theme.secondaryAccent)
                                        SurfaceEditor(title: "AI hint", text: $model.scenarioDraft.aiHint, tint: CuratorStage.usageNotes.theme.accent)

                                        HStack(spacing: 12) {
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
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "No used item selected",
                            systemImage: "note.text",
                            description: Text("After your quick review pass, used items will appear here for a deeper scenario pass.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 740)
            }
        }
    }
}

private struct LLMSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings: LLMSettings
    let onSave: (LLMSettings) -> Void

    init(initialSettings: LLMSettings, onSave: @escaping (LLMSettings) -> Void) {
        _settings = State(initialValue: initialSettings)
        self.onSave = onSave
    }

    var body: some View {
        ZStack {
            StageBackdrop(stage: .usageNotes)

            VStack(alignment: .leading, spacing: 18) {
                StageHeroCard(
                    stage: .usageNotes,
                    eyebrow: "OpenAI Configuration",
                    title: "Voice transcription and cleanup",
                    subtitle: "The app records audio locally, sends the file to OpenAI transcription, and then uses a cleanup model to turn the raw transcript into a structured usage note.",
                    metrics: [
                        .init(label: "Transcription", value: settings.transcriptionModel.isEmpty ? "Unset" : settings.transcriptionModel),
                        .init(label: "Cleanup", value: settings.cleanupModel.isEmpty ? "Unset" : settings.cleanupModel),
                        .init(label: "API Key", value: settings.apiKey.isEmpty ? "Missing" : "Saved")
                    ]
                )

                CuratorPanel(tint: CuratorStage.usageNotes.theme.secondaryAccent) {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("OpenAI Base URL", text: $settings.baseURL)
                            .textFieldStyle(.roundedBorder)
                        SecureField("API Key", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                        TextField("Transcription Model (use whisper-1 for Whisper)", text: $settings.transcriptionModel)
                            .textFieldStyle(.roundedBorder)
                        TextField("Cleanup Model", text: $settings.cleanupModel)
                            .textFieldStyle(.roundedBorder)

                        InfoBadge(
                            title: "Model note",
                            value: "As of March 21, 2026, OpenAI's Whisper API model is whisper-1. Newer non-Whisper transcription models include gpt-4o-transcribe and gpt-4o-mini-transcribe.",
                            tint: CuratorStage.usageNotes.theme.accent
                        )

                        SurfaceEditor(title: "System Prompt", text: $settings.systemPrompt, tint: CuratorStage.usageNotes.theme.secondaryAccent, minHeight: 200)

                        HStack {
                            Spacer()
                            Button("Cancel") {
                                dismiss()
                            }
                            Button("Save") {
                                onSave(settings)
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}

private struct StageHeroMetric: Hashable {
    let label: String
    let value: String
}

private struct StageHeroCard: View {
    let stage: CuratorStage
    let eyebrow: String
    let title: String
    let subtitle: String
    let metrics: [StageHeroMetric]

    var body: some View {
        let theme = stage.theme

        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [theme.accent.opacity(0.95), theme.secondaryAccent.opacity(0.9)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 54, height: 54)

                        Image(systemName: stage.theme.symbol)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(eyebrow)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(title)
                            .font(.system(size: 30, weight: .black, design: .rounded))
                    }
                }

                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 18)

            HStack(spacing: 12) {
                ForEach(metrics, id: \.self) { metric in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metric.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(metric.value)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white.opacity(0.56))
                    )
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.accent.opacity(0.28),
                            theme.secondaryAccent.opacity(0.16),
                            Color.white.opacity(0.56)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: theme.accent.opacity(0.10), radius: 24, y: 12)
    }
}

private struct CuratorPanel<Content: View>: View {
    let tint: Color
    @ViewBuilder var content: Content

    init(tint: Color, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(tint.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: tint.opacity(0.10), radius: 20, y: 10)
    }
}

private struct PanelHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 42, height: 42)
                Image(systemName: symbol)
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct MetricStrip: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.headline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.10))
        )
    }
}

private struct InfoBadge: View {
    let title: String
    let value: String
    let tint: Color
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.10))
        )
    }
}

private struct CapsuleBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

private struct ShortcutBadge: View {
    let key: String
    let action: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(.body, design: .rounded, weight: .bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.14))
                )
            Text(action)
                .font(.body.weight(.medium))
        }
    }
}

private struct ChecklistRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}

private struct PreviewRowCard: View {
    let index: Int
    let headers: [String]
    let row: [String: String]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Row \(index)")
                    .font(.headline)
                Spacer()
                CapsuleBadge(text: "\(headers.count) fields", tint: tint)
            }

            ForEach(headers, id: \.self) { header in
                HStack(alignment: .top, spacing: 12) {
                    Text(header)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Text(row[header] ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.08))
        )
    }
}

private struct DetailSurface<Content: View>: View {
    let title: String
    let tint: Color
    @ViewBuilder let content: Content

    init(title: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            ScrollView {
                content
            }
            .frame(maxHeight: 240)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(tint.opacity(0.08))
            )
        }
    }
}

private struct SurfaceEditor: View {
    let title: String
    @Binding var text: String
    let tint: Color
    var minHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: minHeight)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(tint.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(tint.opacity(0.12), lineWidth: 1)
                )
        }
    }
}

private struct StageBackdrop: View {
    let stage: CuratorStage

    var body: some View {
        let theme = stage.theme

        ZStack {
            LinearGradient(
                colors: [
                    Color(NSColor.windowBackgroundColor),
                    theme.accent.opacity(0.10),
                    theme.secondaryAccent.opacity(0.08),
                    Color(NSColor.underPageBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(theme.accent.opacity(0.18))
                .frame(width: 480, height: 480)
                .blur(radius: 90)
                .offset(x: -360, y: -220)

            Circle()
                .fill(theme.secondaryAccent.opacity(0.15))
                .frame(width: 380, height: 380)
                .blur(radius: 90)
                .offset(x: 360, y: 260)
        }
        .animation(.easeInOut(duration: 0.28), value: stage)
    }
}

private struct StageTheme {
    let accent: Color
    let secondaryAccent: Color
    let symbol: String
}

private extension CuratorStage {
    var theme: StageTheme {
        switch self {
        case .importData:
            return StageTheme(
                accent: Color(red: 0.08, green: 0.53, blue: 0.56),
                secondaryAccent: Color(red: 0.84, green: 0.59, blue: 0.18),
                symbol: "tray.and.arrow.down.fill"
            )
        case .quickReview:
            return StageTheme(
                accent: Color(red: 0.78, green: 0.36, blue: 0.18),
                secondaryAccent: Color(red: 0.63, green: 0.17, blue: 0.21),
                symbol: "bolt.fill"
            )
        case .usageNotes:
            return StageTheme(
                accent: Color(red: 0.13, green: 0.39, blue: 0.78),
                secondaryAccent: Color(red: 0.06, green: 0.62, blue: 0.67),
                symbol: "waveform.badge.mic"
            )
        }
    }
}
