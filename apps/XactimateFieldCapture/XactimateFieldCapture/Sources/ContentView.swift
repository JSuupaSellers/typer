import SwiftUI

private enum WorkspaceSurface: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case scope = "Scope"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var model = FieldCaptureAppModel()
    @State private var showingPublishConfirm = false
    @State private var showingSettings = false
    @State private var selectedSurface: WorkspaceSurface = .chat

    private let ink = Color(red: 0.11, green: 0.13, blue: 0.18)
    private let mutedInk = Color(red: 0.42, green: 0.47, blue: 0.54)
    private let accent = Color(red: 0.12, green: 0.45, blue: 0.36)
    private let accentWash = Color(red: 0.90, green: 0.96, blue: 0.93)
    private let userBubbleBg = Color(red: 0.95, green: 0.95, blue: 0.97)
    private let cardStroke = Color.black.opacity(0.08)
    private let rejectedTint = Color(red: 0.94, green: 0.95, blue: 0.97)

    var body: some View {
        NavigationStack {
            Group {
                if model.draft != nil {
                    switch selectedSurface {
                    case .chat:
                        chatView
                    case .scope:
                        scopeView
                    }
                } else {
                    emptyStateView
                }
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.showingClaims = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(ink)
                    }
                }

                ToolbarItem(placement: .principal) {
                    if model.draft != nil {
                        Picker("Surface", selection: $selectedSurface) {
                            ForEach(WorkspaceSurface.allCases) { surface in
                                Text(surface.rawValue).tag(surface)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    } else {
                        Text("Field Capture")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(ink)
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(mutedInk)
                    }

                    Button {
                        Task { await model.startNewClaim() }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(ink)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                composerBar
            }
            .sheet(isPresented: $model.showingClaims) {
                claimsSheet
            }
            .sheet(isPresented: $showingSettings) {
                settingsSheet
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .alert("Publish this draft to the bridge?", isPresented: $showingPublishConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Publish") {
                    Task { await model.publishDraft() }
                }
            } message: {
                Text("This will queue the currently accepted room items for the Raspberry Pi bridge.")
            }
            .overlay {
                if !model.busyMessage.isEmpty {
                    busyOverlay
                }
            }
            .task {
                await model.loadClaims(silently: true)
            }
        }
    }

    // MARK: - Chat

    private var chatView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 20) {
                if !model.transcript.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 13))
                            .foregroundStyle(accent)
                        Text(model.transcript)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(mutedInk)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(accentWash.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let messages = model.draft?.messages, !messages.isEmpty {
                    ForEach(messages) { message in
                        messageRow(message)
                    }
                }

                if let pending = model.activePendingTurn {
                    HStack {
                        Spacer(minLength: 60)
                        Text(pending.submittedText)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(ink)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(userBubbleBg, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(accent)
                            .scaleEffect(0.85)
                        Text(pending.statusText)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(mutedInk)
                        Spacer()
                    }
                    .padding(.leading, 4)
                }

                if (model.draft?.messages ?? []).isEmpty && model.activePendingTurn == nil {
                    chatEmptyState
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
        .refreshable {
            await model.refreshDraft()
        }
    }

    @ViewBuilder
    private func messageRow(_ message: DraftMessagePayload) -> some View {
        if message.role == "assistant" {
            HStack {
                Text(message.text)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(ink)
                    .textSelection(.enabled)
                Spacer(minLength: 60)
            }
            .padding(.leading, 4)
        } else {
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(userBubbleBg, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private var chatEmptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 80)
            Image(systemName: "message")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(mutedInk.opacity(0.4))
            Text("Start a conversation")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(ink)
            Text("Describe a room, correction, or missing scope.")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(mutedInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Empty State (no draft)

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(mutedInk.opacity(0.4))
            Text("No claim open")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(ink)
            Text("Open a claim to start capturing scope.")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(mutedInk)

            Button {
                Task { await model.openDraft() }
            } label: {
                Text("Open Claim")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(accent, in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!model.canOpenDraft)
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Scope

    private var scopeView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    scopeActionButton("Accept All", icon: "checkmark.circle", style: .outline) {
                        Task { await model.acceptAll() }
                    }
                    .disabled(!model.canAcceptAll)

                    scopeActionButton("Plan", icon: "bolt.horizontal.circle", style: .filled) {
                        Task { await model.planDraft() }
                    }
                    .disabled(!model.canPlan)

                    scopeActionButton("Publish", icon: "paperplane.fill", style: .dark) {
                        showingPublishConfirm = true
                    }
                    .disabled(!model.canPublish)
                }

                if let plan = model.planResponse {
                    HStack(spacing: 8) {
                        Image(systemName: "checklist")
                            .foregroundStyle(accent)
                        Text(planSummaryText(plan))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(ink)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(accentWash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let publish = model.publishResponse {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(accent)
                        Text("Queued \(publish.commandCount) commands (seq \(publish.startingSeq)-\(publish.endingSeq))")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(ink)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(accentWash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if model.rooms.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.rooms, id: \.self) { room in
                                Button(room) {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                        model.selectedRoom = room
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(model.selectedRoom == room ? .white : ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(model.selectedRoom == room ? accent : Color(.systemGray6))
                                )
                            }
                        }
                    }
                }

                if model.filteredSections.isEmpty {
                    VStack(spacing: 10) {
                        Spacer().frame(height: 40)
                        Image(systemName: "square.stack.3d.down.right")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(mutedInk.opacity(0.4))
                        Text("No scoped sections yet")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(ink)
                        Text("Keep talking through the loss and sections will appear here.")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(mutedInk)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(model.filteredSections) { group in
                        scopeGroupCard(group)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 100)
        }
        .refreshable {
            await model.refreshDraft()
        }
    }

    private enum ScopeButtonStyle { case outline, filled, dark }

    private func scopeActionButton(
        _ title: String,
        icon: String,
        style: ScopeButtonStyle,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(style == .outline ? ink : .white)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(style == .filled ? accent : (style == .dark ? ink : Color(.systemGray6)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(style == .outline ? cardStroke : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Composer

    private var composerBar: some View {
        VStack(spacing: 8) {
            if model.audioFileURL != nil {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(accent)
                        .font(.system(size: 14))
                    Text("Voice clip ready")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(mutedInk)
                    Spacer()
                    Button("Send") {
                        Task { await model.sendVoiceTurn() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .disabled(!model.canSendVoice)

                    Button {
                        model.audioFileURL = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(mutedInk.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    Task { await model.toggleRecording() }
                } label: {
                    Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(model.isRecording ? .white : mutedInk)
                        .frame(width: 36, height: 36)
                        .background(
                            model.isRecording ? Color.red : Color(.systemGray5),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)

                TextField("Message...", text: $model.messageDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(ink)
                    .lineLimit(1 ... 5)
                    .padding(.vertical, 10)

                Button {
                    Task { await model.sendTextTurn() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            model.canSendText ? ink : Color(.systemGray4),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!model.canSendText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.systemGray6))
            )
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Scope Group Card

    private func scopeGroupCard(_ group: DraftSectionPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.room)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(ink)
                    Text(group.note.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                        .kerning(0.6)
                }
                Spacer()
                Text("\(group.items.count) items")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(mutedInk)
            }

            ForEach(group.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.approvedCode)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(accent)
                            Text(item.description)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(ink)
                            let details = detailLine(for: item)
                            if !details.isEmpty {
                                Text(details)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(mutedInk)
                            }
                        }
                        Spacer(minLength: 8)
                        statusBadge(item.status)
                    }

                    if !item.rationale.trimmed.isEmpty {
                        Text(item.rationale)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(mutedInk)
                    }

                    HStack(spacing: 8) {
                        actionChip("Accept", isActive: item.status == "accepted", tint: accent) {
                            Task { await model.setItemStatus(item.id, status: "accepted") }
                        }
                        .disabled(model.activePendingTurn != nil)

                        actionChip("Reject", isActive: item.status == "rejected", tint: mutedInk) {
                            Task { await model.setItemStatus(item.id, status: "rejected") }
                        }
                        .disabled(model.activePendingTurn != nil)
                    }
                }
                .padding(14)
                .background(Color(.systemGray6).opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(item.status == "accepted" ? accent.opacity(0.2) : cardStroke, lineWidth: 1)
                )
            }
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(cardStroke, lineWidth: 1)
        )
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status.capitalized)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(status == "accepted" ? accent : ink.opacity(0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                status == "accepted" ? accentWash : (status == "rejected" ? rejectedTint : Color(.systemGray6)),
                in: Capsule(style: .continuous)
            )
    }

    private func actionChip(
        _ title: String,
        isActive: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isActive ? tint.opacity(0.12) : Color(.systemGray6), in: Capsule(style: .continuous))
    }

    // MARK: - Sheets

    private var claimsSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    if model.claimSummaries.isEmpty {
                        VStack(spacing: 10) {
                            Spacer().frame(height: 40)
                            Image(systemName: "tray")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(mutedInk.opacity(0.4))
                            Text("No saved claims")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(ink)
                            Text("Open a claim and it will appear here.")
                                .font(.system(size: 14))
                                .foregroundStyle(mutedInk)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(model.claimSummaries) { summary in
                            Button {
                                Task { await model.switchToClaim(summary) }
                            } label: {
                                claimListRow(summary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Claims")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { model.showingClaims = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New") {
                        model.showingClaims = false
                        Task { await model.startNewClaim() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Backend URL", text: $model.backendBaseURL)
                        .textInputAutocapitalization(.never)
                    SecureField("Producer API Key", text: $model.backendAPIKey)
                        .textInputAutocapitalization(.never)
                }

                Section("Current Claim") {
                    TextField("Job ID", text: $model.jobID)
                        .textInputAutocapitalization(.never)
                    TextField("Bridge ID", text: $model.bridgeID)
                        .textInputAutocapitalization(.never)
                }

                Section("Actions") {
                    Button(model.draft == nil ? "Open Claim" : "Refresh Draft") {
                        Task {
                            if model.draft == nil {
                                await model.openDraft()
                            } else {
                                await model.refreshDraft()
                            }
                        }
                    }
                    .disabled(!model.canOpenDraft)

                    Button("Load Claims") {
                        Task { await model.loadClaims() }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingSettings = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Overlays

    private var busyOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(accent)
            Text(model.busyMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ink)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Claim List Row

    private func claimListRow(_ summary: ClaimSummaryPayload) -> some View {
        let isCurrent = summary.jobId == model.jobID.trimmed

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(summary.jobId)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink)
                    if isCurrent {
                        Text("Active")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(accentWash, in: Capsule())
                    }
                }
                Text(summary.latestMessagePreview.isEmpty ? "No conversation yet." : summary.latestMessagePreview)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(mutedInk)
                    .lineLimit(2)
                Text("\(summary.roomCount) rooms  \u{2022}  \(summary.itemCount) items  \u{2022}  \(summary.messageCount) turns")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(mutedInk.opacity(0.7))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(mutedInk.opacity(0.4))
        }
        .padding(16)
        .background(Color(.systemGray6).opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Helpers

    private func detailLine(for item: DraftLineItemPayload) -> String {
        [
            item.surface,
            item.damageType,
            item.activity.isEmpty ? "" : "Act \(item.activity)",
            item.quantity.isEmpty ? "" : "Qty \(item.quantity)",
        ]
        .map(\.trimmed)
        .filter { !$0.isEmpty }
        .joined(separator: " \u{2022} ")
    }

    private func planSummaryText(_ plan: PlanResponse) -> String {
        if plan.unresolvedCount > 0 { return "\(plan.unresolvedCount) unresolved" }
        if plan.needsReviewCount > 0 { return "\(plan.needsReviewCount) need review" }
        return "Ready to publish"
    }
}
