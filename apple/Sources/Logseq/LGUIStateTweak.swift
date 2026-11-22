import LUIAppleBackend
import SwiftUI

@MainActor
enum LGUIStateTweak {
    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.registerTweak(LUIAppleTweak(
            identifier: "ui-state",
            fingerprint: "lui-tweak-v1|8:ui-state|profiles:ios/swiftui|properties:13:editor-active:bool:required:none,17:presentation-open:bool:required:none,6:screen:string:required:none",
            properties: [
                .init(name: "screen", kind: .string, isRequired: true),
                .init(name: "editor-active", kind: .bool, isRequired: true),
                .init(name: "presentation-open", kind: .bool, isRequired: true),
            ]
        ) { content, context in
            AnyView(LGUIStateContent(content: content, context: context))
        })
    }
}

private struct LGUIStateContent: View {
    let content: AnyView
    let context: LUIAppleExtensionViewContext

    private struct State: Equatable {
        let screen: String
        let editorActive: Bool
        let presentationOpen: Bool
    }

    var body: some View {
        let _ = context.revision
        let screen: String = if case let .string(value) = context.property("screen") { value } else { "unknown" }
        let state = State(screen: screen, editorActive: context.property("editor-active") == .bool(true),
                          presentationOpen: context.property("presentation-open") == .bool(true))
        content.onChange(of: state, initial: true) { _, state in
            #if os(iOS)
            LogseqCrashReporting.uiState(screen: .init(rawValue: state.screen) ?? .unknown,
                                        editorActive: state.editorActive)
            LogseqCrashReporting.presentation(.core, open: state.presentationOpen)
            #endif
        }
    }
}
