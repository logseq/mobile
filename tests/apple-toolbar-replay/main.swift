import Logseq
import Observation
import SwiftUI

struct ReplayStage: Decodable {
    let name: String
    let patches: [String]
}

@MainActor @Observable
final class ToolbarReplay {
    let renderer = LGRenderer()
    let stages: [ReplayStage]
    var index = 0

    init() {
        stages = try! JSONDecoder().decode([ReplayStage].self, from:
            Data(contentsOf: Bundle.module.url(forResource: "stages", withExtension: "json")!))
        apply()
    }

    func advance() {
        guard index + 1 < stages.count else { return }
        index += 1
        apply()
    }

    private func apply() {
        for patch in stages[index].patches { try! renderer.apply(patchJSON: patch) }
    }
}

@main
struct ToolbarReplayApp: App {
    @State private var replay = ToolbarReplay()
    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottomLeading) {
                LGRendererRoot(renderer: replay.renderer)
                VStack(alignment: .leading) {
                    Text(replay.stages[replay.index].name)
                        .accessibilityIdentifier("fixture.phase." + replay.stages[replay.index].name)
                    Button("Next toolbar case") { replay.advance() }
                        .accessibilityIdentifier("fixture.next")
                }
                .padding(24)
                .background(.regularMaterial)
                .padding(.bottom, 100)
            }
        }
    }
}
