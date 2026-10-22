import Foundation
import LogseqModel
@testable import Logseq

@main struct DeepLinkParserCheck {
    @MainActor static func main() throws {
        let link = SharedDeepLink(URL(string: "logseq://graph/Other%20%E4%B8%AD%E6%96%87%20%2B?page=C%2B%2B+notes&block-id=block")!)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(link)) as! [String: Any]
        guard json["path"] as? String == "/Other 中文 +" else {
            throw NSError(domain: "DeepLinkParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Graph links must transport the decoded graph path to the shared core"])
        }
        let query = json["query"] as! [[String: Any]]
        precondition(query[0]["value"] as? String == "C+++notes")
        precondition(query[1]["value"] as? String == "block")
        var copied = ""
        let router = LGPlatformCommandRouter(setClipboardText: { copied = $0 }, performHaptic: { _ in }, present: { _ in })
        router.handle(LGPlatformCommandBatch(revision: 1, graphName: "Other 中文 +", commands: [
            LogseqOutlinerCommand(type: "setClipboardURLs", style: nil, uuid: nil, uuids: ["block"], text: nil)
        ]))
        precondition(!copied.contains(" "), "Copied graph URLs must percent-encode spaces")
        let roundtrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SharedDeepLink(URL(string: copied)!))) as! [String: Any]
        precondition(roundtrip["path"] as? String == "/Other 中文 +")
        print("PASS: graph deep links preserve decoded paths, Unicode, literal plus signs, and node targets")
    }
}
