import Foundation
import LUIAppleBackend
import Observation
import LogseqModel

public protocol LGNativeCalling {
    @MainActor func performAsync(_ operation: LGNativeOperation) async -> String
    func initialize(
        platformCode: Int,
        hostCode: Int,
        authenticationCode: Int
    ) -> String
    func appear(node: Int) -> String
    func press(node: Int) -> String
    func longPress(node: Int) -> String
    func textChanged(node: Int, text: String) -> String
    func submit(node: Int) -> String
    func toggleChanged(node: Int, checked: Bool) -> String
    func change(node: Int) -> String
    func valueChanged(node: Int, value: Double) -> String
    func dismiss(node: Int) -> String
    func doublePress(node: Int) -> String
    func extensionEvent(
        node: Int,
        identifier: String,
        name: String,
        text: String,
        value: Int
    ) -> String
    func picked(node: Int, payload: String) -> String
    func visibleRange(node: Int, first: Int, last: Int) -> String
    func scrollCompleted(node: Int, token: Int, outcome: String) -> String
    func dispose() -> String
    func takeEffect() -> String
    func resolveEffect(id: Int, succeeded: Bool, message: String) -> String
    func applySnapshot(_ response: String) -> String
    func applyHostUpdate(kind: String, payload: String) -> String
}

public enum LGNativeOperation: Sendable {
    case appear(Int), press(Int), longPress(Int), submit(Int), change(Int), dismiss(Int), doublePress(Int)
    case textChanged(Int, String), toggleChanged(Int, Bool), valueChanged(Int, Double)
    case extensionEvent(Int, String, String, String, Int), picked(Int, String)
    case visibleRange(Int, Int, Int), scrollCompleted(Int, Int, String)
    case takeEffect, resolveEffect(Int, Bool, String), snapshot(String), hostUpdate(String, String)

    func perform(on native: any LGNativeCalling) -> String {
        switch self {
        case let .appear(node): native.appear(node: node)
        case let .press(node): native.press(node: node)
        case let .longPress(node): native.longPress(node: node)
        case let .submit(node): native.submit(node: node)
        case let .change(node): native.change(node: node)
        case let .dismiss(node): native.dismiss(node: node)
        case let .doublePress(node): native.doublePress(node: node)
        case let .textChanged(node, text): native.textChanged(node: node, text: text)
        case let .toggleChanged(node, checked): native.toggleChanged(node: node, checked: checked)
        case let .valueChanged(node, value): native.valueChanged(node: node, value: value)
        case let .extensionEvent(node, identifier, name, text, value):
            native.extensionEvent(node: node, identifier: identifier, name: name, text: text, value: value)
        case let .picked(node, payload): native.picked(node: node, payload: payload)
        case let .visibleRange(node, first, last): native.visibleRange(node: node, first: first, last: last)
        case let .scrollCompleted(node, token, outcome): native.scrollCompleted(node: node, token: token, outcome: outcome)
        case .takeEffect: native.takeEffect()
        case let .resolveEffect(id, succeeded, message): native.resolveEffect(id: id, succeeded: succeeded, message: message)
        case let .snapshot(response): native.applySnapshot(response)
        case let .hostUpdate(kind, payload): native.applyHostUpdate(kind: kind, payload: payload)
        }
    }
}

extension LGNativeCalling {
    @MainActor public func performAsync(_ operation: LGNativeOperation) async -> String {
        operation.perform(on: self)
    }
}

// All native access is serialized by LogseqCoreExecutor, including async UI jobs.
public final class LGCoreNativeCaller: LGNativeCalling, @unchecked Sendable {
    private let core: LogseqCore

    public init(core: LogseqCore = LogseqCore.shared) {
        self.core = core
    }

    @MainActor public func performAsync(_ operation: LGNativeOperation) async -> String {
        await LogseqCore.performUIAsync { operation.perform(on: self) }
    }

    public func initialize(
        platformCode: Int,
        hostCode: Int,
        authenticationCode: Int
    ) -> String {
        core.logseq_lui_initialize(
            platformCode,
            hostCode,
            authenticationCode
        )
    }

    public func appear(node: Int) -> String { core.logseq_lui_appear(node) }
    public func press(node: Int) -> String { core.logseq_lui_press(node) }
    public func longPress(node: Int) -> String { core.logseq_lui_long_press(node) }
    public func textChanged(node: Int, text: String) -> String {
        core.logseq_lui_text_changed(node, text)
    }
    public func submit(node: Int) -> String { core.logseq_lui_submit(node) }
    public func toggleChanged(node: Int, checked: Bool) -> String {
        core.logseq_lui_toggle_changed(node, checked)
    }
    public func change(node: Int) -> String { core.logseq_lui_change(node) }
    public func valueChanged(node: Int, value: Double) -> String {
        core.logseq_lui_value_changed(node, value)
    }
    public func dismiss(node: Int) -> String { core.logseq_lui_dismiss(node) }
    public func doublePress(node: Int) -> String {
        core.logseq_lui_double_press(node)
    }
    public func extensionEvent(
        node: Int,
        identifier: String,
        name: String,
        text: String,
        value: Int
    ) -> String {
        core.logseq_lui_extension_event(node, identifier, name, text, value)
    }
    public func picked(node: Int, payload: String) -> String {
        core.logseq_lui_picked(node, payload)
    }
    public func visibleRange(node: Int, first: Int, last: Int) -> String {
        core.logseq_lui_visible_range(node, first, last)
    }
    public func scrollCompleted(node: Int, token: Int, outcome: String) -> String {
        core.logseq_lui_scroll_completed(node, token, outcome)
    }
    public func dispose() -> String { core.logseq_lui_dispose() }
    public func takeEffect() -> String { core.logseq_lui_take_effect() }
    public func resolveEffect(id: Int, succeeded: Bool, message: String) -> String {
        core.logseq_lui_resolve_effect(id, succeeded, message)
    }
    public func applySnapshot(_ response: String) -> String {
        core.logseq_lui_apply_snapshot(response)
    }
    public func applyHostUpdate(kind: String, payload: String) -> String {
        core.logseq_lui_apply_host_update(kind, payload)
    }
}
