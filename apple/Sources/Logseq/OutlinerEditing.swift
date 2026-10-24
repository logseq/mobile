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
        case .quote, .math, .codeBlock, .video, .iframe, .html, .image, .youtubeTimestamp, .cloze:
            return true
        default:
            return false
        }
    }

    static func containsRich(_ nodes: [LogseqMarkupNode]) -> Bool {
        nodes.contains { isRich($0.type) || containsRich($0.children) }
    }

    static func containsInteractive(_ nodes: [LogseqMarkupNode]) -> Bool {
        nodes.contains { node in
            switch node.type {
            case .video, .iframe, .html, .image, .youtubeTimestamp, .cloze:
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
            if isRich(node.type) && !(node.type == .math && node.style == "inline") {
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

enum NativeEditorInputPolicy {
    private struct Policy: Decodable {
        struct EmptyPair: Decodable { let text: String; let deleteOffset: Int }
        let emptyPairs: [EmptyPair]?
        let multiline: Bool?
    }

    static func allowsLineBreak(_ inputPolicy: String) -> Bool {
        (try? JSONDecoder().decode(Policy.self, from: Data(inputPolicy.utf8)))?.multiline == true
    }

    static func deletingEmptyPair(from text: String, range: NSRange, replacementText: String,
                                  inputPolicy: String = "{}") -> (text: String, caretUTF16Offset: Int)? {
        guard replacementText.isEmpty, range.length == 1,
              let policy = try? JSONDecoder().decode(Policy.self, from: Data(inputPolicy.utf8)) else { return nil }
        let value = text as NSString
        for rule in policy.emptyPairs ?? [] {
            let length = (rule.text as NSString).length
            guard length > 1, rule.deleteOffset >= 0, rule.deleteOffset < length,
                  range.location >= rule.deleteOffset else { continue }
            let pair = NSRange(location: range.location - rule.deleteOffset, length: length)
            guard NSMaxRange(pair) <= value.length, value.substring(with: pair) == rule.text else { continue }
            return (value.replacingCharacters(in: pair, with: ""), pair.location)
        }
        return nil
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
    static let statusIconSize: CGFloat = 22
    static let statusVisibleSpacing: CGFloat = 7
    // The bullet's visible radius is 3.5 in a 24-point canvas. Task icons
    // occupy x=1...19 of a 20-unit viewBox. Subtract their transparent inset
    // from both gaps so the visible edges have the same spacing.
    private static let statusInkInset = statusIconSize / 20
    static let statusLeading = rootBulletCenterX + 3.5 + statusVisibleSpacing - statusInkInset
    static let statusContentSpacing = statusVisibleSpacing - statusInkInset

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
