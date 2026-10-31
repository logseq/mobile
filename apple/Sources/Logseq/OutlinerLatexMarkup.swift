import Foundation
import SwiftUI
import LogseqModel
#if os(iOS)
import UIKit
import WebKit
#endif

enum LatexMarkupDocument {
    static func containsMath(_ nodes: [LogseqMarkupNode]) -> Bool {
        nodes.contains { $0.type == .math || containsMath($0.children) }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func markup(_ nodes: [LogseqMarkupNode]) -> String {
        nodes.map { node in
            let content = markup(node.children)
            switch node.type {
            case .math:
                let display = node.style != "inline"
                let tag = display ? "div" : "span"
                return "<\(tag) data-tex=\"\(escape(node.text ?? ""))\" data-display=\"\(display)\"></\(tag)>"
            case .text: return escape(node.text ?? "").replacingOccurrences(of: "\n", with: "<br>")
            case .code: return "<code>" + escape(node.text ?? "") + "</code>"
            case .codeBlock: return "<pre><code>" + escape(node.text ?? "") + "</code></pre>"
            case .emphasis:
                let tag: String
                switch node.style {
                case "bold": tag = "strong"
                case "italic": tag = "em"
                case "underline": tag = "u"
                case "strikeThrough": tag = "s"
                default: tag = "span"
                }
                return "<\(tag)>\(content)</\(tag)>"
            case .quote: return "<blockquote>" + content + "</blockquote>"
            case .nodeReference, .tagReference:
                let title = node.title ?? ""
                let label = node.type == .tagReference ? "#" + title : "[[" + title + "]]"
                guard let uuid = node.uuid, let url = OutlinerMarkupLink.node(uuid: uuid).url else { return escape(label) }
                return "<a href=\"\(escape(url.absoluteString))\">\(escape(label))</a>"
            case .link:
                let label = node.children.isEmpty ? escape(node.url ?? "") : content
                guard let raw = node.url, let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return label }
                return "<a href=\"\(escape(raw))\">\(label)</a>"
            case .image:
                guard let raw = node.url, let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return escape(node.text ?? "") }
                return "<img alt=\"\(escape(node.text ?? ""))\" src=\"\(escape(raw))\">"
            case .video, .iframe, .html, .youtubeTimestamp, .cloze:
                return escape(node.text ?? node.url ?? "")
            }
        }.joined()
    }

    private static let script = resource("katex.min", "js")
    private static let style = resource("katex-inline.min", "css")
    private static func resource(_ name: String, _ ext: String) -> String {
        let url = Bundle.module.url(forResource: name, withExtension: ext)
            ?? Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "KaTeX")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    static func html(nodes: [LogseqMarkupNode], fontSize: CGFloat, foreground: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; img-src https: http: data:">
        <style>\(style)
        body{display:flow-root;margin:0;background:transparent;color:\(foreground);font:\(fontSize)px -apple-system;line-height:1.4;overflow-wrap:anywhere}
        a{color:inherit;text-decoration:underline}pre,div[data-display]{overflow-x:auto}
        .katex-display{margin:.5em 0}.katex{font-size:1.05em}img{max-width:100%}
        </style><script>\(script)</script></head><body>\(markup(nodes))
        <script>
        for(const node of document.querySelectorAll('[data-tex]')){
          katex.render(node.dataset.tex,node,{displayMode:node.dataset.display==='true',throwOnError:false,trust:false,strict:false});
        }
        document.addEventListener('click',event=>{
          if(!event.target.closest('a'))window.webkit.messageHandlers.mathEdit.postMessage(null);
        });
        const report=()=>window.webkit.messageHandlers.mathHeight.postMessage(Math.ceil(document.body.getBoundingClientRect().height));
        new ResizeObserver(report).observe(document.body);document.fonts.ready.then(report);report();
        </script></body></html>
        """
    }
}

struct NativeLatexMarkupContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 17
    @State private var height: CGFloat = 30
    let nodes: [LogseqMarkupNode]
    let allowsLinkInteraction: () -> Bool
    let onOpenMarkupLink: (OutlinerMarkupLink) -> Void
    var onEdit: (() -> Void)? = nil

    var body: some View {
        #if os(iOS)
        LatexWebContent(html: LatexMarkupDocument.html(nodes: nodes, fontSize: fontSize,
            foreground: colorScheme == .dark ? LogseqThemePolicy.dark.primaryTextHex : LogseqThemePolicy.light.primaryTextHex),
            height: $height, allowsLinkInteraction: allowsLinkInteraction,
            onOpenMarkupLink: onOpenMarkupLink, onEdit: onEdit)
            .frame(height: height).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("block.rich.math")
        #else
        Text(nodes.map { $0.text ?? "" }.joined())
        #endif
    }
}

#if os(iOS)
private struct LatexWebContent: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    let allowsLinkInteraction: () -> Bool
    let onOpenMarkupLink: (OutlinerMarkupLink) -> Void
    let onEdit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "mathHeight")
        configuration.userContentController.add(context.coordinator, name: "mathEdit")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        view.loadHTMLString(html, baseURL: nil)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "mathHeight")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "mathEdit")
        view.stopLoading()
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: LatexWebContent
        var loadedHTML: String?
        init(_ parent: LatexWebContent) { self.parent = parent }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "mathEdit" {
                if parent.allowsLinkInteraction() { parent.onEdit?() }
                return
            }
            guard let value = message.body as? Double, value.isFinite, value > 0 else { return }
            let height = CGFloat(value)
            guard abs(parent.height - height) > 0.5 else { return }
            parent.height = height
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated else { decisionHandler(.allow); return }
            if parent.allowsLinkInteraction(), let url = action.request.url {
                if let link = OutlinerMarkupLink(url: url) { parent.onOpenMarkupLink(link) }
                else if ["https", "http"].contains(url.scheme?.lowercased() ?? "") { UIApplication.shared.open(url) }
            }
            decisionHandler(.cancel)
        }
    }
}
#endif
