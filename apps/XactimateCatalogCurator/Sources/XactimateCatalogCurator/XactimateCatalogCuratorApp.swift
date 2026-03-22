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
            if model.selectedStage == .quickReview, model.currentReviewItem != nil {
                CommandMenu("Quick Review") {
                    Button("Mark Used Before") {
                        model.markCurrentReviewItem(as: .usedBefore)
                    }
                    .keyboardShortcut(.space, modifiers: [])

                    Button("Mark Never Used") {
                        model.markCurrentReviewItem(as: .neverUsed)
                    }
                    .keyboardShortcut("n", modifiers: [])

                    Button("Skip Item") {
                        model.skipCurrentReviewItem()
                    }
                    .keyboardShortcut("s", modifiers: [])
                }
            }
        }
    }
}
