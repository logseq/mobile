#if os(iOS)
import UIKit
import LogseqModel

enum OutlinerTapCaret {
    static func position(at point: CGPoint, manager: NSLayoutManager, container: NSTextContainer,
                         text: NSString) -> Int {
        guard text.length > 0 else { return 0 }
        var fraction: CGFloat = 0
        let index = manager.characterIndex(for: point, in: container,
            fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < text.length else { return text.length }
        let character = text.rangeOfComposedCharacterSequence(at: index)
        return fraction > 0.5 ? NSMaxRange(character) : character.location
    }

    static func sourceOffset(_ offset: Int, title: String, nodes: [LogseqMarkupNode]) -> Int {
        let source = title as NSString
        guard !nodes.isEmpty else { return min(max(0, offset), source.length) }
        var visible = 0
        var cursor = 0
        var selected: Int?
        func segment(_ text: String, sourceText: String? = nil, link: Bool = false) {
            let length = (text as NSString).length
            let remaining = NSRange(location: cursor, length: source.length - cursor)
            var range = source.range(of: text, range: remaining)
            if let sourceText {
                let stored = source.range(of: sourceText, range: remaining)
                if stored.location < range.location { range = stored }
            }
            let start = range.location == NSNotFound ? cursor : range.location
            if selected == nil && offset <= visible + length {
                selected = min(source.length, start + max(0, offset - visible))
            }
            cursor = min(source.length, start + (range.location == NSNotFound ? length : range.length))
            visible += length
            // A link's destination is absent from the displayed text.
            if link, cursor + 2 <= source.length, source.substring(with: NSRange(location: cursor, length: 2)) == "](" {
                cursor += 2
                var depth = 1
                while cursor < source.length && depth > 0 {
                    let character = source.character(at: cursor)
                    if character == 92 && cursor + 1 < source.length { cursor += 2; continue }
                    if character == 40 { depth += 1 }
                    if character == 41 { depth -= 1 }
                    cursor += 1
                }
            }
        }
        func visit(_ node: LogseqMarkupNode) {
            switch node.type {
            case .emphasis, .quote: node.children.forEach(visit)
            case .link:
                segment(String(OutlinerMarkupAttributedString.make(nodes: node.children, fallback: node.url ?? "").characters), link: true)
            case .nodeReference: segment("[[" + (node.title ?? "") + "]]", sourceText: node.uuid.map { "[[" + $0 + "]]" })
            case .tagReference: segment("#" + (node.title ?? ""), sourceText: node.uuid.map { "#[[" + $0 + "]]" })
            default: segment(node.text ?? "")
            }
        }
        nodes.forEach(visit)
        return selected ?? source.length
    }

    static func offset(at point: CGPoint, width: CGFloat, title: String, nodes: [LogseqMarkupNode]) -> Int {
        let attributed = NSMutableAttributedString(attributedString: NSAttributedString(OutlinerMarkupAttributedString.make(nodes: nodes, fallback: title)))
        let font = UIFont.preferredFont(forTextStyle: .body)
        attributed.addAttribute(.font, value: font, range: NSRange(location: 0, length: attributed.length))
        var cursor = 0
        func fonts(_ node: LogseqMarkupNode) {
            let start = cursor
            if [.emphasis, .quote, .link].contains(node.type) && !node.children.isEmpty {
                node.children.forEach(fonts)
            } else {
                cursor += String(OutlinerMarkupAttributedString.make(nodes: [node], fallback: "").characters).utf16.count
            }
            let selected: UIFont?
            switch node.type {
            case .code: selected = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            case .emphasis, .quote:
                let base: UIFont
                switch node.style {
                case "heading-1": base = .preferredFont(forTextStyle: .title1)
                case "heading-2": base = .preferredFont(forTextStyle: .title2)
                case "heading-3": base = .preferredFont(forTextStyle: .title3)
                case "heading-4", "heading-5", "heading-6": base = .preferredFont(forTextStyle: .headline)
                default: base = font
                }
                if node.style == "italic" {
                    selected = UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitItalic) ?? base.fontDescriptor, size: 0)
                } else if node.style == "bold" || node.style?.hasPrefix("heading-") == true {
                    selected = UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor, size: 0)
                } else { selected = nil }
            default: selected = nil
            }
            if let selected, cursor <= attributed.length {
                attributed.addAttribute(.font, value: selected, range: NSRange(location: start, length: cursor - start))
            }
        }
        nodes.forEach(fonts)
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return sourceOffset(position(at: point, manager: manager, container: container, text: attributed.string as NSString), title: title, nodes: nodes)
    }
}
#endif
