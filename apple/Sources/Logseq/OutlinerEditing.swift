import SwiftUI
import LogseqModel

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
