import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: CuratorAppModel
    @State private var isImporterPresented = false
    @State private var isPhotoImporterPresented = false
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

                EstimatePhotosStageView(isPhotoImporterPresented: $isPhotoImporterPresented)
                    .tabItem { Label("Estimate Photos", systemImage: "photo.on.rectangle.angled") }
                    .tag(CuratorStage.estimatePhotos)

                RecommendationStageView()
                    .tabItem { Label("Recommend", systemImage: "text.magnifyingglass") }
                    .tag(CuratorStage.recommendations)
            }
            .padding(20)
            .frame(minWidth: 1220, minHeight: 780)
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
                if model.selectedStage == .importData {
                    Button("Choose Workbook") {
                        isImporterPresented = true
                    }
                    .disabled(model.isBusy)
                }

                if model.selectedStage == .estimatePhotos {
                    Button("Choose Estimate Photos") {
                        isPhotoImporterPresented = true
                    }
                    .disabled(model.isBusy || model.isScanningEstimatePhotos)
                }

                Button("Export Curated JSON") {
                    model.exportCuratedJSON()
                }
                .disabled(model.isBusy || model.isScanningEstimatePhotos || model.stats.usedItems == 0)

                Button("AI Settings") {
                    isLLMSettingsPresented = true
                }
                .disabled(model.isBusy || model.isScanningEstimatePhotos)
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
        .fileImporter(
            isPresented: $isPhotoImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                model.chooseEstimatePhotos(urls)
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

private struct EstimatePhotosStageView: View {
    @EnvironmentObject private var model: CuratorAppModel
    @Binding var isPhotoImporterPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StageHeroCard(
                stage: .estimatePhotos,
                eyebrow: "Stage 4",
                title: "Mine Existing Estimates",
                subtitle: "Load batches of estimate photos, let Gemini read the visible CAT/SEL pairs, deduplicate them across the set, and automatically mark matching catalog items as used.",
                metrics: [
                    .init(label: "Photos", value: "\(model.photoScanSummary.totalPhotos)"),
                    .init(label: "Processed", value: "\(model.photoScanSummary.processedPhotos)"),
                    .init(label: "Unique Codes", value: "\(model.photoScanSummary.uniqueCodes.count)"),
                    .init(label: "Marked Used", value: "\(model.photoScanSummary.newlyMarkedItems)")
                ]
            )

            HSplitView {
                CuratorPanel(tint: CuratorStage.estimatePhotos.theme.accent) {
                    VStack(alignment: .leading, spacing: 16) {
                        PanelHeader(
                            eyebrow: "Batch Input",
                            title: "Estimate photo set",
                            subtitle: "This works best on straight-on estimate screenshots or document photos where CAT and SEL columns are readable. Each image is sent to Gemini individually."
                        )

                        HStack(spacing: 12) {
                            Button {
                                isPhotoImporterPresented = true
                            } label: {
                                Label("Choose Photos", systemImage: "photo.badge.plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(model.isScanningEstimatePhotos)

                            Button {
                                model.analyzeSelectedEstimatePhotos()
                            } label: {
                                Label(model.isScanningEstimatePhotos ? "Scanning..." : "Analyze and Mark Used", systemImage: "sparkles.rectangle.stack")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(model.estimatePhotoURLs.isEmpty || model.isScanningEstimatePhotos)
                        }

                        HStack {
                            Button("Clear Session") {
                                model.clearEstimatePhotoSelection()
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.estimatePhotoURLs.isEmpty || model.isScanningEstimatePhotos)

                            Spacer()

                            Label(
                                model.llmSettings.hasVisionConfiguration ? "Gemini ready" : "Gemini not configured",
                                systemImage: model.llmSettings.hasVisionConfiguration ? "eye" : "exclamationmark.triangle"
                            )
                            .foregroundStyle(model.llmSettings.hasVisionConfiguration ? CuratorStage.estimatePhotos.theme.accent : .orange)
                        }

                        MetricStrip(
                            title: "Selected photos",
                            value: "\(model.estimatePhotoURLs.count)",
                            tint: CuratorStage.estimatePhotos.theme.secondaryAccent
                        )

                        if model.photoScanSummary.totalPhotos > 0 {
                            ProgressView(
                                value: Double(model.photoScanSummary.processedPhotos),
                                total: Double(max(model.photoScanSummary.totalPhotos, 1))
                            ) {
                                Text("Batch progress")
                            } currentValueLabel: {
                                Text("\(model.photoScanSummary.processedPhotos) / \(model.photoScanSummary.totalPhotos)")
                            }
                        }

                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(model.estimatePhotoURLs, id: \.self) { url in
                                    Text(url.lastPathComponent)
                                        .font(.callout)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(CuratorStage.estimatePhotos.theme.accent.opacity(0.08))
                                        )
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: 300, idealWidth: 340)

                CuratorPanel(tint: CuratorStage.estimatePhotos.theme.secondaryAccent) {
                    VStack(alignment: .leading, spacing: 16) {
                        PanelHeader(
                            eyebrow: "Per Photo",
                            title: "Scan results",
                            subtitle: "Each photo is analyzed individually with Gemini so batches can scale to large estimate sets without one bad image blocking the whole run."
                        )

                        if model.photoScanEntries.isEmpty {
                            ContentUnavailableView(
                                "No estimate photos loaded",
                                systemImage: "photo.on.rectangle",
                                description: Text("Choose a batch of photos to start mining CAT/SEL pairs.")
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(model.photoScanEntries) { entry in
                                        PhotoScanEntryCard(entry: entry, tint: CuratorStage.estimatePhotos.theme.accent)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: 430)

                CuratorPanel(tint: CuratorStage.estimatePhotos.theme.accent) {
                    VStack(alignment: .leading, spacing: 16) {
                        PanelHeader(
                            eyebrow: "Auto Marking",
                            title: "Catalog updates",
                            subtitle: "After the batch finishes, matching CAT/SEL pairs are marked as used automatically. Any unmatched codes stay visible here for cleanup."
                        )

                        HStack(spacing: 12) {
                            MetricCard(title: "Matched", value: "\(model.photoScanSummary.matchedItems)", symbol: "link", tint: CuratorStage.estimatePhotos.theme.accent)
                            MetricCard(title: "Newly Marked", value: "\(model.photoScanSummary.newlyMarkedItems)", symbol: "checkmark.circle", tint: CuratorStage.estimatePhotos.theme.secondaryAccent)
                        }

                        HStack(spacing: 12) {
                            MetricCard(title: "Already Used", value: "\(model.photoScanSummary.alreadyUsedItems)", symbol: "arrow.triangle.2.circlepath", tint: CuratorStage.estimatePhotos.theme.secondaryAccent)
                            MetricCard(title: "Failed Photos", value: "\(model.photoScanSummary.failedPhotos)", symbol: "exclamationmark.triangle", tint: CuratorStage.estimatePhotos.theme.accent)
                        }

                        DetailSurface(title: "Unique CAT/SEL pairs", tint: CuratorStage.estimatePhotos.theme.secondaryAccent) {
                            if model.photoScanSummary.uniqueCodes.isEmpty {
                                Text("No CAT/SEL pairs have been extracted yet.")
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(model.photoScanSummary.uniqueCodes, id: \.self) { code in
                                        Text(code.displayCode)
                                            .font(.system(.body, design: .monospaced, weight: .medium))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }

                        DetailSurface(title: "Unmatched codes", tint: CuratorStage.estimatePhotos.theme.accent) {
                            if model.photoScanSummary.unmatchedCodes.isEmpty {
                                Text("No unmatched codes right now.")
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(model.photoScanSummary.unmatchedCodes, id: \.self) { code in
                                        Text(code.displayCode)
                                            .font(.system(.body, design: .monospaced, weight: .medium))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: 320, idealWidth: 340)
            }
        }
    }
}

private struct RecommendationStageView: View {
    @EnvironmentObject private var model: CuratorAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StageHeroCard(
                stage: .recommendations,
                eyebrow: "Stage 5",
                title: "Recommendation Sandbox",
                subtitle: "Describe the scope the way you would in the field, and the app ranks CAT/SEL candidates from your curated playbook using structured scenarios plus feedback from your past accepts and rejects.",
                metrics: [
                    .init(label: "Used Items", value: "\(model.stats.usedItems)"),
                    .init(label: "Scenarios", value: "\(model.stats.usageNoteCount)"),
                    .init(label: "Candidates", value: "\(model.recommendationResults.count)"),
                    .init(label: "Top Match", value: model.selectedRecommendation?.item.displayCode ?? "Waiting")
                ]
            )

            HSplitView {
                CuratorPanel(tint: CuratorStage.recommendations.theme.accent) {
                    VStack(alignment: .leading, spacing: 16) {
                        PanelHeader(
                            eyebrow: "Scope Intake",
                            title: "Describe the estimate need",
                            subtitle: "Use the structured fields when you know them, then add a freeform narrative the same way you would explain the room out loud."
                        )

                        HStack(spacing: 12) {
                            TextField("Room / area", text: $model.recommendationQuery.room)
                                .textFieldStyle(.roundedBorder)
                            TextField("Surface", text: $model.recommendationQuery.surface)
                                .textFieldStyle(.roundedBorder)
                            TextField("Damage / repair type", text: $model.recommendationQuery.damageType)
                                .textFieldStyle(.roundedBorder)
                        }

                        TextField("Keywords or estimator shorthand", text: $model.recommendationQuery.keywords)
                            .textFieldStyle(.roundedBorder)

                        Stepper(value: $model.recommendationQuery.maxResults, in: 3 ... 10) {
                            Text("Show top \(model.recommendationQuery.maxResults) candidates")
                        }

                        SurfaceEditor(
                            title: "Narrative",
                            text: $model.recommendationQuery.narrative,
                            tint: CuratorStage.recommendations.theme.secondaryAccent,
                            minHeight: 220
                        )

                        HStack(spacing: 12) {
                            Button {
                                model.runRecommendations()
                            } label: {
                                Label("Rank Candidates", systemImage: "text.magnifyingglass")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)

                            Button("Clear Query") {
                                model.clearRecommendationQuery()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }

                        InfoBadge(
                            title: "How ranking works",
                            value: "Structured room, surface, damage type, tags, keywords, synonyms, cleaned usage notes, and past accept/reject feedback all contribute to the score.",
                            tint: CuratorStage.recommendations.theme.accent
                        )
                    }
                }
                .frame(minWidth: 320, idealWidth: 360)

                CuratorPanel(tint: CuratorStage.recommendations.theme.secondaryAccent) {
                    VStack(alignment: .leading, spacing: 16) {
                        PanelHeader(
                            eyebrow: "Ranked Matches",
                            title: "Top candidates",
                            subtitle: "These results come from the used-item set only, so the sandbox stays aligned to your real estimating workflow."
                        )

                        if model.recommendationResults.isEmpty {
                            ContentUnavailableView(
                                "No ranked candidates yet",
                                systemImage: "text.magnifyingglass",
                                description: Text("Run a recommendation query to see the strongest CAT/SEL matches from your curated catalog.")
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(model.recommendationResults) { candidate in
                                        RecommendationCandidateCard(
                                            candidate: candidate,
                                            isSelected: candidate.id == model.selectedRecommendation?.id,
                                            tint: CuratorStage.recommendations.theme.accent,
                                            secondaryTint: CuratorStage.recommendations.theme.secondaryAccent,
                                            onSelect: { model.selectRecommendation(id: candidate.id) },
                                            onFeedback: { decision in
                                                model.applyRecommendationFeedback(decision, for: candidate.id)
                                            }
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: 420)

                CuratorPanel(tint: CuratorStage.recommendations.theme.accent) {
                    VStack(alignment: .leading, spacing: 16) {
                        PanelHeader(
                            eyebrow: "Why It Matched",
                            title: model.selectedRecommendation?.item.displayCode ?? "Recommendation detail",
                            subtitle: "Inspect the reasoning, the saved scenario signals, and the feedback counts before you trust a suggestion."
                        )

                        if let candidate = model.selectedRecommendation {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(candidate.item.description)
                                            .font(.system(.title3, design: .rounded, weight: .bold))
                                        if !candidate.item.details.isEmpty {
                                            Text(candidate.item.details)
                                                .foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 8) {
                                        RecommendationConfidenceBadge(confidence: candidate.confidence, tint: CuratorStage.recommendations.theme.accent)
                                        CapsuleBadge(text: candidate.item.unit.isEmpty ? "No unit" : candidate.item.unit, tint: CuratorStage.recommendations.theme.secondaryAccent)
                                    }
                                }

                                HStack(spacing: 12) {
                                    MetricCard(title: "Score", value: String(format: "%.1f", candidate.score), symbol: "dial.medium", tint: CuratorStage.recommendations.theme.accent)
                                    MetricCard(title: "Accepted", value: "\(candidate.acceptedCount)", symbol: "hand.thumbsup", tint: CuratorStage.recommendations.theme.secondaryAccent)
                                    MetricCard(title: "Rejected", value: "\(candidate.rejectedCount)", symbol: "hand.thumbsdown", tint: CuratorStage.recommendations.theme.accent)
                                }

                                DetailSurface(title: "Why it rose to the top", tint: CuratorStage.recommendations.theme.accent) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(candidate.reasons, id: \.self) { reason in
                                            Text("• \(reason)")
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }

                                DetailSurface(title: "Matched terms", tint: CuratorStage.recommendations.theme.secondaryAccent) {
                                    if candidate.matchedTerms.isEmpty {
                                        Text("No matched terms were captured for this result.")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        WrapTagCloud(terms: candidate.matchedTerms, tint: CuratorStage.recommendations.theme.secondaryAccent)
                                    }
                                }

                                DetailSurface(title: "Saved scenarios", tint: CuratorStage.recommendations.theme.accent) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        if candidate.highlights.isEmpty {
                                            Text("This item does not have a saved scenario yet, so the score came mostly from the item text and prior feedback.")
                                                .foregroundStyle(.secondary)
                                        } else {
                                            ForEach(candidate.highlights) { highlight in
                                                RecommendationScenarioHighlightCard(
                                                    highlight: highlight,
                                                    tint: CuratorStage.recommendations.theme.secondaryAccent
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            ContentUnavailableView(
                                "Select a recommendation",
                                systemImage: "sparkles",
                                description: Text("When results appear, pick one to inspect its supporting scenarios and feedback history.")
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(minWidth: 360, idealWidth: 400)
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
                    subtitle: "Record how you actually use each line item, let OpenAI transcribe the raw explanation, and turn it into structured guidance that can power later recommendations.",
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

                                        HStack(spacing: 12) {
                                            TextField("Room / area", text: $model.scenarioDraft.room)
                                                .textFieldStyle(.roundedBorder)
                                            TextField("Surface", text: $model.scenarioDraft.surface)
                                                .textFieldStyle(.roundedBorder)
                                            TextField("Damage / repair type", text: $model.scenarioDraft.damageType)
                                                .textFieldStyle(.roundedBorder)
                                        }

                                        TextField("Keywords", text: $model.scenarioDraft.keywords)
                                            .textFieldStyle(.roundedBorder)
                                        TextField("Synonyms / shorthand", text: $model.scenarioDraft.synonyms)
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
                                        SurfaceEditor(title: "When not to use", text: $model.scenarioDraft.whenNotToUse, tint: CuratorStage.usageNotes.theme.accent, minHeight: 110)
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
                    eyebrow: "AI Configuration",
                    title: "Vision, voice, and cleanup",
                    subtitle: "The app analyzes estimate photos with Gemini, then uses OpenAI for voice transcription and transcript cleanup.",
                    metrics: [
                        .init(label: "Gemini", value: settings.estimatePhotoModel.isEmpty ? "Unset" : settings.estimatePhotoModel),
                        .init(label: "Transcription", value: settings.transcriptionModel.isEmpty ? "Unset" : settings.transcriptionModel),
                        .init(label: "Cleanup", value: settings.cleanupModel.isEmpty ? "Unset" : settings.cleanupModel),
                        .init(label: "OpenAI Key", value: settings.apiKey.isEmpty ? "Missing" : "Saved")
                    ]
                )

                CuratorPanel(tint: CuratorStage.usageNotes.theme.secondaryAccent) {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("OpenAI Base URL", text: $settings.baseURL)
                            .textFieldStyle(.roundedBorder)
                        SecureField("OpenAI API Key", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Gemini API Key", text: $settings.geminiAPIKey)
                            .textFieldStyle(.roundedBorder)
                        TextField("Estimate Photo Model", text: $settings.estimatePhotoModel)
                            .textFieldStyle(.roundedBorder)
                        TextField("Transcription Model (use whisper-1 for Whisper)", text: $settings.transcriptionModel)
                            .textFieldStyle(.roundedBorder)
                        TextField("Cleanup Model", text: $settings.cleanupModel)
                            .textFieldStyle(.roundedBorder)

                        InfoBadge(
                            title: "Model note",
                            value: "As of March 21, 2026, Google exposes Gemini 3 series model IDs like gemini-3-flash-preview and gemini-3.1-flash-lite-preview, not a literal model id named gemini-3.0. This app defaults estimate-photo scanning to gemini-3-flash-preview and keeps OpenAI for Whisper transcription and cleanup.",
                            tint: CuratorStage.usageNotes.theme.accent
                        )

                        SurfaceEditor(title: "Estimate Photo Prompt", text: $settings.estimatePhotoPrompt, tint: CuratorStage.usageNotes.theme.accent, minHeight: 150)
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

private struct PhotoScanEntryCard: View {
    let entry: PhotoScanEntry
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.fileURL.lastPathComponent)
                        .font(.headline)
                    Text(entry.fileURL.deletingLastPathComponent().path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                PhotoScanStatusBadge(status: entry.status, tint: tint)
            }

            if !entry.detectedCodes.isEmpty {
                Text(entry.detectedCodes.map(\.displayCode).joined(separator: ", "))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !entry.note.isEmpty {
                Text(entry.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !entry.errorMessage.isEmpty {
                Text(entry.errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.08))
        )
    }
}

private struct PhotoScanStatusBadge: View {
    let status: PhotoScanStatus
    let tint: Color

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(fillColor))
    }

    private var fillColor: Color {
        switch status {
        case .pending:
            return tint.opacity(0.10)
        case .scanning:
            return Color.orange.opacity(0.18)
        case .completed:
            return Color.green.opacity(0.18)
        case .failed:
            return Color.red.opacity(0.18)
        }
    }
}

private struct RecommendationCandidateCard: View {
    let candidate: RecommendationCandidate
    let isSelected: Bool
    let tint: Color
    let secondaryTint: Color
    let onSelect: () -> Void
    let onFeedback: (RecommendationFeedbackDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.item.displayCode)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    Text(candidate.item.description)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    RecommendationConfidenceBadge(confidence: candidate.confidence, tint: tint)
                    Text(String(format: "%.1f", candidate.score))
                        .font(.system(.headline, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if !candidate.reasons.isEmpty {
                Text(candidate.reasons.prefix(2).joined(separator: " "))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !candidate.matchedTerms.isEmpty {
                WrapTagCloud(terms: Array(candidate.matchedTerms.prefix(6)), tint: secondaryTint)
            }

            HStack(spacing: 10) {
                Button("Inspect") {
                    onSelect()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    onFeedback(.accepted)
                } label: {
                    Label("Accept", systemImage: "hand.thumbsup")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onFeedback(.rejected)
                } label: {
                    Label("Reject", systemImage: "hand.thumbsdown")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isSelected ? tint.opacity(0.14) : secondaryTint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder((isSelected ? tint : secondaryTint).opacity(0.22), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: onSelect)
    }
}

private struct RecommendationConfidenceBadge: View {
    let confidence: RecommendationConfidence
    let tint: Color

    var body: some View {
        Text(confidence.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(fillColor))
    }

    private var fillColor: Color {
        switch confidence {
        case .high:
            return tint.opacity(0.18)
        case .medium:
            return Color.orange.opacity(0.18)
        case .low:
            return Color.gray.opacity(0.16)
        }
    }
}

private struct RecommendationScenarioHighlightCard: View {
    let highlight: RecommendationScenarioHighlight
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(highlight.title)
                        .font(.headline)
                    if !highlight.whenToUse.isEmpty {
                        Text(highlight.whenToUse)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Text(String(format: "%.1f", highlight.score))
                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if !highlight.room.isEmpty {
                    CapsuleBadge(text: "Room: \(highlight.room)", tint: tint)
                }
                if !highlight.surface.isEmpty {
                    CapsuleBadge(text: "Surface: \(highlight.surface)", tint: tint)
                }
                if !highlight.damageType.isEmpty {
                    CapsuleBadge(text: "Damage: \(highlight.damageType)", tint: tint)
                }
            }

            if !highlight.matchedTerms.isEmpty {
                WrapTagCloud(terms: highlight.matchedTerms, tint: tint)
            }

            if !highlight.whenNotToUse.isEmpty {
                Text("Avoid when: \(highlight.whenNotToUse)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !highlight.aiHint.isEmpty {
                Text("AI hint: \(highlight.aiHint)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.08))
        )
    }
}

private struct WrapTagCloud: View {
    let terms: [String]
    let tint: Color

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(terms, id: \.self) { term in
                Text(term)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(
                        Capsule().fill(tint.opacity(0.14))
                    )
            }
        }
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
        case .estimatePhotos:
            return StageTheme(
                accent: Color(red: 0.18, green: 0.47, blue: 0.26),
                secondaryAccent: Color(red: 0.62, green: 0.42, blue: 0.12),
                symbol: "photo.on.rectangle.angled"
            )
        case .recommendations:
            return StageTheme(
                accent: Color(red: 0.14, green: 0.23, blue: 0.46),
                secondaryAccent: Color(red: 0.82, green: 0.38, blue: 0.18),
                symbol: "text.magnifyingglass"
            )
        }
    }
}
