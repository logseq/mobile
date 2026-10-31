import SwiftUI
import LogseqModel

#if os(iOS)
import AVKit
import UIKit
import WebKit
#endif


struct OutlinerMixedRichMarkupContent: View {
    @Environment(\.lgPropertyValue) private var propertyValue
    let nodes: [LogseqMarkupNode]
    let fallback: String
    let youtubePlaybackStarts: [String: Int]
    let onSeekYouTube: (String, Int) -> Void
    let allowsLinkInteraction: () -> Bool
    let onOpenMarkupLink: (OutlinerMarkupLink) -> Void
    var onEdit: (() -> Void)? = nil

    private var chunks: [[LogseqMarkupNode]] {
        OutlinerRichMarkupPolicy.chunks(nodes)
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
                if LatexMarkupDocument.containsMath(chunk) {
                    NativeLatexMarkupContent(nodes: chunk, allowsLinkInteraction: allowsLinkInteraction,
                        onOpenMarkupLink: onOpenMarkupLink, onEdit: onEdit)
                } else if chunk.count == 1,
                   let node = chunk.first,
                   OutlinerRichMarkupPolicy.isRich(node.type) {
                    OutlinerRichBlockContent(
                        node: node,
                        youtubeStartSeconds: node.url.flatMap { youtubePlaybackStarts[$0] },
                        onSeekYouTube: onSeekYouTube,
                        allowsLinkInteraction: allowsLinkInteraction,
                        onOpenMarkupLink: onOpenMarkupLink,
                        onEdit: onEdit
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
                Text(OutlinerMarkupAttributedString.make(nodes: chunk, fallback: fallback, textStyle: propertyValue ? .callout : .body))
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
            case .text, .codeBlock, .math, .cloze, .youtubeTimestamp, .video, .iframe, .html, .image:
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
            return nodeLink(label: "[[" + (node.title ?? "") + "]]", uuid: node.uuid)
        case .tagReference:
            return nodeLink(label: "#" + (node.title ?? ""), uuid: node.uuid)
        case .video, .iframe, .html, .image:
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
            case .link, .nodeReference, .tagReference, .video, .iframe, .html, .image,
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
    static func make(nodes: [LogseqMarkupNode], fallback: String, textStyle: Font.TextStyle = .body) -> AttributedString {
        guard !nodes.isEmpty else { return AttributedString(fallback) }
        var result = AttributedString()
        for node in nodes {
            result.append(make(node, textStyle: textStyle))
        }
        return result
    }

    private static func make(_ node: LogseqMarkupNode, textStyle: Font.TextStyle) -> AttributedString {
        switch node.type {
        case .text:
            return AttributedString(node.text ?? "")
        case .code:
            var value = AttributedString(node.text ?? "")
            value.font = .system(textStyle, design: .monospaced)
            value.backgroundColor = Color.secondary.opacity(0.12)
            return value
        case .codeBlock, .math, .cloze:
            return AttributedString(node.text ?? "")
        case .youtubeTimestamp:
            return AttributedString("◷ " + (node.text ?? ""))
        case .emphasis, .quote:
            var value = make(nodes: node.children, fallback: "", textStyle: textStyle)
            switch node.style {
            case "heading-1": value.font = .title.bold()
            case "heading-2": value.font = .title2.bold()
            case "heading-3": value.font = .title3.bold()
            case "heading-4", "heading-5", "heading-6": value.font = .headline
            case "bold": value.font = .system(textStyle).bold()
            case "italic": value.font = .system(textStyle).italic()
            case "underline": value.underlineStyle = .single
            case "strikeThrough": value.strikethroughStyle = .single
            case "highlight": value.backgroundColor = Color.yellow.opacity(0.25)
            default: break
            }
            return value
        case .link:
            var value = make(nodes: node.children, fallback: node.url ?? "", textStyle: textStyle)
            value.link = node.url.flatMap(URL.init(string:))
            return value
        case .nodeReference:
            var value = AttributedString("[[" + (node.title ?? "") + "]]")
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
        case .video, .iframe, .html, .image:
            return AttributedString(node.url ?? "")
        }
    }
}

struct OutlinerRichBlockContent: View {
    @Environment(\.lgPropertyValue) private var propertyValue
    let node: LogseqMarkupNode
    let youtubeStartSeconds: Int?
    let onSeekYouTube: (String, Int) -> Void
    let allowsLinkInteraction: () -> Bool
    let onOpenMarkupLink: (OutlinerMarkupLink) -> Void
    var onEdit: (() -> Void)? = nil

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
                NativeLatexMarkupContent(nodes: [node], allowsLinkInteraction: allowsLinkInteraction,
                    onOpenMarkupLink: onOpenMarkupLink, onEdit: onEdit)
            case .codeBlock:
                SyntaxHighlightedCodeBlock(
                    code: node.text ?? "",
                    language: node.style
                )
            case .video:
                EmbeddedVideo(
                    node: node,
                    startSeconds: youtubeStartSeconds
                )
            case .html:
                #if os(iOS)
                AppleWebView(url: nil, headers: [:], html: node.text).frame(height: 220)
                #else
                Text(node.text ?? "")
                #endif
            case .image:
                AsyncImage(url: node.url.flatMap(URL.init(string:))) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else if phase.error != nil { Text("Image unavailable").foregroundStyle(.secondary) }
                    else { ProgressView() }
                }
                .frame(maxWidth: .infinity, maxHeight: 240)
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityLabel(node.text ?? "Image")
            case .iframe:
                EmbeddedWebContent(url: node.embedURL.flatMap { URL(string: $0) }, headers: node.mediaHeaders)
            case .youtubeTimestamp:
                YouTubeTimestamp(
                    label: node.text ?? "",
                    url: node.url,
                    seconds: node.seconds,
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
        Text(OutlinerMarkupAttributedString.make(nodes: node.children, fallback: "", textStyle: propertyValue ? .callout : .body))
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

private struct ShowCodeLanguageKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var lgShowCodeLanguage: Bool {
        get { self[ShowCodeLanguageKey.self] }
        set { self[ShowCodeLanguageKey.self] = newValue }
    }
}

private struct SyntaxHighlightedCodeBlock: View {
    @Environment(\.lgShowCodeLanguage) private var showLanguage
    let code: String
    let language: String?
    @State private var highlighted: (code: String, language: String?, text: AttributedString)?

    private var displayText: AttributedString {
        if let highlighted, highlighted.code == code, highlighted.language == language { return highlighted.text }
        return AttributedString(code)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showLanguage, let language, !language.isEmpty {
                Text(verbatim: language)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                Text(displayText)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(showLanguage ? Color.secondary.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: [code, language ?? ""]) {
            highlighted = nil
            let tokens = await CodeSyntaxHighlighter.shared.tokens(code: code, language: language ?? "")
            guard !Task.isCancelled else { return }
            #if os(iOS)
            highlighted = (code, language, NativeCodeHighlighting.attributed(code, tokens: tokens))
            #else
            highlighted = (code, language, AttributedString(code))
            #endif
        }
    }
}

enum NativeMediaRequest {
    static func positionedURL(_ source: String?, parameter: String?, seconds: Int?) -> URL? {
        guard let source, let url = URL(string: source) else { return nil }
        guard let parameter, let seconds, seconds >= 0,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != parameter }
            + [URLQueryItem(name: parameter, value: String(seconds))]
        return components.url
    }
}

private struct EmbeddedVideo: View {
    let node: LogseqMarkupNode
    let startSeconds: Int?

    @ViewBuilder var body: some View {
        if let embedURL = NativeMediaRequest.positionedURL(node.embedURL, parameter: node.positionParameter, seconds: startSeconds) {
            EmbeddedWebContent(url: embedURL, headers: node.mediaHeaders)
        } else if let source = node.url, let url = URL(string: source) {
            #if os(iOS)
            NativeAppleVideo(url: url).frame(height: 220)
            #else
            Link(url.absoluteString, destination: url)
            #endif
        } else {
            Text("Invalid video URL").foregroundStyle(.secondary)
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
    var headers: [String: String] = [:]


    @ViewBuilder var body: some View {
        if let url {
            #if os(iOS)
            AppleWebView(url: url, headers: headers)
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
    let url: URL?
    let headers: [String: String]
    var html: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if let html {
            guard context.coordinator.loadedHTML != html else { return }
            context.coordinator.loadedHTML = html
            webView.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>:root{color-scheme:light dark}body{background:transparent;font:17px -apple-system;margin:0}img{max-width:100%}</style>" + html, baseURL: nil)
            return
        }
        guard let url else { return }
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        guard context.coordinator.loadedRequest != request else { return }
        context.coordinator.loadedRequest = request
        webView.load(request)
    }

    final class Coordinator {
        var loadedRequest: URLRequest?
        var loadedHTML: String?
    }
}
#endif
