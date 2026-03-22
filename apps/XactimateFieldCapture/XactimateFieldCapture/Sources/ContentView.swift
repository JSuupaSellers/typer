import SwiftUI

struct ContentView: View {
    @StateObject private var model = FieldCaptureAppModel()
    @State private var showingPublishConfirm = false

    private let canvasTop = Color(red: 0.98, green: 0.97, blue: 0.94)
    private let canvasBottom = Color(red: 0.91, green: 0.95, blue: 0.99)
    private let panelFill = Color.white.opacity(0.92)
    private let panelStroke = Color.black.opacity(0.06)
    private let ink = Color(red: 0.10, green: 0.14, blue: 0.18)
    private let accent = Color(red: 0.09, green: 0.46, blue: 0.33)
    private let assistantBubble = Color(red: 0.94, green: 0.96, blue: 0.98)
    private let transcriptTint = Color(red: 0.92, green: 0.97, blue: 0.93)
    private let rejectedTint = Color(red: 0.92, green: 0.92, blue: 0.92)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sessionHeader
                    settingsPanel
                    claimsPanel
                    if model.draft != nil {
                        overviewPanel
                        chatPanel
                        roomFilterPanel
                        roomStackPanel
                        actionPanel
                    } else {
                        emptyStatePanel
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 124)
            }
            .background(background)
            .task {
                await model.loadClaims(silently: true)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.showingClaims = true
                    } label: {
                        Image(systemName: "sidebar.left")
                            .foregroundStyle(ink)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Claim Draft")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.startNewClaim() }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(accent)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                composerBar
            }
            .sheet(isPresented: $model.showingClaims) {
                claimsSheet
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        model.errorMessage = nil
                    }
                }
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
                    ProgressView(model.busyMessage)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: Color.black.opacity(0.14), radius: 24, y: 12)
                }
            }
        }
    }

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Room-by-room estimating")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .foregroundStyle(ink)
                    Text("Talk through the loss, let the backend build the draft, then review sections before they reach the Pi.")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.opacity(0.72))
                }
                Spacer(minLength: 12)
                statusPill(label: model.draft == nil ? "Idle" : "Live Draft", systemImage: model.draft == nil ? "circle.dashed" : "bolt.fill")
            }

            if let summary = model.currentClaimSummary {
                HStack(spacing: 10) {
                    Text(summary.jobId)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(ink)
                    Text("\(summary.roomCount) rooms")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink.opacity(0.55))
                    Text("\(summary.itemCount) items")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink.opacity(0.55))
                }
            }

            if let publish = model.publishResponse {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(accent)
                    Text("Queued \(publish.commandCount) commands at seq \(publish.startingSeq)-\(publish.endingSeq).")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink.opacity(0.85))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(transcriptTint, in: Capsule(style: .continuous))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.95), Color(red: 0.92, green: 0.96, blue: 0.95)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.8), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 20, y: 10)
    }

    private var settingsPanel: some View {
        panel {
            VStack(alignment: .leading, spacing: 14) {
                sectionEyebrow("Connection")
                VStack(spacing: 10) {
                    polishedField(title: "Backend URL", text: $model.backendBaseURL)
                    polishedSecureField(title: "Producer API Key", text: $model.backendAPIKey)
                    HStack(spacing: 10) {
                        polishedField(title: "Job ID", text: $model.jobID)
                        polishedField(title: "Bridge ID", text: $model.bridgeID)
                    }
                }
                HStack(spacing: 10) {
                    Button("Open Draft") {
                        Task { await model.openDraft() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(!model.canOpenDraft)

                    if model.draft != nil {
                        Button("Refresh") {
                            Task { await model.refreshDraft() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var claimsPanel: some View {
        panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    sectionEyebrow("Claims")
                    Spacer()
                    Button("See All") {
                        model.showingClaims = true
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                }

                if model.claimSummaries.isEmpty {
                    Text("No claims loaded yet. Open a draft or create a new claim to start a claim list.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.opacity(0.6))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(model.claimSummaries.prefix(6)) { summary in
                                Button {
                                    Task { await model.switchToClaim(summary) }
                                } label: {
                                    claimCard(summary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    actionButton("New Claim", systemImage: "plus", fill: accent, foreground: .white) {
                        Task { await model.startNewClaim() }
                    }
                    actionButton("Refresh Claims", systemImage: "arrow.clockwise", fill: Color.white, foreground: ink) {
                        Task { await model.loadClaims() }
                    }
                }
            }
        }
    }

    private var overviewPanel: some View {
        panel {
            VStack(alignment: .leading, spacing: 14) {
                sectionEyebrow("Overview")
                HStack(spacing: 10) {
                    metricCard(value: "\(model.rooms.count - 1)", label: "Rooms", tint: accent)
                    metricCard(value: "\(acceptedCount)", label: "Accepted", tint: .green)
                    metricCard(value: "\(rejectedCount)", label: "Rejected", tint: .gray)
                    metricCard(value: "\(messageCount)", label: "Turns", tint: .blue)
                }
            }
        }
    }

    private var chatPanel: some View {
        panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    sectionEyebrow("Conversation")
                    Spacer()
                    if !model.transcript.isEmpty {
                        statusPill(label: "Voice Applied", systemImage: "waveform")
                    }
                }

                if !model.transcript.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "waveform")
                            .foregroundStyle(accent)
                        Text(model.transcript)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(ink.opacity(0.75))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(transcriptTint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                if let messages = model.draft?.messages, !messages.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(messages) { message in
                            HStack {
                                if message.role == "assistant" {
                                    chatBubble(message, fill: assistantBubble, foreground: ink, suppressStroke: false)
                                    Spacer(minLength: 52)
                                } else {
                                    Spacer(minLength: 52)
                                    chatBubble(message, fill: accent, foreground: .white, suppressStroke: true)
                                }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No turns yet")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(ink)
                        Text("Start with something natural like “Living room ceiling has a 2x2 patch and repaint the ceiling” or record a voice turn.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(ink.opacity(0.65))
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
        }
    }

    private var roomFilterPanel: some View {
        panel {
            VStack(alignment: .leading, spacing: 12) {
                sectionEyebrow("Rooms")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.rooms, id: \.self) { room in
                            Button(room) {
                                model.selectedRoom = room
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(model.selectedRoom == room ? accent : Color.white.opacity(0.72))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(model.selectedRoom == room ? accent : panelStroke, lineWidth: 1)
                            )
                            .foregroundStyle(model.selectedRoom == room ? Color.white : ink)
                        }
                    }
                }
            }
        }
    }

    private var roomStackPanel: some View {
        panel {
            VStack(alignment: .leading, spacing: 14) {
                sectionEyebrow("Room Stack")
                if model.filteredSections.isEmpty {
                    Text("Line items will appear here grouped by room and section once the draft agent starts filling them in.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.opacity(0.6))
                } else {
                    ForEach(model.filteredSections) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(group.room)
                                        .font(.system(size: 18, weight: .bold, design: .rounded))
                                        .foregroundStyle(ink)
                                    Text(group.note.uppercased())
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .kerning(0.8)
                                        .foregroundStyle(accent)
                                }
                                Spacer()
                                Text("\(group.items.count)")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(ink.opacity(0.75))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.84), in: Capsule(style: .continuous))
                            }

                            ForEach(group.items) { item in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(item.approvedCode)
                                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                                .foregroundStyle(accent)
                                            Text(item.description)
                                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                                .foregroundStyle(ink)
                                            let details = detailLine(for: item)
                                            if !details.isEmpty {
                                                Text(details)
                                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                                    .foregroundStyle(ink.opacity(0.62))
                                            }
                                        }
                                        Spacer()
                                        statusBadge(item.status)
                                    }

                                    if !item.rationale.trimmed.isEmpty {
                                        Text(item.rationale)
                                            .font(.system(size: 13, weight: .medium, design: .rounded))
                                            .foregroundStyle(ink.opacity(0.65))
                                    }

                                    HStack(spacing: 8) {
                                        actionChip("Accept", tint: .green, fill: item.status == "accepted" ? .green.opacity(0.18) : .white) {
                                            Task { await model.setItemStatus(item.id, status: "accepted") }
                                        }
                                        actionChip("Reject", tint: .secondary, fill: item.status == "rejected" ? rejectedTint : .white) {
                                            Task { await model.setItemStatus(item.id, status: "rejected") }
                                        }
                                    }
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(item.status == "accepted" ? accent.opacity(0.18) : panelStroke, lineWidth: 1)
                                )
                            }
                        }
                        .padding(16)
                        .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                }
            }
        }
    }

    private var claimsSheet: some View {
        NavigationStack {
            List {
                Section("Working Claims") {
                    ForEach(model.claimSummaries) { summary in
                        Button {
                            Task { await model.switchToClaim(summary) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(summary.jobId)
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                        .foregroundStyle(ink)
                                    Spacer()
                                    if summary.jobId == model.jobID.trimmed {
                                        Text("Open")
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                            .foregroundStyle(accent)
                                    }
                                }
                                Text(summary.latestMessagePreview.isEmpty ? "No conversation yet." : summary.latestMessagePreview)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(ink.opacity(0.62))
                                    .lineLimit(2)
                                Text("\(summary.roomCount) rooms • \(summary.itemCount) items • \(summary.messageCount) turns")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(ink.opacity(0.48))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Claims")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        model.showingClaims = false
                    }
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

    private var actionPanel: some View {
        panel {
            VStack(alignment: .leading, spacing: 14) {
                sectionEyebrow("Workflow")
                HStack(spacing: 10) {
                    actionButton("Accept All", systemImage: "checkmark.circle", fill: Color.white, foreground: ink) {
                        Task { await model.acceptAll() }
                    }
                    actionButton("Plan for Pi", systemImage: "bolt.horizontal.circle", fill: accent, foreground: .white) {
                        Task { await model.planDraft() }
                    }
                    .disabled(!model.canPlan)
                }

                if let plan = model.planResponse {
                    HStack(spacing: 10) {
                        metricCard(value: "\(plan.approvedCount)", label: "Approved", tint: .green)
                        metricCard(value: "\(plan.needsReviewCount)", label: "Review", tint: .orange)
                        metricCard(value: "\(plan.unresolvedCount)", label: "Unresolved", tint: .red)
                    }
                }

                actionButton("Publish to Bridge", systemImage: "paperplane.fill", fill: ink, foreground: .white) {
                    showingPublishConfirm = true
                }
                .disabled(!model.canPublish)
            }
        }
    }

    private var emptyStatePanel: some View {
        panel {
            VStack(alignment: .leading, spacing: 10) {
                sectionEyebrow("Start Here")
                Text("Open a draft first, then use the composer below to talk through the loss room by room. The app is designed to feel like a live estimating conversation, not a form.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(ink.opacity(0.68))
            }
        }
    }

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let audioFileURL = model.audioFileURL {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .foregroundStyle(accent)
                    Text(audioFileURL.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink.opacity(0.75))
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Describe a room, correction, or missing scope...", text: $model.messageDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(panelStroke, lineWidth: 1)
                    )
                    .lineLimit(1 ... 5)

                iconButton(systemImage: model.isRecording ? "stop.fill" : "mic.fill", fill: model.isRecording ? .red : accent) {
                    Task { await model.toggleRecording() }
                }

                iconButton(systemImage: "arrow.up", fill: ink) {
                    Task { await model.sendTextTurn() }
                }
                .disabled(!model.canSendText)

                iconButton(systemImage: "waveform", fill: accent) {
                    Task { await model.sendVoiceTurn() }
                }
                .disabled(!model.canSendVoice)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.05))
                .frame(height: 1)
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [canvasTop, canvasBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 280, height: 280)
                .blur(radius: 12)
                .offset(x: 120, y: -240)

            Circle()
                .fill(Color(red: 0.85, green: 0.93, blue: 0.90).opacity(0.6))
                .frame(width: 240, height: 240)
                .blur(radius: 18)
                .offset(x: -140, y: -120)
        }
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.045), radius: 18, y: 8)
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .kerning(0.8)
            .foregroundStyle(ink.opacity(0.5))
    }

    private func polishedField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.opacity(0.55))
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(panelStroke, lineWidth: 1)
                )
        }
    }

    private func polishedSecureField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.opacity(0.55))
            SecureField(title, text: text)
                .textInputAutocapitalization(.never)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(panelStroke, lineWidth: 1)
                )
        }
    }

    private func metricCard(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(ink.opacity(0.52))
                .textCase(.uppercase)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
    }

    private func chatBubble(_ message: DraftMessagePayload, fill: Color, foreground: Color, suppressStroke: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
            Text(message.role.capitalized)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .textCase(.uppercase)
                .opacity(0.66)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(fill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(suppressStroke ? Color.clear : panelStroke, lineWidth: 1)
        )
    }

    private func statusBadge(_ status: String) -> some View {
        let accepted = status == "accepted"
        return Text(status.capitalized)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(accepted ? accent.opacity(0.12) : rejectedTint, in: Capsule(style: .continuous))
            .foregroundStyle(accepted ? accent : ink.opacity(0.58))
    }

    private func statusPill(label: String, systemImage: String) -> some View {
        Label(label, systemImage: systemImage)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.85), in: Capsule(style: .continuous))
    }

    private func actionChip(_ title: String, tint: Color, fill: Color, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(fill, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.15), lineWidth: 1)
            )
    }

    private func actionButton(_ title: String, systemImage: String, fill: Color, foreground: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .background(fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(fill == Color.white ? panelStroke : Color.clear, lineWidth: 1)
        )
    }

    private func iconButton(systemImage: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func detailLine(for item: DraftLineItemPayload) -> String {
        [item.surface, item.damageType, item.quantity.isEmpty ? "" : "Qty \(item.quantity)"]
            .map(\.trimmed)
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    private var acceptedCount: Int {
        model.draft?.items.filter { $0.status == "accepted" }.count ?? 0
    }

    private var rejectedCount: Int {
        model.draft?.items.filter { $0.status == "rejected" }.count ?? 0
    }

    private var messageCount: Int {
        model.draft?.messages.count ?? 0
    }

    private func claimCard(_ summary: ClaimSummaryPayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(summary.jobId)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(summary.jobId == model.jobID.trimmed ? Color.white : ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if summary.jobId == model.jobID.trimmed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.white.opacity(0.92))
                }
            }

            Text(summary.latestMessagePreview.isEmpty ? "No turns yet." : summary.latestMessagePreview)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle((summary.jobId == model.jobID.trimmed ? Color.white : ink).opacity(0.78))
                .lineLimit(3)

            Text("\(summary.roomCount) rooms • \(summary.itemCount) items")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle((summary.jobId == model.jobID.trimmed ? Color.white : accent).opacity(0.92))
        }
        .padding(14)
        .frame(width: 210, alignment: .leading)
        .background(
            summary.jobId == model.jobID.trimmed
                ? AnyShapeStyle(LinearGradient(colors: [accent, Color(red: 0.10, green: 0.37, blue: 0.28)], startPoint: .topLeading, endPoint: .bottomTrailing))
                : AnyShapeStyle(Color.white.opacity(0.82))
        , in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(summary.jobId == model.jobID.trimmed ? Color.clear : panelStroke, lineWidth: 1)
        )
    }
}
