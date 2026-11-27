import LUIAppleBackend
import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
struct LGBottomTabStrip: View {
    let context: LUIAppleExtensionViewContext

    @Environment(\.luiSemanticColors) private var colors
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @GestureState private var dragPosition: CGFloat?
    @State private var pendingSelection: Int?
    @State private var size: CGSize = .zero

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(LUIAppleExtension(
            identifier: "bottom-tab-strip",
            fingerprint: "lui-extension-v1|16:bottom-tab-strip|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:10:cell-width:int:required:none,14:selected-index:int:required:none,5:inset:int:required:none,5:items:string:required:none|events:6:select[5:index:int:required]",
            acceptsStandardChildren: true,
            properties: [
                .init(name: "selected-index", kind: .int, isRequired: true),
                .init(name: "inset", kind: .int, isRequired: true),
                .init(name: "items", kind: .string, isRequired: true),
                .init(name: "cell-width", kind: .int, isRequired: true),
            ],
            events: [
                .init(name: "select", fields: [.init(name: "index", kind: .int, isRequired: true)]),
            ]
        ) { AnyView(LGBottomTabStrip(context: $0)) })
    }

    @ViewBuilder var body: some View {
        let _ = context.revision
        #if os(iOS)
        if #available(iOS 26.0, *), let items = nativeItems {
            let horizontalMargin: CGFloat = 21
            LGNativeBottomTabBar(
                items: items, selectedIndex: selectedIndex,
                tint: colors["link"], foreground: colors["foreground"], layoutDirection: layoutDirection,
                context: context
            )
            // UITabBar reserves horizontal margins around its floating capsule.
            .frame(width: CGFloat(items.count) * tabWidth + inset * 2 + 2 * horizontalMargin, height: 58)
            .padding(.horizontal, -horizontalMargin)
            .background(LGSidebarPanExclusion())
            // Align the floating items within UITabBar with the trailing actions.
            .offset(y: 11)
        } else {
            fallbackStrip
        }
        #else
        fallbackStrip
        #endif
    }

    private var fallbackStrip: some View {
        let count = context.childIDs.first.map { context.childIDs(of: $0).count } ?? 0
        let selected = selectedIndex
        let inset = inset
        let cellWidth = (size.width - 2 * inset) / CGFloat(max(1, count))
        let position = dragPosition ?? (pendingSelection ?? selected).map { CGFloat($0) }
        return context.content
            .background {
                if let position, count > 0, cellWidth > 0 {
                    let center = inset + (position + 0.5) * cellWidth
                    indicator(dragging: dragPosition != nil)
                        .frame(width: cellWidth, height: max(0, size.height - 2 * inset))
                        .position(x: horizontalPosition(center), y: size.height / 2)
                        .animation(dragPosition == nil && !reduceMotion ? .spring(duration: 0.28, bounce: 0) : nil,
                                   value: position)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
            .contentShape(Capsule())
            .highPriorityGesture(tabDrag(count: count, cellWidth: cellWidth, inset: inset))
            .onChange(of: selected) { pendingSelection = nil }
            #if os(iOS)
            .background(LGSidebarPanExclusion())
            #endif
            .modifier(LGBottomBarGlass(surface: .capture))
    }

    #if os(iOS)
    private var nativeItems: [LGNativeBottomTabBar.Item]? {
        guard case let .string(json) = context.property("items") else { return nil }
        return try? JSONDecoder().decode([LGNativeBottomTabBar.Item].self, from: Data(json.utf8))
    }
    #endif

    private var selectedIndex: Int? {
        guard case let .int(index) = context.property("selected-index"), index >= 0 else { return nil }
        return index
    }

    private var inset: CGFloat {
        guard case let .int(value) = context.property("inset") else { return 0 }
        return CGFloat(value)
    }

    private var tabWidth: CGFloat {
        guard case let .int(value) = context.property("cell-width") else { return 58 }
        return CGFloat(value)
    }

    @ViewBuilder
    private func indicator(dragging: Bool) -> some View {
        let capsule = Capsule().fill(colors["bottom-tab-selected"] ?? Color.primary.opacity(0.12))
        if #available(iOS 26.0, macOS 26.0, *), !reduceTransparency {
            capsule.glassEffect(dragging ? .regular : .identity, in: .capsule)
        } else {
            capsule
        }
    }

    private func horizontalPosition(_ value: CGFloat) -> CGFloat {
        layoutDirection == .rightToLeft ? size.width - value : value
    }

    private func tabDrag(count: Int, cellWidth: CGFloat, inset: CGFloat) -> some Gesture {
        func index(at x: CGFloat) -> CGFloat {
            (horizontalPosition(x) - inset) / cellWidth - 0.5
        }
        func isHorizontal(_ value: DragGesture.Value) -> Bool {
            abs(value.translation.width) > abs(value.translation.height)
        }
        return DragGesture(minimumDistance: 8)
            .updating($dragPosition) { value, position, transaction in
                guard count > 0, cellWidth > 0, position != nil || isHorizontal(value) else { return }
                let raw = index(at: value.location.x)
                let clamped = min(max(raw, 0), CGFloat(count - 1))
                // Give the outer tabs a few points of elastic travel.
                position = clamped + min(max((raw - clamped) * 0.2, -0.08), 0.08)
                transaction.animation = nil
            }
            .onEnded { value in
                guard count > 0, cellWidth > 0, isHorizontal(value), context.isUserInteractionEnabled else { return }
                let target = Int(min(max(index(at: value.location.x), 0), CGFloat(count - 1)).rounded())
                guard target != selectedIndex else { return }
                do {
                    try context.emit(name: "select", values: ["index": .int(target)])
                    pendingSelection = target
                } catch {
                    pendingSelection = nil
                }
            }
    }
}

#if os(iOS)
private struct LGNativeBottomTabBar: UIViewRepresentable {
    struct Item: Decodable, Equatable {
        let title: String
        let name: String
        let image: String
        let selectedImage: String
        let unread: Bool?

        @MainActor func configure(_ item: UITabBarItem, tag: Int, foreground: UIColor, accent: UIColor) {
            item.image = icon(image, foreground: foreground, accent: accent)
            item.selectedImage = icon(selectedImage, foreground: accent, accent: accent)
            item.tag = tag
            item.accessibilityLabel = title
            item.accessibilityIdentifier = "tab.bottom.\(name)"
        }

        @MainActor private func icon(_ iconName: String, foreground: UIColor, accent: UIColor) -> UIImage? {
            switch LGIconPolicy.icons[iconName] {
            case let .systemName(symbol):
                if name == "notifications",
                   let bell = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24)) {
                    let size = CGSize(width: 26, height: 26)
                    return UIGraphicsImageRenderer(size: size).image { context in
                        let origin = CGPoint(x: (size.width - bell.size.width) / 2, y: (size.height - bell.size.height) / 2)
                        if unread == true {
                            bell.withTintColor(foreground, renderingMode: .alwaysOriginal).draw(at: origin)
                            context.cgContext.setFillColor(accent.cgColor)
                            context.cgContext.fillEllipse(in: CGRect(x: size.width / 2 - 2, y: 9, width: 4, height: 4))
                        } else {
                            bell.draw(at: origin)
                        }
                    }.withRenderingMode(unread == true ? .alwaysOriginal : .alwaysTemplate)
                }
                return UIImage(systemName: symbol)
            case let .assetName(asset):
                return UIImage(named: asset, in: .module, compatibleWith: nil)
            default:
                return nil
            }
        }
    }

    let items: [Item]
    let selectedIndex: Int?
    let tint: Color?
    let foreground: Color?
    let layoutDirection: LayoutDirection
    let context: LUIAppleExtensionViewContext

    func makeCoordinator() -> Coordinator {
        Coordinator(context: context)
    }

    func makeUIView(context: Context) -> UITabBar {
        let bar = UITabBar()
        bar.delegate = context.coordinator
        return bar
    }

    func updateUIView(_ bar: UITabBar, context: Context) {
        let coordinator = context.coordinator
        coordinator.context = self.context
        let trait = bar.traitCollection
        let primary = (foreground.map { UIColor($0) } ?? UIColor.label).resolvedColor(with: trait)
        let accent = (tint.map { UIColor($0) } ?? bar.tintColor ?? UIColor.systemBlue).resolvedColor(with: trait)
        let unreadColors = items.contains { $0.unread == true } ? [primary, accent] : []
        if coordinator.items.map(\.name) != items.map(\.name) {
            bar.items = items.enumerated().map { index, item in
                let tab = UITabBarItem(title: nil, image: nil, selectedImage: nil)
                item.configure(tab, tag: index, foreground: primary, accent: accent)
                return tab
            }
        } else if let tabs = bar.items {
            for (index, item) in items.enumerated() where item != coordinator.items[index]
                || (item.unread == true && coordinator.unreadColors != unreadColors) {
                item.configure(tabs[index], tag: index, foreground: primary, accent: accent)
            }
        }
        coordinator.items = items
        coordinator.unreadColors = unreadColors
        coordinator.selectedIndex = selectedIndex
        if bar.selectedItem?.tag != selectedIndex {
            bar.selectedItem = bar.items?.first(where: { $0.tag == selectedIndex })
        }
        bar.tintColor = tint.map { UIColor($0) }
        bar.semanticContentAttribute = layoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
    }

    @MainActor final class Coordinator: NSObject, UITabBarDelegate {
        var context: LUIAppleExtensionViewContext
        var items: [Item] = []
        var unreadColors: [UIColor] = []
        var selectedIndex: Int?

        init(context: LUIAppleExtensionViewContext) {
            self.context = context
        }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            if context.isUserInteractionEnabled {
                try? context.emit(name: "select", values: ["index": .int(item.tag)])
            } else {
                tabBar.selectedItem = tabBar.items?.first(where: { $0.tag == selectedIndex })
            }
        }
    }
}
#endif
