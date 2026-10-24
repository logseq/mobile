import Foundation
import SwiftUI
import UIKit
import WebKit
import LogseqModel
@testable import Logseq
@testable import LUIAppleBackend

@main struct FeedbackMathRecording: App {
    var body: some Scene { WindowGroup { FeedbackMathView() } }
}

struct FeedbackMathView: View {
    private var formulas: [[LogseqMarkupNode]] {
        let snapshot = #"""
        {"ok":true,"result":{"graphName":"LaTeX regression","selectedGraphId":"feedback-math","outlinerRows":[
          {"depth":0,"block":{"uuid":"inline","pageId":"page","title":"For each mouse, let h be the baseline.","markup":[{"type":"text","text":"For each mouse, let "},{"type":"math","style":"inline","text":"h_{\\mathrm{wean}}^{\\mathrm{ear}}"},{"type":"text","text":" be ear heteroplasmy at weaning, and "},{"type":"math","style":"inline","text":"h_t^{\\mathrm{cull}}"},{"type":"text","text":" be heteroplasmy in tissue t at culling."}]}},
          {"depth":0,"block":{"uuid":"display","pageId":"page","title":"The tissue-specific shift","markup":[{"type":"math","style":"display","text":"\\Delta_t = h_t^{\\mathrm{cull}} - h_{\\mathrm{wean}}^{\\mathrm{ear}}"}]}},
          {"depth":0,"block":{"uuid":"braces","pageId":"page","title":"Decomposition with annotations","markup":[{"type":"math","style":"display","text":"\\underbrace{a-b}_{\\text{ear drift}} + \\underbrace{c-a}_{\\text{organ divergence}}"}]}},
          {"depth":0,"block":{"uuid":"fraction","pageId":"page","title":"Fractions and roots","markup":[{"type":"math","style":"display","text":"\\frac{1}{\\sqrt{x^2+1}}"}]}}
        ]}}
        """#
        let envelope = try! JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as! [String: Any]
        let result = envelope["result"] as! [String: Any]
        let rows = result["outlinerRows"] as! [[String: Any]]
        return try! rows.map { row -> [LogseqMarkupNode] in
            let block = row["block"] as! [String: Any]
            return try JSONDecoder().decode([LogseqMarkupNode].self,
                from: JSONSerialization.data(withJSONObject: block["markup"]!))
        }
    }
    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("LaTeX rendering · #1466").font(.title2)
                    ForEach(formulas.indices, id: \.self) { index in
                        OutlinerMixedRichMarkupContent(nodes: formulas[index], fallback: "",
                            youtubePlaybackStarts: [:], onSeekYouTube: { _, _ in },
                            allowsLinkInteraction: { true }, onOpenMarkupLink: { _ in })
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color.white).foregroundStyle(.black).font(.body)
            .task {
                try? await Task.sleep(for: .seconds(8))
                @MainActor func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
                let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
                let webViews = windows.flatMap(views).compactMap { $0 as? WKWebView }
                var rendered = 0
                var hasAnnotations = false
                var diagnostics: [[String: Any]] = []
                var unclipped = true
                for web in webViews {
                    if let result = try? await web.evaluateJavaScript("JSON.stringify({count:document.querySelectorAll('.katex').length,errors:document.querySelectorAll('.katex-error').length,annotations:document.body.textContent.includes('drift')&&document.body.textContent.includes('divergence'),text:document.body.innerText,height:innerHeight,body:document.body.getBoundingClientRect().height,scroll:document.body.scrollHeight,bottom:Math.max(...Array.from(document.querySelectorAll('.katex-html span')).map(n=>n.getBoundingClientRect().bottom)),displays:Array.from(document.querySelectorAll('.katex-display')).map(n=>({client:n.clientHeight,scroll:n.scrollHeight,clips:getComputedStyle(n).overflowY!=='visible'}))})") as? String,
                       let values = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] {
                        diagnostics.append(values)
                        if let bottom = values["bottom"] as? Double, let height = values["height"] as? Double { unclipped = unclipped && bottom <= height + 1 }
                        if let displays = values["displays"] as? [[String: Any]] { unclipped = unclipped && displays.allSatisfy { $0["clips"] as? Bool != true || ($0["scroll"] as? Int ?? 0) <= ($0["client"] as? Int ?? 0) + 1 } }
                        if values["errors"] as? Int == 0 { rendered += values["count"] as? Int ?? 0 }
                        hasAnnotations = hasAnnotations || values["annotations"] as? Bool == true
                    }
                }
                let result: [String: Any] = ["observations": ["five-formulas-rendered": rendered == 5, "underbrace-annotations": hasAnnotations, "no-vertical-clipping":unclipped], "diagnostics":diagnostics]
                try? JSONSerialization.data(withJSONObject: result).write(to: URL.documentsDirectory.appendingPathComponent("feedback-result.json"))
            }
    }
}
