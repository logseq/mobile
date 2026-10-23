import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor enum LGBlockClipboard {
    static let typeIdentifier = "com.logseq.blocks"

    static func write(_ payload: String) -> Bool {
        guard let data = payload.data(using: .utf8),
              let fields = try? JSONDecoder().decode([String: String].self, from: data),
              let plain = fields["plainText"], let rich = fields["blocksEDN"] else { return false }
        #if canImport(UIKit)
        UIPasteboard.general.items = [["public.utf8-plain-text": Data(plain.utf8), typeIdentifier: Data(rich.utf8)]]
        #elseif canImport(AppKit)
        let item = NSPasteboardItem()
        item.setString(plain, forType: .string)
        item.setData(Data(rich.utf8), forType: .init(typeIdentifier))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        #else
        return false
        #endif
        return true
    }

    #if canImport(UIKit)
    static func content(before: String, selection: NSRange) -> String? {
        guard let plain = UIPasteboard.general.string else { return nil }
        let rich = UIPasteboard.general.data(forPasteboardType: typeIdentifier)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let fields: [String: Any] = ["beforeTitle": before, "selectionStart": selection.location,
                                    "selectionLength": selection.length, "plainText": plain, "blocksEDN": rich]
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    #endif
}
