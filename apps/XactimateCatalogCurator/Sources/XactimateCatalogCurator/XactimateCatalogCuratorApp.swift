import SwiftUI

@main
struct XactimateCatalogCuratorApp: App {
    @StateObject private var model = CuratorAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .commands {
            CommandMenu("Quick Review") {
                Button("Mark Used Before") {
                    model.markCurrentReviewItem(as: .usedBefore)
                }
                .disabled(model.selectedStage != .quickReview || model.currentReviewItem == nil)

                Button("Mark Never Used") {
                    model.markCurrentReviewItem(as: .neverUsed)
                }
                .disabled(model.selectedStage != .quickReview || model.currentReviewItem == nil)

                Button("Skip Item") {
                    model.skipCurrentReviewItem()
                }
                .disabled(model.selectedStage != .quickReview || model.currentReviewItem == nil)
            }
        }
    }
}
