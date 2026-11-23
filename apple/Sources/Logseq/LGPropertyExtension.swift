import LUIAppleBackend
import SwiftUI
#if os(iOS)
import UIKit
#endif

extension EnvironmentValues {
    @Entry var lgPropertyValue = false
}

@MainActor
enum LGPropertyExtension {
    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(LUIAppleExtension(
            identifier: "native-table-viewport",
            fingerprint: "lui-extension-v1|21:native-table-viewport|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:10:identifier:string:required:none|events:16:viewport-changed[5:width:int:required,6:offset:int:required]",
            acceptsStandardChildren: true,
            properties: [.init(name: "identifier", kind: .string, isRequired: true)],
            events: [.init(name: "viewport-changed", fields: [
                .init(name: "offset", kind: .int, isRequired: true),
                .init(name: "width", kind: .int, isRequired: true)])]
        ) { AnyView(LGTableViewport(context: $0)) })
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
            identifier: "outliner-continuation",
            fingerprint: "lui-extension-v1|21:outliner-continuation|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:10:identifier:string:required:none,11:guide-count:int:required:none,12:bullet-depth:int:required:none|events:",
            acceptsStandardChildren: true,
            properties: [.init(name: "bullet-depth", kind: .int, isRequired: true),
                         .init(name: "guide-count", kind: .int, isRequired: true),
                         .init(name: "identifier", kind: .string, isRequired: true)]
        ) { context in
            let count: Int = if case let .int(value) = context.property("guide-count") { value } else { 0 }
            let identifier: String = if case let .string(value) = context.property("identifier") { value } else { "" }
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                ForEach(context.childIDs, id: \.self) { context.content(for: $0) }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    #if os(iOS)
                    OutlinerIndentGuides(identifier: identifier, guideCount: count)
                    #else
                    Canvas { context, size in
                        context.stroke(Path(OutlinerGuideGeometry.path(depth: count, expanded: false, size: size)),
                            with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                    }.allowsHitTesting(false)
                    #endif
                })
        })
        try registry.register(LUIAppleExtension(
            identifier: "journal-refresh",
            fingerprint: "lui-extension-v1|15:journal-refresh|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:10:refreshing:bool:required:none,7:enabled:bool:required:none|events:7:refresh[]",
            acceptsStandardChildren: true,
            properties: [
                .init(name: "enabled", kind: .bool, isRequired: true),
                .init(name: "refreshing", kind: .bool, isRequired: true),
            ],
            events: [.init(name: "refresh", fields: [])]
        ) { context in
            #if os(iOS)
            return AnyView(LGJournalRefresh(
                enabled: context.property("enabled") == .bool(true),
                refreshing: context.property("refreshing") == .bool(true),
                refresh: { try? context.emit(name: "refresh", values: [:]) }
            ).frame(width: 1, height: 1).accessibilityHidden(true))
            #else
            return AnyView(EmptyView())
            #endif
        })
        #if os(iOS)
        try registry.register(LUIAppleExtension(
            identifier: "journal-task-transition",
            fingerprint: "lui-extension-v1|23:journal-task-transition|profiles:ios/swiftui|standard-children:1|children:|properties:9:collapsed:string:required:none|events:",
            acceptsStandardChildren: true,
            properties: [.init(name: "collapsed", kind: .string, isRequired: true)]
        ) { AnyView(LGJournalTaskTransition(context: $0)) })
        try registry.register(LUIAppleExtension(
            identifier: "journal-task-chevron",
            fingerprint: "lui-extension-v1|20:journal-task-chevron|profiles:ios/swiftui|standard-children:1|children:|properties:9:collapsed:bool:required:none|events:",
            acceptsStandardChildren: true,
            properties: [.init(name: "collapsed", kind: .bool, isRequired: true)]
        ) { AnyView(LGJournalTaskChevron(context: $0)) })
        #endif
        try registry.register(LUIAppleExtension(
            identifier: "native-property-date",
            fingerprint: "lui-extension-v1|20:native-property-date|profiles:android/kotlin,ios/swiftui|standard-children:0|children:|properties:10:identifier:string:required:none,4:kind:string:required:none,10:time-label:string:required:none,5:value:string:required:none|events:6:change[5:value:string:required]",
            properties: [
                .init(name: "identifier", kind: .string, isRequired: true),
                .init(name: "kind", kind: .string, isRequired: true),
                .init(name: "time-label", kind: .string, isRequired: true),
                .init(name: "value", kind: .string, isRequired: true),
            ],
            events: [.init(name: "change", fields: [.init(name: "value", kind: .string, isRequired: true)])]
        ) { AnyView(LGPropertyDatePicker(context: $0)) })
    }
}

#if os(iOS)
private let journalDisclosureAnimation = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)

private struct LGJournalTaskTransition: View {
    let context: LUIAppleExtensionViewContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = context.revision
        ForEach(context.childIDs, id: \.self) { id in
            context.content(for: id)
        }
        .animation(
            reduceMotion ? nil : journalDisclosureAnimation,
            value: context.property("collapsed")
        )
    }
}

private struct LGJournalTaskChevron: View {
    let context: LUIAppleExtensionViewContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        let _ = context.revision
        let collapsed = context.property("collapsed") == .bool(true)
        let leftToRight = layoutDirection == .leftToRight
        ForEach(context.childIDs, id: \.self) { id in
            context.content(for: id)
                .rotationEffect(.degrees(collapsed ? (leftToRight ? 0 : 180) : 90))
        }
        .animation(reduceMotion ? nil : journalDisclosureAnimation, value: collapsed)
        .accessibilityHidden(true)
    }
}

private struct LGJournalRefresh: UIViewRepresentable {
    let enabled: Bool
    let refreshing: Bool
    let refresh: @MainActor () -> Void

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.refresh = refresh
        view.enabled = enabled
        view.refreshing = refreshing
        view.updateControl()
    }

    static func dismantleUIView(_ view: Probe, coordinator: Void) {
        view.detach()
    }

    final class Probe: UIView {
        var refresh: (@MainActor () -> Void)?
        var enabled = false
        var refreshing = false
        private weak var scrollView: UIScrollView?
        private var previousBounce = false
        private var controlObservation: NSKeyValueObservation?
        private lazy var control: UIRefreshControl = {
            let control = UIRefreshControl()
            control.accessibilityIdentifier = "journal-tasks.refresh-control"
            control.addTarget(self, action: #selector(didRefresh), for: .valueChanged)
            return control
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateControl()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            updateControl()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if scrollView?.refreshControl !== control { updateControl() }
        }

        func updateControl() {
            guard enabled, window != nil else {
                detach()
                return
            }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) {
                ancestor = view.superview
            }
            guard let scroll = ancestor as? UIScrollView else { return }
            if scroll !== scrollView {
                detach()
                guard scroll.refreshControl == nil else { return }
                scrollView = scroll
                previousBounce = scroll.alwaysBounceVertical
                controlObservation = scroll.observe(\.refreshControl, options: [.new]) { [weak self] _, _ in
                    // SwiftUI can replace the control when it updates the host scroll view.
                    Task { @MainActor [weak self] in
                        guard let self, scrollView?.refreshControl !== control else { return }
                        updateControl()
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, scrollView?.refreshControl !== control else { return }
                    updateControl()
                }
            }
            if scroll.refreshControl == nil {
                scroll.alwaysBounceVertical = true
                scroll.refreshControl = control
            }
            if !refreshing {
                control.endRefreshing()
            }
        }

        func detach() {
            controlObservation = nil
            guard let scroll = scrollView else { return }
            if scroll.refreshControl === control {
                control.endRefreshing()
                scroll.refreshControl = nil
            }
            if scroll.refreshControl == nil { scroll.alwaysBounceVertical = previousBounce }
            scrollView = nil
        }

        @objc private func didRefresh() {
            refresh?()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                if let self, !refreshing {
                    control.endRefreshing()
                }
            }
        }
    }
}
#endif

private struct LGPropertyRowLayout: Layout {
    let stacked: Bool

    private func metrics(width: CGFloat, subviews: Subviews) -> (Bool, CGFloat, CGSize, CGSize) {
        let intrinsic = subviews[0].sizeThatFits(.unspecified)
        let keyWidth = intrinsic.width <= 24 ? intrinsic.width : min(144, width * 0.44)
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
        VStack(spacing: 16) {
            DatePicker("Value", selection: selection, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .accessibilityIdentifier(string("identifier"))
            if includesTime {
                DatePicker(string("time-label"), selection: selection, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                    .accessibilityIdentifier(string("identifier") + ".time")
            }
        }
    }
}

private struct LGTableViewport: View {
    let context: LUIAppleExtensionViewContext

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(context.childIDs, id: \.self) { context.content(for: $0) }
            }.background {
                #if os(iOS)
                LGTableScrollObserver { offset, width in
                    try? context.emit(name: "viewport-changed", values: ["offset": .int(offset), "width": .int(width)])
                }
                .frame(width: 0, height: 0)
                #endif
            }
        }
    }
}

#if os(iOS)
private struct LGTableScrollObserver: UIViewRepresentable {
    let report: (Int, Int) -> Void
    func makeUIView(context: Context) -> Probe { Probe(report: report) }
    func updateUIView(_ view: Probe, context: Context) { view.report = report }

    final class Probe: UIView {
        var report: (Int, Int) -> Void
        private weak var scroll: UIScrollView?
        private var offsetObservation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?
        private var lastOffset = -1
        private var lastWidth = -1

        init(report: @escaping (Int, Int) -> Void) { self.report = report; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        override func layoutSubviews() { super.layoutSubviews(); attach(); changed() }

        private func attach() {
            guard window != nil, scroll == nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    self.scroll = scroll
                    offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.changed() }
                    }
                    boundsObservation = scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.changed() }
                    }
                    changed()
                    return
                }
                ancestor = view.superview
            }
        }

        private func changed() {
            guard let scroll else { return }
            let offset = max(0, Int(scroll.contentOffset.x.rounded()))
            let width = Int(scroll.bounds.width.rounded())
            guard width > 0, offset != lastOffset || width != lastWidth else { return }
            lastOffset = offset; lastWidth = width
            report(offset, width)
        }
    }
}
#endif
