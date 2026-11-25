#if os(iOS)
import LUIAppleBackend
import SwiftUI

@MainActor enum LGReactionPickerExtension {
    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(LUIAppleExtension(
            identifier: "native-reaction-picker",
            fingerprint: "lui-extension-v1|22:native-reaction-picker|profiles:ios/swiftui|standard-children:1|children:|properties:|events:7:dismiss[]",
            acceptsStandardChildren: true,
            events: [.init(name: "dismiss", fields: [])]
        ) { context in
            AnyView(LGReactionPickerPresentation(context: context))
        })
        try registry.register(LUIAppleExtension(
            identifier: "reaction-search-input",
            fingerprint: "lui-extension-v1|21:reaction-search-input|profiles:android/kotlin,ios/swiftui|standard-children:0|children:|properties:11:clear-title:string:required:none,11:placeholder:string:required:none|events:13:query-changed[5:query:string:required]",
            properties: [.init(name: "clear-title", kind: .string, isRequired: true),
                         .init(name: "placeholder", kind: .string, isRequired: true)],
            events: [.init(name: "query-changed", fields: [.init(name: "query", kind: .string, isRequired: true)])]
        ) { context in
            AnyView(LGReactionSearchInput(context: context))
        })
    }
}

private struct LGReactionPickerPresentation: View {
    let context: LUIAppleExtensionViewContext
    @State private var presented = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.logseqDarkTheme) private var darkTheme

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { presented = true }
            .sheet(isPresented: $presented, onDismiss: { try? context.emit(name: "dismiss") }) {
                if let content = context.childIDs.first {
                    context.content(for: content)
                        .presentationDetents([.fraction(0.42), .large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(LogseqThemePolicy.sheetBackground(
                            isDark: colorScheme == .dark, darkTheme: darkTheme
                        ))
                }
            }
    }
}
private struct LGReactionSearchInput: View {
    let context: LUIAppleExtensionViewContext
    @State private var query = ""
    @FocusState private var focused: Bool
    @Environment(\.luiSemanticColors) private var colors

    var body: some View {
        let placeholder = title("placeholder")
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("", text: $query, prompt: Text(verbatim: placeholder))
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { focused = false }
                .accessibilityLabel(Text(verbatim: placeholder))
                .accessibilityIdentifier("reaction.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: title("clear-title")))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(colors["task-tab-background"] ?? Color.primary.opacity(0.08), in: Capsule())
        .onChange(of: query) { _, text in
            try? context.emit(name: "query-changed", values: ["query": .string(text)])
        }
    }

    private func title(_ name: String) -> String {
        if case let .string(value) = context.property(name) { return value }
        return ""
    }
}
#endif
