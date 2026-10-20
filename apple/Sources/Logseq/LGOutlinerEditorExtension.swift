import LUIAppleBackend
import SwiftUI

@MainActor
enum LGOutlinerEditorExtension {
    static let identifier = "outliner-editor"
    static let fingerprint = "lui-extension-v1|15:outliner-editor|profiles:android/kotlin,ios/swiftui|standard-children:0|children:|properties:12:input-policy:string:required:none,18:caret-utf16-offset:int:required:none,5:title:string:required:none,8:block-id:string:required:none|events:11:text-change[18:caret-utf16-offset:int:required,5:title:string:required],12:caret-change[18:caret-utf16-offset:int:required],6:return[18:caret-utf16-offset:int:required,5:title:string:required],9:backspace[16:selection-length:int:required,5:title:string:required]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(
            LUIAppleExtension(
                identifier: identifier,
                fingerprint: fingerprint,
                properties: [
                    .init(name: "block-id", kind: .string, isRequired: true),
                    .init(name: "title", kind: .string, isRequired: true),
                    .init(name: "caret-utf16-offset", kind: .int, isRequired: true),
                    .init(name: "input-policy", kind: .string, isRequired: true),
                ],
                events: [
                    .init(name: "text-change", fields: [
                        .init(name: "title", kind: .string, isRequired: true),
                        .init(name: "caret-utf16-offset", kind: .int, isRequired: true),
                    ]),
                    .init(name: "return", fields: [
                        .init(name: "title", kind: .string, isRequired: true),
                        .init(name: "caret-utf16-offset", kind: .int, isRequired: true),
                    ]),
                    .init(name: "backspace", fields: [
                        .init(name: "title", kind: .string, isRequired: true),
                        .init(name: "selection-length", kind: .int, isRequired: true),
                    ]),
                    .init(name: "caret-change", fields: [
                        .init(name: "caret-utf16-offset", kind: .int, isRequired: true),
                    ]),
                ]
            ) { context in
                AnyView(LGOutlinerEditor(context: context))
            }
        )
    }
}

@MainActor
private struct LGOutlinerEditor: View {
    let context: LUIAppleExtensionViewContext

    var body: some View {
        OutlinerInlineEditor(
            text: stringProperty("title"),
            blockID: stringProperty("block-id"),
            desiredCaretUTF16Offset: intProperty("caret-utf16-offset"),
            inputPolicy: stringProperty("input-policy"),
            onTextChange: { title, caret in
                emit(name: "text-change", values: [
                    "title": .string(title),
                    "caret-utf16-offset": .int(caret),
                ])
            },
            onReturn: { title, caret in
                emit(name: "return", values: [
                    "title": .string(title),
                    "caret-utf16-offset": .int(caret),
                ])
            },
            onBackspace: { title, selectionLength in
                emit(name: "backspace", values: [
                    "title": .string(title),
                    "selection-length": .int(selectionLength),
                ])
            },
            onCaretChange: { caret in
                emit(name: "caret-change", values: [
                    "caret-utf16-offset": .int(caret),
                ])
            }
        )
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }

    private func stringProperty(_ name: String) -> String {
        guard case let .string(value) = context.property(name) else { return "" }
        return value
    }

    private func intProperty(_ name: String) -> Int {
        guard case let .int(value) = context.property(name) else { return 0 }
        return value
    }

    private func emit(name: String, values: [String: LUIExtensionValue]) {
        do {
            try context.emit(name: name, values: values)
        } catch {
            logger.error("Could not emit outliner editor event: \(String(describing: error))")
        }
    }
}
