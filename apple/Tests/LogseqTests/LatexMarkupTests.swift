import Foundation
import Testing
import LogseqModel
@testable import Logseq

@Suite struct LatexMarkupTests {
    private func nodes(_ json: String) throws -> [LogseqMarkupNode] {
        try JSONDecoder().decode([LogseqMarkupNode].self, from: Data(json.utf8))
    }

    @Test func keepsInlineMathInsideTheSentenceAndDisplayMathSeparate() throws {
        let value = try nodes(#"[{"type":"text","text":"Before "},{"type":"math","style":"inline","text":"x^2"},{"type":"text","text":" after"},{"type":"math","style":"display","text":"y^2"}]"#)
        let html = LatexMarkupDocument.markup(value)
        #expect(html.contains("Before <span data-tex=\"x^2\" data-display=\"false\"></span> after"))
        #expect(html.contains("<div data-tex=\"y^2\" data-display=\"true\"></div>"))
        #expect(OutlinerRichMarkupPolicy.chunks(value).count == 2)
    }

    @Test func escapesUserContentAndBundlesOfflineMathSupport() throws {
        let value = try nodes(#"[{"type":"text","text":"<script>alert(1)</script>"},{"type":"math","style":"display","text":"\\underbrace{a-b}_{\\text{drift}}"}]"#)
        let html = LatexMarkupDocument.html(nodes: value, fontSize: 17, foreground: "#111111")
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(html.contains("katex.render"))
        #expect(html.contains("underbrace"))
        #expect(html.contains("data:font/woff2;base64,"))
        #expect(html.contains("trust:false"))
        #expect(!html.contains("<script src="))
    }

    @Test func preservesReferencesButRejectsExecutableLinks() throws {
        let value = try nodes(#"[{"type":"nodeReference","uuid":"node-id","title":"Reference"},{"type":"link","url":"javascript:alert(1)","children":[{"type":"text","text":"unsafe"}]}]"#)
        let html = LatexMarkupDocument.markup(value)
        #expect(html.contains("[[Reference]]"))
        #expect(html.contains("unsafe"))
        #expect(!html.contains("javascript:"))
    }
}
