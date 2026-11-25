import Foundation
import SwiftUI
import LogseqModel
import LUIAppleBackend
#if os(iOS)
import UniformTypeIdentifiers
import UIKit
#endif

struct OutlinerRowPayload: Decodable, Equatable {
    struct PDFReference: Codable, Equatable {
        let id: String
        let assetUuid: String
        let assetTitle: String
        let page: Int
    }
    struct Summary: Decodable, Identifiable, Equatable {
        let uuid: String
        let title: String
        var id: String { uuid }
    }
    struct Status: Decodable, Identifiable, Equatable {
        let uuid: String
        let title: String
        let icon: String
        let foreground: String?
        var id: String { uuid }

        #if os(iOS)
        func menuImage(in semanticColors: [String: Color]) -> UIImage? {
            let key = icon.replacingOccurrences(of: "app:", with: "")
            guard case let .assetName(name) = LGIconPolicy.icons[key] else { return nil }
            return UIImage(named: name, in: .module, compatibleWith: nil)?
                .withTintColor(UIColor(color(in: semanticColors)), renderingMode: .alwaysOriginal)
        }
        #endif

        func color(in semanticColors: [String: Color]) -> Color {
            guard let foreground else { return .primary }
            if let color = semanticColors[foreground] { return color }
            let hex = foreground.hasPrefix("#") ? String(foreground.dropFirst()) : ""
            guard (hex.count == 6 || hex.count == 8), let bits = UInt64(hex, radix: 16) else { return .primary }
            let rgb = hex.count == 8 ? bits >> 8 : bits
            return Color(red: Double((rgb >> 16) & 255) / 255,
                         green: Double((rgb >> 8) & 255) / 255,
                         blue: Double(rgb & 255) / 255,
                         opacity: hex.count == 8 ? Double(bits & 255) / 255 : 1)
        }
    }
    let uuid: String
    let scrollAnchorID: String?
    let embedSourceUuid: String?
    let title: String
    let markup: [LogseqMarkupNode]
    let depth: Int
    let hasChildren: Bool
    let collapsed: Bool
    let isAsset: Bool
    let assetType: String
    let localPath: String
    let youtubeURL: String
    let completed: Bool
    let selected: Bool
    let selectionMode: Bool?
    let selectionMember: Bool?
    let isTask: Bool?
    let menuLabels: [String: String]?
    let discussionsAvailable: Bool?
    let isComment: Bool?
    let editing: Bool?
    let allowsDrag: Bool?
    let trailingInset: CGFloat?
    let hasCustomContent: Bool?
    let opensAsPage: Bool
    let nodeIcon: NodeIconPayload?
    let listNumber: Int?
    let journalBullet: Bool
    let syncFailed: Bool
    let priority: Status?
    let status: Status?
    let statuses: [Status]
    let priorities: [Status]?
    let tags: [Summary]
    let canRemoveTags: Bool?
    let removeTagTitle: String?
    let pdfAnnotation: PDFReference?
    /// Translated in the shared catalog. Older payloads fall back to the English source.
    let openLabel: String?
    let editLabel: String?
    let collapseLabel: String?

    var openAccessibilityLabel: String { openLabel ?? "Open block" }
    var editAccessibilityLabel: String { editLabel ?? "Edit block " + title }
    var collapseAccessibilityLabel: String {
        collapseLabel ?? (collapsed ? "Expand block" : "Collapse block")
    }

    var disclosureGutter: CGFloat { hasChildren ? trailingInset ?? 0 : 0 }
}

#if os(iOS)
@MainActor final class OutlinerBlockInteractions: NSObject, UIContextMenuInteractionDelegate, UIDragInteractionDelegate {
    struct Configuration {
        let menu: () -> UIMenu?
        let dragID: String?
        let beginDrag: () -> Void
        let previewBackground: UIColor
    }

    private lazy var dragInteraction = UIDragInteraction(delegate: self)

    var configuration: Configuration? {
        didSet {
            let enabled = configuration?.dragID != nil
            if dragInteraction.isEnabled != enabled { dragInteraction.isEnabled = enabled }
        }
    }

    func install(on view: UIView) {
        // UIKit can hand off from the context menu to drag when they share a view.
        view.addInteraction(dragInteraction)
        view.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = configuration?.menu() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        preview(for: interaction.view)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        preview(for: interaction.view)
    }

    private func preview(for view: UIView?) -> UITargetedPreview? {
        guard let view, view.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 10)
        if let background = configuration?.previewBackground { parameters.backgroundColor = background }
        return UITargetedPreview(view: view, parameters: parameters)
    }

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        guard let id = configuration?.dragID else { return [] }
        return [UIDragItem(itemProvider: NSItemProvider(object: id as NSString))]
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
        // UIKit may request items while previewing the menu. Select only after lift.
        configuration?.beginDrag()
    }
}

private struct OutlinerHostedBlockRow<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let interactions: OutlinerBlockInteractions.Configuration
    @Environment(\.self) private var environment

    func makeCoordinator() -> OutlinerBlockInteractions { OutlinerBlockInteractions() }

    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        let controller = UIHostingController(rootView: hostedContent)
        controller.view.backgroundColor = .clear
        controller.sizingOptions = .intrinsicContentSize
        context.coordinator.install(on: controller.view)
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<AnyView>, context: Context) {
        controller.rootView = hostedContent
        context.coordinator.configuration = interactions
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIHostingController<AnyView>, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiViewController.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private var hostedContent: AnyView {
        // Keep the row host's accessibility infrastructure while forwarding app settings.
        AnyView(content
            .environment(\.luiSemanticColors, environment.luiSemanticColors)
            .environment(\.lgPropertyValue, environment.lgPropertyValue)
            .environment(\.lgImagePreviews, environment.lgImagePreviews)
            .environment(\.lgOpenPDF, environment.lgOpenPDF)
            .environment(\.outlinerScrollRetention, environment.outlinerScrollRetention)
            .environment(\.locale, environment.locale)
            .environment(\.openURL, environment.openURL))
    }
}
#endif

@MainActor enum OutlinerRowExtension {
    private final class CachedPayload {
        let row: OutlinerRowPayload
        init(_ row: OutlinerRowPayload) { self.row = row }
    }

    private static let payloads: NSCache<NSString, CachedPayload> = {
        let cache = NSCache<NSString, CachedPayload>()
        cache.countLimit = 512
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    private static func payload(_ encoded: String) -> OutlinerRowPayload? {
        let key = encoded as NSString
        if let cached = payloads.object(forKey: key) { return cached.row }
        guard let data = encoded.data(using: .utf8),
              let row = try? JSONDecoder().decode(OutlinerRowPayload.self, from: data) else { return nil }
        payloads.setObject(CachedPayload(row), forKey: key, cost: data.count)
        return row
    }

    static let identifier = "outliner-block-row"
    static let fingerprint = "lui-extension-v1|18:outliner-block-row|profiles:ios/swiftui|standard-children:1|children:|properties:7:payload:string:required:none|events:10:drag-start[4:uuid:string:required],10:long-press[4:uuid:string:required],10:remove-tag[4:uuid:string:required],10:set-status[4:uuid:string:required,5:count:int:required],11:menu-action[7:payload:string:required],12:set-priority[8:priority:string:required],16:toggle-selection[4:uuid:string:required],4:drop[4:uuid:string:required,9:placement:string:required],4:edit[18:caret-utf16-offset:int:optional,4:uuid:string:required],8:collapse[4:uuid:string:required],9:open-node[4:uuid:string:required]"

    static func register(in registry: LUIAppleExtensionRegistry, playback: LGYouTubePlaybackState) throws {
        let uuid = LUIExtensionEventField(name: "uuid", kind: .string, isRequired: true)
        try registry.register(LUIAppleExtension(identifier: identifier, fingerprint: fingerprint,
            acceptsStandardChildren: true,
            properties: [.init(name: "payload", kind: .string, isRequired: true)],
            events: ["open-node", "remove-tag", "collapse", "long-press", "drag-start", "toggle-selection"].map {
                LUIExtensionEvent(name: $0, fields: [uuid])
            } + [.init(name: "edit", fields: [uuid, .init(name: "caret-utf16-offset", kind: .int, isRequired: false)]),
                 .init(name: "menu-action", fields: [.init(name: "payload", kind: .string, isRequired: true)]),
                 .init(name: "drop", fields: [uuid, .init(name: "placement", kind: .string, isRequired: true)]),
                 .init(name: "set-status", fields: [uuid, .init(name: "count", kind: .int, isRequired: true)]),
                 .init(name: "set-priority", fields: [.init(name: "priority", kind: .string, isRequired: true)])]
        ) { context in
            guard case let .string(encoded) = context.property("payload"),
                  let row = payload(encoded) else {
                return AnyView(EmptyView())
            }
            return AnyView(OutlinerRow(context: context, row: row, playback: playback))
        })
    }
}

@MainActor private struct OutlinerRow: View {
    let context: LUIAppleExtensionViewContext
    let row: OutlinerRowPayload
    let playback: LGYouTubePlaybackState
    @State private var dropGeometry = OutlinerRowDropGeometry()
    @State private var titleWidth: CGFloat = 0
    @Environment(\.luiSemanticColors) private var semanticColors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lgPropertyValue) private var propertyValue
    @Environment(\.lgOpenPDFAnnotation) private var openPDFAnnotation

    private var bulletForeground: Color {
        #if os(iOS)
        Color(uiColor: UIColor.secondaryLabel.withAlphaComponent(0.4))
        #else
        Color.secondary.opacity(0.4)
        #endif
    }

    private var hasCustomContent: Bool {
        row.hasCustomContent ?? !context.childIDs.isEmpty
    }

    @ViewBuilder var body: some View {
        #if os(iOS)
        if !(row.editing ?? !context.childIDs.isEmpty) {
            let selectable = content(interactions: blockInteractions)
                .contentShape(Rectangle())
                .modifier(OutlinerSelectionSwipe { emit("toggle-selection") })
                .accessibilityAction(named: menuText(row.selectionMember == true ? "Unselect" : "Select")) {
                    emit("toggle-selection")
                }
            if row.allowsDrag != false {
                selectable
                .overlay { OutlinerDropIndicator(placement: dropGeometry.placement, depth: row.depth) }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dropGeometry.height = $0 }
                .onDrop(of: [UTType.plainText], delegate: OutlinerRowDropDelegate(geometry: dropGeometry, depth: row.depth) {
                    emit("drop", extra: ["placement": .string($0.eventValue)])
                    return true
                })
            } else {
                selectable
            }
        } else { content() }
        #else
        content()
        #endif
    }

    #if os(iOS)
    private func content(interactions: OutlinerBlockInteractions.Configuration? = nil) -> some View {
        Group {
            if !hasCustomContent && OutlinerTextRow.supports(row) {
                OutlinerTextRow(row: row,
                    emit: { name, uuid, values in emit(name, uuid: uuid, extra: values) },
                    onOpenLink: { url in
                        guard context.isUserInteractionEnabled else { return }
                        if let link = OutlinerMarkupLink(url: url), case let .node(uuid) = link { emit("open-node", uuid: uuid) }
                        else { openURL(url) }
                    }, interactions: interactions)
            } else if let interactions {
                OutlinerHostedBlockRow(content: swiftUIContent, interactions: interactions)
            } else {
                swiftUIContent
            }
        }
        .tint(semanticColors["link"] ?? LogseqThemePolicy.linkColor(isDark: colorScheme == .dark))
        .padding(.trailing, row.hasChildren ? 0 : row.trailingInset ?? 0)
    }
    #else
    private func content() -> some View {
        swiftUIContent
            .tint(semanticColors["link"] ?? LogseqThemePolicy.linkColor(isDark: colorScheme == .dark))
            .padding(.trailing, row.hasChildren ? 0 : row.trailingInset ?? 0)
    }
    #endif

    #if os(iOS)
    private var blockInteractions: OutlinerBlockInteractions.Configuration {
        .init(
            menu: { context.isUserInteractionEnabled ? blockMenu() : nil },
            dragID: context.isUserInteractionEnabled && row.allowsDrag != false && !row.journalBullet ? row.uuid : nil,
            beginDrag: { emit("drag-start") },
            previewBackground: UIColor(semanticColors["surface"] ?? Color(uiColor: .secondarySystemBackground))
        )
    }

    private func blockMenu() -> UIMenu {
        var items: [UIMenuElement] = [
            UIAction(title: menuTitle("Open block"), image: menuImage("arrow.up.right")) { _ in
                emit("open-node", uuid: row.embedSourceUuid)
            }
        ]
        if row.discussionsAvailable == true {
            var collaboration = [menuAction("Add reaction", icon: "face.smiling", action: "reaction")]
            if row.isComment != true {
                collaboration.insert(menuAction("Comments", icon: "bubble", action: "comments"), at: 0)
            }
            items.append(UIMenu(options: .displayInline, children: collaboration))
        }
        if row.isTask == true {
            var taskItems: [UIMenuElement] = [
                menuAction("Scheduled", icon: "calendar", action: "scheduled"),
                menuAction("Deadline", icon: "flag", action: "deadline")
            ]
            if !row.statuses.isEmpty {
                let statuses = row.statuses.enumerated().map { index, status in
                    UIAction(title: status.title, image: status.menuImage(in: semanticColors)) { _ in
                        emit("set-status", extra: ["count": .int(index)])
                    }
                }
                taskItems.append(UIMenu(title: menuTitle("Status"), image: menuImage("checkmark.circle"), children: statuses))
            }
            items.append(UIMenu(options: .displayInline, children: taskItems))
        }
        var clipboard: [UIAction] = [menuAction("Copy", icon: "doc.on.doc", action: "copy")]
        if !propertyValue { clipboard.append(menuAction("Cut", icon: "scissors", action: "cut")) }
        clipboard.append(menuAction("Copy reference", icon: "r.square", action: "copyReference"))
        clipboard.append(menuAction("Copy URL", icon: "link", action: "copyURL"))
        items.append(UIMenu(options: .displayInline, children: clipboard))
        items.append(UIMenu(title: menuTitle("Move"), image: menuImage("arrow.up.arrow.down"), children: [
            menuAction("Move up", icon: "arrow.up", action: "moveUp"),
            menuAction("Move down", icon: "arrow.down", action: "moveDown"),
            menuAction("Outdent", icon: "arrow.left", action: "outdent"),
            menuAction("Indent", icon: "arrow.right", action: "indent")
        ]))
        items.append(menuAction("Delete", icon: "trash", action: "delete", attributes: .destructive))
        return UIMenu(children: items)
    }

    private func menuTitle(_ key: String) -> String { row.menuLabels?[key] ?? key }
    private func menuText(_ key: String) -> Text { Text(verbatim: menuTitle(key)) }

    private func menuImage(_ name: String, tint: UIColor = .label) -> UIImage? {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        return UIImage(systemName: name)?.withTintColor(tint.resolvedColor(with: traits), renderingMode: .alwaysOriginal)
    }

    private func menuAction(_ title: String, icon: String, action: String,
                            attributes: UIMenuElement.Attributes = []) -> UIAction {
        let tint: UIColor = attributes.contains(.destructive) ? .systemRed : .label
        return UIAction(title: menuTitle(title), image: menuImage(icon, tint: tint), attributes: attributes) { _ in
            emit("menu-action", extra: ["payload": .string(action)])
        }
    }
    #endif

    private var swiftUIContent: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: CGFloat(max(0, row.depth)) * 22, height: 1)
            let bullet = Group {
                if row.journalBullet {
                    IconImage(name: row.collapsed && row.hasChildren ? "outliner_bullet_closed" : "outliner_bullet", size: 24).frame(height: 24)
                        .foregroundStyle(bulletForeground)
                        .accessibilityIdentifier("button.outliner.zoom." + row.uuid + "." + row.title)
                } else {
                    Button { emit("open-node", uuid: row.embedSourceUuid) } label: {
                        if let number = row.listNumber {
                            Text("\(number).").font(.subheadline).frame(width: 24, height: 24)
                                .accessibilityIdentifier("outliner.number." + row.uuid)
                        } else if let icon = row.nodeIcon {
                            NodeIconView(icon: icon, size: 18).frame(width: 24, height: 24)
                        } else {
                            IconImage(name: row.collapsed && row.hasChildren ? "outliner_bullet_closed" : "outliner_bullet", size: 24).frame(height: 24)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(bulletForeground)
                    .accessibilityLabel(row.openAccessibilityLabel)
                    .accessibilityIdentifier("button.outliner.zoom." + row.uuid + "." + row.title)
                }
            }
            bullet
            .simultaneousGesture(LongPressGesture().onEnded { _ in
                if row.editing == true { emit("long-press") }
            })
            .padding(.trailing, row.status != nil
                ? OutlinerLayoutMetrics.statusLeading - OutlinerLayoutMetrics.bulletHitSize
                : (row.priority != nil ? -4 : OutlinerLayoutMetrics.bulletContentSpacing))
            if let status = row.status {
                Menu {
                    ForEach(Array(row.statuses.enumerated()), id: \.element.id) { index, item in
                        Button { emit("set-status", extra: ["count": .int(index)]) } label: {
                            SwiftUI.Label { Text(verbatim: item.title) } icon: {
                                #if os(iOS)
                                if let image = item.menuImage(in: semanticColors) { Image(uiImage: image) }
                                #else
                                statusIcon(item)
                                #endif
                            }
                        }
                        .accessibilityIdentifier("button.block-task-status-option." + item.uuid)
                    }
                } label: {
                    statusIcon(status).frame(width: OutlinerLayoutMetrics.statusIconSize, height: 24)
                }
                .tint(status.color(in: semanticColors))
                .padding(.trailing, OutlinerLayoutMetrics.statusContentSpacing)
                .accessibilityLabel(status.title)
                .accessibilityIdentifier("button.block-task-status")
            }
            if let priority = row.priority {
                Menu {
                    Picker("Priority", selection: Binding(get: { priority.uuid }, set: {
                        emit("set-priority", extra: ["priority": .string($0)])
                    })) {
                        ForEach(row.priorities ?? []) { item in
                            SwiftUI.Label { Text(verbatim: item.title) } icon: { statusIcon(item) }
                                .tag(item.uuid)
                                .accessibilityIdentifier("button.block-task-priority-option." + item.uuid)
                        }
                    }
                    Button("Clear priority", role: .destructive) {
                        emit("set-priority", extra: ["priority": .string("")])
                    }
                } label: {
                    statusIcon(priority).frame(width: 20, height: 24)
                }
                .padding(.trailing, 5)
                .accessibilityLabel(priority.title)
                .accessibilityIdentifier("button.block-task-priority")
            }
            #if os(iOS)
            if let reference = row.pdfAnnotation {
                OutlinerPDFPageLink(reference: reference, identifier: row.uuid, enabled: context.isUserInteractionEnabled) {
                    guard let data = try? JSONEncoder().encode(reference) else { return }
                    openPDFAnnotation?(String(decoding: data, as: UTF8.self))
                }
                .fixedSize()
                .frame(height: OutlinerLayoutMetrics.titleLineHeight)
            }
            #endif
            VStack(alignment: .leading, spacing: 2) {
                if hasCustomContent, let editor = context.childIDs.first {
                    context.content(for: editor)
                        .font(row.markup.contains { $0.type == .codeBlock } ? .caption : .body)
                        #if os(iOS)
                        .environment(\.outlinerAnchorID, row.scrollAnchorID ?? row.uuid)
                        #endif
                } else if row.isAsset {
                    LGAssetPreview(uuid: row.uuid, title: row.title, assetType: row.assetType, localPath: row.localPath,
                        allowsInteraction: { context.isUserInteractionEnabled },
                        selectBlock: row.selectionMode == true ? { emit("toggle-selection") } : nil,
                        selectionLabel: row.selectionMode == true ? row.editAccessibilityLabel : nil)
                } else {
                    title
                        .accessibilityIdentifier("outliner.block-action." + row.uuid)
                        .accessibilityLabel(row.editAccessibilityLabel)
                        .contentShape(Rectangle())
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
                        .onTapGesture(coordinateSpace: .local) { point in
                            #if os(iOS)
                            if row.selectionMode == true { emit("toggle-selection") }
                            else if !row.opensAsPage && !OutlinerRichMarkupPolicy.containsRich(row.markup) {
                                emit("edit", extra: ["caret-utf16-offset": .int(OutlinerTapCaret.offset(
                                    at: point, width: titleWidth, title: row.title, nodes: row.markup))])
                            } else { emit(row.opensAsPage ? "open-node" : "edit") }
                            #else
                            emit(row.opensAsPage ? "open-node" : "edit")
                            #endif
                        }
                }
                if !row.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(row.tags) { tag in
                            Button { emit("open-node", uuid: tag.uuid) } label: { Text(verbatim: "#" + tag.title) }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                                .frame(height: 22)
                                .accessibilityIdentifier("button.block-tag." + tag.uuid)
                                .contextMenu {
                                    if row.canRemoveTags == true, let title = row.removeTagTitle {
                                        Button(title, role: .destructive) { emit("remove-tag", uuid: tag.uuid) }
                                    }
                                }
                        }
                    }
                }
                if row.syncFailed {
                    Text("Sync failed").font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("outliner.sync-failed." + row.uuid)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(iOS)
            .background(OutlinerScrollAnchorMarker(blockID: row.uuid, anchorID: row.scrollAnchorID ?? row.uuid))
            #endif
            if row.hasChildren {
                let hitSize = OutlinerLayoutMetrics.disclosureHitSize
                let hitWidth = hitSize + row.disclosureGutter
                Color.clear.frame(width: hitWidth, height: OutlinerLayoutMetrics.titleLineHeight)
                    .overlay(alignment: .topTrailing) {
                        Button { emit("collapse") } label: {
                            HStack(spacing: 0) {
                                Spacer(minLength: 0)
                                Image(systemName: row.collapsed ? "arrowtriangle.right.fill" : "arrowtriangle.down.fill")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                Color.clear.frame(width: OutlinerLayoutMetrics.disclosureGlyphInset + row.disclosureGutter)
                            }
                            .frame(width: hitWidth, height: hitSize)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(y: -10)
                        .accessibilityLabel(row.collapseAccessibilityLabel)
                        .accessibilityIdentifier("button.outliner.collapse." + row.uuid)
                    }
            }
        }
        .font(.body)
        .padding(.vertical, 2)
        .background { OutlinerIndentGuides(row: row) }
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(row.selected ? 0.12 : 0))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: row.selected)
        }
    }

    private var title: some View {
        OutlinerMixedRichMarkupContent(nodes: row.markup, fallback: row.title,
            youtubePlaybackStarts: playback.starts,
            onSeekYouTube: { playback.starts[$0] = $1 },
            allowsLinkInteraction: { context.isUserInteractionEnabled && row.selectionMode != true },
            onOpenMarkupLink: { link in if case let .node(uuid) = link { emit("open-node", uuid: uuid) } },
            onEdit: { emit(row.selectionMode == true ? "toggle-selection" : row.opensAsPage ? "open-node" : "edit") })
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .strikethrough(row.completed)
            .foregroundStyle(row.completed ? .secondary : .primary)
    }

    private func statusIcon(_ status: OutlinerRowPayload.Status) -> some View {
        let key = status.icon.replacingOccurrences(of: "app:", with: "")
        let asset: String
        if case let .assetName(name) = LGIconPolicy.icons[key] { asset = name }
        else { asset = "task_todo" }
        return IconImage(name: asset, size: OutlinerLayoutMetrics.statusIconSize)
            .foregroundStyle(status.color(in: semanticColors))
            .shadow(color: .black.opacity(0.18), radius: 0.6, x: 0, y: 0.5)
    }

    private func emit(_ name: String, uuid: String? = nil, extra: [String: LUIExtensionValue] = [:]) {
        guard context.isUserInteractionEnabled else { return }
        var values = extra
        if name != "set-priority" && name != "menu-action" { values["uuid"] = .string(uuid ?? row.uuid) }
        do { try context.emit(name: name, values: values) }
        catch { LogseqRuntimeLog.shared.append(level: .error, source: .ui, message: "Outliner interaction failed: \(error)") }
    }
}

#if os(iOS)
private struct OutlinerPDFPageLink: UIViewRepresentable {
    let reference: OutlinerRowPayload.PDFReference
    let identifier: String
    let enabled: Bool
    let open: () -> Void

    func makeUIView(context: Context) -> UIButton { UIButton(type: .system) }
    func updateUIView(_ button: UIButton, context: Context) {
        button.setTitle("📌 P\(reference.page)", for: .normal)
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityIdentifier = "pdf.annotation-page." + identifier
        button.accessibilityLabel = "Open PDF at page \(reference.page)"
        button.isEnabled = enabled
        button.removeAction(identifiedBy: UIAction.Identifier("open-pdf"), for: .touchUpInside)
        button.addAction(UIAction(identifier: UIAction.Identifier("open-pdf")) { _ in open() }, for: .touchUpInside)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: max(44, uiView.intrinsicContentSize.width + 4), height: 44)
    }
}
#endif
