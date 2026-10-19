import Foundation
@testable import Logseq

@MainActor
private final class NativeProbe: @preconcurrency LGNativeCalling {
    var effects: [String] = []
    var calls: [String] = []
    var delayEmptyEffectRead = false
    var enqueueOnPress = false
    var resolved: [Int] = []
    private var asynchronous = false
    private var generation = 1
    private func patch() -> String {
        generation += 1
        return "{\"generation\":\(generation),\"ops\":[]}"
    }
    func performAsync(_ operation: LGNativeOperation) async -> String {
        if case .snapshot = operation { try? await Task.sleep(for: .milliseconds(100)) }
        if case .takeEffect = operation, delayEmptyEffectRead, effects.isEmpty {
            delayEmptyEffectRead = false
            try? await Task.sleep(for: .milliseconds(100))
            return ""
        }
        asynchronous = true
        defer { asynchronous = false }
        return operation.perform(on: self)
    }
    func initialize(platformCode: Int, hostCode: Int, authenticationCode: Int) -> String { "{\"generation\":1,\"ops\":[]}" }
    func appear(node: Int) -> String { "" }
    func press(node: Int) -> String {
        calls.append("press")
        if enqueueOnPress { effects.append(#"{"id":42,"kind":"probe","text":""}"#) }
        return patch()
    }
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
    func resolveEffect(id: Int, succeeded: Bool, message: String) -> String { resolved.append(id); return "" }
    func applySnapshot(_ response: String) -> String {
        if !asynchronous { Thread.sleep(forTimeInterval: 0.1) }
        calls.append("snapshot")
        return patch()
    }
    func applyHostUpdate(kind: String, payload: String) -> String { "" }
}

@MainActor private final class DiscardExecutor: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct CheckNativeWorkQueue {
    @MainActor static func main() async throws {
        let native = NativeProbe()
        let runtime = LGRuntime(native: native)
        try runtime.start(platformCode: 2)
        let started = ProcessInfo.processInfo.systemUptime
        try runtime.applyCoreResponse(#"{"ok":true,"result":{"graphName":"Large graph"}}"#)
        runtime.renderer.onEvent?(LGRendererEvent(kind: .press, nodeID: 1))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        precondition(elapsed < 0.02, "Submitting native work blocked the main actor")
        var heartbeats = 0
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(10))
            heartbeats += 1
        }
        precondition(heartbeats == 15)
        precondition(native.calls == ["snapshot", "press"], "Native input overtook its snapshot")
        precondition(runtime.renderer.backend.generation == 3, "Patches were reordered")
        try runtime.applyCoreResponse(#"{"ok":true,"result":{"graphName":"Stale graph"}}"#)
        runtime.stop()
        try await Task.sleep(for: .milliseconds(150))
        precondition(native.calls == ["snapshot", "press"], "Stopped work was executed")
        print("PASS: native UI work keeps the main actor responsive, preserves ordering, and drops stopped work")
        let racingNative = NativeProbe()
        racingNative.delayEmptyEffectRead = true
        racingNative.enqueueOnPress = true
        let racingRuntime = LGRuntime(native: racingNative, effectExecutor: DiscardExecutor())
        try racingRuntime.start(platformCode: 2)
        try await Task.sleep(for: .milliseconds(20))
        racingRuntime.renderer.onEvent?(LGRendererEvent(kind: .press, nodeID: 1))
        try await Task.sleep(for: .milliseconds(250))
        precondition(racingNative.resolved == [42], "An input arriving during an empty effect read lost its wakeup")
        racingRuntime.stop()
        print("PASS: input during an empty async effect read is still drained")
    }
}

#if !LOGSEQ_LINKED_CORE
@_cdecl("logseq_initialize")
func unexpectedCoreInitialization() { fatalError("Unexpected native core initialization") }
#endif
