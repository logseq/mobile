#if os(iOS)
import SwiftUI
import UIKit
import LUIAppleBackend
import LogseqModel

/// The common text row has one native layout pass. Rich media and the editor
/// remain SwiftUI children of OutlinerRow.
struct OutlinerTextRow: UIViewRepresentable {
    let row: OutlinerRowPayload
    @Environment(\.luiSemanticColors) private var semanticColors
    @Environment(\.colorScheme) private var colorScheme
    let emit: (String, String?, [String: LUIExtensionValue]) -> Void
    let onOpenLink: (URL) -> Void

    static func supports(_ row: OutlinerRowPayload) -> Bool {
        !row.isAsset && row.markup.allSatisfy { node in
            node.type == .text || (node.type == .link && node.children.allSatisfy { $0.type == .text })
        }
    }

    func makeUIView(context: Context) -> OutlinerTextRowView { OutlinerTextRowView() }
    func updateUIView(_ view: OutlinerTextRowView, context: Context) {
        view.update(row, semanticColors: semanticColors,
            linkColor: LogseqThemePolicy.linkColor(isDark: colorScheme == .dark), emit: emit, onOpenLink: onOpenLink)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: OutlinerTextRowView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

@MainActor private final class OutlinerTitleLabel: UILabel {
    var activate: (() -> Void)?
    private let textStorage = NSTextStorage()
    private let textLayout = NSLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)
    private var contentNeedsLayout = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        textContainer.lineFragmentPadding = 0
        textStorage.addLayoutManager(textLayout)
        textLayout.addTextContainer(textContainer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var attributedText: NSAttributedString? { didSet { contentNeedsLayout = true } }
    override var font: UIFont! { didSet { contentNeedsLayout = true } }

    var verticalInset: CGFloat {
        OutlinerNativeTextLayoutPolicy.verticalInset(
            fontLineHeight: font.lineHeight, minimumLineHeight: OutlinerLayoutMetrics.titleLineHeight)
    }

    // UITextView rasterizes the padded glyph origin on the physical pixel grid.
    var drawingInset: CGFloat {
        floor(verticalInset * contentScaleFactor) / contentScaleFactor
    }

    override func drawText(in rect: CGRect) {
        if contentNeedsLayout {
            let content = NSMutableAttributedString(attributedString: attributedText ?? NSAttributedString(string: text ?? ""))
            content.addAttribute(.font, value: font as Any, range: NSRange(location: 0, length: content.length))
            textStorage.setAttributedString(content)
            contentNeedsLayout = false
        }
        textContainer.size = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        textLayout.ensureLayout(for: textContainer)
        let range = textLayout.glyphRange(for: textContainer)
        let origin = CGPoint(x: 0, y: drawingInset)
        textLayout.drawBackground(forGlyphRange: range, at: origin)
        textLayout.drawGlyphs(forGlyphRange: range, at: origin)
    }

    override func accessibilityActivate() -> Bool {
        guard let activate else { return false }
        activate()
        return true
    }
}

@MainActor final class OutlinerTextRowView: UIView {
    // URL activation is handled here; UILabel's standard link attribute forces system blue.
    private static let linkAttribute = NSAttributedString.Key("LogseqURL")
    private let guides = OutlinerIndentGuideView()
    private let title = OutlinerTitleLabel()
    private let bullet = UIButton(type: .custom)
    private let priority = UIButton(type: .custom)
    private let status = UIButton(type: .custom)
    private let disclosure = UIButton(type: .custom)
    private let failure = UILabel()
    private var tags: [UIButton] = []
    private var row: OutlinerRowPayload?
    private var semanticColors: [String: Color] = [:]
    private var emit: ((String, String?, [String: LUIExtensionValue]) -> Void)?
    private var onOpenLink: ((URL) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.activate = { [weak self] in self?.edit() }
        title.numberOfLines = 0
        title.isUserInteractionEnabled = true
        title.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapTitle(_:))))
        bullet.setImage(UIImage(named: "outliner_bullet", in: .module, compatibleWith: nil)?.withRenderingMode(.alwaysTemplate), for: .normal)
        bullet.tintColor = UIColor.secondaryLabel.withAlphaComponent(0.4)
        bullet.addTarget(self, action: #selector(open), for: .touchUpInside)
        priority.showsMenuAsPrimaryAction = true
        priority.preferredMenuElementOrder = .fixed
        priority.accessibilityIdentifier = "button.block-task-priority"
        status.imageView?.contentMode = .scaleAspectFit
        status.showsMenuAsPrimaryAction = true
        status.preferredMenuElementOrder = .fixed
        status.accessibilityIdentifier = "button.block-task-status"
        disclosure.contentHorizontalAlignment = .right
        var disclosureConfiguration = UIButton.Configuration.plain()
        disclosureConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 6)
        disclosureConfiguration.baseForegroundColor = .secondaryLabel
        disclosure.configuration = disclosureConfiguration
        disclosure.addTarget(self, action: #selector(collapse), for: .touchUpInside)
        failure.text = String(localized: "Sync failed")
        failure.textColor = .systemRed
        for child in [guides, title, bullet, status, priority, disclosure, failure] { addSubview(child) }
        layer.cornerRadius = 10
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: OutlinerTextRowView, _: UITraitCollection) in
            view.updateFonts()
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (view: OutlinerTextRowView, _: UITraitCollection) in
            guard let icon = view.row?.nodeIcon else { return }
            view.bullet.setImage(NodeIconExtension.image(icon, size: 18, traits: view.traitCollection), for: .normal)
        }
        updateFonts()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private var resolvedLinkColor: UIColor?

    func update(_ row: OutlinerRowPayload, semanticColors: [String: Color] = [:], linkColor: Color? = nil,
                emit: @escaping (String, String?, [String: LUIExtensionValue]) -> Void,
                onOpenLink: ((URL) -> Void)? = nil) {
        self.emit = emit
        self.onOpenLink = onOpenLink
        self.semanticColors = semanticColors
        status.tintColor = UIColor(row.status?.color(in: semanticColors) ?? .primary)
        let nextLinkColor = UIColor(semanticColors["link"] ?? linkColor
            ?? LogseqThemePolicy.linkColor(isDark: traitCollection.userInterfaceStyle == .dark)).resolvedColor(with: traitCollection)
        guard self.row != row || resolvedLinkColor != nextLinkColor else { return }
        resolvedLinkColor = nextLinkColor
        self.row = row
        guides.update(row)
        let attributes: [NSAttributedString.Key: Any] = row.completed
            ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: UIColor.secondaryLabel]
            : [.foregroundColor: UIColor.label]
        let value = NSMutableAttributedString(string: "")
        var actions: [UIAccessibilityCustomAction] = []
        if row.markup.isEmpty { value.append(NSAttributedString(string: row.title, attributes: attributes)) }
        for node in row.markup {
            if node.type == .link {
                let label = node.children.isEmpty ? node.url ?? "" : node.children.map { $0.text ?? "" }.joined()
                var linkAttributes = attributes
                if let url = node.url.flatMap(URL.init(string:)) {
                    linkAttributes[Self.linkAttribute] = url
                    if !row.completed { linkAttributes[.foregroundColor] = nextLinkColor }
                    actions.append(UIAccessibilityCustomAction(name: label) { [weak self] _ in
                        self?.onOpenLink?(url)
                        return true
                    })
                }
                value.append(NSAttributedString(string: label, attributes: linkAttributes))
            } else {
                value.append(NSAttributedString(string: node.text ?? "", attributes: attributes))
            }
        }
        title.attributedText = value
        title.accessibilityCustomActions = actions
        title.accessibilityIdentifier = "outliner.block-action." + row.uuid
        title.accessibilityLabel = "Edit block " + row.title
        title.accessibilityTraits = .button
        bullet.accessibilityIdentifier = "button.outliner.zoom." + row.uuid + "." + row.title
        bullet.accessibilityLabel = "Open block"
        let bulletAsset = row.collapsed && row.hasChildren ? "outliner_bullet_closed" : "outliner_bullet"
        bullet.setImage(row.nodeIcon.flatMap { NodeIconExtension.image($0, size: 18, traits: traitCollection) }
            ?? UIImage(named: bulletAsset, in: .module, compatibleWith: nil)?.withRenderingMode(.alwaysTemplate), for: .normal)
        bullet.isUserInteractionEnabled = !row.journalBullet
        bullet.accessibilityTraits = row.journalBullet ? .image : .button
        priority.isHidden = row.priority == nil
        priority.imageView?.contentMode = .scaleAspectFit
        priority.setImage(row.priority.flatMap { statusImage($0.icon) }, for: .normal)
        applyIconShadow(priority.imageView)
        priority.tintColor = .secondaryLabel
        priority.accessibilityLabel = row.priority?.title
        if let selected = row.priority {
            var actions = (row.priorities ?? []).map { item in
                UIAction(title: item.title, image: item.menuImage(in: semanticColors),
                         state: item.uuid == selected.uuid ? .on : .off) { [weak self] _ in
                    self?.emit?("set-priority", nil, ["priority": .string(item.uuid)])
                }
            }
            actions.append(UIAction(title: String(localized: "Clear priority"), attributes: .destructive) { [weak self] _ in
                self?.emit?("set-priority", nil, ["priority": .string("")])
            })
            priority.menu = UIMenu(children: actions)
        } else { priority.menu = nil }
        status.isHidden = row.status == nil
        if let task = row.status {
            status.setImage(statusImage(task.icon), for: .normal)
            status.imageView?.contentMode = .center
            applyIconShadow(status.imageView)
            status.accessibilityLabel = task.title
            status.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] complete in
                guard let self, let row = self.row else { complete([]); return }
                complete(row.statuses.enumerated().map { index, item in
                    UIAction(title: item.title, image: item.menuImage(in: self.semanticColors)) { [weak self] _ in
                        self?.emit?("set-status", nil, ["count": .int(index)])
                    }
                })
            }])
        }
        disclosure.isHidden = !row.hasChildren
        disclosure.setImage(UIImage(systemName: row.collapsed ? "arrowtriangle.right.fill" : "arrowtriangle.down.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10)), for: .normal)
        disclosure.tintColor = .secondaryLabel
        disclosure.accessibilityIdentifier = "button.outliner.collapse." + row.uuid
        disclosure.accessibilityLabel = row.collapsed ? "Expand block" : "Collapse block"
        failure.isHidden = !row.syncFailed
        failure.accessibilityIdentifier = "outliner.sync-failed." + row.uuid
        while tags.count > row.tags.count { tags.removeLast().removeFromSuperview() }
        for (index, tag) in row.tags.enumerated() {
            if index == tags.count { let button = UIButton(type: .system); tags.append(button); addSubview(button) }
            let button = tags[index]
            button.tintColor = nextLinkColor
            button.setTitle("#" + tag.title, for: .normal)
            button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .caption1)
            button.accessibilityIdentifier = "button.block-tag." + tag.uuid
            button.removeTarget(nil, action: nil, for: .touchUpInside)
            button.tag = index
            button.addTarget(self, action: #selector(openTag(_:)), for: .touchUpInside)
            if row.canRemoveTags == true, let title = row.removeTagTitle {
                button.menu = UIMenu(children: [UIAction(title: title, attributes: .destructive) { [weak self] _ in
                    self?.emit?("remove-tag", tag.uuid, [:])
                }])
                button.showsMenuAsPrimaryAction = false
            } else {
                button.menu = nil
            }
        }
        backgroundColor = row.selected ? tintColor.withAlphaComponent(0.12) : .clear
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func updateFonts() {
        title.font = .preferredFont(forTextStyle: .body)
        failure.font = .preferredFont(forTextStyle: .caption1)
        for tag in tags { tag.titleLabel?.font = .preferredFont(forTextStyle: .caption1) }
    }

    private func applyIconShadow(_ imageView: UIImageView?) {
        guard let imageView else { return }
        imageView.clipsToBounds = false
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowOpacity = 0.18
        imageView.layer.shadowRadius = 0.6
        imageView.layer.shadowOffset = CGSize(width: 0, height: 0.5)
    }

    private func statusImage(_ icon: String) -> UIImage? {
        let key = icon.replacingOccurrences(of: "app:", with: "")
        guard case let .assetName(name) = LGIconPolicy.icons[key] else { return nil }
        return UIImage(named: name, in: .module, compatibleWith: traitCollection)?.withRenderingMode(.alwaysTemplate)
    }

    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        guard let row else { return 0 }
        let inset = CGFloat(max(0, row.depth)) * 22
        let statusWidth: CGFloat = row.status == nil ? 0 : OutlinerLayoutMetrics.statusIconSize + OutlinerLayoutMetrics.statusContentSpacing
        let trailing: CGFloat = row.hasChildren ? 44 : 0
        let priorityWidth: CGFloat = row.priority == nil ? 0 : 25
        let iconLeading: CGFloat = row.status != nil ? OutlinerLayoutMetrics.statusLeading : (row.priority != nil ? 20 : 26)
        let leading = inset + iconLeading + statusWidth + priorityWidth
        let bodyWidth = max(1, width - leading - trailing)
        let titleHeight = OutlinerNativeTextMeasurement.size(text: title.attributedText?.string ?? "",
            font: title.font, width: bodyWidth, verticalInset: title.verticalInset,
            scale: traitCollection.displayScale).height
        var height = titleHeight + 4
        if apply {
            bullet.frame = CGRect(x: inset, y: 2, width: 24, height: 24)
            status.frame = CGRect(x: inset + iconLeading, y: 2, width: OutlinerLayoutMetrics.statusIconSize, height: 24)
            priority.frame = CGRect(x: inset + iconLeading + statusWidth, y: 2, width: 20, height: 24)
            title.frame = CGRect(x: leading, y: 2, width: bodyWidth, height: titleHeight)
            disclosure.frame = CGRect(x: width - trailing, y: -8, width: 44, height: 44)
        }
        if !tags.isEmpty {
            var x = leading
            for button in tags {
                let size = button.sizeThatFits(CGSize(width: bodyWidth, height: 22))
                if apply { button.frame = CGRect(x: x, y: height, width: size.width, height: 22) }
                x += size.width + 6
            }
            height += 24
        }
        if row.syncFailed {
            let size = failure.sizeThatFits(CGSize(width: bodyWidth, height: .greatestFiniteMagnitude))
            if apply { failure.frame = CGRect(x: leading, y: height, width: bodyWidth, height: size.height) }
            height += size.height + 2
        }
        return height
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event)
            || (!disclosure.isHidden && disclosure.frame.contains(point))
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: layout(width: size.width, apply: false)) }
    override func layoutSubviews() {
        super.layoutSubviews()
        guides.frame = bounds
        _ = layout(width: bounds.width, apply: true)
    }
    @objc private func tapTitle(_ gesture: UITapGestureRecognizer) {
        activateTitle(at: gesture.location(in: title))
    }

    func activateTitle(at point: CGPoint) {
        guard let row, !row.opensAsPage else { edit(); return }
        guard let attributed = title.attributedText, attributed.length > 0 else {
            emit?("edit", nil, ["caret-utf16-offset": .int(0)])
            return
        }
        let text = NSMutableAttributedString(attributedString: attributed)
        text.addAttribute(.font, value: title.font ?? .preferredFont(forTextStyle: .body),
                          range: NSRange(location: 0, length: text.length))
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: title.bounds.size)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = title.numberOfLines
        container.lineBreakMode = title.lineBreakMode
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let location = CGPoint(x: point.x, y: point.y - title.drawingInset)
        let glyph = manager.glyphIndex(for: location, in: container)
        if glyph < manager.numberOfGlyphs,
           manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(location) {
            let character = manager.characterIndexForGlyph(at: glyph)
            if let url = text.attribute(Self.linkAttribute, at: character, effectiveRange: nil) as? URL {
                onOpenLink?(url)
                return
            }
        }
        let offset = OutlinerTapCaret.position(at: location, manager: manager, container: container, text: text.string as NSString)
        emit?("edit", nil, ["caret-utf16-offset": .int(OutlinerTapCaret.sourceOffset(offset, title: row.title, nodes: row.markup))])
    }
    @objc private func edit() { emit?(row?.opensAsPage == true ? "open-node" : "edit", nil, [:]) }
    @objc private func open() { emit?("open-node", nil, [:]) }
    @objc private func collapse() { emit?("collapse", nil, [:]) }
    @objc private func openTag(_ sender: UIButton) {
        guard let row, row.tags.indices.contains(sender.tag) else { return }
        emit?("open-node", row.tags[sender.tag].uuid, [:])
    }
}
#endif
