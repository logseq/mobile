import SwiftUI
import LogseqModel

enum BlockEditPresentation: Equatable {
    case composer
    case inline
}

enum BlockEditingPolicy {
    static func presentation(for contentMode: LogseqContentMode) -> BlockEditPresentation {
        contentMode == .outliner ? .inline : .composer
    }
}

enum BlockSelectionActivation: Equatable {
    case longPress
}

enum BlockSelectionGesturePolicy {
    static let activation = BlockSelectionActivation.longPress
}

enum OutlinerClipboardPolicy {
    static func nodeReferences(_ uuids: [String]) -> String {
        uuids.map { "[[\($0)]]" }.joined(separator: "\n")
    }
}

enum OutlinerMarkupLink: Equatable {
    case node(uuid: String)

    var url: URL? {
        switch self { case let .node(uuid): return URL(string: "logseq-node://\(uuid)") }
    }

    init?(url: URL) {
        guard let uuid = url.host, !uuid.isEmpty else { return nil }
        switch url.scheme {
        case "logseq-node":
            self = .node(uuid: uuid)
        default:
            return nil
        }
    }
}

struct OutlinerMarkupPresentation: Equatable {
    let plainText: String
    let links: [OutlinerMarkupLink]

    static func make(
        nodes: [LogseqMarkupNode],
        fallback: String
    ) -> OutlinerMarkupPresentation {
        guard !nodes.isEmpty else {
            return OutlinerMarkupPresentation(plainText: fallback, links: [])
        }
        var text = ""
        var links: [OutlinerMarkupLink] = []

        func append(_ nodes: [LogseqMarkupNode]) {
            for node in nodes {
                switch node.type {
                case .text, .code, .codeBlock, .math, .cloze, .youtubeTimestamp:
                    text += node.text ?? ""
                case .emphasis, .quote:
                    append(node.children)
                case .link:
                    if node.children.isEmpty {
                        text += node.url ?? ""
                    } else {
                        append(node.children)
                    }
                case .nodeReference:
                    text += "[[" + (node.title ?? "") + "]]"
                    if let uuid = node.uuid {
                        links.append(.node(uuid: uuid))
                    }
                case .tagReference:
                    text += "#" + (node.title ?? "")
                    if let uuid = node.uuid {
                        links.append(.node(uuid: uuid))
                    }
                case .video, .iframe:
                    text += node.url ?? ""
                }
            }
        }

        append(nodes)
        return OutlinerMarkupPresentation(plainText: text, links: links)
    }
}

enum OutlinerRichMarkupPolicy {
    static func isRich(_ type: LogseqMarkupNodeType) -> Bool {
        switch type {
        case .quote, .math, .codeBlock, .video, .iframe, .youtubeTimestamp, .cloze:
            return true
        default:
            return false
        }
    }

    static func containsRich(_ nodes: [LogseqMarkupNode]) -> Bool {
        nodes.contains { isRich($0.type) }
    }

    static func containsInteractive(_ nodes: [LogseqMarkupNode]) -> Bool {
        nodes.contains { node in
            switch node.type {
            case .video, .iframe, .youtubeTimestamp, .cloze:
                return true
            default:
                return containsInteractive(node.children)
            }
        }
    }

    static func chunks(_ nodes: [LogseqMarkupNode]) -> [[LogseqMarkupNode]] {
        var result: [[LogseqMarkupNode]] = []
        var inline: [LogseqMarkupNode] = []

        func flushInline() {
            guard !inline.isEmpty else { return }
            result.append(inline)
            inline.removeAll(keepingCapacity: true)
        }

        for node in nodes {
            if isRich(node.type) {
                flushInline()
                result.append([node])
            } else {
                inline.append(node)
            }
        }
        flushInline()
        return result
    }
}

enum BlockTagPresentationPolicy {
    static func inlineTagIDs(_ nodes: [LogseqMarkupNode]) -> Set<String> {
        var result: Set<String> = []
        collectInlineTagIDs(nodes, into: &result)
        return result
    }

    static func trailingTags(
        tags: [LogseqEntitySummary],
        markup: [LogseqMarkupNode]
    ) -> [LogseqEntitySummary] {
        let inlineIDs = inlineTagIDs(markup)
        var seen: Set<String> = []
        return tags.filter { tag in
            guard !inlineIDs.contains(tag.uuid) else { return false }
            guard !seen.contains(tag.uuid) else { return false }
            seen.insert(tag.uuid)
            return true
        }
    }

    private static func collectInlineTagIDs(
        _ nodes: [LogseqMarkupNode],
        into result: inout Set<String>
    ) {
        for node in nodes {
            if node.type == .tagReference, let uuid = node.uuid {
                result.insert(uuid)
            }
            collectInlineTagIDs(node.children, into: &result)
        }
    }
}

enum InlineEditorTextReconciliationDecision: Equatable {
    case keepLocal
    case acknowledgeLocal
    case applyModel
}

enum InlineEditorTextReconciliationPolicy {
    /// While a Return-key handoff is pending, the editor keeps showing the
    /// full pre-split text at the old block position and applies the model
    /// text only in the same render pass that moves the editor to the new
    /// block, so the split appears atomically without flicker.
    static func decision(
        modelText: String,
        localText: String?,
        isSameBlock: Bool = true,
        isAwaitingBlockHandoff: Bool = false
    ) -> InlineEditorTextReconciliationDecision {
        if isAwaitingBlockHandoff {
            return isSameBlock ? .keepLocal : .applyModel
        }
        guard let localText else { return .applyModel }
        if modelText == localText { return .acknowledgeLocal }
        if !isSameBlock { return .applyModel }
        return .keepLocal
    }
}

enum InlineEditorCaretEmissionPolicy {
    static func shouldEmit(
        textMatchesModel: Bool,
        isApplyingModel: Bool
    ) -> Bool {
        textMatchesModel && !isApplyingModel
    }
}

enum AndroidInlineEditorInputAction: Equatable {
    case textChange(text: String, caretUTF16Offset: Int)
    case returnKey(text: String, caretUTF16Offset: Int)
}

enum AndroidInlineEditorInputPolicy {
    static func transition(
        previousText: String,
        updatedText: String,
        updatedCaretUTF16Offset: Int
    ) -> AndroidInlineEditorInputAction {
        if !previousText.contains("\n"), updatedText.contains("\n") {
            return .returnKey(
                text: updatedText.replacingOccurrences(of: "\n", with: ""),
                caretUTF16Offset: max(updatedCaretUTF16Offset - 1, 0)
            )
        }
        return .textChange(
            text: updatedText,
            caretUTF16Offset: max(updatedCaretUTF16Offset, 0)
        )
    }

    static func shouldMergeBackward(
        text: String,
        selectionStartUTF16Offset: Int,
        selectionEndUTF16Offset: Int
    ) -> Bool {
        selectionStartUTF16Offset == 0 && selectionEndUTF16Offset == 0
    }
}

enum InlineEditorHandoffMerge {
    /// Keystrokes swallowed while a Return handoff was pending are inserted
    /// at the caret the core requested for the new block.
    static func merged(
        modelText: String,
        desiredCaretUTF16Offset: Int?,
        bufferedTyping: String
    ) -> (text: String, caretUTF16Offset: Int) {
        let caret = min(max(desiredCaretUTF16Offset ?? modelText.count, 0), modelText.count)
        guard !bufferedTyping.isEmpty else { return (modelText, caret) }
        let value = modelText as NSString
        let nsCaret = min(max(desiredCaretUTF16Offset ?? value.length, 0), value.length)
        let text = value.replacingCharacters(
            in: NSRange(location: nsCaret, length: 0),
            with: bufferedTyping
        )
        return (text, nsCaret + (bufferedTyping as NSString).length)
    }
}

enum InlineEditorFocusPolicy {
    static func shouldRequestFocus(
        isAttachedToWindow: Bool,
        isFirstResponder: Bool
    ) -> Bool {
        !isFirstResponder
    }
}

enum InlineEditorPairDeletion {
    static func deletingEmptyNodeReference(
        from text: String,
        range: NSRange,
        replacementText: String
    ) -> (text: String, caretUTF16Offset: Int)? {
        guard replacementText.isEmpty, range.length == 1, range.location > 0 else {
            return nil
        }
        let value = text as NSString
        let pairRange = NSRange(location: range.location - 1, length: 4)
        guard NSMaxRange(pairRange) <= value.length,
              value.substring(with: pairRange) == "[[]]" else {
            return nil
        }
        return (
            value.replacingCharacters(in: pairRange, with: ""),
            pairRange.location
        )
    }
}

enum OutlinerAutocompleteLayoutPolicy {
    static let isVertical = true
    static let maximumHeight: CGFloat = 220.0
    static let rowHeight: CGFloat = 44.0
    static let verticalPadding: CGFloat = 16.0

    static func height(candidateCount: Int) -> CGFloat {
        guard candidateCount > 0 else { return 0.0 }
        return min(CGFloat(candidateCount) * rowHeight + verticalPadding, maximumHeight)
    }
}

enum EmbeddedMediaPolicy {
    private static let youtubeHosts = [
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "youtube-nocookie.com",
        "www.youtube-nocookie.com",
    ]

    static func safeURL(_ value: String?) -> URL? {
        guard let value,
              let url = URL(string: value),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    static func youtubeEmbedURL(_ url: URL, startSeconds: Int? = nil) -> URL? {
        let host = (url.host ?? "").lowercased()
        var videoID: String?
        if host == "youtu.be" || host == "www.youtu.be" {
            videoID = url.pathComponents.dropFirst().first
        } else if youtubeHosts.contains(host) {
            if url.path == "/watch" {
                videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value
            } else if url.pathComponents.count >= 3,
                      ["embed", "shorts", "live"].contains(url.pathComponents[1]) {
                videoID = url.pathComponents[2]
            }
        }
        guard let videoID,
              isValidYouTubeVideoID(videoID)
        else { return nil }

        let sourceQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var start = startSeconds.flatMap { $0 > 0 ? $0 : nil }
        if start == nil, let rawStart = sourceQuery
            .first(where: { $0.name == "start" || $0.name == "t" })?.value,
           let parsedStart = Int(rawStart), parsedStart > 0 {
            start = parsedStart
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube-nocookie.com"
        components.path = "/embed/\(videoID)"
        components.queryItems = [URLQueryItem(name: "playsinline", value: "1")]
        if let start {
            components.queryItems?.append(URLQueryItem(name: "start", value: String(start)))
        }
        return components.url
    }

    private static func isValidYouTubeVideoID(_ value: String) -> Bool {
        guard value.count == 11 else { return false }
        let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        for character in value where !allowed.contains(character) {
            return false
        }
        return true
    }

    static func webVideoEmbedURL(_ url: URL, startSeconds: Int? = nil) -> URL? {
        if let youtube = youtubeEmbedURL(url, startSeconds: startSeconds) { return youtube }
        let host = (url.host ?? "").lowercased()
        return host == "player.vimeo.com" ? url : nil
    }

    static func webRequestHeaders(for url: URL) -> [String: String] {
        let host = (url.host ?? "").lowercased()
        guard youtubeHosts.contains(host) else { return [:] }
        return ["Referer": "https://logseq.com/"]
    }

    static func webReferer(for url: URL) -> String? {
        webRequestHeaders(for: url)["Referer"]
    }
}

enum OutlinerYouTubeTimestampPolicy {
    static func associateTargets(
        _ nodes: [LogseqMarkupNode],
        precedingYouTubeURL: String? = nil
    ) -> [LogseqMarkupNode] {
        var currentYouTubeURL = precedingYouTubeURL
        return nodes.map { node in
            if node.type == .video,
               let source = node.url,
               let url = EmbeddedMediaPolicy.safeURL(source),
               EmbeddedMediaPolicy.youtubeEmbedURL(url) != nil {
                currentYouTubeURL = source
                return node
            }
            guard node.type == .youtubeTimestamp,
                  node.url == nil,
                  let currentYouTubeURL else { return node }
            return LogseqMarkupNode(
                type: node.type,
                text: node.text,
                style: node.style,
                url: currentYouTubeURL,
                uuid: node.uuid,
                title: node.title,
                children: node.children
            )
        }
    }

    static func targetURLsByBlockID(
        _ blocks: [(id: String, nodes: [LogseqMarkupNode])]
    ) -> [String: String] {
        var currentYouTubeURL: String?
        var result: [String: String] = [:]
        for block in blocks {
            for node in block.nodes {
                if node.type == .video,
                   let source = node.url,
                   let url = EmbeddedMediaPolicy.safeURL(source),
                   EmbeddedMediaPolicy.youtubeEmbedURL(url) != nil {
                    currentYouTubeURL = source
                } else if node.type == .youtubeTimestamp,
                          node.url == nil,
                          let currentYouTubeURL {
                    result[block.id] = currentYouTubeURL
                }
            }
        }
        return result
    }

    static func seconds(_ node: LogseqMarkupNode) -> Int? {
        guard node.type == .youtubeTimestamp,
              let value = node.style,
              let seconds = Int(value),
              seconds >= 0 else { return nil }
        return seconds
    }
}

struct OutlinerRowRenderKey: Equatable, @unchecked Sendable {
    let row: LogseqOutlineRow
    let statuses: [LogseqTaskStatus]
    let isEditing: Bool
    let isSelected: Bool
    let isSelectionActive: Bool
    let editingTitle: String
    let desiredCaretUTF16Offset: Int?
}

enum OutlinerToolbarAction: Hashable {
    case task
    case outdent
    case indent
    case tag
    case pageReference
    case camera
    case audio
    case attachment
    case hideKeyboard
    case copy
    case delete
    case copyReference
    case copyURL
    case unselect
    case undo
    case redo

    var eventValue: String? {
        switch self {
        case .task: return "task"
        case .outdent: return "outdent"
        case .indent: return "indent"
        case .tag: return "tag"
        case .pageReference: return "pageReference"
        case .camera: return "camera"
        case .audio: return "audio"
        case .attachment: return "attachment"
        case .hideKeyboard: return "hideKeyboard"
        case .copy: return "copy"
        case .delete: return "delete"
        case .copyReference: return "copyReference"
        case .copyURL: return "copyURL"
        case .unselect: return "unselect"
        case .undo, .redo: return nil
        }
    }

    var systemImageName: String {
        switch self {
        case .task: return "checkmark.square"
        case .outdent: return "arrow.left"
        case .indent: return "arrow.right"
        case .tag: return "number"
        case .camera: return "camera"
        case .audio: return "mic"
        case .attachment: return "paperclip"
        case .pageReference: return "parentheses"
        case .hideKeyboard: return "keyboard.chevron.compact.down"
        case .copy: return "doc.on.doc"
        case .delete: return "trash"
        case .copyReference: return "r.square"
        case .copyURL: return "link"
        case .unselect: return "xmark"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .task: return "Task"
        case .outdent: return "Outdent"
        case .indent: return "Indent"
        case .tag: return "Tag"
        case .pageReference: return "Page reference"
        case .camera: return "Photo"
        case .audio: return "Record audio"
        case .attachment: return "Upload asset"
        case .hideKeyboard: return "Hide keyboard"
        case .copy: return "Copy"
        case .delete: return "Delete"
        case .copyReference: return "Copy reference"
        case .copyURL: return "Copy URL"
        case .unselect: return "Unselect"
        case .undo: return "Undo"
        case .redo: return "Redo"
        }
    }

    var preservesInlineEditorFocus: Bool {
        switch self {
        case .task, .outdent, .indent, .tag, .pageReference:
            return true
        case .camera, .audio, .attachment, .hideKeyboard, .copy, .delete,
             .copyReference, .copyURL, .unselect, .undo, .redo:
            return false
        }
    }
}

enum OutlinerToolbarPolicy {
    static let editorItemWidth: CGFloat = 42
    static let selectionItemWidth: CGFloat = 58
    static let selectionItemSpacing: CGFloat = 6
    static let iconSize: CGFloat = 18
    static let iconBoxSize: CGFloat = 22
    static let captionHeight: CGFloat = 14

    static let editorActions: [OutlinerToolbarAction] = [
        .task, .outdent, .indent, .tag, .camera, .audio, .pageReference,
    ]

    static let trailingEditorAction = OutlinerToolbarAction.hideKeyboard

    static let selectionActions: [OutlinerToolbarAction] = [
        .copy, .outdent, .indent, .delete, .copyReference, .copyURL,
    ]

    static let trailingSelectionAction = OutlinerToolbarAction.unselect

    static func taskAccessibilityTitle(statusTitle: String?) -> String {
        "Task: \(statusTitle ?? "None")"
    }
}

enum OutlinerLayoutMetrics {
    static let outerHorizontalInset: CGFloat = 8
    static let indentation: CGFloat = 22
    static let bulletHitSize: CGFloat = 24
    static let titleLineHeight: CGFloat = bulletHitSize
    static let depthSpacerHeight: CGFloat = 0
    static let rowVerticalPadding: CGFloat = 5
    static let bulletContentSpacing: CGFloat = 2
    static let rootBulletCenterX = bulletHitSize / 2

    static func bulletCenterX(depth: Int) -> CGFloat {
        rootBulletCenterX + CGFloat(depth) * indentation
    }

    static func guideCenterX(level: Int) -> CGFloat {
        bulletCenterX(depth: level)
    }
}

enum OutlinerNativeTextLayoutPolicy {
    static func verticalInset(
        fontLineHeight: CGFloat,
        minimumLineHeight: CGFloat
    ) -> CGFloat {
        max(0.0, (minimumLineHeight - fontLineHeight) / 2)
    }
}

enum OutlinerEditorViewportPolicy {
    static func viewportChangeCanOccludeEditor(
        previousHeight: CGFloat,
        currentHeight: CGFloat
    ) -> Bool {
        currentHeight < previousHeight
    }

    static func isFullyVisible(frame: CGRect, viewportHeight: CGFloat) -> Bool {
        frame.minY >= 0 && frame.maxY <= viewportHeight
    }

    static func shouldEndEditing(
        blockID: String,
        renderedEditorBlockID: String?,
        renderedBlockIDs: Set<String>,
        isUserScrolling: Bool,
        isScrollExitArmed: Bool
    ) -> Bool {
        isScrollExitArmed
            && isUserScrolling
            && renderedEditorBlockID == blockID
            && !renderedBlockIDs.contains(blockID)
    }

    static func shouldEnsureVisible(
        previousBlockID: String?,
        blockID: String?,
        viewportChanged: Bool,
        isBlockVisible: Bool
    ) -> Bool {
        guard let blockID else { return false }
        guard !isBlockVisible else { return false }
        return viewportChanged || previousBlockID != blockID
    }
}

enum OutlinerScrollAnchorPolicy {
    static func retainedAnchor(
        current: String?,
        previousRowIDs: [String],
        rowIDs: [String]
    ) -> String? {
        guard let current else { return nil }
        let available = Set(rowIDs)
        if available.contains(current) { return current }
        guard let index = previousRowIDs.firstIndex(of: current) else { return nil }
        for distance in 1...max(previousRowIDs.count, 1) {
            let next = index + distance
            if next < previousRowIDs.count, available.contains(previousRowIDs[next]) {
                return previousRowIDs[next]
            }
            let previous = index - distance
            if previous >= 0, available.contains(previousRowIDs[previous]) {
                return previousRowIDs[previous]
            }
        }
        return nil
    }
}

enum OutlinerPaginationPolicy {
    static let buttonTitle = "Load earlier journals"
    static let accessibilityIdentifier = "button.outliner.load-older-journals"
}

enum OutlinerSectionNavigationPolicy {
    static func pageUUID(
        isJournalHome: Bool,
        sectionBlockPageIDs: [String]
    ) -> String? {
        guard isJournalHome else { return nil }
        return sectionBlockPageIDs.first
    }
}

enum OutlinerNavigationPolicy {
    static func backStepCount(presentedPath: [String], modelPath: [String]) -> Int {
        guard modelPath.starts(with: presentedPath) else { return 0 }
        return modelPath.count - presentedPath.count
    }

    static func pathAfterBackButton<Element>(_ path: [Element]) -> [Element] {
        path.isEmpty ? [] : Array(path.dropLast())
    }
}

enum AppNavigationRoute: Hashable {
    case node(String)
}

struct NodeNavigationPreview {
    let title: String
    let rows: [LogseqOutlineRow]
    let sections: [LogseqBlockSection]
}

enum NodeNavigationPreviewPolicy {
    static func make(
        uuid: String,
        rows: [LogseqOutlineRow],
        sections: [LogseqBlockSection],
        linkedTitle: String?
    ) -> NodeNavigationPreview {
        let matchingSections = sections.filter { section in
            section.blocks.contains { $0.pageId == uuid }
        }
        let matchingBlockIDs = Set(
            matchingSections.flatMap(\.blocks).map(\.uuid)
        )
        let matchingRows = rows.filter { matchingBlockIDs.contains($0.block.uuid) }
        let targetBlock = rows.first { $0.block.uuid == uuid }?.block
        let title = matchingSections.first?.title
            ?? targetBlock?.title
            ?? linkedTitle
            ?? "Untitled"
        return NodeNavigationPreview(
            title: title,
            rows: matchingRows,
            sections: matchingSections
        )
    }
}

enum AppNavigationPathPolicy {
    static func nodeCount(_ path: [AppNavigationRoute]) -> Int {
        path.reduce(into: 0) { count, route in
            if case .node = route { count += 1 }
        }
    }

    static func shouldAppend(_ route: AppNavigationRoute, to path: [AppNavigationRoute]) -> Bool {
        path.last != route
    }

    static func pathAfterRequest(
        _ route: AppNavigationRoute,
        in path: [AppNavigationRoute]
    ) -> [AppNavigationRoute] {
        shouldAppend(route, to: path) ? path + [route] : path
    }

    static func pathAfterResolution(
        _ route: AppNavigationRoute,
        resolved: Bool,
        in path: [AppNavigationRoute]
    ) -> [AppNavigationRoute] {
        guard !resolved,
              let index = path.lastIndex(of: route) else { return path }
        var result = path
        result.remove(at: index)
        return result
    }

    static func coreCloseCount(
        previousPath: [AppNavigationRoute],
        path: [AppNavigationRoute],
        projectedNodeCount: Int
    ) -> Int {
        let presentedCloseCount = max(0, nodeCount(previousPath) - nodeCount(path))
        let projectedExcess = max(0, projectedNodeCount - nodeCount(path))
        return min(presentedCloseCount, projectedExcess)
    }

    static func shouldKeepResolvedProjection(
        _ route: AppNavigationRoute,
        requestedDepth: Int,
        in path: [AppNavigationRoute]
    ) -> Bool {
        requestedDepth > 0
            && path.count >= requestedDepth
            && path[requestedDepth - 1] == route
    }
}

enum RelatedContentPolicy {
    static func sectionTitle(isTag: Bool, hasBlocks: Bool) -> String? {
        isTag ? "Tagged nodes" : (hasBlocks ? "Linked references" : nil)
    }

    static func emptyTitle(isTag: Bool, hasBlocks: Bool) -> String? {
        isTag && !hasBlocks ? "No tagged nodes" : nil
    }
}

struct RelatedBlockGroup: Identifiable, Equatable {
    let id: String
    let breadcrumbs: [LogseqEntitySummary]
    let blocks: [LogseqBlock]
}

enum RelatedBlockGrouping {
    static func groups(_ blocks: [LogseqBlock]) -> [RelatedBlockGroup] {
        var order: [String] = []
        var breadcrumbsByID: [String: [LogseqEntitySummary]] = [:]
        var blocksByID: [String: [LogseqBlock]] = [:]
        for block in blocks {
            let key = block.breadcrumbs.last?.uuid ?? block.parentId ?? block.pageId
            if blocksByID[key] == nil {
                order.append(key)
                breadcrumbsByID[key] = block.breadcrumbs
                blocksByID[key] = []
            }
            blocksByID[key]!.append(block)
        }
        return order.map { key in
            RelatedBlockGroup(
                id: key,
                breadcrumbs: breadcrumbsByID[key]!,
                blocks: blocksByID[key]!
            )
        }
    }
}

enum OutlinerAccessibilityTitle {
    private static func displayTitle(_ title: String) -> String {
        title.isEmpty ? "Untitled block" : title
    }

    static func zoom(blockTitle: String) -> String {
        "Zoom into \(displayTitle(blockTitle))"
    }

    static func collapse(blockTitle: String, isCollapsed: Bool) -> String {
        "\(isCollapsed ? "Expand" : "Collapse") \(displayTitle(blockTitle))"
    }
}

enum OutlinerDropPlacement: Equatable {
    case before
    case inside
    case after

    var eventValue: String {
        switch self {
        case .before: return "before"
        case .inside: return "inside"
        case .after: return "after"
        }
    }
}

enum OutlinerDropZone {
    static func placement(locationY: CGFloat, rowHeight: CGFloat) -> OutlinerDropPlacement {
        let height = max(rowHeight, 1)
        if locationY < height * 0.25 { return .before }
        if locationY > height * 0.75 { return .after }
        return .inside
    }
}

struct OutlinerKeyboardHideCounter {
    private(set) var hideCount = 0
    private(set) var hasPendingHandoff = false
    private var activeEditorIDs: Set<String> = []

    var isEditing: Bool {
        !activeEditorIDs.isEmpty || hasPendingHandoff
    }

    mutating func editorAppeared(id: String) {
        if activeEditorIDs.isEmpty && !hasPendingHandoff {
            hideCount = 0
        }
        hasPendingHandoff = false
        activeEditorIDs.insert(id)
    }

    mutating func editorChanged(from previousID: String, to currentID: String) {
        activeEditorIDs.remove(previousID)
        activeEditorIDs.insert(currentID)
        hasPendingHandoff = false
    }

    mutating func editorDisappeared(id: String) {
        activeEditorIDs.remove(id)
        if activeEditorIDs.isEmpty {
            hasPendingHandoff = true
        }
    }

    mutating func finishPendingHandoff() {
        if activeEditorIDs.isEmpty {
            hasPendingHandoff = false
        }
    }

    mutating func keyboardWillHide() {
        if isEditing {
            hideCount += 1
        }
    }
}
