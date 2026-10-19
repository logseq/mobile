#if os(iOS)
import SwiftUI
import UIKit
import LUIAppleBackend

/// The common text row has one native layout pass. Rich media and the editor
/// remain SwiftUI children of OutlinerRow.
struct OutlinerTextRow: UIViewRepresentable {
    let row: OutlinerRowPayload
    @Environment(\.luiSemanticColors) private var semanticColors
    let emit: (String, String?, [String: LUIExtensionValue]) -> Void

    func makeUIView(context: Context) -> OutlinerTextRowView { OutlinerTextRowView() }
    func updateUIView(_ view: OutlinerTextRowView, context: Context) {
        view.update(row, statusTint: UIColor(row.status?.color(in: semanticColors) ?? .primary), emit: emit)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: OutlinerTextRowView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

@MainActor private final class OutlinerTitleLabel: UILabel {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool {
        guard let activate else { return false }
        activate()
        return true
    }
}

@MainActor final class OutlinerTextRowView: UIView {
    private let guides = OutlinerIndentGuideView()
    private let title = OutlinerTitleLabel()
    private let bullet = UIButton(type: .custom)
    private let priority = UIImageView()
    private let status = UIButton(type: .custom)
    private let disclosure = UIButton(type: .custom)
    private let failure = UILabel()
    private var tags: [UIButton] = []
    private var row: OutlinerRowPayload?
    private var emit: ((String, String?, [String: LUIExtensionValue]) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.activate = { [weak self] in self?.edit() }
        title.numberOfLines = 0
        title.isUserInteractionEnabled = true
        title.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(edit)))
        bullet.setImage(UIImage(named: "outliner_bullet", in: .module, compatibleWith: nil)?.withRenderingMode(.alwaysTemplate), for: .normal)
        bullet.tintColor = UIColor.secondaryLabel.withAlphaComponent(0.4)
        bullet.addTarget(self, action: #selector(open), for: .touchUpInside)
        status.imageView?.contentMode = .scaleAspectFit
        status.showsMenuAsPrimaryAction = true
        status.accessibilityIdentifier = "button.block-task-status"
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
        updateFonts()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(_ row: OutlinerRowPayload, statusTint: UIColor, emit: @escaping (String, String?, [String: LUIExtensionValue]) -> Void) {
        self.emit = emit
        status.tintColor = statusTint
        guard self.row != row else { return }
        self.row = row
        guides.update(row)
        let value = row.markup.isEmpty ? row.title : row.markup.map { $0.text ?? "" }.joined()
        let attributes: [NSAttributedString.Key: Any] = row.completed
            ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: UIColor.secondaryLabel]
            : [.foregroundColor: UIColor.label]
        title.attributedText = NSAttributedString(string: value, attributes: attributes)
        title.accessibilityIdentifier = "outliner.block-action." + row.uuid
        title.accessibilityLabel = "Edit block " + row.title
        title.accessibilityTraits = .button
        bullet.accessibilityIdentifier = "button.outliner.zoom." + row.uuid + "." + row.title
        bullet.accessibilityLabel = "Open block"
        let bulletAsset = row.collapsed && row.hasChildren ? "outliner_bullet_closed" : "outliner_bullet"
        bullet.setImage(UIImage(named: bulletAsset, in: .module, compatibleWith: nil)?.withRenderingMode(.alwaysTemplate), for: .normal)
        bullet.isUserInteractionEnabled = !row.journalBullet
        bullet.accessibilityTraits = row.journalBullet ? .image : .button
        priority.isHidden = row.priority == nil
        priority.contentMode = .scaleAspectFit
        priority.image = row.priority.flatMap { statusImage($0.icon) }
        priority.tintColor = .secondaryLabel
        priority.accessibilityLabel = row.priority?.title
        status.isHidden = row.status == nil
        if let task = row.status {
            status.setImage(statusImage(task.icon), for: .normal)
            status.imageView?.contentMode = .center
            status.accessibilityLabel = task.title
            status.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] complete in
                guard let self, let row = self.row else { complete([]); return }
                complete(row.statuses.enumerated().map { index, item in
                    UIAction(title: item.title, image: self.statusImage(item.icon)) { [weak self] _ in
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
            button.setTitle("#" + tag.title, for: .normal)
            button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .caption1)
            button.accessibilityIdentifier = "button.block-tag." + tag.uuid
            button.removeTarget(nil, action: nil, for: .touchUpInside)
            button.tag = index
            button.addTarget(self, action: #selector(openTag(_:)), for: .touchUpInside)
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

    private func statusImage(_ icon: String) -> UIImage? {
        let key = icon.replacingOccurrences(of: "app:", with: "")
        guard case let .assetName(name) = LGIconPolicy.icons[key] else { return nil }
        return UIImage(named: name, in: .module, compatibleWith: traitCollection)?.withRenderingMode(.alwaysTemplate)
    }

    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        guard let row else { return 0 }
        let inset = CGFloat(max(0, row.depth)) * 22
        let statusWidth: CGFloat = row.status == nil ? 0 : 29
        let trailing: CGFloat = row.hasChildren ? 28 : 0
        let priorityWidth: CGFloat = row.priority == nil ? 0 : 25
        let leading = inset + 26 + statusWidth + priorityWidth
        let bodyWidth = max(1, width - leading - trailing)
        let titleHeight = max(24, ceil(title.sizeThatFits(CGSize(width: bodyWidth, height: .greatestFiniteMagnitude)).height))
        var height = titleHeight + 4
        if apply {
            bullet.frame = CGRect(x: inset, y: 2, width: 24, height: 24)
            status.frame = CGRect(x: inset + 26, y: 2, width: 22, height: 24)
            priority.frame = CGRect(x: inset + 26 + statusWidth, y: 2, width: 20, height: 24)
            title.frame = CGRect(x: leading, y: 2, width: bodyWidth, height: titleHeight)
            disclosure.frame = CGRect(x: width - trailing, y: 2, width: 28, height: 24)
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
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: layout(width: size.width, apply: false)) }
    override func layoutSubviews() {
        super.layoutSubviews()
        guides.frame = bounds
        _ = layout(width: bounds.width, apply: true)
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
