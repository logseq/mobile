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
            fingerprint: "lui-extension-v1|33:native-outliner-selection-toolbar|profiles:ios/swiftui|standard-children:1|children:|properties:10:more-label:string:required:none,12:more-actions:string:required:none,12:status-label:string:required:none,8:statuses:string:required:none|events:13:select-status[5:value:string:required],14:perform-action[5:value:string:required]",
            acceptsStandardChildren: true,
            properties: [.init(name: "more-actions", kind: .string, isRequired: true),
                         .init(name: "more-label", kind: .string, isRequired: true),
                         .init(name: "status-label", kind: .string, isRequired: true),
                         .init(name: "statuses", kind: .string, isRequired: true)],
            events: [.init(name: "perform-action", fields: [.init(name: "value", kind: .string, isRequired: true)]),
                     .init(name: "select-status", fields: [.init(name: "value", kind: .string, isRequired: true)])]
        ) { AnyView(OutlinerSelectionToolbar(context: $0)) })
    }

    var body: some View {
        if let toolbar = context.childIDs.first {
            let _ = context.revision
            let _ = context.measureStamp(of: toolbar)
            let children = context.childIDs(of: toolbar)
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    leadingCapsule(children, availableWidth: proxy.size.width - Self.cell - Self.capsuleGap)
                    Spacer(minLength: Self.capsuleGap)
                    moreButton
                }
            }
            .frame(height: Self.cell)
            .frame(height: 58)
            .padding(.horizontal, 16)
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
        .modifier(LGBottomBarGlass(surface: .selection))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbar.outliner.selection")
    }

    private var moreButton: some View {
        let label: String
        if case let .string(value) = context.property("more-label") { label = value }
        else { label = "More actions" }
        let actions: [SelectionActionsMenu.Action]
        if case let .string(value) = context.property("more-actions") {
            actions = (try? JSONDecoder().decode([SelectionActionsMenu.Action].self, from: Data(value.utf8))) ?? []
        } else {
            actions = []
        }
        return SelectionActionsMenu(label: label, actions: actions) { action in
            guard context.isUserInteractionEnabled else { return }
            try? context.emit(name: "perform-action", values: ["value": .string(action)])
        }
        .frame(width: Self.cell, height: Self.cell)
        .modifier(LGBottomBarGlass(surface: .trailing))
    }
}

private struct SelectionActionsMenu: UIViewRepresentable {
    struct Action: Decodable, Equatable {
        let action: String
        let title: String
        let icon: String
        let destructive: Bool
    }

    final class Coordinator {
        var actions: [Action] = []
        var perform: ((String) -> Void)?
    }

    let label: String
    let actions: [Action]
    let perform: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19))
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = .label
        button.configuration = configuration
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "button.outliner.selection.more"
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.perform = perform
        button.accessibilityLabel = label
        button.isEnabled = !actions.isEmpty
        // Keep UIKit's presented menu attached during unrelated graph updates.
        guard coordinator.actions != actions else { return }
        coordinator.actions = actions
        let icons = LGIconPolicy.icons
        button.menu = UIMenu(children: actions.map { item in
            let image: UIImage?
            if case let .systemName(name) = icons[item.icon] {
                image = UIImage(systemName: name)
            } else {
                image = nil
            }
            return UIAction(
                title: item.title,
                image: image,
                identifier: UIAction.Identifier("button.outliner.selection.menu." + item.action),
                attributes: item.destructive ? .destructive : []
            ) { [weak coordinator] _ in
                coordinator?.perform?(item.action)
            }
        })
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
