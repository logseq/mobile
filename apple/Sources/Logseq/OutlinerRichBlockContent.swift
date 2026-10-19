import SwiftUI
import LogseqModel

import HighlightSwift
import SwiftUIMath
#if os(iOS)
import AVKit
import UIKit
import WebKit
#endif


struct OutlinerMixedRichMarkupContent: View {
    let nodes: [LogseqMarkupNode]
    let fallback: String
    let precedingYouTubeURL: String?
    let youtubePlaybackStarts: [String: Int]
    let onSeekYouTube: (String, Int) -> Void
    let allowsLinkInteraction: () -> Bool
    let onOpenMarkupLink: (OutlinerMarkupLink) -> Void

    private var targetedNodes: [LogseqMarkupNode] {
        OutlinerYouTubeTimestampPolicy.associateTargets(
            nodes,
            precedingYouTubeURL: precedingYouTubeURL
        )
    }

    private var chunks: [[LogseqMarkupNode]] {
        OutlinerRichMarkupPolicy.chunks(targetedNodes)
    }

    var body: AnyView {
        if !OutlinerRichMarkupPolicy.containsRich(nodes) {
            return AnyView(inlineContent(nodes).accessibilityIdentifier("block.rich.inline.0"))
        }
        return AnyView(richContent)
    }

    private var richContent: some View {
        let chunks = self.chunks
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<chunks.count, id: \.self) { index in
                let chunk = chunks[index]
                if chunk.count == 1,
                   let node = chunk.first,
                   OutlinerRichMarkupPolicy.isRich(node.type) {
                    OutlinerRichBlockContent(
                        node: node,
                        youtubeStartSeconds: node.url.flatMap { youtubePlaybackStarts[$0] },
                        onSeekYouTube: onSeekYouTube,
                        allowsLinkInteraction: allowsLinkInteraction,
                        onOpenMarkupLink: onOpenMarkupLink
                    )
                } else {
                    inlineContent(chunk)
                        .accessibilityIdentifier("block.rich.inline.\(index)")
                }
            }
        }
    }

    @ViewBuilder private func inlineContent(_ chunk: [LogseqMarkupNode]) -> some View {
        Group {
            if chunk.allSatisfy({ $0.type == .text }) {
                Text(verbatim: chunk.isEmpty ? fallback : chunk.map { $0.text ?? "" }.joined())
            } else {
                Text(OutlinerMarkupAttributedString.make(nodes: chunk, fallback: fallback))
            }
        }
            .environment(\.openURL, OpenURLAction { url in
                guard allowsLinkInteraction() else { return .discarded }
                guard let link = OutlinerMarkupLink(url: url) else { return .systemAction }
                onOpenMarkupLink(link)
                return .handled
            })
    }

}

enum OutlinerMarkupMarkdown {
    static func requiresAttributedText(_ nodes: [LogseqMarkupNode]) -> Bool {
        nodes.contains { node in
            switch node.type {
            case .text, .codeBlock, .math, .cloze, .youtubeTimestamp, .video, .iframe:
                return false
            case .code, .emphasis, .quote, .link, .nodeReference, .tagReference:
                return true
            }
        }
    }

    static func make(nodes: [LogseqMarkupNode], fallback: String) -> String {
        guard !nodes.isEmpty else { return escape(fallback) }
        return nodes.map(make).joined()
    }

    private static func make(_ node: LogseqMarkupNode) -> String {
        switch node.type {
        case .text:
            return escape(node.text ?? "")
        case .code:
            return "`" + (node.text ?? "").replacingOccurrences(of: "`", with: "\\`") + "`"
        case .codeBlock, .math, .cloze:
            return escape(node.text ?? "")
        case .youtubeTimestamp:
            return escape("◷ " + (node.text ?? ""))
        case .emphasis, .quote:
            let children = node.children.map(make).joined()
            switch node.style {
            case "bold": return "**" + children + "**"
            case "italic": return "_" + children + "_"
            case "strikeThrough": return "~~" + children + "~~"
            default: return children
            }
        case .link:
            let label = node.children.isEmpty
                ? escape(node.url ?? "")
                : node.children.map(make).joined()
            guard let url = node.url, !url.isEmpty else { return label }
            return "[" + label + "](" + escapeDestination(url) + ")"
        case .nodeReference:
            return nodeLink(label: node.title ?? "", uuid: node.uuid)
        case .tagReference:
            return nodeLink(label: "#" + (node.title ?? ""), uuid: node.uuid)
        case .video, .iframe:
            return escape(node.url ?? "")
        }
    }

    private static func nodeLink(label: String, uuid: String?) -> String {
        guard let uuid, !uuid.isEmpty else { return escape(label) }
        return "[" + escape(label) + "](logseq-node://" + escapeDestination(uuid) + ")"
    }

    private static func escape(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["`", "*", "_", "{", "}", "[", "]", "<", ">", "#"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result
    }

    private static func escapeDestination(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "%5C")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20")
    }
}

enum OutlinerMarkupInteractionPolicy {
    static func hasInteractiveContent(_ nodes: [LogseqMarkupNode]) -> Bool {
        nodes.contains { node in
            switch node.type {
            case .link, .nodeReference, .tagReference, .video, .iframe,
                 .youtubeTimestamp, .cloze:
                return true
            case .emphasis, .quote:
                return hasInteractiveContent(node.children)
            case .text, .code, .codeBlock, .math:
                return false
            }
        }
    }
}

enum OutlinerMarkupAttributedString {
    static func make(nodes: [LogseqMarkupNode], fallback: String) -> AttributedString {
        guard !nodes.isEmpty else { return AttributedString(fallback) }
        var result = AttributedString()
        for node in nodes {
            result.append(make(node))
        }
        return result
    }

    private static func make(_ node: LogseqMarkupNode) -> AttributedString {
        switch node.type {
        case .text:
            return AttributedString(node.text ?? "")
        case .code:
            var value = AttributedString(node.text ?? "")
            value.font = .system(.body, design: .monospaced)
            value.backgroundColor = Color.secondary.opacity(0.12)
            return value
        case .codeBlock, .math, .cloze:
            return AttributedString(node.text ?? "")
        case .youtubeTimestamp:
            return AttributedString("◷ " + (node.text ?? ""))
        case .emphasis, .quote:
            var value = make(nodes: node.children, fallback: "")
            switch node.style {
            case "bold": value.font = .body.bold()
            case "italic": value.font = .body.italic()
            case "underline": value.underlineStyle = .single
            case "strikeThrough": value.strikethroughStyle = .single
            case "highlight": value.backgroundColor = Color.yellow.opacity(0.25)
            default: break
            }
            return value
        case .link:
            var value = make(nodes: node.children, fallback: node.url ?? "")
            value.link = node.url.flatMap(URL.init(string:))
            return value
        case .nodeReference:
            var value = AttributedString(node.title ?? "")
            if let uuid = node.uuid {
                value.link = OutlinerMarkupLink.node(uuid: uuid).url
            }
            return value
        case .tagReference:
            var value = AttributedString("#" + (node.title ?? ""))
            if let uuid = node.uuid {
                value.link = OutlinerMarkupLink.node(uuid: uuid).url
            }
            return value
        case .video, .iframe:
            return AttributedString(node.url ?? "")
        }
    }
}

struct OutlinerRichBlockContent: View {
    let node: LogseqMarkupNode
    let youtubeStartSeconds: Int?
    let onSeekYouTube: (String, Int) -> Void
    let allowsLinkInteraction: () -> Bool
    let onOpenMarkupLink: (OutlinerMarkupLink) -> Void

    @ViewBuilder var body: some View {
        Group {
            switch node.type {
            case .quote:
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 3)
                    quoteText
                        .italic()
                        .foregroundStyle(.secondary)
                }
            case .math:
                NativeLatexView(
                    expression: node.text ?? "",
                    isDisplay: node.style != "inline"
                )
            case .codeBlock:
                SyntaxHighlightedCodeBlock(
                    code: node.text ?? "",
                    language: node.style
                )
            case .video:
                EmbeddedVideo(
                    url: EmbeddedMediaPolicy.safeURL(node.url),
                    startSeconds: youtubeStartSeconds
                )
            case .iframe:
                EmbeddedWebContent(url: EmbeddedMediaPolicy.safeURL(node.url))
            case .youtubeTimestamp:
                YouTubeTimestamp(
                    label: node.text ?? "",
                    url: node.url,
                    seconds: OutlinerYouTubeTimestampPolicy.seconds(node),
                    onSeek: onSeekYouTube
                )
            case .cloze:
                InteractiveCloze(text: node.text ?? "")
            default:
                Text(verbatim: node.text ?? node.url ?? "")
            }
        }
        .accessibilityIdentifier(contentAccessibilityIdentifier)
    }

    private var contentAccessibilityIdentifier: String {
        if let youtubeStartSeconds {
            switch node.type {
            case .video:
                return "block.rich.video.start.\(youtubeStartSeconds)"
            case .youtubeTimestamp:
                return "block.rich.youtubeTimestamp.start.\(youtubeStartSeconds)"
            default:
                break
            }
        }
        return "block.rich.\(node.type.rawValue)"
    }

    @ViewBuilder private var quoteText: some View {
        Text(OutlinerMarkupAttributedString.make(nodes: node.children, fallback: ""))
            .environment(\.openURL, OpenURLAction { url in
                guard allowsLinkInteraction() else { return .discarded }
                guard let link = OutlinerMarkupLink(url: url) else { return .systemAction }
                onOpenMarkupLink(link)
                return .handled
            })
    }
}

private struct YouTubeTimestamp: View {
    let label: String
    let url: String?
    let seconds: Int?
    let onSeek: (String, Int) -> Void

    @ViewBuilder
    var body: some View {
        if let url, let seconds {
            Button {
                onSeek(url, seconds)
            } label: {
                timestampLabel
                    .foregroundStyle(.tint)
                    .platformTimestampHitShape()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Seek YouTube video to " + label)
        } else {
            timestampLabel.foregroundStyle(.secondary)
        }
    }

    private var timestampLabel: some View {
        Text(verbatim: "◷ " + label)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    @ViewBuilder func platformTimestampHitShape() -> some View {
        contentShape(Rectangle())
    }
}

private struct InteractiveCloze: View {
    let text: String
    @State private var isRevealed = false

    var body: some View {
        Button {
            isRevealed.toggle()
        } label: {
            Text(verbatim: isRevealed ? text : "Tap to reveal")
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRevealed ? text : "Reveal cloze")
    }
}

private struct SyntaxHighlightedCodeBlock: View {
    let code: String
    let language: String?

    private var contentHeight: CGFloat {
        let lineCount = max(code.components(separatedBy: "\n").count, 1)
        return min(max(CGFloat(lineCount * 20 + 34), 72), 320)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(verbatim: language)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                CodeText(code)
                    .codeTextColors(.theme(.github))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct NativeLatexView: View {
    let expression: String
    let isDisplay: Bool

    var body: some View {
        SwiftUIMath.Math(expression)
            .mathTypesettingStyle(isDisplay ? .display : .text)
            .frame(maxWidth: .infinity, minHeight: isDisplay ? 56 : 30, alignment: .leading)
    }
}

private struct EmbeddedVideo: View {
    let url: URL?
    let startSeconds: Int?

    @ViewBuilder var body: some View {
        if let url,
           let embedURL = EmbeddedMediaPolicy.webVideoEmbedURL(
            url,
            startSeconds: startSeconds
           ) {
            EmbeddedWebContent(url: embedURL)
        } else if let url {
            #if os(iOS)
            NativeAppleVideo(url: url)
                .frame(height: 220)
            #else
            Link(url.absoluteString, destination: url)
            #endif
        } else {
            Text("Invalid video URL")
                .foregroundStyle(.secondary)
        }
    }
}

#if os(iOS)
private struct NativeAppleVideo: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onDisappear { player.pause() }
    }
}
#endif

private struct EmbeddedWebContent: View {
    let url: URL?


    @ViewBuilder var body: some View {
        if let url {
            #if os(iOS)
            AppleWebView(url: url)
                .frame(height: 240)
            #else
            Link(url.absoluteString, destination: url)
            #endif
        } else {
            Text("Invalid embed URL")
                .foregroundStyle(.secondary)
        }
    }
}

#if os(iOS)
private struct AppleWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        return WKWebView(frame: .zero, configuration: configuration)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        var request = URLRequest(url: url)
        for (field, value) in EmbeddedMediaPolicy.webRequestHeaders(for: url) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        webView.load(request)
    }

    final class Coordinator {
        var loadedURL: URL?
    }
}
#endif
