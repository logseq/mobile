import Foundation
import LogseqModel
import LUIAppleBackend
import Observation
import SwiftUI
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#endif

@MainActor
enum LGExtensionRegistry {
    static func makeRegistry() throws -> LUIAppleExtensionRegistry {
        let registry = LUIAppleExtensionRegistry()
        try LGLiquidGlassTweak.register(in: registry)
        try LGNavigationExtension.register(in: registry)
        try LGSearchPresentationExtension.register(in: registry)
        try NodeIconExtension.register(in: registry)
        try LGOutlinerEditorExtension.register(in: registry)
        try LGRichBlockExtension.register(
            in: registry,
            playback: LGYouTubePlaybackState()
        )
        try OutlinerRowExtension.register(in: registry, playback: LGYouTubePlaybackState())
        return registry
    }
}

@MainActor
@Observable
final class LGYouTubePlaybackState {
    var starts: [String: Int] = [:]
}

@Observable
final class OutlinerRowDropGeometry {
    var height: CGFloat = 44
    var placement: OutlinerDropPlacement?
}

struct OutlinerDropIndicator: View {
    let placement: OutlinerDropPlacement?
    let depth: Int

    var body: some View {
        Canvas { context, size in
            guard let placement else { return }
            let parentX = min(size.width, CGFloat(max(0, depth)) * 22 + 12)
            let y: CGFloat = placement == .before ? 1 : max(1, size.height - 1)
            let x = placement == .inside ? min(size.width, parentX + 22) : parentX
            var line = Path()
            if placement == .inside {
                line.move(to: CGPoint(x: parentX, y: max(1, y - 12)))
                line.addLine(to: CGPoint(x: parentX, y: y))
                line.addLine(to: CGPoint(x: x, y: y))
            } else { line.move(to: CGPoint(x: x, y: y)) }
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(.accentColor))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if os(iOS)
struct OutlinerRowDropDelegate: DropDelegate {
    let geometry: OutlinerRowDropGeometry
    var depth: Int = 0
    let onDrop: (OutlinerDropPlacement) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText])
    }

    func dropEntered(info: DropInfo) {
        geometry.placement = OutlinerDropZone.placement(locationX: info.location.x, locationY: info.location.y, rowHeight: geometry.height, depth: depth)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropEntered(info: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { geometry.placement = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { geometry.placement = nil }
        return onDrop(OutlinerDropZone.placement(
            locationX: info.location.x,
            locationY: info.location.y,
            rowHeight: geometry.height,
            depth: depth
        ))
    }
}

#endif

@MainActor
private enum LGRichBlockExtension {
    static let identifier = "outliner-block-content"
    static let fingerprint = "lui-extension-v1|22:outliner-block-content|profiles:android/kotlin,ios/swiftui|standard-children:0|children:|properties:10:asset-type:string:required:none,10:local-path:string:required:none,11:markup-json:string:required:none,12:is-completed:bool:required:none,18:youtube-target-url:string:required:none,5:title:string:required:none,8:block-id:string:required:none,8:is-asset:bool:required:none|events:10:drag-start[4:uuid:string:required],4:drop[4:uuid:string:required,9:placement:string:required],4:edit[4:uuid:string:required],9:open-node[4:uuid:string:required]"

    static func register(
        in registry: LUIAppleExtensionRegistry,
        playback: LGYouTubePlaybackState
    ) throws {
        try registry.register(
            LUIAppleExtension(
                identifier: identifier,
                fingerprint: fingerprint,
                properties: [
                    .init(name: "title", kind: .string, isRequired: true),
                    .init(name: "block-id", kind: .string, isRequired: true),
                    .init(name: "markup-json", kind: .string, isRequired: true),
                    .init(name: "youtube-target-url", kind: .string, isRequired: true),
                    .init(name: "is-asset", kind: .bool, isRequired: true),
                    .init(name: "is-completed", kind: .bool, isRequired: true),
                    .init(name: "asset-type", kind: .string, isRequired: true),
                    .init(name: "local-path", kind: .string, isRequired: true),
                ],
                events: [
                    .init(name: "drag-start", fields: [
                        .init(name: "uuid", kind: .string, isRequired: true),
                    ]),
                    .init(name: "drop", fields: [
                        .init(name: "uuid", kind: .string, isRequired: true),
                        .init(name: "placement", kind: .string, isRequired: true),
                    ]),
                    .init(name: "edit", fields: [
                        .init(name: "uuid", kind: .string, isRequired: true),
                    ]),
                    .init(name: "open-node", fields: [
                        .init(name: "uuid", kind: .string, isRequired: true),
                    ]),
                ]
            ) { context in
                AnyView(LGRichBlock(context: context, playback: playback))
            }
        )
    }
}

@MainActor
private struct LGRichBlock: View {
    let context: LUIAppleExtensionViewContext
    let playback: LGYouTubePlaybackState
    @State private var dropGeometry = OutlinerRowDropGeometry()

    var body: some View {
        #if os(iOS)
        content
            .overlay { OutlinerDropIndicator(placement: dropGeometry.placement, depth: 0) }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                dropGeometry.height = height
            }
            .onDrag {
                emitDragStart()
                return NSItemProvider(object: blockID as NSString)
            }
            .onDrop(
                of: [UTType.plainText],
                delegate: OutlinerRowDropDelegate(
                    geometry: dropGeometry,
                    onDrop: emitDrop
                )
            )
        #else
        content
        #endif
    }

    private var content: some View {
        Group {
            if boolProperty("is-asset") {
                LGAssetPreview(
                    uuid: blockID,
                    title: stringProperty("title"),
                    assetType: stringProperty("asset-type"),
                    localPath: stringProperty("local-path")
                )
            } else {
                OutlinerMixedRichMarkupContent(
                    nodes: markupNodes,
                    fallback: stringProperty("title"),
                    youtubePlaybackStarts: playback.starts,
                    onSeekYouTube: { url, seconds in
                        playback.starts[url] = seconds
                    },
                    allowsLinkInteraction: { context.isUserInteractionEnabled },
                    onOpenMarkupLink: { link in
                        switch link {
                        case .node(let uuid):
                            emitOpenNode(uuid)
                        }
                    }
                )
                .padding(.vertical, titleVerticalInset)
            }
        }
        .font(.body)
        .frame(
            maxWidth: .infinity,
            minHeight: boolProperty("is-asset") ? nil : OutlinerLayoutMetrics.titleLineHeight,
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
        .strikethrough(boolProperty("is-completed"))
        .foregroundStyle(boolProperty("is-completed") ? .secondary : .primary)
    }

    private var blockID: String {
        stringProperty("block-id")
    }

    private var titleVerticalInset: CGFloat {
        #if os(iOS)
        // Use the editor's font metrics for every line count, including wrapped text.
        OutlinerNativeTextLayoutPolicy.verticalInset(
            fontLineHeight: UIFont.preferredFont(forTextStyle: .body).lineHeight,
            minimumLineHeight: OutlinerLayoutMetrics.titleLineHeight
        )
        #else
        0
        #endif
    }

    private func boolProperty(_ name: String) -> Bool {
        guard case let .bool(value) = context.property(name) else { return false }
        return value
    }

    private var markupNodes: [LogseqMarkupNode] {
        let data = Data(stringProperty("markup-json").utf8)
        return (try? JSONDecoder().decode([LogseqMarkupNode].self, from: data)) ?? []
    }

    private var androidContentHandlesTouches: Bool {
        boolProperty("is-asset")
            || OutlinerMarkupInteractionPolicy.hasInteractiveContent(markupNodes)
    }

    private func stringProperty(_ name: String) -> String {
        guard case let .string(value) = context.property(name) else { return "" }
        return value
    }

    private func emitOpenNode(_ uuid: String) {
        guard context.isUserInteractionEnabled else { return }
        do {
            try context.emit(name: "open-node", values: ["uuid": .string(uuid)])
        } catch {
            logger.error("Could not emit rich block event: \(String(describing: error))")
        }
    }

    private func emitEdit() {
        do {
            try context.emit(name: "edit", values: ["uuid": .string(blockID)])
        } catch {
            logger.error("Could not emit rich block event: \(String(describing: error))")
        }
    }

    private func emitDragStart() {
        do {
            try context.emit(name: "drag-start", values: ["uuid": .string(blockID)])
        } catch {
            logger.error("Could not emit block drag event: \(String(describing: error))")
        }
    }

    private func emitDrop(_ placement: OutlinerDropPlacement) -> Bool {
        do {
            try context.emit(name: "drop", values: [
                "uuid": .string(blockID),
                "placement": .string(placement.eventValue),
            ])
            return true
        } catch {
            logger.error("Could not emit block drop event: \(String(describing: error))")
            return false
        }
    }
}

@MainActor
enum LGAssetPreviewPolicy {
    static func usesInlineAudioPlayer(assetType: String, localPath: String) -> Bool {
        !localPath.isEmpty
            && AssetPresentationPolicy.kind(
                assetType: assetType,
                localPath: localPath
            ) == .audio
    }
}

@MainActor
struct LGAssetPreview: View {
    let uuid: String
    let title: String
    let assetType: String
    let localPath: String
    @Environment(\.lgImagePreviews) private var imagePreviews
    @State private var downloadedURL: URL?
    @State private var downloadError: String?
    @State private var retry = 0

    var body: some View {
        #if os(iOS)
        if kind == .image {
            Group {
                if let url = downloadedURL ?? LocalAssetPath.resolve(localPath, title: title, assetType: assetType) {
                    Button {
                        Task { await imagePreviews?.present(uuid: uuid, fallback: url) }
                    } label: {
                        LGInlineImage(url: url)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preview image")
                    .accessibilityIdentifier("image.open." + uuid)
                } else if let downloadError {
                    Button { retry += 1 } label: {
                        SwiftUI.Label("Retry image", systemImage: "arrow.clockwise")
                    }
                    .accessibilityHint(downloadError)
                } else {
                    ProgressView().frame(height: 120)
                }
            }
            .task(id: "\(uuid):\(retry)") {
                guard LocalAssetPath.resolve(localPath, title: title, assetType: assetType) == nil else { return }
                downloadError = nil
                do {
                    let url = try await LGGraphAssetLoader.load(uuid: uuid, assetType: assetType)
                    try Task.checkCancellation()
                    downloadedURL = url
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    downloadError = error.localizedDescription
                }
            }
        } else if LGAssetPreviewPolicy.usesInlineAudioPlayer(
            assetType: assetType,
            localPath: localPath
        ), let url = LocalAssetPath.resolve(
            localPath,
            title: title,
            assetType: assetType
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: title.isEmpty ? "Untitled file" : title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(3)
                AssetAudioPlayer(path: url.path)
                    .frame(height: 44)
            }
        } else {
            fileSummary
        }
        #else
        fileSummary
        #endif
    }

    private var kind: AssetPresentationKind {
        AssetPresentationPolicy.kind(assetType: assetType, localPath: localPath)
    }

    private var fileSummary: some View {
        HStack(spacing: 8) {
            IconImage(name: kind == .audio ? "audio" : "paperclip")
                .frame(width: 18, height: 18)
            Text(verbatim: title.isEmpty ? "Untitled file" : title)
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(3)
        }
        .accessibilityIdentifier("asset.preview.file")
    }
}
