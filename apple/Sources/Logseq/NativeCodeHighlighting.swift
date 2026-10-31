import SwiftUI
import LogseqModel
#if os(iOS)
import UIKit

enum NativeCodeHighlighting {
    static func color(_ style: String) -> UIColor {
        let role = style.split(separator: " ").first.map(String.init) ?? ""
        return UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            let hex: UInt32
            switch role {
            case "keyword", "operator", "tag": hex = dark ? 0xff7b72 : 0xcf222e
            case "atom", "number", "attribute": hex = dark ? 0x79c0ff : 0x0550ae
            case "def", "type", "variable-3": hex = dark ? 0xd2a8ff : 0x8250df
            case "string", "string-2": hex = dark ? 0xa5d6ff : 0x0a3069
            case "comment": hex = dark ? 0x8b949e : 0x57606a
            case "builtin", "variable-2", "qualifier": hex = dark ? 0xffa657 : 0x953800
            case "meta", "link": hex = dark ? 0x79c0ff : 0x0550ae
            case "error": hex = dark ? 0xff7b72 : 0xcf222e
            default: return .label
            }
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }

    static func apply(_ tokens: [CodeSyntaxToken], to text: NSMutableAttributedString) {
        text.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: text.length))
        for token in tokens where token.start >= 0 && token.end > token.start && token.end <= text.length {
            text.addAttribute(.foregroundColor, value: color(token.style),
                range: NSRange(location: token.start, length: token.end - token.start))
        }
    }

    static func attributed(_ code: String, tokens: [CodeSyntaxToken]) -> AttributedString {
        let text = NSMutableAttributedString(string: code)
        apply(tokens, to: text)
        return (try? AttributedString(text, including: \.uiKit)) ?? AttributedString(code)
    }
}
#endif
