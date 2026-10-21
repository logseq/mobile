import UIKit
import SwiftUI
import Vision
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class JournalHeadingEffects: LGEffectExecuting {
    var openedPage: String?

    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "open-node" { openedPage = effect.text }
        return LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct JournalHeadingCheck {
    @MainActor static func main() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        for appearance in ["light", "dark"] {
            let effects = JournalHeadingEffects()
            let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
            let snapshot = #"{"ok":true,"result":{"graphName":"Work","selectedGraphId":"work","outlinerRows":[{"block":{"uuid":"entry","title":"Journal entry","pageId":"journal-page","journalTitle":"Oct 21st, 2026","journalDay":20261021},"depth":0}],"outlinerState":{"selectedBlockIds":[]}}}"#
            try runtime.applyCoreResponse(snapshot)
            try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
            try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer)
                .preferredColorScheme(appearance == "dark" ? .dark : .light)
                .transaction { $0.disablesAnimations = true; $0.animation = nil })
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
            try await Task.sleep(for: .milliseconds(700))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try image.pngData()!.write(to: documents.appendingPathComponent("journal-heading-\(appearance).png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
            let visible = (request.results ?? []).filter { $0.boundingBox.midY > 0.55 }
                .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            guard visible.contains("Oct 21st, 2026") else {
                throw failure("Journal date must be visible in the rendered \(appearance) screenshot; found: \(visible)")
            }
            let backend = runtime.renderer.backend
            func descendants(_ id: Int) -> [Int] {
                [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
            }
            guard let heading = backend.rootIDs.flatMap(descendants).first(where: {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == "button.journal.journal-page"
            }) else { throw failure("Missing journal navigation heading") }
            try backend.performPress(node: heading)
            await runtime.drainEffectsForTesting()
            guard effects.openedPage == "journal-page" else {
                throw failure("Pressing the visible date must open its journal page")
            }
        }
        print("PASS: journal dates are visible in light and dark screenshots and open their journal page")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "JournalHeading", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
