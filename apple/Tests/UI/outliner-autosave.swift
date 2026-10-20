import Foundation
@testable import Logseq

@MainActor
private final class NativeQueue: @preconcurrency LGNativeCalling {
    var effects: [String] = []
    func initialize(platformCode: Int, hostCode: Int, authenticationCode: Int) -> String { "" }
    func appear(node: Int) -> String { "" }
    func press(node: Int) -> String { "" }
    func longPress(node: Int) -> String { "" }
    func textChanged(node: Int, text: String) -> String { "" }
    func submit(node: Int) -> String { "" }
    func toggleChanged(node: Int, checked: Bool) -> String { "" }
    func change(node: Int) -> String { "" }
    func valueChanged(node: Int, value: Double) -> String { "" }
    func dismiss(node: Int) -> String { "" }
    func doublePress(node: Int) -> String { "" }
    func picked(node: Int, payload: String) -> String { "" }
    func visibleRange(node: Int, first: Int, last: Int) -> String { "" }
    func scrollCompleted(node: Int, token: Int, outcome: String) -> String { "" }
    func extensionEvent(node: Int, identifier: String, name: String, text: String, value: Int) -> String { "" }
    func dispose() -> String { "" }
    func takeEffect() -> String { effects.isEmpty ? "" : effects.removeFirst() }
    func resolveEffect(id: Int, succeeded: Bool, message: String) -> String { "" }
    func applySnapshot(_ response: String) -> String { "" }
    func applyHostUpdate(kind: String, payload: String) -> String { "" }
}

@MainActor
private final class Recorder: LGEffectExecuting {
    var effects: [String] = []
    var result = "{}"
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        effects.append(effect.kind)
        return LGEffectResolution(succeeded: true, message: "{\"apiVersion\":1,\"ok\":true,\"result\":\(result)}")
    }
}

@main
struct Check {
    @MainActor static func main() async {
        var failed = false
        let cases: [(String, Bool, String)] = [
            ("choose-outliner-autocomplete", false, "{}"),
            ("change-outliner-text", false, "{}"),
            ("change-outliner-text", false, #"{"outlinerState":{"autocomplete":{"kind":"tag"}}}"#),
            ("change-outliner-text", false, #"{"outlinerState":{"autocomplete":null},"nodeRoutes":[{"outlinerState":{"autocomplete":{"kind":"node"}}}]}"#),
            ("change-outliner-text", false, #"{"outlinerState":{"autocomplete":{"kind":"tag"}},"nodeRoutes":[{"outlinerState":{"autocomplete":null}}]}"#),
        ]
        for (kind, shouldSave, result) in cases {
            let native = NativeQueue()
            native.effects = ["{\"id\":1,\"kind\":\"\(kind)\",\"text\":\"Project\"}"]
            let recorder = Recorder()
            recorder.result = result
            let runtime = LGRuntime(native: native, effectExecutor: recorder)
            await runtime.drainEffectsForTesting()
            try? await Task.sleep(for: .milliseconds(1100))
            await runtime.drainEffectsForTesting()
            let passed = recorder.effects.contains("save-outliner-editing") == shouldSave
            print("\(passed ? "PASS" : "FAIL"): \(kind), effects=\(recorder.effects)")
            failed = failed || !passed
        }
        let native = NativeQueue()
        native.effects = [
            #"{"id":1,"kind":"change-outliner-text","text":"Draft"}"#,
            #"{"id":2,"kind":"hydrate-outliner-rows","text":"[]"}"#,
            #"{"waitMs":1}"#,
            #"{"id":3,"kind":"save-outliner-editing","text":"editing"}"#,
        ]
        let recorder = Recorder()
        let runtime = LGRuntime(native: native, effectExecutor: recorder)
        await runtime.drainEffectsForTesting()
        try? await Task.sleep(for: .milliseconds(1100))
        await runtime.drainEffectsForTesting()
        let keepsAutosave = recorder.effects.contains("save-outliner-editing")
        print("\(keepsAutosave ? "PASS" : "FAIL"): native runtime executes the core save after its deadline")
        failed = failed || !keepsAutosave
        if failed { exit(1) }
    }
}

// This harness injects the effect boundary and must never initialize the native core.
#if !LOGSEQ_LINKED_CORE
@_cdecl("logseq_initialize")
func unexpectedCoreInitialization() { fatalError("Unexpected native core initialization") }
#endif
