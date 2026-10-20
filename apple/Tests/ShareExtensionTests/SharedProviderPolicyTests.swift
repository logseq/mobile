import Foundation

@main
struct SharedProviderPolicyTests {
    static func main() {
        expect(
            [
                .asset("public.jpeg"),
                .url,
                .text,
            ],
            for: ["public.jpeg", "public.url", "public.utf8-plain-text", "public.data"],
            message: "semantic images must be captured before their link or text fallback"
        )
        expect(
            [.asset("public.mpeg-4-audio")],
            for: ["public.mpeg-4-audio", "public.data"],
            message: "audio must be captured as an asset"
        )
        expect(
            [.asset("com.apple.quicktime-movie")],
            for: ["com.apple.quicktime-movie", "public.data"],
            message: "movies must be captured as assets"
        )
        expect(
            [.asset("com.adobe.pdf")],
            for: ["com.adobe.pdf", "public.data"],
            message: "PDF files must be captured as assets"
        )
        expect(
            [.asset("public.png")],
            for: ["public.png", "public.data"],
            message: "screenshots must be captured as PNG assets"
        )
        expect(
            [.asset("net.daringfireball.markdown"), .text],
            for: ["net.daringfireball.markdown", "public.utf8-plain-text"],
            message: "Markdown documents must keep their file representation"
        )
        expect(
            [.fileURL, .text],
            for: ["public.file-url", "public.utf8-plain-text"],
            message: "shared files must be copied rather than saved as temporary links"
        )
        expect(
            [.text, .asset("public.data")],
            for: ["public.data", "public.utf8-plain-text"],
            message: "generic data must not steal a text share"
        )
        expect(
            [.url, .text, .asset("public.data")],
            for: ["public.data", "public.url", "public.utf8-plain-text"],
            message: "generic data must not steal a URL share"
        )
        expect(
            [.asset("public.data")],
            for: ["public.data"],
            message: "a file-only provider must still be captured"
        )
        expect(
            [],
            for: ["com.example.unsupported"],
            message: "unsupported provider types must be ignored"
        )
        fallsBackAfterARepresentationFails()
        stopsAfterTheFirstRepresentationSucceeds()
        returnsNilWhenEveryRepresentationFails()
    }

    private static func expect(
        _ expected: [ShareCaptureRoute],
        for identifiers: [String],
        message: String
    ) {
        let actual = ShareCaptureRoutePolicy.routes(for: identifiers)
        guard actual == expected else {
            fputs("FAIL: \(message)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
            exit(1)
        }
    }

    private static func fallsBackAfterARepresentationFails() {
        var attempts: [ShareCaptureRoute] = []
        var captured: String?
        ShareCaptureRouteRunner.firstResult(in: [.asset("public.jpeg"), .text]) { route, finish in
            attempts.append(route)
            finish(route == .text ? "shared text" : nil)
        } completion: { captured = $0 }
        guard attempts == [.asset("public.jpeg"), .text], captured == "shared text" else {
            fputs("FAIL: a failed asset representation must fall back to text\n", stderr)
            exit(1)
        }
    }

    private static func stopsAfterTheFirstRepresentationSucceeds() {
        var attempts: [ShareCaptureRoute] = []
        var captured: String?
        ShareCaptureRouteRunner.firstResult(in: [.url, .text]) { route, finish in
            attempts.append(route)
            finish("shared URL")
        } completion: { captured = $0 }
        guard attempts == [.url], captured == "shared URL" else {
            fputs("FAIL: successful representations must not create duplicate captures\n", stderr)
            exit(1)
        }
    }

    private static func returnsNilWhenEveryRepresentationFails() {
        var attempts: [ShareCaptureRoute] = []
        var completed = false
        ShareCaptureRouteRunner.firstResult(in: [.url, .text]) { route, finish in
            attempts.append(route)
            finish(nil as String?)
        } completion: { result in
            completed = result == nil
        }
        guard attempts == [.url, .text], completed else {
            fputs("FAIL: route exhaustion must complete exactly once with nil\n", stderr)
            exit(1)
        }
    }
}
