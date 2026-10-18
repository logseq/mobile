import LUIAppleBackend
import SwiftUI
#if os(iOS)
import UIKit
#endif

enum LGNavigationSurfacePolicy {
    static let androidContentTopPadding = CGFloat(0)
    static let androidDestinationContentTopPadding = CGFloat(56)

    static func usesSystemGroupedBackground(contentPreference: Bool) -> Bool {
        contentPreference
    }

    static func bottomPadding(occupiesLayoutSpace: Bool) -> CGFloat {
        occupiesLayoutSpace ? CGFloat(7) : CGFloat(0)
    }

    static func systemToolbarItemWidth(
        iconWidth: CGFloat,
        minimumHitTarget: CGFloat
    ) -> CGFloat {
        max(iconWidth, minimumHitTarget)
    }
}

@MainActor
enum LGNavigationExtension {
    static let identifier = "native-navigation-stack"
    static let fingerprint = "lui-extension-v1|23:native-navigation-stack|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:10:back-depth:int:required:none,26:composer-dismissal-enabled:bool:required:none,28:bottom-occupies-layout-space:bool:required:none,5:depth:int:required:none,5:title:string:required:none|events:16:dismiss-composer[],4:back[5:count:int:required]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(
            LUIAppleExtension(
                identifier: identifier,
                fingerprint: fingerprint,
                acceptsStandardChildren: true,
                properties: [
                    .init(name: "back-depth", kind: .int, isRequired: true),
                    .init(name: "depth", kind: .int, isRequired: true),
                    .init(name: "bottom-occupies-layout-space", kind: .bool, isRequired: true),
                    .init(name: "composer-dismissal-enabled", kind: .bool, isRequired: true),
                    .init(name: "title", kind: .string, isRequired: true),
                ],
                events: [
                    .init(name: "back", fields: [
                        .init(name: "count", kind: .int, isRequired: true),
                    ]),
                    .init(name: "dismiss-composer", fields: []),
                ]
            ) { context in
                AnyView(LGNavigationStack(context: context))
            }
        )
        try registry.registerTweak(
            LUIAppleTweak(
                identifier: "native-navigation-title",
                fingerprint: "lui-tweak-v1|23:native-navigation-title|profiles:ios/swiftui|properties:5:title:string:required:none",
                properties: [
                    .init(name: "title", kind: .string, isRequired: true),
                ]
            ) { content, context in
                AnyView(LGNavigationDestination(context: context, content: content))
            }
        )
    }
}

@MainActor
private struct LGNavigationStack: View {
    let context: LUIAppleExtensionViewContext

    var body: some View {
        LGNavigationContent(
            context: context,
            rootIndex: 0,
            routeStartIndex: 6,
            depth: depth,
            synchronizationName: "navigation",
            toolbarStartIndex: 1,
            bottomChromeIndex: 5,
            bottomOccupiesLayoutSpace: bottomOccupiesLayoutSpace,
            composerDismissalEnabled: composerDismissalEnabled,
            rootTransform: nil
        )
    }

    private var depth: Int {
        guard case let .int(value) = context.property("depth") else { return 0 }
        return value
    }

    private var bottomOccupiesLayoutSpace: Bool {
        guard case let .bool(value) = context.property("bottom-occupies-layout-space") else {
            return false
        }
        return value
    }

    private var composerDismissalEnabled: Bool {
        guard case let .bool(value) = context.property("composer-dismissal-enabled") else {
            return false
        }
        return value
    }

}

private struct LGNavigationDestination: View {
    let context: LUIAppleExtensionViewContext
    let content: AnyView

    var body: some View {
        let _ = context.revision
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }

    private var title: String {
        guard case let .string(value) = context.property("title") else { return "" }
        return value
    }
}

@MainActor
enum LGSearchPresentationExtension {
    static let identifier = "native-search-presentation"
    static let fingerprint = "lui-extension-v1|26:native-search-presentation|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:5:depth:int:required:none,5:query:string:required:none,5:title:string:required:none,9:presented:bool:required:none|events:13:query-changed[5:query:string:required],4:back[5:count:int:required],7:dismiss[]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(
            LUIAppleExtension(
                identifier: identifier,
                fingerprint: fingerprint,
                acceptsStandardChildren: true,
                properties: [
                    .init(name: "presented", kind: .bool, isRequired: true),
                    .init(name: "depth", kind: .int, isRequired: true),
                    .init(name: "query", kind: .string, isRequired: true),
                    .init(name: "title", kind: .string, isRequired: true),
                ],
                events: [
                    .init(name: "back", fields: [
                        .init(name: "count", kind: .int, isRequired: true),
                    ]),
                    .init(name: "dismiss", fields: []),
                    .init(name: "query-changed", fields: [
                        .init(name: "query", kind: .string, isRequired: true),
                    ]),
                ]
            ) { context in
                AnyView(LGSearchPresentation(context: context))
            }
        )
    }
}

@MainActor
private struct LGSearchPresentation: View {
    let context: LUIAppleExtensionViewContext

    var body: some View {
        baseContent
            .fullScreenCover(isPresented: presentedBinding) {
                LGSearchSession(context: context)
                    .presentationBackground(.clear)
                    .transaction { $0.disablesAnimations = false }
            }
            .transaction(value: presented) { $0.disablesAnimations = true }
    }

    private var baseContent: AnyView {
        guard let childID = context.childIDs.first else { return AnyView(EmptyView()) }
        return context.content(for: childID)
    }

    private var presented: Bool {
        guard case let .bool(value) = context.property("presented") else { return false }
        return value
    }

    private var presentedBinding: Binding<Bool> {
        Binding(get: { presented }, set: { value in
            if !value { try? context.emit(name: "dismiss", values: [:]) }
        })
    }
}

private struct LGSearchSession: View {
    let context: LUIAppleExtensionViewContext
    #if os(iOS)
    @State private var nativeSearchPresented = true
    @FocusState private var searchFocused: Bool
    @State private var visible = false
    @State private var closing = false
    #endif

    var body: some View {
        searchNavigation
            #if os(iOS)
            .opacity(visible ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.18)) { visible = true } }
            #endif
    }

    private var searchNavigation: some View {
        LGNavigationContent(
            context: context,
            rootIndex: 1,
            routeStartIndex: 2,
            depth: depth,
            synchronizationName: "search navigation",
            toolbarStartIndex: nil,
            bottomChromeIndex: nil,
            bottomOccupiesLayoutSpace: false,
            composerDismissalEnabled: false,
            rootTransform: searchRootTransform
        )
    }

    private func searchRootTransform(_ content: AnyView) -> AnyView {
        let content = AnyView(content.environment(\.luiTextHighlightQuery, query))
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return AnyView(nativeBottomSearch(content))
        }
        return AnyView(nativeLegacySearch(content))
        #else
        return AnyView(nativeAutomaticSearch(content))
        #endif
    }

    private func nativeAutomaticSearch(_ content: AnyView) -> some View {
        content
            .searchable(
                text: queryBinding,
                placement: .automatic,
                prompt: "Search pages and blocks"
            )
    }

    #if os(iOS)
    private func nativeLegacySearch(_ content: AnyView) -> some View {
        content
            .navigationTitle(searchTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: queryBinding,
                isPresented: nativeSearchPresentedBinding,
                placement: .automatic,
                prompt: "Search pages and blocks"
            )
            .onAppear {
                nativeSearchPresented = true
            }
    }

    @available(iOS 26.0, *)
    private func nativeBottomSearch(_ content: AnyView) -> some View {
        content
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(searchTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: queryBinding,
                isPresented: nativeSearchPresentedBinding,
                placement: .toolbar,
                prompt: "Search pages and blocks"
            )
            .searchFocused($searchFocused)
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: exitSearch) {
                        Image("close", bundle: .module)
                            .frame(width: 20, height: 20)
                            .frame(width: 44, height: 44)
                            .accessibilityIdentifier("button.search.close")
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Close search")
                    .accessibilityIdentifier("button.search.close")
                }
            }
            .overlay(alignment: .topLeading) {
                LGNativeSearchActivator(
                    focusRequested: nativeSearchPresented,
                    presentationAction: { nativeSearchPresented = true },
                    focusAction: { searchFocused = true }
                )
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            }
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .tracking || newPhase == .interacting {
                    searchFocused = false
                }
            }
    }

    private func exitSearch() {
        guard !closing else { return }
        closing = true
        searchFocused = false
        withAnimation(.easeOut(duration: 0.18)) { visible = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            emitDismiss()
        }
    }

    private var nativeSearchPresentedBinding: Binding<Bool> {
        Binding(
            get: { nativeSearchPresented },
            set: { isPresented in
                nativeSearchPresented = isPresented
                if !isPresented { exitSearch() }
            }
        )
    }
    #endif

    private var depth: Int {
        guard case let .int(value) = context.property("depth") else { return 0 }
        return value
    }

    private var query: String {
        guard case let .string(value) = context.property("query") else { return "" }
        return value
    }

    private var searchTitle: String {
        guard case let .string(value) = context.property("title") else { return "Search" }
        return value
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { query },
            set: { newValue in
                emitQueryChanged(newValue)
            }
        )
    }

    private func emitDismiss() {
        do {
            try context.emit(name: "dismiss", values: [:])
        } catch {
            logger.error("Could not dismiss native search: \(String(describing: error))")
        }
    }

    private func emitQueryChanged(_ query: String) {
        do {
            try context.emit(name: "query-changed", values: ["query": .string(query)])
        } catch {
            logger.error("Could not update native search query: \(String(describing: error))")
        }
    }
}

#if os(iOS)
@MainActor
private struct LGNativeSearchActivator: UIViewRepresentable {
    let focusRequested: Bool
    let presentationAction: () -> Void
    let focusAction: () -> Void

    func makeUIView(context: Context) -> ObserverView {
        ObserverView(
            focusRequested: focusRequested,
            presentationAction: presentationAction,
            focusAction: focusAction
        )
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.focusRequested = focusRequested
        view.presentationAction = presentationAction
        view.focusAction = focusAction
        view.focusSearchFieldIfNeeded()
    }

    final class ObserverView: UIView {
        var focusRequested: Bool
        var presentationAction: () -> Void
        var focusAction: () -> Void
        private var hasRequestedPresentation = false
        private var hasFocused = false
        private var focusScheduled = false

        init(
            focusRequested: Bool,
            presentationAction: @escaping () -> Void,
            focusAction: @escaping () -> Void
        ) {
            self.focusRequested = focusRequested
            self.presentationAction = presentationAction
            self.focusAction = focusAction
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !hasRequestedPresentation else { return }
            hasRequestedPresentation = true
            // Request input as soon as the search surface enters the window.
            // Keyboard presentation and the search transition can run together.
            DispatchQueue.main.async { [weak self] in
                guard let self, window != nil else { return }
                presentationAction()
                focusSearchFieldIfNeeded()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            focusSearchFieldIfNeeded()
        }

        func focusSearchFieldIfNeeded() {
            guard focusRequested, window != nil, !hasFocused, !focusScheduled else { return }
            focusScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                focusScheduled = false
                guard focusRequested, !hasFocused,
                      let searchField = window?.firstDescendant(of: UISearchTextField.self),
                      searchField.isFirstResponder || searchField.becomeFirstResponder()
                else { return }
                hasFocused = true
                focusAction()
            }
        }
    }
}

private extension UIView {
    func firstDescendant<ViewType: UIView>(of type: ViewType.Type) -> ViewType? {
        if let match = self as? ViewType {
            return match
        }
        for child in subviews {
            if let match = child.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}
#endif

@MainActor
private struct LGNavigationContent: View {
    let context: LUIAppleExtensionViewContext
    let rootIndex: Int
    let routeStartIndex: Int
    let depth: Int
    let synchronizationName: String
    let toolbarStartIndex: Int?
    let bottomChromeIndex: Int?
    let bottomOccupiesLayoutSpace: Bool
    let composerDismissalEnabled: Bool
    let rootTransform: ((AnyView) -> AnyView)?
    @State private var path: [Int] = []
    @State private var usesSystemGroupedBackground = false
    @State private var visibleScrollTitle: String?
    @AppStorage("logseq.appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        navigationLayout
            .onPreferenceChange(LUIListSurfacePreferenceKey.self) { usesSystemBackground in
                usesSystemGroupedBackground = usesSystemBackground
            }
            .onPreferenceChange(LUIScrollTitlePreferenceKey.self) { title in
                if let title { visibleScrollTitle = title }
            }
    }

    @ViewBuilder
    private var navigationLayout: some View {
        navigationStack
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if bottomOccupiesLayoutSpace {
                    sizedBottomChrome
                }
            }
            .overlay(alignment: .bottom) {
                if !bottomOccupiesLayoutSpace {
                    sizedBottomChrome
                }
            }
            .background(routeBackground.ignoresSafeArea())
    }

    private var navigationStack: some View {
        NavigationStack(path: pathBinding) {
            rootNavigationSurface
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .background(routeBackground)
                .overlay {
                    if composerDismissalEnabled {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: emitDismissComposer)
                            .accessibilityLabel("Dismiss composer")
                            .accessibilityIdentifier("surface.composer.dismiss")
                    }
                }
                .navigationDestination(for: Int.self) { childID in
                    context.content(for: childID)
                        .padding(.top, destinationContentTopPadding)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .background(routeBackground)
                        .toolbar {
                            destinationTrailingToolbar
                        }
                }
                .toolbar {
                    if let toolbarStartIndex {
                        if #available(iOS 26.0, *) {
                            ToolbarItem(placement: rootLeadingToolbarPlacement) {
                                let childID = context.childIDs[toolbarStartIndex]
                                context.content(for: childID)
                                    .id(context.contentRevision(for: childID))
                                    .modifier(LGLiquidGlassSurface(shape: .circle))
                                    .frame(width: LGNavigationSurfacePolicy.systemToolbarItemWidth(
                                        iconWidth: 24,
                                        minimumHitTarget: 44
                                    ))
                            }
                            .sharedBackgroundVisibility(.hidden)
                            ToolbarItem(placement: rootLeadingToolbarPlacement) {
                                rootToolbarTitle(index: toolbarStartIndex + 1)
                            }
                            .sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem(placement: rootLeadingToolbarPlacement) {
                                context.content(for: context.childIDs[toolbarStartIndex])
                            }
                            ToolbarItem(placement: rootLeadingToolbarPlacement) {
                                rootToolbarTitle(index: toolbarStartIndex + 1)
                            }
                        }
                        #if os(iOS)
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            context.content(for: context.childIDs[toolbarStartIndex + 2])
                            context.content(for: context.childIDs[toolbarStartIndex + 3])
                        }
                        #else
                        ToolbarItemGroup(placement: .primaryAction) {
                            context.content(for: context.childIDs[toolbarStartIndex + 2])
                            context.content(for: context.childIDs[toolbarStartIndex + 3])
                        }
                        #endif
                    }
                }
                #if os(iOS)
                .toolbar(.visible, for: .navigationBar)
                #endif
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(routeBackground.ignoresSafeArea())
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(routeBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .onAppear {
            path = desiredPath
        }
        .onChange(of: desiredPath) { _, newPath in
            if path != newPath {
                path = newPath
            }
        }
    }

    private var rootContent: AnyView {
        guard context.childIDs.count > rootIndex else {
            return AnyView(EmptyView())
        }
        return context.content(for: context.childIDs[rootIndex])
    }

    private var transformedRootContent: AnyView {
        rootTransform?(rootContent) ?? rootContent
    }

    @ViewBuilder
    private var rootNavigationSurface: some View {
        transformedRootContent
            .padding(.top, navigationContentTopPadding)
    }


    private var themePalette: LogseqThemePalette {
        LogseqThemePolicy.palette(
            mode: LogseqThemeMode(rawValue: appearance) ?? .system,
            systemIsDark: colorScheme == .dark
        )
    }

    private var routeBackground: Color {
        #if os(iOS)
        if LGNavigationSurfacePolicy.usesSystemGroupedBackground(
            contentPreference: usesSystemGroupedBackground
        ) {
            return Color(uiColor: .systemGroupedBackground)
        }
        #endif
        return themePalette.background
    }

    @ViewBuilder
    private func rootToolbarTitle(index: Int) -> some View {
        if navigationTitle.isEmpty, let title = visibleScrollTitle {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("title.main")
        } else {
            context.content(for: context.childIDs[index])
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var navigationTitle: String {
        guard case let .string(value) = context.property("title") else { return "" }
        return value
    }

    private var navigationContentTopPadding: CGFloat {
        0
    }

    private var destinationContentTopPadding: CGFloat {
        0
    }

    @ToolbarContentBuilder
    private var destinationTrailingToolbar: some ToolbarContent {
        if let toolbarStartIndex {
            #if os(iOS)
            ToolbarItemGroup(placement: .topBarTrailing) {
                context.content(for: context.childIDs[toolbarStartIndex + 2])
                context.content(for: context.childIDs[toolbarStartIndex + 3])
            }
            #else
            ToolbarItemGroup(placement: .primaryAction) {
                context.content(for: context.childIDs[toolbarStartIndex + 2])
                context.content(for: context.childIDs[toolbarStartIndex + 3])
            }
            #endif
        }
    }

    private var bottomChrome: AnyView {
        guard let bottomChromeIndex,
              context.childIDs.count > bottomChromeIndex
        else { return AnyView(EmptyView()) }
        return context.content(for: context.childIDs[bottomChromeIndex])
    }

    @ViewBuilder
    private var sizedBottomChrome: some View {
        if bottomOccupiesLayoutSpace {
            bottomChrome
                .fixedSize(horizontal: false, vertical: true)
                .modifier(LGBottomChromeSurface())
                .modifier(LGBottomChromeHitTarget(isRounded: true))
                .padding(.horizontal, 16)
                .padding(.bottom, LGNavigationSurfacePolicy.bottomPadding(
                    occupiesLayoutSpace: true
                ))
        } else {
            bottomChrome
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(LGBottomChromeHitTarget(isRounded: false))
        }
    }

    private var desiredPath: [Int] {
        let childIDs = context.childIDs
        let availableDepth = max(0, childIDs.count - routeStartIndex)
        let retainedDepth = min(max(0, depth), availableDepth)
        var result: [Int] = []
        for index in 0..<retainedDepth {
            result.append(childIDs[index + routeStartIndex])
        }
        return result
    }

    private var rootLeadingToolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    private var pathBinding: Binding<[Int]> {
        Binding(
            get: { path },
            set: { newPath in
                let removedCount = max(0, path.count - newPath.count)
                path = newPath
                if removedCount > 0 {
                    Task { @MainActor in
                        await Task.yield()
                        emitBack(count: removedCount)
                    }
                }
            }
        )
    }

    private func emitBack(count: Int) {
        do {
            try context.emit(name: "back", values: ["count": .int(count)])
        } catch {
            logger.error(
                "Could not synchronize native \(synchronizationName): \(String(describing: error))"
            )
        }
    }

    private func emitDismissComposer() {
        do {
            try context.emit(name: "dismiss-composer", values: [:])
        } catch {
            logger.error("Could not dismiss composer: \(String(describing: error))")
        }
    }
}

private struct LGBottomChromeSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
        } else {
            content.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
        }
    }
}

private struct LGBottomChromeHitTarget: ViewModifier {
    let isRounded: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isRounded {
            content
                .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .onTapGesture {}
        } else {
            content
                .contentShape(Rectangle())
                .onTapGesture {}
        }
    }
}
