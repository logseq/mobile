import Foundation
import SwiftUI
import LogseqModel
import LUIAppleBackend
#if os(iOS)
import UniformTypeIdentifiers
import UIKit
#endif

struct OutlinerRowPayload: Decodable, Equatable {
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
    let opensAsPage: Bool
    let journalBullet: Bool
    let syncFailed: Bool
    let priority: Status?
    let status: Status?
    let statuses: [Status]
    let tags: [Summary]
}

@MainActor enum OutlinerRowExtension {
    static let identifier = "outliner-block-row"
    static let fingerprint = "lui-extension-v1|18:outliner-block-row|profiles:ios/swiftui|standard-children:1|children:|properties:7:payload:string:required:none|events:10:drag-start[4:uuid:string:required],10:long-press[4:uuid:string:required],10:set-status[4:uuid:string:required,5:count:int:required],4:drop[4:uuid:string:required,9:placement:string:required],4:edit[4:uuid:string:required],8:collapse[4:uuid:string:required],9:open-node[4:uuid:string:required]"

    static func register(in registry: LUIAppleExtensionRegistry, playback: LGYouTubePlaybackState) throws {
        let uuid = LUIExtensionEventField(name: "uuid", kind: .string, isRequired: true)
        try registry.register(LUIAppleExtension(identifier: identifier, fingerprint: fingerprint,
            acceptsStandardChildren: true,
            properties: [.init(name: "payload", kind: .string, isRequired: true)],
            events: ["edit", "open-node", "collapse", "long-press", "drag-start"].map {
                LUIExtensionEvent(name: $0, fields: [uuid])
            } + [.init(name: "drop", fields: [uuid, .init(name: "placement", kind: .string, isRequired: true)]),
                 .init(name: "set-status", fields: [uuid, .init(name: "count", kind: .int, isRequired: true)])]
        ) { context in
            guard case let .string(encoded) = context.property("payload"),
                  let row = try? JSONDecoder().decode(OutlinerRowPayload.self, from: Data(encoded.utf8)) else {
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
    @Environment(\.luiSemanticColors) private var semanticColors

    @ViewBuilder var body: some View {
        #if os(iOS)
        if context.childIDs.isEmpty {
            content
                .overlay { OutlinerDropIndicator(placement: dropGeometry.placement, depth: row.depth) }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dropGeometry.height = $0 }
                .onLongPressGesture { emit("long-press") }
                .onDrag { emit("drag-start"); return NSItemProvider(object: row.uuid as NSString) }
                .onDrop(of: [UTType.plainText], delegate: OutlinerRowDropDelegate(geometry: dropGeometry, depth: row.depth) {
                    emit("drop", extra: ["placement": .string($0.eventValue)])
                    return true
                })
        } else { content }
        #else
        content
        #endif
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        if context.childIDs.isEmpty && !row.isAsset && row.markup.allSatisfy({ $0.type == .text }) {
            OutlinerTextRow(row: row, emit: { name, uuid, values in emit(name, uuid: uuid, extra: values) })
        } else { swiftUIContent }
        #else
        swiftUIContent
        #endif
    }

    private var swiftUIContent: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: CGFloat(max(0, row.depth)) * 22, height: 1)
            Group {
                if row.journalBullet {
                    IconImage(name: row.collapsed && row.hasChildren ? "outliner_bullet_closed" : "outliner_bullet", size: 24).frame(height: 24)
                        .foregroundStyle(Color.secondary.opacity(0.4))
                        .accessibilityIdentifier("button.outliner.zoom." + row.uuid + "." + row.title)
                } else {
                    Button { emit("open-node") } label: {
                        IconImage(name: row.collapsed && row.hasChildren ? "outliner_bullet_closed" : "outliner_bullet", size: 24).frame(height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .accessibilityLabel("Open block")
                    .accessibilityIdentifier("button.outliner.zoom." + row.uuid + "." + row.title)
                }
            }
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
                statusIcon(priority).frame(width: 20, height: 24)
                    .padding(.trailing, 5)
                    .accessibilityLabel(priority.title)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let editor = context.childIDs.first {
                    context.content(for: editor)
                } else if row.isAsset {
                    LGAssetPreview(uuid: row.uuid, title: row.title, assetType: row.assetType, localPath: row.localPath)
                } else {
                    title
                        .accessibilityIdentifier("outliner.block-action." + row.uuid)
                        .accessibilityLabel("Edit block " + row.title)
                        .contentShape(Rectangle())
                        .onTapGesture { emit(row.opensAsPage ? "open-node" : "edit") }
                }
                if !row.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(row.tags) { tag in
                            Button { emit("open-node", uuid: tag.uuid) } label: { Text(verbatim: "#" + tag.title) }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                                .frame(height: 22)
                                .accessibilityIdentifier("button.block-tag." + tag.uuid)
                        }
                    }
                }
                if row.syncFailed {
                    Text("Sync failed").font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("outliner.sync-failed." + row.uuid)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.hasChildren {
                Button { emit("collapse") } label: {
                    Image(systemName: row.collapsed ? "arrowtriangle.right.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.collapsed ? "Expand block" : "Collapse block")
                .accessibilityIdentifier("button.outliner.collapse." + row.uuid)
            }
        }
        .font(.body)
        .padding(.vertical, 2)
        .background { OutlinerIndentGuides(row: row) }
        .background(row.selected ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private var title: some View {
        OutlinerMixedRichMarkupContent(nodes: row.markup, fallback: row.title,
            youtubePlaybackStarts: playback.starts,
            onSeekYouTube: { playback.starts[$0] = $1 },
            allowsLinkInteraction: { context.isUserInteractionEnabled },
            onOpenMarkupLink: { link in if case let .node(uuid) = link { emit("open-node", uuid: uuid) } })
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
        values["uuid"] = .string(uuid ?? row.uuid)
        do { try context.emit(name: name, values: values) }
        catch { LogseqRuntimeLog.shared.append(level: .error, source: .ui, message: "Outliner interaction failed: \(error)") }
    }
}
