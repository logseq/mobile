import LUIAppleBackend
import SwiftUI

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
            fingerprint: "lui-extension-v1|16:bottom-tab-strip|profiles:ios/swiftui|standard-children:1|children:|properties:14:selected-index:int:required:none,5:inset:int:required:none|events:6:select[5:index:int:required]",
            acceptsStandardChildren: true,
            properties: [
                .init(name: "selected-index", kind: .int, isRequired: true),
                .init(name: "inset", kind: .int, isRequired: true),
            ],
            events: [.init(name: "select", fields: [.init(name: "index", kind: .int, isRequired: true)])]
        ) { AnyView(LGBottomTabStrip(context: $0)) })
    }

    var body: some View {
        let _ = context.revision
        let count = context.childIDs.first.map { context.childIDs(of: $0).count } ?? 0
        let selected = selectedIndex
        let inset = inset
        let cellWidth = (size.width - 2 * inset) / CGFloat(max(1, count))
        let position = dragPosition ?? (pendingSelection ?? selected).map { CGFloat($0) }
        context.content
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

    private var selectedIndex: Int? {
        guard case let .int(index) = context.property("selected-index"), index >= 0 else { return nil }
        return index
    }

    private var inset: CGFloat {
        guard case let .int(value) = context.property("inset") else { return 0 }
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
