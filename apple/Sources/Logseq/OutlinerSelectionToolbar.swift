#if os(iOS)
import LUIAppleBackend
import SwiftUI
import UIKit

@MainActor
struct OutlinerSelectionToolbar: View {
    let context: LUIAppleExtensionViewContext
    @Environment(\.luiSemanticColors) private var semanticColors

    private static let cell: CGFloat = 44
    private static let capsuleGap: CGFloat = 12

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(LUIAppleExtension(
            identifier: "native-outliner-selection-toolbar",
            fingerprint: "lui-extension-v1|33:native-outliner-selection-toolbar|profiles:ios/swiftui|standard-children:1|children:|properties:12:status-label:string:required:none,8:statuses:string:required:none|events:13:select-status[5:value:string:required]",
            acceptsStandardChildren: true,
            properties: [.init(name: "status-label", kind: .string, isRequired: true),
                         .init(name: "statuses", kind: .string, isRequired: true)],
            events: [.init(name: "select-status", fields: [.init(name: "value", kind: .string, isRequired: true)])]
        ) { AnyView(OutlinerSelectionToolbar(context: $0)) })
    }

    var body: some View {
        if let toolbar = context.childIDs.first {
            let _ = context.measureStamp(of: toolbar)
            let children = context.childIDs(of: toolbar)
            if let more = children.last {
                let leading = Array(children.dropLast())
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        leadingCapsule(leading, availableWidth: proxy.size.width - Self.cell - Self.capsuleGap)
                        Spacer(minLength: Self.capsuleGap)
                        moreButton(more)
                    }
                }
                .frame(height: Self.cell)
                .frame(height: 58)
                .padding(.horizontal, 16)
            }
        }
    }

    private var statuses: [OutlinerRowPayload.Status] {
        guard case let .string(encoded) = context.property("statuses") else { return [] }
        return (try? JSONDecoder().decode([OutlinerRowPayload.Status].self, from: Data(encoded.utf8))) ?? []
    }

    private var statusLabel: String {
        if case let .string(value) = context.property("status-label") { return value }
        return "Status"
    }

    private func leadingCapsule(_ ids: [Int], availableWidth: CGFloat) -> some View {
        let intrinsic = CGFloat(ids.count) * Self.cell
        let width = min(intrinsic, max(Self.cell, availableWidth))
        return ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(ids, id: \.self) { id in
                    Group {
                        if id == ids.first {
                            SelectionStatusMenu(label: statusLabel, statuses: statuses, semanticColors: semanticColors) { uuid in
                                try? context.emit(name: "select-status", values: ["value": .string(uuid)])
                            }
                        } else {
                            context.nodeView(of: id).buttonStyle(.plain)
                        }
                    }
                    .frame(width: Self.cell, height: Self.cell)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollDisabled(intrinsic <= width)
        .frame(width: width, height: Self.cell)
        .clipShape(Capsule())
        .modifier(LGLiquidGlassSurface(shape: .capsule))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbar.outliner.selection")
    }

    private func moreButton(_ id: Int) -> some View {
        context.nodeView(of: id)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .frame(width: Self.cell, height: Self.cell)
            .modifier(LGLiquidGlassSurface(shape: .circle))
    }
}

private struct SelectionStatusMenu: UIViewRepresentable {
    let label: String
    let statuses: [OutlinerRowPayload.Status]
    let semanticColors: [String: Color]
    let select: (String) -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "checkmark.square", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19))
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = .label
        button.configuration = configuration
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "button.outliner.selection.status"
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.accessibilityLabel = label
        button.isEnabled = !statuses.isEmpty
        button.menu = UIMenu(children: statuses.map { status in
            UIAction(title: status.title, image: status.menuImage(in: semanticColors)) { _ in select(status.uuid) }
        })
    }
}
#endif
