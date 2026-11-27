#if os(iOS)
import LUIAppleBackend
import SwiftUI

struct LGComposerAttachmentRemove: View {
    let context: LUIAppleExtensionViewContext

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(LUIAppleExtension(
            identifier: "composer-attachment-remove",
            fingerprint: "lui-extension-v1|26:composer-attachment-remove|profiles:ios/swiftui|standard-children:1|children:|properties:5:label:string:required:none|events:6:remove[]",
            acceptsStandardChildren: true,
            properties: [.init(name: "label", kind: .string, isRequired: true)],
            events: [.init(name: "remove", fields: [])]
        ) { AnyView(LGComposerAttachmentRemove(context: $0)) })
    }

    var body: some View {
        let _ = context.revision
        context.content
            .allowsHitTesting(false)
            .overlay(alignment: .topTrailing) { removeButton }
    }

    private var removeButton: some View {
        Button {
            guard context.isUserInteractionEnabled else { return }
            try? context.emit(name: "remove")
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.black.opacity(0.6), in: Circle())
                .padding([.top, .trailing], 8)
                .frame(width: 44, height: 44, alignment: .topTrailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier("composer.asset.remove")
    }

    private var label: String {
        guard case let .string(label) = context.property("label") else { return "Remove attachment" }
        return label
    }
}
#endif
