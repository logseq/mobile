#if os(iOS)
import UIKit

// SwiftUI Text excludes the final line's font leading. UITextView's fitting
// height includes it, so measure the same glyph bounds as the display text.
enum OutlinerNativeTextMeasurement {
    @MainActor static func configureTextContainer(_ textView: UITextView) {
        textView.isScrollEnabled = false
        textView.textContainer.lineFragmentPadding = 0
    }

    static func size(text: String, font: UIFont, width: CGFloat,
                     verticalInset: CGFloat, scale: CGFloat) -> CGSize {
        guard !text.isEmpty else {
            let lineHeight = max(24, font.lineHeight + verticalInset * 2)
            return CGSize(width: width, height: ceil(lineHeight * scale) / scale)
        }
        let bounds = NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin], context: nil)
        let textHeight = ceil(bounds.height * scale) / scale
        let height = ceil((textHeight + verticalInset * 2) * scale) / scale
        return CGSize(width: width, height: height)
    }
}

class OutlinerLayoutTextView: UITextView {
    private var layoutWidth: CGFloat?

    override func layoutSubviews() {
        super.layoutSubviews()
        // UIKit resets the container height when its bounds change. The visible
        // frame excludes final-line leading, but TextKit needs the complete last
        // line to resolve caret positions in an expanding, non-scrolling editor.
        if textContainer.size.height != .greatestFiniteMagnitude {
            textContainer.heightTracksTextView = false
            textContainer.size.height = .greatestFiniteMagnitude
        }
        if layoutWidth != bounds.width {
            layoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}
#endif
