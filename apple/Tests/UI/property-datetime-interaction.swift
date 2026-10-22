import SwiftUI
import Observation
import UIKit
@testable import Logseq

@MainActor @Observable private final class DateInteractionEffects: LGEffectExecuting {
    var submitted = "Not saved"
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "node-property",
           let value = try? JSONSerialization.jsonObject(with: Data(effect.text.utf8)) as? [String: Any],
           let timestamp = value["value"] as? String {
            if value["attr"] as? String == "user.property/Deadline", let millis = Double(timestamp) {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                submitted = "Saved datetime: " + formatter.string(from: Date(timeIntervalSince1970: millis / 1000))
            } else { submitted = "Saved date: " + timestamp }
        }
        return LGEffectResolution(succeeded: false, message: "Test capture", output: .discard)
    }
}

@main struct PropertyDateTimeInteractionApp: App {
    @State private var effects: DateInteractionEffects
    @State private var runtime: LGRuntime
    @State private var started = false

    init() {
        let effects = DateInteractionEffects()
        _effects = State(initialValue: effects)
        _runtime = State(initialValue: LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects))
    }

    var body: some Scene {
        WindowGroup {
            LGRendererRoot(renderer: runtime.renderer)
                .overlay(alignment: .top) {
                    Text(effects.submitted).accessibilityIdentifier("date.submitted")
                }
                .task {
                    guard !started else { return }
                    started = true
                    do {
                        let fixture = Bundle.main.url(forResource: "property-datetime-interaction", withExtension: "json")!
                        var snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
                        var result = snapshot["result"] as! [String: Any]
                        var panel = result["nodeProperties"] as! [String: Any]
                        var properties = panel["properties"] as! [[String: Any]]
                        let calendar = Calendar(identifier: .gregorian)
                        let initial = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 9, minute: 30))!
                        let index = properties.firstIndex { $0["attr"] as? String == "user.property/Deadline" }!
                        properties[index]["editorValue"] = String(Int64(initial.timeIntervalSince1970 * 1000))
                        panel["properties"] = properties
                        result["nodeProperties"] = panel
                        snapshot["result"] = result
                        let response = String(decoding: try JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self)
                        try runtime.applyCoreResponse(response)
                        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
                        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
                    } catch { effects.submitted = String(describing: error) }
                }
        }
    }
}
