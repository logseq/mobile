import LUIAppleBackend
import SwiftUI

extension EnvironmentValues {
    @Entry var lgPropertyValue = false
}

@MainActor
enum LGPropertyExtension {
    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(LUIAppleExtension(
            identifier: "native-property-row",
            fingerprint: "lui-extension-v1|19:native-property-row|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:7:stacked:bool:required:none|events:",
            acceptsStandardChildren: true,
            properties: [.init(name: "stacked", kind: .bool, isRequired: true)]
        ) { context in
            let stacked = context.property("stacked") == .bool(true)
            return AnyView(LGPropertyRowLayout(stacked: stacked) {
                ForEach(context.childIDs, id: \.self) { id in
                    context.content(for: id)
                }
            }.environment(\.lgPropertyValue, true))
        })
        try registry.register(LUIAppleExtension(
            identifier: "native-property-date",
            fingerprint: "lui-extension-v1|20:native-property-date|profiles:android/kotlin,ios/swiftui|standard-children:0|children:|properties:10:identifier:string:required:none,4:kind:string:required:none,5:value:string:required:none|events:6:change[5:value:string:required]",
            properties: [
                .init(name: "identifier", kind: .string, isRequired: true),
                .init(name: "kind", kind: .string, isRequired: true),
                .init(name: "value", kind: .string, isRequired: true),
            ],
            events: [.init(name: "change", fields: [.init(name: "value", kind: .string, isRequired: true)])]
        ) { AnyView(LGPropertyDatePicker(context: $0)) })
    }
}

private struct LGPropertyRowLayout: Layout {
    let stacked: Bool

    private func metrics(width: CGFloat, subviews: Subviews) -> (Bool, CGFloat, CGSize, CGSize) {
        let keyWidth = min(148, width * 0.46)
        let intrinsic = subviews[0].sizeThatFits(.unspecified)
        let vertical = stacked || intrinsic.width > keyWidth || width - keyWidth - 8 < 96
        let key = subviews[0].sizeThatFits(.init(width: vertical ? width : keyWidth, height: nil))
        let value = subviews[1].sizeThatFits(.init(width: vertical ? width : width - keyWidth - 8, height: nil))
        return (vertical, keyWidth, key, value)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? 320
        let (vertical, _, key, value) = metrics(width: width, subviews: subviews)
        return .init(width: width, height: vertical ? key.height + 2 + value.height : max(key.height, value.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (vertical, keyWidth, key, value) = metrics(width: bounds.width, subviews: subviews)
        subviews[0].place(at: .init(x: bounds.minX, y: vertical ? bounds.minY : bounds.midY - key.height / 2),
                          proposal: .init(width: vertical ? bounds.width : keyWidth, height: key.height))
        subviews[1].place(at: .init(x: vertical ? bounds.minX : bounds.minX + keyWidth + 8,
                                  y: vertical ? bounds.minY + key.height + 2 : bounds.midY - value.height / 2),
                          proposal: .init(width: vertical ? bounds.width : bounds.width - keyWidth - 8, height: value.height))
    }
}

private struct LGPropertyDatePicker: View {
    let context: LUIAppleExtensionViewContext

    private func string(_ name: String) -> String {
        if case let .string(value) = context.property(name) { return value }
        return ""
    }
    private var includesTime: Bool { string("kind") == "datetime" }
    private var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
    private var selection: Binding<Date> {
        Binding(get: {
            if includesTime, let millis = Double(string("value")) { return Date(timeIntervalSince1970: millis / 1000) }
            return formatter.date(from: string("value")) ?? Date()
        }, set: { date in
            let value = includesTime ? String(Int64((date.timeIntervalSince1970 * 1000).rounded())) : formatter.string(from: date)
            do { try context.emit(name: "change", values: ["value": .string(value)]) }
            catch { logger.error("Could not update property date: \(String(describing: error))") }
        })
    }
    var body: some View {
        DatePicker("Value", selection: selection, displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date])
            .datePickerStyle(.graphical)
            .labelsHidden()
            .accessibilityIdentifier(string("identifier"))
    }
}
