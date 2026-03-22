import SwiftUI

private enum WorkspaceSurface: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case scope = "Scope"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .chat:
            return "bubble.left.and.bubble.right.fill"
        case .scope:
            return "square.stack.3d.up.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .chat:
            return "Conversation"
        case .scope:
            return "Room stack"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = FieldCaptureAppModel()
    @State private var showingPublishConfirm = false
    @State private var showingSettings = false
    @State private var selectedSurface: WorkspaceSurface = .chat

    private let canvas = Color(red: 0.95, green: 0.97, blue: 0.99)
    private let canvasShade = Color(red: 0.91, green: 0.94, blue: 0.98)
    private let cardStroke = Color.black.opacity(0.08)
    private let cardShadow = Color.black.opacity(0.09)
    private let ink = Color(red: 0.11, green: 0.13, blue: 0.18)
    private let mutedInk = Color(red: 0.42, green: 0.47, blue: 0.54)
    private let accent = Color(red: 0.12, green: 0.45, blue: 0.36)
    private let accentDeep = Color(red: 0.08, green: 0.26, blue: 0.23)
    private let accentWash = Color(red: 0.90, green: 0.96, blue: 0.93)
    private let userBubble = Color(red: 0.16, green: 0.18, blue: 0.22)
    private let assistantBubble = Color.white.opacity(0.88)
    private let rejectedTint = Color(red: 0.94, green: 0.95, blue: 0.97)

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    heroPanel
                    recentClaimsStrip

                    if model.draft != nil {
                        summaryPanel
                        workspacePicker
                        workspacePanel
                    } else {
                        welcomePanel
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 156)
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
                        Image(systemName: "rectangle.stack.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ink)
                    }
                }

                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("Claim Workspace")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(ink)
                        Text(model.draft == nil ? "Waiting to open" : "Live claim draft")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(mutedInk)
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ink)
                    }

                    Button {
                        Task { await model.startNewClaim() }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .semibold))
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
            .sheet(isPresented: $showingSettings) {
                settingsSheet
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
                    busyOverlay
                }
            }
        }
    }

    private var heroPanel: some View {
        glassCard(cornerRadius: 30, padding: 22) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Field estimating", systemImage: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)

                        Text(currentClaimTitle)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)

                        Text(heroDescription)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    statusPill(label: workflowStateLabel, systemImage: workflowStateIcon)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        heroMetric(value: "\(roomCount)", label: "Rooms")
                        heroMetric(value: "\(model.draft?.items.count ?? 0)", label: "Items")
                        heroMetric(value: "\(messageCount)", label: "Turns")
                        heroMetric(value: "\(acceptedCount)", label: "Accepted")
                    }
                }

                if let publish = model.publishResponse {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(accent)
                        Text("Queued \(publish.commandCount) commands to the bridge at seq \(publish.startingSeq)-\(publish.endingSeq).")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(ink)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(accentWash, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                HStack(spacing: 10) {
                    prominentCapsuleButton(
                        title: model.draft == nil ? "Open Claim" : "Refresh Draft",
                        systemImage: model.draft == nil ? "arrow.up.forward.app" : "arrow.clockwise",
                        fill: accent,
                        foreground: .white
                    ) {
                        Task {
                            if model.draft == nil {
                                await model.openDraft()
                            } else {
                                await model.refreshDraft()
                            }
                        }
                    }
                    .disabled(!model.canOpenDraft)

                    subtleCapsuleButton(title: "Claims", systemImage: "rectangle.stack") {
                        model.showingClaims = true
                    }
                }
            }
        }
    }

    private var recentClaimsStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("Recent Claims")
                Spacer()
                Button("See All") {
                    model.showingClaims = true
                }
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
            }

            if model.claimSummaries.isEmpty {
                glassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No working claims yet")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(ink)
                        Text("Create a new claim or open the current claim ID to start the room-by-room conversation.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(mutedInk)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(model.claimSummaries.prefix(8)) { summary in
                            Button {
                                Task { await model.switchToClaim(summary) }
                            } label: {
                                claimCard(summary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var summaryPanel: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    sectionLabel("Claim Snapshot")
                    Spacer()
                    if let plan = model.planResponse {
                        Text(planSummaryText(plan))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        metricCard(value: "\(acceptedCount)", label: "Accepted", tint: accent)
                        metricCard(value: "\(pendingCount)", label: "Pending", tint: .orange)
                        metricCard(value: "\(rejectedCount)", label: "Rejected", tint: .gray)
                        metricCard(value: "\(messageCount)", label: "Turns", tint: .blue)
                    }
                }
            }
        }
    }

    private var workspacePicker: some View {
        HStack(spacing: 10) {
            ForEach(WorkspaceSurface.allCases) { surface in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        selectedSurface = surface
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: surface.icon)
                            .font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(surface.rawValue)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                            Text(surface.subtitle)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selectedSurface == surface ? Color.white : ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(selectedSurface == surface ? LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing) : LinearGradient(colors: [Color.white.opacity(0.66), Color.white.opacity(0.50)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(selectedSurface == surface ? Color.clear : cardStroke, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var workspacePanel: some View {
        switch selectedSurface {
        case .chat:
            chatWorkspace
        case .scope:
            scopeWorkspace
        }
    }

    private var chatWorkspace: some View {
        glassCard(cornerRadius: 32, padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Claim Conversation")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(ink)
                        Text("Use voice or text naturally. The backend agent should keep evolving the room-by-room draft here.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(mutedInk)
                    }
                    Spacer(minLength: 10)
                    if !model.transcript.isEmpty {
                        statusPill(label: "Voice Applied", systemImage: "waveform")
                    }
                }

                if !model.transcript.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundStyle(accent)
                        Text(model.transcript)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(ink.opacity(0.76))
                    }
                    .padding(14)
                    .background(accentWash, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                if let messages = model.draft?.messages, !messages.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(messages) { message in
                            HStack {
                                if message.role == "assistant" {
                                    messageBubble(message, fill: assistantBubble, foreground: ink, isLeading: true, showsStroke: true)
                                    Spacer(minLength: 54)
                                } else {
                                    Spacer(minLength: 54)
                                    messageBubble(message, fill: userBubble, foreground: .white, isLeading: false, showsStroke: false)
                                }
                            }
                        }
                    }
                } else {
                    modernEmptyState(
                        systemImage: "ellipsis.message",
                        title: "No conversation yet",
                        body: "Open a claim, then describe the loss naturally. Start with a room and the top-most scope, then work downward."
                    )
                }
            }
        }
    }

    private var scopeWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            glassCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Room Stack")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(ink)
                            Text("Review the draft the way you scope in the field: room by room, section by section, then send the accepted stack to the Pi.")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(mutedInk)
                        }
                        Spacer(minLength: 10)
                    }

                    HStack(spacing: 10) {
                        actionButton(
                            "Accept All",
                            systemImage: "checkmark.circle",
                            fill: Color.white.opacity(0.88),
                            foreground: ink
                            ,
                            outlined: true
                        ) {
                            Task { await model.acceptAll() }
                        }

                        actionButton(
                            "Plan",
                            systemImage: "bolt.horizontal.circle",
                            fill: accent,
                            foreground: .white,
                            outlined: false
                        ) {
                            Task { await model.planDraft() }
                        }
                        .disabled(!model.canPlan)

                        actionButton(
                            "Publish",
                            systemImage: "paperplane.fill",
                            fill: ink,
                            foreground: .white,
                            outlined: false
                        ) {
                            showingPublishConfirm = true
                        }
                        .disabled(!model.canPublish)
                    }

                    if let plan = model.planResponse {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                metricCard(value: "\(plan.approvedCount)", label: "Approved", tint: .green)
                                metricCard(value: "\(plan.needsReviewCount)", label: "Review", tint: .orange)
                                metricCard(value: "\(plan.unresolvedCount)", label: "Unresolved", tint: .red)
                            }
                        }
                    }
                }
            }

            glassCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("Room Filter")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(model.rooms, id: \.self) { room in
                                Button(room) {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                        model.selectedRoom = room
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(model.selectedRoom == room ? Color.white : ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(model.selectedRoom == room ? accent : Color.white.opacity(0.72))
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(model.selectedRoom == room ? Color.clear : cardStroke, lineWidth: 1)
                                )
                            }
                        }
                    }
                }
            }

            if model.filteredSections.isEmpty {
                glassCard {
                    modernEmptyState(
                        systemImage: "square.stack.3d.down.right",
                        title: "No scoped sections yet",
                        body: "Keep talking through the loss and the room stack will populate here in review order."
                    )
                }
            } else {
                VStack(spacing: 14) {
                    ForEach(model.filteredSections) { group in
                        scopeGroupCard(group)
                    }
                }
            }
        }
    }

    private var welcomePanel: some View {
        glassCard(cornerRadius: 32, padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                modernEmptyState(
                    systemImage: "mic.and.signal.meter",
                    title: "Open a claim to start the workspace",
                    body: "The main flow is voice or text into the backend agent, then review the room stack before publish. Settings stay tucked away so the claim stays front and center."
                )

                HStack(spacing: 10) {
                    prominentCapsuleButton(title: "Open Claim", systemImage: "arrow.up.forward.app", fill: accent, foreground: .white) {
                        Task { await model.openDraft() }
                    }
                    .disabled(!model.canOpenDraft)

                    subtleCapsuleButton(title: "Settings", systemImage: "slider.horizontal.3") {
                        showingSettings = true
                    }
                }
            }
        }
    }

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let audioFileURL = model.audioFileURL {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice clip ready")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(ink)
                        Text(audioFileURL.lastPathComponent)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(mutedInk)
                    }
                    Spacer()
                    Button("Send Voice") {
                        Task { await model.sendVoiceTurn() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .disabled(!model.canSendVoice)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    Task { await model.toggleRecording() }
                } label: {
                    Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(model.isRecording ? Color.red : accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                TextField("Describe a room, correction, or missing scope...", text: $model.messageDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(cardStroke, lineWidth: 1)
                    )
                    .lineLimit(1 ... 5)

                Button {
                    Task { await model.sendTextTurn() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(model.canSendText ? ink : mutedInk.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .disabled(!model.canSendText)
            }

            if model.draft == nil {
                Text("Open a claim first, then use the composer as the primary way to evolve the draft.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(mutedInk)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: cardShadow, radius: 22, y: 10)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var claimsSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    glassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Working Claims")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundStyle(ink)
                            Text("Switch between active jobs without losing the current chat flow.")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(mutedInk)
                        }
                    }

                    if model.claimSummaries.isEmpty {
                        glassCard {
                            modernEmptyState(
                                systemImage: "tray",
                                title: "No saved claims yet",
                                body: "Open the current claim ID or create a new one and it will appear here for quick switching."
                            )
                        }
                    } else {
                        VStack(spacing: 12) {
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
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(background)
            .navigationTitle("Claims")
            .navigationBarTitleDisplayMode(.inline)
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
                    Button("Done") {
                        showingSettings = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var busyOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(accent)
                .scaleEffect(1.1)
            Text(model.busyMessage)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(ink)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: cardShadow, radius: 28, y: 14)
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [canvas, canvasShade],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.white.opacity(0.62))
                .frame(width: 280, height: 280)
                .blur(radius: 18)
                .offset(x: 138, y: -280)

            Circle()
                .fill(accent.opacity(0.16))
                .frame(width: 280, height: 280)
                .blur(radius: 38)
                .offset(x: 130, y: -320)

            Circle()
                .fill(Color(red: 0.43, green: 0.63, blue: 0.88).opacity(0.16))
                .frame(width: 260, height: 260)
                .blur(radius: 42)
                .offset(x: -140, y: -150)

            Circle()
                .fill(Color(red: 0.71, green: 0.84, blue: 1.0).opacity(0.14))
                .frame(width: 320, height: 320)
                .blur(radius: 60)
                .offset(x: -160, y: 180)
        }
    }

    private func glassCard<Content: View>(
        cornerRadius: CGFloat = 28,
        padding: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.56))
        )
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.58), lineWidth: 1)
        )
        .shadow(color: cardShadow, radius: 20, y: 10)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .kerning(0.8)
            .foregroundStyle(mutedInk.opacity(0.9))
    }

    private func heroMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(ink)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(mutedInk)
                .kerning(0.6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(cardStroke, lineWidth: 1)
        )
    }

    private func metricCard(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(mutedInk)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(cardStroke, lineWidth: 1)
        )
    }

    private func statusPill(label: String, systemImage: String) -> some View {
        Label(label, systemImage: systemImage)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.84), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.62), lineWidth: 1)
            )
    }

    private func prominentCapsuleButton(
        title: String,
        systemImage: String,
        fill: Color,
        foreground: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .background(fill, in: Capsule(style: .continuous))
    }

    private func subtleCapsuleButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ink)
        .background(Color.white.opacity(0.76), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(cardStroke, lineWidth: 1)
        )
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        fill: Color,
        foreground: Color,
        outlined: Bool,
        action: @escaping () -> Void
    ) -> some View {
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
                .stroke(outlined ? cardStroke : Color.clear, lineWidth: 1)
        )
    }

    private func modernEmptyState(systemImage: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(accent)
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(ink)
            Text(body)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func messageBubble(
        _ message: DraftMessagePayload,
        fill: Color,
        foreground: Color,
        isLeading: Bool,
        showsStroke: Bool
    ) -> some View {
        VStack(alignment: isLeading ? .leading : .trailing, spacing: 7) {
            Text(message.text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .multilineTextAlignment(isLeading ? .leading : .trailing)
            Text(message.role.capitalized)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .opacity(0.62)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(fill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(showsStroke ? cardStroke : Color.clear, lineWidth: 1)
        )
    }

    private func scopeGroupCard(_ group: DraftSectionPayload) -> some View {
        glassCard(cornerRadius: 30, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(group.room)
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(ink)
                        Text(group.note.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                            .kerning(0.8)
                    }

                    Spacer()

                    Text("\(group.items.count) items")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(mutedInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.74), in: Capsule(style: .continuous))
                }

                ForEach(group.items) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 6) {
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
                                        .foregroundStyle(mutedInk)
                                }
                            }

                            Spacer(minLength: 10)
                            statusBadge(item.status)
                        }

                        if !item.rationale.trimmed.isEmpty {
                            Text(item.rationale)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(mutedInk)
                        }

                        HStack(spacing: 8) {
                            actionChip(
                                "Accept",
                                tint: accent,
                                fill: item.status == "accepted" ? accentWash : Color.white.opacity(0.84)
                            ) {
                                Task { await model.setItemStatus(item.id, status: "accepted") }
                            }

                            actionChip(
                                "Reject",
                                tint: ink.opacity(0.72),
                                fill: item.status == "rejected" ? rejectedTint : Color.white.opacity(0.84)
                            ) {
                                Task { await model.setItemStatus(item.id, status: "rejected") }
                            }
                        }
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(item.status == "accepted" ? accent.opacity(0.18) : cardStroke, lineWidth: 1)
                    )
                }
            }
        }
    }

    private func statusBadge(_ status: String) -> some View {
        let accepted = status == "accepted"
        let rejected = status == "rejected"

        return Text(status.capitalized)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                accepted ? accentWash : (rejected ? rejectedTint : Color.white.opacity(0.84)),
                in: Capsule(style: .continuous)
            )
            .foregroundStyle(accepted ? accent : ink.opacity(0.66))
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
                    .stroke(tint.opacity(0.10), lineWidth: 1)
            )
    }

    private func detailLine(for item: DraftLineItemPayload) -> String {
        [item.surface, item.damageType, item.quantity.isEmpty ? "" : "Qty \(item.quantity)"]
            .map(\.trimmed)
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    private func claimCard(_ summary: ClaimSummaryPayload) -> some View {
        let isCurrent = summary.jobId == model.jobID.trimmed

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(summary.jobId)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(isCurrent ? Color.white : ink)
                    .lineLimit(1)
                Spacer(minLength: 10)
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "chevron.right.circle.fill")
                    .foregroundStyle(isCurrent ? Color.white.opacity(0.88) : accent.opacity(0.72))
            }

            Text(summary.latestMessagePreview.isEmpty ? "No conversation yet." : summary.latestMessagePreview)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle((isCurrent ? Color.white : ink).opacity(0.76))
                .lineLimit(3)

            Text("\(summary.roomCount) rooms • \(summary.itemCount) items • \(summary.messageCount) turns")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(isCurrent ? Color.white.opacity(0.86) : mutedInk)
        }
        .padding(16)
        .frame(width: 228, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    isCurrent
                        ? LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color.white.opacity(0.82), Color.white.opacity(0.68)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(isCurrent ? Color.clear : cardStroke, lineWidth: 1)
        )
        .shadow(color: cardShadow.opacity(isCurrent ? 1.0 : 0.55), radius: 18, y: 8)
    }

    private func claimListRow(_ summary: ClaimSummaryPayload) -> some View {
        let isCurrent = summary.jobId == model.jobID.trimmed

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.jobId)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(ink)
                    Text(summary.bridgeId)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(mutedInk)
                }

                Spacer()

                if isCurrent {
                    Text("Open")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(accentWash, in: Capsule(style: .continuous))
                }
            }

            Text(summary.latestMessagePreview.isEmpty ? "No conversation yet." : summary.latestMessagePreview)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(mutedInk)
                .lineLimit(3)

            Text("\(summary.roomCount) rooms • \(summary.itemCount) items • \(summary.messageCount) turns")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(ink.opacity(0.74))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(cardStroke, lineWidth: 1)
        )
    }

    private func planSummaryText(_ plan: PlanResponse) -> String {
        if plan.unresolvedCount > 0 {
            return "\(plan.unresolvedCount) unresolved"
        }
        if plan.needsReviewCount > 0 {
            return "\(plan.needsReviewCount) need review"
        }
        return "Ready to publish"
    }

    private var workflowStateLabel: String {
        if model.publishResponse != nil {
            return "Queued"
        }
        if model.planResponse != nil {
            return "Planned"
        }
        if model.draft != nil {
            return "Live Draft"
        }
        return "Idle"
    }

    private var workflowStateIcon: String {
        if model.publishResponse != nil {
            return "paperplane.fill"
        }
        if model.planResponse != nil {
            return "bolt.fill"
        }
        if model.draft != nil {
            return "waveform.path.ecg"
        }
        return "circle.dashed"
    }

    private var currentClaimTitle: String {
        let title = model.jobID.trimmed
        return title.isEmpty ? "Untitled Claim" : title
    }

    private var heroDescription: String {
        if let publish = model.publishResponse {
            return "This draft is queued to bridge \(publish.bridgeId). Keep the claim open if you want to revise and republish."
        }

        if let preview = model.currentClaimSummary?.latestMessagePreview.trimmed, !preview.isEmpty {
            return preview
        }

        if let lastMessage = model.draft?.messages.last?.text.trimmed, !lastMessage.isEmpty {
            return lastMessage
        }

        return "Talk through the loss naturally, let the backend agent structure the draft, then review room sections before they reach the Raspberry Pi."
    }

    private var roomCount: Int {
        max(model.rooms.count - 1, 0)
    }

    private var acceptedCount: Int {
        model.draft?.items.filter { $0.status == "accepted" }.count ?? 0
    }

    private var rejectedCount: Int {
        model.draft?.items.filter { $0.status == "rejected" }.count ?? 0
    }

    private var pendingCount: Int {
        max((model.draft?.items.count ?? 0) - acceptedCount - rejectedCount, 0)
    }

    private var messageCount: Int {
        model.draft?.messages.count ?? 0
    }
}
