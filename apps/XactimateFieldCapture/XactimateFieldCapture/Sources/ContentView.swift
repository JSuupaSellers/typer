import SwiftUI

struct ContentView: View {
    @StateObject private var model = FieldCaptureAppModel()
    @State private var showingPublishConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    connectionCard
                    if model.draft != nil {
                        roomsCard
                        chatCard
                        sectionsCard
                        workflowCard
                    } else {
                        emptyDraftCard
                    }
                }
                .padding(16)
                .padding(.bottom, 120)
            }
            .background(background)
            .navigationTitle("Claim Draft")
            .safeAreaInset(edge: .bottom) {
                composerBar
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
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(radius: 16, y: 10)
                }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Talk through the claim room by room.")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("The backend keeps the claim draft, the agent fills line items by section, and you review the room stack before it ever touches the Pi.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.96, green: 0.98, blue: 0.94), Color(red: 0.90, green: 0.94, blue: 0.99)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var connectionCard: some View {
        card("Connection") {
            VStack(spacing: 12) {
                TextField("Backend URL", text: $model.backendBaseURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)

                SecureField("Producer API Key", text: $model.backendAPIKey)
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 12) {
                    TextField("Job ID", text: $model.jobID)
                        .textFieldStyle(.roundedBorder)
                    TextField("Bridge ID", text: $model.bridgeID)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 12) {
                    Button("Open Draft") {
                        Task { await model.openDraft() }
                    }
                    .buttonStyle(.borderedProminent)
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

    private var emptyDraftCard: some View {
        card("Start Here") {
            Text("Open a draft first, then use the composer below to talk through the claim room by room. Voice turns transcribe on the backend, text turns go straight to the draft agent.")
                .foregroundStyle(.secondary)
        }
    }

    private var roomsCard: some View {
        card("Rooms") {
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
                                .fill(model.selectedRoom == room ? Color.accentColor : Color(.secondarySystemBackground))
                        )
                        .foregroundStyle(model.selectedRoom == room ? Color.white : Color.primary)
                    }
                }
            }
        }
    }

    private var chatCard: some View {
        card("Conversation") {
            VStack(alignment: .leading, spacing: 12) {
                if !model.transcript.isEmpty {
                    Label(model.transcript, systemImage: "waveform")
                        .font(.caption)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let messages = model.draft?.messages, !messages.isEmpty {
                    ForEach(messages) { message in
                        HStack {
                            if message.role == "assistant" {
                                messageBubble(message, accent: Color(.secondarySystemBackground), foreground: .primary)
                                Spacer(minLength: 30)
                            } else {
                                Spacer(minLength: 30)
                                messageBubble(message, accent: Color.accentColor.opacity(0.95), foreground: .white)
                            }
                        }
                    }
                } else {
                    Text("No turns yet. Start with something like: “Living room ceiling has a 2x2 patch and repaint the ceiling.”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sectionsCard: some View {
        card("Room Stack") {
            VStack(alignment: .leading, spacing: 16) {
                if model.filteredSections.isEmpty {
                    Text("Accepted and rejected line items will appear here grouped by room and section.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.filteredSections) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.room)
                                        .font(.headline)
                                    Text(group.note)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(group.items.count) item\(group.items.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(group.items) { item in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\(item.approvedCode) • \(item.description)")
                                                .font(.subheadline.weight(.semibold))
                                            Text(detailLine(for: item))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        statusBadge(item.status)
                                    }

                                    if !item.rationale.trimmed.isEmpty {
                                        Text(item.rationale)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    HStack(spacing: 10) {
                                        Button("Accept") {
                                            Task { await model.setItemStatus(item.id, status: "accepted") }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.green)
                                        .controlSize(.small)

                                        Button("Reject") {
                                            Task { await model.setItemStatus(item.id, status: "rejected") }
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(.secondary)
                                        .controlSize(.small)
                                    }
                                }
                                .padding(14)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                        }
                    }
                }
            }
        }
    }

    private var workflowCard: some View {
        card("Workflow") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Button("Accept All") {
                        Task { await model.acceptAll() }
                    }
                    .buttonStyle(.bordered)

                    Button("Plan for Pi") {
                        Task { await model.planDraft() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canPlan)
                }

                if let plan = model.planResponse {
                    HStack(spacing: 12) {
                        statPill(title: "Approved", value: "\(plan.approvedCount)", color: .green)
                        statPill(title: "Review", value: "\(plan.needsReviewCount)", color: .orange)
                        statPill(title: "Unresolved", value: "\(plan.unresolvedCount)", color: .red)
                    }
                }

                Button("Publish to Bridge") {
                    showingPublishConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPublish)

                if let publish = model.publishResponse {
                    Text("Queued \(publish.commandCount) commands at seq \(publish.startingSeq)-\(publish.endingSeq).")
                        .font(.subheadline.weight(.semibold))
                    Text("Approved codes: \(publish.approvedCodes.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let audioFileURL = model.audioFileURL {
                Label(audioFileURL.lastPathComponent, systemImage: "waveform.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Add a room note or correction...", text: $model.messageDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 4)

                Button(model.isRecording ? "Stop" : "Rec") {
                    Task { await model.toggleRecording() }
                }
                .buttonStyle(.bordered)
                .tint(model.isRecording ? .red : .accentColor)

                Button("Send") {
                    Task { await model.sendTextTurn() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSendText)

                Button("Voice") {
                    Task { await model.sendVoiceTurn() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSendVoice)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .background(.ultraThinMaterial)
    }

    private var background: some View {
        LinearGradient(
            colors: [Color(red: 0.98, green: 0.99, blue: 0.97), Color(red: 0.94, green: 0.96, blue: 0.99)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func messageBubble(_ message: DraftMessagePayload, accent: Color, foreground: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.text)
                .font(.body)
            Text(message.role.capitalized)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .opacity(0.7)
        }
        .foregroundStyle(foreground)
        .padding(14)
        .background(accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status.capitalized)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(status == "accepted" ? Color.green.opacity(0.18) : Color.gray.opacity(0.18), in: Capsule(style: .continuous))
            .foregroundStyle(status == "accepted" ? Color.green : Color.secondary)
    }

    private func statPill(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title3.weight(.bold))
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func detailLine(for item: DraftLineItemPayload) -> String {
        [item.surface, item.damageType, item.quantity.isEmpty ? "" : "Qty \(item.quantity)"]
            .map(\.trimmed)
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }
}
