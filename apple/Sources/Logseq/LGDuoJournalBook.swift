#if os(iOS)
import LUIAppleBackend
import SwiftUI
import UIKit

@available(iOS 18.0, *)
@MainActor
private struct LGDuoJournalPages: View {
    let context: LUIAppleExtensionViewContext
    let pages: [Int]
    let width: CGFloat
    let height: CGFloat
    @State private var position: Int?
    @Environment(\.layoutDirection) private var layoutDirection

    private var first: Int { context.property("first-index")?.intValue ?? 0 }
    private var selected: Int { context.property("selected-index")?.intValue ?? 0 }
    private var canTurn: Bool { context.property("can-turn") != .bool(false) }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Array(pages.enumerated().reversed()), id: \.element) { offset, node in
                    context.nodeView(of: node)
                        .frame(width: width, height: height)
                        .environment(\.layoutDirection, layoutDirection)
                        .accessibilityHidden(first + offset != selected)
                        .id(first + offset)
                }
            }
            .scrollTargetLayout()
            .background(LGJournalPagingPan(enabled: canTurn))
        }
        .defaultScrollAnchor(.trailing)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        .scrollIndicators(.hidden)
        .clipped()
        .scrollPosition(id: $position)
        .onChange(of: selected, initial: true) { _, index in
            if position != index { position = index }
        }
        .onScrollPhaseChange { _, phase in
            if phase == .idle { select(position) }
        }
        .onChange(of: canTurn) { _, enabled in
            if !enabled { position = selected }
        }
        .accessibilityScrollAction { edge in
            switch edge {
            case .leading: select(selected + 1)
            case .trailing: select(selected - 1)
            default: break
            }
        }
        // Page positions are chronological. The notes themselves still use the app language.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityIdentifier("journal.duo.book")
    }

    private func select(_ index: Int?) {
        guard canTurn, let index,
              index != selected, (first..<(first + pages.count)).contains(index) else { return }
        try? context.emit(name: "select", values: ["index": .int(index)])
    }
}

// Suspend the horizontal gesture while leaving both notes free to scroll vertically.
private struct LGJournalPagingPan: UIViewRepresentable {
    let enabled: Bool

    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Marker, context: Context) {
        view.enabled = enabled
        view.updatePan()
    }

    static func dismantleUIView(_ view: Marker, coordinator: ()) {
        view.pan?.isEnabled = true
    }

    final class Marker: UIView {
        var enabled = true
        weak var pan: UIPanGestureRecognizer?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            updatePan()
        }

        func updatePan() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    pan = scroll.panGestureRecognizer
                    pan?.isEnabled = enabled
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

@MainActor
struct LGDuoJournalBook: View {
    static let identifier = "duo-journal-book"
    let context: LUIAppleExtensionViewContext

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(LUIAppleExtension(
            identifier: identifier,
            fingerprint: "lui-extension-v1|16:duo-journal-book|profiles:ios/swiftui|standard-children:1|children:|properties:8:can-turn:bool:required:none,11:first-index:int:required:none,14:selected-index:int:required:none|events:6:resize[5:width:int:required],6:select[5:index:int:required]",
            acceptsStandardChildren: true,
            properties: [
                .init(name: "can-turn", kind: .bool, isRequired: true),
                .init(name: "first-index", kind: .int, isRequired: true),
                .init(name: "selected-index", kind: .int, isRequired: true),
            ],
            events: [
                .init(name: "resize", fields: [.init(name: "width", kind: .int, isRequired: true)]),
                .init(name: "select", fields: [.init(name: "index", kind: .int, isRequired: true)]),
            ]
        ) { AnyView(LGDuoJournalBook(context: $0)) })
    }

    var body: some View {
        let _ = context.revision
        let children = context.childIDs
        if #available(iOS 18.0, *), LGSidebarOverlay.isDuo, children.count == 2 {
            GeometryReader { geometry in
                let _ = context.measureStamp(of: children[1])
                let spreads = context.childIDs(of: children[1])
                if geometry.size.width >= 600, !spreads.isEmpty {
                    LGDuoJournalPages(context: context, pages: spreads,
                                      width: geometry.size.width, height: geometry.size.height)
                } else {
                    context.content(for: children[0])
                }
            }
            .onGeometryChange(for: Bool.self) { $0.size.width >= 600 } action: { wide in
                try? context.emit(name: "resize", values: ["width": .int(wide ? 600 : 0)])
            }
        } else if let classic = children.first {
            context.content(for: classic)
        }
    }
}

private extension LUIExtensionValue {
    var intValue: Int? {
        if case let .int(value) = self { return value }
        return nil
    }
}
#endif
