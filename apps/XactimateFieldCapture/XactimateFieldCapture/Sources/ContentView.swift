import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var model = FieldCaptureAppModel()
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showingPublishConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    connectionCard
                    scopeCard
                    captureCard
                    if !model.transcript.isEmpty || model.captureDraft != nil {
                        draftCard
                    }
                    if let plan = model.planResponse {
                        planCard(plan: plan)
                    }
                    publishCard
                }
                .padding(20)
            }
            .background(background)
            .navigationTitle("Field Capture")
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
            .alert("Publish to the bridge?", isPresented: $showingPublishConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Publish") {
                    Task { await model.publishEstimate() }
                }
            } message: {
                Text("This will queue commands in Firebase for the Raspberry Pi bridge to execute.")
            }
            .overlay(alignment: .center) {
                if !model.busyMessage.isEmpty {
                    ProgressView(model.busyMessage)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(radius: 18, y: 10)
                }
            }
            .onChange(of: photoPickerItems) { _, newValue in
                Task { await loadSelectedPhotos(from: newValue) }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capture in the field, keep the intelligence on your backend.")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
            Text("Record audio, attach photos, review the planned CAT/SEL items, then publish only when the plan looks right.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.94, green: 0.98, blue: 0.95), Color(red: 0.88, green: 0.95, blue: 0.98)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var connectionCard: some View {
        card("Backend") {
            VStack(spacing: 12) {
                TextField("Backend URL", text: $model.backendBaseURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)

                SecureField("Producer API Key", text: $model.backendAPIKey)
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var scopeCard: some View {
        card("Scope") {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Job ID", text: $model.jobID)
                        .textFieldStyle(.roundedBorder)
                    TextField("Bridge ID", text: $model.bridgeID)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 12) {
                    TextField("Scope Item ID", text: $model.scopeItemID)
                        .textFieldStyle(.roundedBorder)
                    TextField("Quantity", text: $model.quantity)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 12) {
                    TextField("Room", text: $model.room)
                        .textFieldStyle(.roundedBorder)
                    TextField("Surface", text: $model.surface)
                        .textFieldStyle(.roundedBorder)
                }

                TextField("Damage Type", text: $model.damageType)
                    .textFieldStyle(.roundedBorder)

                TextField("Keywords", text: $model.keywords)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Narrative")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $model.descriptionText)
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                }
            }
        }
    }

    private var captureCard: some View {
        card("Capture") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Button(model.isRecording ? "Stop Recording" : "Record Audio") {
                        Task { await model.toggleRecording() }
                    }
                    .buttonStyle(.borderedProminent)

                    if let audioFileURL = model.audioFileURL {
                        Text(audioFileURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No audio clip yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                PhotosPicker(selection: $photoPickerItems, maxSelectionCount: 12, matching: .images) {
                    Label("Select Photos", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if !model.selectedPhotos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(model.selectedPhotos) { photo in
                                VStack(alignment: .leading, spacing: 6) {
                                    if let image = photo.image {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 88, height: 88)
                                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    }
                                    Text(photo.filename)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button("Prepare Draft") {
                        Task { await model.prepareDraft() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canPrepareDraft)

                    Button("Plan Estimate") {
                        Task { await model.planEstimate() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canPlan)
                }
            }
        }
    }

    private var draftCard: some View {
        card("Draft") {
            VStack(alignment: .leading, spacing: 10) {
                if let draft = model.captureDraft {
                    Text("Uploaded \(draft.photoCount) photo\(draft.photoCount == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if !model.transcript.isEmpty {
                    Text("Transcript")
                        .font(.subheadline.weight(.semibold))
                    Text(model.transcript)
                        .font(.body)
                }
            }
        }
    }

    private func planCard(plan: PlanResponse) -> some View {
        card("Planned Items") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    statPill(title: "Approved", value: "\(plan.approvedCount)", color: .green)
                    statPill(title: "Review", value: "\(plan.needsReviewCount)", color: .orange)
                    statPill(title: "Unresolved", value: "\(plan.unresolvedCount)", color: .red)
                }

                ForEach(plan.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.source.description.isEmpty ? "No description" : item.source.description)
                                .font(.headline)
                            Spacer()
                            statusBadge(item.status)
                        }

                        if let approved = item.approvedCandidate {
                            Text("\(approved.item.code) • \(approved.item.description)")
                                .font(.subheadline.weight(.semibold))
                            Text("Confidence: \(approved.confidence.capitalized)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let topCandidate = item.candidates.first {
                            Text("Top suggestion: \(topCandidate.item.code) • \(topCandidate.item.description)")
                                .font(.subheadline.weight(.semibold))
                            Text("Confidence: \(topCandidate.confidence.capitalized)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !item.reviewReason.isEmpty {
                            Text(item.reviewReason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                }
            }
        }
    }

    private var publishCard: some View {
        card("Publish") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Only publish after the plan is fully approved.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

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
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private func statPill(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(value)
                .font(.headline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }

    private func statusBadge(_ status: String) -> some View {
        let style: (text: String, color: Color) = switch status {
        case "approved":
            ("Approved", .green)
        case "needs_review":
            ("Needs Review", .orange)
        default:
            ("Unresolved", .red)
        }

        return Text(style.text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(style.color.opacity(0.12), in: Capsule())
            .foregroundStyle(style.color)
    }

    private func loadSelectedPhotos(from items: [PhotosPickerItem]) async {
        var loaded: [PickedPhoto] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
                continue
            }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let mimeType = type?.preferredMIMEType ?? "image/jpeg"
            loaded.append(
                PickedPhoto(
                    filename: "photo-\(index + 1).\(ext)",
                    mimeType: mimeType,
                    data: data
                )
            )
        }
        model.setSelectedPhotos(loaded)
    }
}
