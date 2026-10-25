import UIKit
import LogseqModel
@testable import Logseq

@main struct BlockTagMenuCheck {
    @MainActor static func main() async throws {
        let row = OutlinerTextRowView()
        row.frame = CGRect(x: 0, y: 0, width: 320, height: 160)
        var opened: String?
        func update(editable: Bool) throws -> UIButton {
            let json: [String: Any] = ["uuid": "owner", "title": "A tagged block", "markup": [],
                "depth": 0, "hasChildren": false, "collapsed": false, "isAsset": false,
                "assetType": "", "localPath": "", "youtubeURL": "", "completed": false,
                "selected": false, "opensAsPage": false, "journalBullet": false,
                "syncFailed": false, "statuses": [], "tags": [["uuid": "tag", "title": "Project"]],
                "canRemoveTags": editable, "removeTagTitle": "移除标签"]
            let payload = try JSONDecoder().decode(OutlinerRowPayload.self,
                from: JSONSerialization.data(withJSONObject: json))
            row.update(payload, emit: { name, uuid, _ in if name == "open-node" { opened = uuid } }, onOpenLink: { _ in })
            row.layoutIfNeeded()
            return row.subviews.compactMap { $0 as? UIButton }.first {
                $0.accessibilityIdentifier == "button.block-tag.tag"
            }!
        }
        let tag = try update(editable: true)
        guard let action = tag.menu?.children.first as? UIAction,
              action.title == "移除标签", action.attributes.contains(.destructive),
              !tag.showsMenuAsPrimaryAction else {
            throw failure("The existing tag must offer a localized Remove tag menu on long press")
        }
        tag.sendActions(for: .touchUpInside)
        guard opened == "tag" else { throw failure("A normal tag tap must still navigate") }
        let protected = try update(editable: false)
        guard protected.menu == nil else { throw failure("A reused tag button must remove its menu for a protected owner") }
        print("PASS: existing tag buttons retain tap navigation and expose localized removal only for editable owners")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "BlockTagMenu", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
