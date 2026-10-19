import SwiftUI
import LogseqModel

struct GraphDownloadProgressView: View {
    let coordinator: LGPlatformPresentationCoordinator

    var body: some View {
        if let progress = coordinator.graphDownloadProgress {
            VStack(alignment: .leading, spacing: 18) {
                Text(progress.graphName).font(.title2.bold())
                Text(stageTitle(progress.phase))
                    .accessibilityIdentifier("graph-download.stage")
                if progress.phase == "importing", let total = progress.totalItems, total > 0 {
                    let fraction = min(1, Double(progress.completedItems) / Double(total))
                    ProgressView(value: fraction)
                    HStack {
                        Text("\(progress.completedItems.formatted()) of \(total.formatted()) records organized")
                        Spacer()
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("graph-download.count")
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                Text("Your graph will open when it’s ready.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("sheet.graph-download")
        }
    }

    private func stageTitle(_ phase: String) -> String {
        switch phase {
        case "downloading": "Getting your notes…"
        case "decoding": "Preparing your notes…"
        case "importing": "Organizing your notes…"
        case "opening": "Opening your graph…"
        default: "Connecting to your graph…"
        }
    }
}
