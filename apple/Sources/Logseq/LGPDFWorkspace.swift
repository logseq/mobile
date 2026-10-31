import Foundation
import LUIAppleBackend
import SwiftUI
#if os(iOS)
import PDFKit
import UIKit
#endif

extension EnvironmentValues {
    @Entry var lgOpenPDF: ((String, String, URL) -> Void)?
    @Entry var lgOpenPDFAnnotation: ((String) -> Void)?
}

@MainActor
enum LGPDFWorkspaceExtension {
    static let identifier = "native-pdf-workspace"
    static let fingerprint = "lui-extension-v1|20:native-pdf-workspace|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:7:payload:string:required:none|events:5:event[7:payload:string:required]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(LUIAppleExtension(identifier: identifier, fingerprint: fingerprint,
            acceptsStandardChildren: true,
            properties: [.init(name: "payload", kind: .string, isRequired: true)],
            events: [.init(name: "event", fields: [.init(name: "payload", kind: .string, isRequired: true)])]
        ) { context in AnyView(LGPDFWorkspace(context: context)) })
    }
}

private struct LGPDFWorkspace: View {
    let context: LUIAppleExtensionViewContext
    private var payload: [String: Any]? {
        guard case let .string(text) = context.property("payload"), let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    var body: some View {
        let _ = context.revision
        LGPDFSplitContent(context: context, payload: payload)
    }
}

private struct LGPDFSplitContent: View {
    let context: LUIAppleExtensionViewContext
    let payload: [String: Any]?
    @State private var fraction = 0.5
    @State private var isResizing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let open = payload != nil
            let fullScreen = open && ((payload?["fullScreen"] as? Bool) ?? (geometry.size.width < 600))
            let available = max(1, geometry.size.width - 14)
            let minimum = min(CGFloat(240), available * 0.35)
            let width = min(max(minimum, available * fraction), available - minimum)
            HStack(spacing: 0) {
                #if os(iOS)
                if let payload {
                    LGPDFReader(payload: payload.merging(["fullScreen": fullScreen]) { _, mode in mode }, send: { value in
                        var value = value
                        value["assetUuid"] = payload["assetUuid"]
                        value["graphId"] = payload["graphId"]
                        send(value)
                    })
                        .frame(width: fullScreen ? geometry.size.width : width)
                        .accessibilityIdentifier("pdf.reader")
                    LGPDFResizeHandle(onDelta: { delta in
                        let current = min(max(minimum, available * fraction), available - minimum)
                        withTransaction(Transaction(animation: nil)) {
                            fraction = min(max(minimum, current + delta), available - minimum) / available
                        }
                    }, onActive: { isResizing = $0 }, onAdjust: { direction in
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                            fraction = min(max(minimum, width + CGFloat(direction) * available * 0.1), available - minimum) / available
                        }
                    }, onReset: {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { fraction = 0.5 }
                    })
                    .frame(width: 44, height: geometry.size.height)
                    .padding(.horizontal, -15)
                    .zIndex(1)
                    .opacity(fullScreen ? 0 : 1)
                    .allowsHitTesting(!fullScreen)
                    .accessibilityHidden(fullScreen)
                }
                #endif
                Group {
                    if let child = context.childIDs.first { context.content(for: child) }
                }
                .frame(width: open ? available - width : geometry.size.width, height: geometry.size.height)
                .opacity(fullScreen ? 0 : 1)
                .allowsHitTesting(!fullScreen)
                .accessibilityHidden(fullScreen)
                .environment(\.lgOpenPDF, { uuid, title, url in
                    send(["action": "open", "uuid": uuid, "title": title, "path": url.path])
                })
                .environment(\.lgOpenPDFAnnotation, { encoded in
                    guard let data = encoded.data(using: .utf8), let reference = try? JSONSerialization.jsonObject(with: data) else { return }
                    send(["action": "open-annotation", "annotation": reference])
                })
                .accessibilityIdentifier(open ? "pdf.main" : "application.main")
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .transaction { if isResizing { $0.disablesAnimations = true } }
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        try? context.emit(name: "event", values: ["payload": .string(text)])
    }
}

#if os(iOS)
private struct LGPDFResizeHandle: UIViewRepresentable {
    let onDelta: (CGFloat) -> Void
    let onActive: (Bool) -> Void
    let onAdjust: (Int) -> Void
    let onReset: () -> Void
    func makeUIView(context: Context) -> LGPDFResizeHandleView { LGPDFResizeHandleView() }
    func updateUIView(_ view: LGPDFResizeHandleView, context: Context) {
        view.onDelta = onDelta
        view.onActive = onActive
        view.onAdjust = onAdjust
        view.onReset = onReset
    }
}

final class LGPDFResizeHandleView: UIView {
    var onDelta: (CGFloat) -> Void = { _ in }
    var onActive: (Bool) -> Void = { _ in }
    var onAdjust: (Int) -> Void = { _ in }
    var onReset: () -> Void = {}
    private let line = UIView()
    private let grip = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        line.backgroundColor = .separator
        grip.backgroundColor = .tertiaryLabel
        grip.layer.cornerRadius = 2
        addSubview(line)
        addSubview(grip)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resize(_:))))
        let reset = UITapGestureRecognizer(target: self, action: #selector(resetSplit))
        reset.numberOfTapsRequired = 2
        addGestureRecognizer(reset)
        isAccessibilityElement = true
        accessibilityIdentifier = "pdf.divider"
        accessibilityLabel = "Resize PDF and notes"
        accessibilityHint = "Drag to resize. Double-tap to reset equal columns."
        accessibilityTraits = .adjustable
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Reset equal columns", target: self, selector: #selector(resetSplit))]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
        grip.bounds = CGRect(x: 0, y: 0, width: 4, height: 36)
        grip.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
    @objc private func resize(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { onActive(true); showActive(true) }
        if recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended {
            onDelta(recognizer.translation(in: window).x)
            recognizer.setTranslation(.zero, in: window)
        }
        if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
            onActive(false)
            showActive(false)
        }
    }
    private func showActive(_ active: Bool) {
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15) {
            self.grip.backgroundColor = active ? self.tintColor : .tertiaryLabel
            self.grip.transform = active ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
        }
    }
    @objc private func resetSplit() -> Bool { onReset(); return true }
    override func accessibilityIncrement() { onAdjust(1) }
    override func accessibilityDecrement() { onAdjust(-1) }
}

private struct LGPDFReader: UIViewControllerRepresentable {
    let payload: [String: Any]
    let send: ([String: Any]) -> Void
    func makeUIViewController(context: Context) -> LGPDFReaderController {
        let controller = LGPDFReaderController()
        controller.send = send
        controller.apply(payload)
        return controller
    }
    func updateUIViewController(_ controller: LGPDFReaderController, context: Context) {
        controller.send = send
        controller.apply(payload)
    }
}

@MainActor
private final class LGPDFGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.name == "pdf.annotation-tap" || otherGestureRecognizer.name == "pdf.annotation-tap"
    }
}

final class LGPDFSelectionView: PDFView {
    // PDFKit owns its native gesture delegate methods, which vary by OS version.
    private let selectionGestureDelegate = LGPDFGestureDelegate()
    var didSelectText: (() -> Void)?
    var didSelectHighlight: ((String) -> Void)?
    private var startPage: PDFPage?
    private var startPoint = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        let pencil = UIPanGestureRecognizer(target: self, action: #selector(selectWithPencil(_:)))
        pencil.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencil.maximumNumberOfTouches = 1
        pencil.name = "pdf.pencil-select"
        pencil.delegate = selectionGestureDelegate
        addGestureRecognizer(pencil)
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectHighlight(_:)))
        tap.name = "pdf.annotation-tap"
        tap.cancelsTouchesInView = false
        tap.delegate = selectionGestureDelegate
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A finger scrolls; a Pencil drag selects immediately, without a long press.
        func configure(_ view: UIView) {
            if let scroll = view as? UIScrollView {
                scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            }
            view.subviews.forEach(configure)
        }
        subviews.forEach(configure)
    }

    @objc private func selectWithPencil(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard let page = page(for: point, nearest: true), let document, document.allowsCopying else { return }
        let location = convert(point, to: page)
        switch recognizer.state {
        case .began:
            startPage = page
            startPoint = location
            setCurrentSelection(page.selectionForWord(at: location), animate: false)
        case .changed, .ended:
            if let startPage {
                setCurrentSelection(document.selection(from: startPage, at: startPoint, to: page, at: location), animate: false)
            }
            if recognizer.state == .ended { startPage = nil; didSelectText?() }
        case .cancelled, .failed: startPage = nil
        default: break
        }
    }

    @objc private func selectHighlight(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard let page = page(for: point, nearest: false),
              let annotation = page.annotation(at: convert(point, to: page)),
              let name = annotation.userName, name.hasPrefix("logseq:") else { return }
        didSelectHighlight?(String(name.dropFirst(7)))
    }

}

@MainActor
final class LGPDFReaderController: UIViewController {
    let pdfView = LGPDFSelectionView()
    var send: ([String: Any]) -> Void = { _ in }
    private var payload: [String: Any] = [:]
    private var identity = ""
    private var highlights: [[String: Any]] = []
    private var renderedHighlights: [[String: Any]] = []
    private var appliedAnnotations: [PDFAnnotation] = []
    private var selectedID: String?
    private var color = "yellow"
    private let titleLabel = UILabel()
    private let status = UILabel()
    private let highlightButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let colorButton = UIButton(type: .system)
    private let fullScreenButton = UIButton(type: .system)
    private var documentTask: Task<Void, Never>?
    private var visitTask: Task<Void, Never>?
    private var lastSize = CGSize.zero
    private var fileError: String?
    private var restoredPage = false
    private var navigationToken: Int?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.accessibilityIdentifier = "pdf.document"
        let close = button("Close PDF", image: "xmark", id: "pdf.close") { [weak self] in self?.send(["action": "close"]) }
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(fullScreenButton, title: "Full-screen PDF", image: "arrow.up.left.and.arrow.down.right", id: "pdf.toggle-fullscreen") { [weak self] in
            guard let self else { return }
            send(["action": "set-fullscreen", "fullScreen": !(payload["fullScreen"] as? Bool ?? false)])
        }
        let header = UIStackView(arrangedSubviews: [close, titleLabel, fullScreenButton])
        header.alignment = .center
        header.spacing = 4
        let toolbar = UIStackView()
        toolbar.alignment = .center
        toolbar.spacing = 2
        configure(highlightButton, title: "Highlight selected text", image: "highlighter", id: "pdf.highlight") { [weak self] in self?.highlightSelection() }
        configure(colorButton, title: "Highlight color", image: "circle.fill", id: "pdf.color", action: {})
        colorButton.showsMenuAsPrimaryAction = true
        colorButton.menu = UIMenu(children: ["yellow", "red", "green", "blue", "purple"].map { color in
            UIAction(title: color.capitalized, image: UIImage(systemName: "circle.fill")?.withTintColor(Self.highlightColor(color), renderingMode: .alwaysOriginal)) { [weak self] _ in
                self?.color = color
                self?.colorButton.tintColor = Self.highlightColor(color)
                self?.recolorSelection()
            }
        })
        colorButton.tintColor = Self.highlightColor(color)
        configure(copyButton, title: "Copy annotation reference", image: "link", id: "pdf.copy-reference") { [weak self] in
            guard let id = self?.selectedID else { return }
            UIPasteboard.general.string = "((\(id)))"
        }
        configure(deleteButton, title: "Delete highlight", image: "trash", id: "pdf.delete") { [weak self] in
            guard let self, let selectedID else { return }
            send(["action": "delete", "id": selectedID])
            self.selectedID = nil
            updateSelection()
        }
        let annotations = button("Open annotations in main", image: "text.bubble", id: "pdf.annotations") { [weak self] in self?.send(["action": "open-annotations"]) }
        let previous = button("Previous page", image: "chevron.up", id: "pdf.previous") { [weak self] in self?.pdfView.goToPreviousPage(nil) }
        let next = button("Next page", image: "chevron.down", id: "pdf.next") { [weak self] in self?.pdfView.goToNextPage(nil) }
        let retry = button("Retry PDF", image: "arrow.clockwise", id: "pdf.retry") { [weak self] in
            guard let self else { return }
            if pdfView.document == nil { identity = ""; apply(payload) }
            send(["action": "load"])
        }
        [highlightButton, colorButton, annotations, copyButton, deleteButton, previous, next, retry].forEach(toolbar.addArrangedSubview)
        let scroller = UIScrollView()
        scroller.showsHorizontalScrollIndicator = false
        scroller.addSubview(toolbar)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            toolbar.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            toolbar.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
        ])
        status.font = .preferredFont(forTextStyle: .caption1)
        status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 2
        status.textColor = .secondaryLabel
        status.accessibilityIdentifier = "pdf.status"
        let stack = UIStackView(arrangedSubviews: [header, scroller, status, pdfView])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroller.heightAnchor.constraint(equalToConstant: 44),
        ])
        pdfView.didSelectText = { [weak self] in self?.updateSelection() }
        pdfView.didSelectHighlight = { [weak self] id in
            self?.pdfView.clearSelection()
            self?.selectedID = id
            self?.updateSelection()
        }
        for name in [Notification.Name.PDFViewSelectionChanged, .PDFViewPageChanged, .PDFViewScaleChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(pdfChanged(_:)), name: name, object: pdfView)
        }
        titleLabel.text = payload["title"] as? String
        updateSelection()
    }

    deinit {
        documentTask?.cancel()
        visitTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func pdfChanged(_ notification: Notification) {
        updateSelection()
        if notification.name == .PDFViewPageChanged { recordPage() }
        if notification.name != .PDFViewSelectionChanged { renderHighlights() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if payload["fullScreen"] as? Bool == true { view.window?.endEditing(true) }
    }

    func apply(_ payload: [String: Any]) {
        let wasFullScreen = self.payload["fullScreen"] as? Bool ?? false
        self.payload = payload
        loadViewIfNeeded()
        titleLabel.text = payload["title"] as? String
        let fullScreen = payload["fullScreen"] as? Bool ?? false
        fullScreenButton.setImage(UIImage(systemName: fullScreen ? "rectangle.split.2x1" : "arrow.up.left.and.arrow.down.right"), for: .normal)
        fullScreenButton.accessibilityLabel = fullScreen ? "Show PDF and notes" : "Full-screen PDF"
        if fullScreen && !wasFullScreen { view.window?.endEditing(true) }
        highlights = payload["highlights"] as? [[String: Any]] ?? []
        let next = (payload["graphId"] as? String ?? "") + ":" + (payload["assetUuid"] as? String ?? "")
        if next != identity {
            identity = next
            fileError = nil
            selectedID = nil
            restoredPage = false
            navigationToken = nil
            pdfView.document = nil
            appliedAnnotations = []
            renderedHighlights = []
            documentTask?.cancel()
            let uuid = payload["assetUuid"] as? String ?? ""
            let localPath = payload["path"] as? String ?? ""
            documentTask = Task { [weak self] in
                do {
                    let url: URL
                    if let local = LocalAssetPath.resolve(localPath, title: "Document.pdf", assetType: "pdf") { url = local }
                    else { url = try await LGGraphAssetLoader.load(uuid: uuid, assetType: "pdf") }
                    try Task.checkCancellation()
                    guard let self, identity == next else { return }
                    let document = PDFDocument(url: url)
                    guard let document else { throw CocoaError(.fileReadCorruptFile) }
                    guard !document.isLocked else { throw CocoaError(.fileReadNoPermission) }
                    pdfView.document = document
                    pdfView.layoutIfNeeded()
                    renderHighlights(force: true)
                    restorePageIfReady()
                    updateSelection()
                } catch is CancellationError { return }
                catch { self?.fileError = "Unable to open PDF: \(error.localizedDescription)"; self?.updateSelection() }
            }
        } else { renderHighlights() }
        restorePageIfReady()
        updateSelection()
    }

    private func restorePageIfReady() {
        let token = payload["navigationToken"] as? Int
        guard (!restoredPage || token != navigationToken), payload["loading"] as? Bool != true,
              let document = pdfView.document, document.pageCount > 0 else { return }
        restoredPage = true
        navigationToken = token
        pdfView.clearSelection()
        selectedID = payload["targetAnnotation"] as? String
        let page = min(max(1, payload["targetPage"] as? Int ?? payload["page"] as? Int ?? 1), document.pageCount)
        if let target = document.page(at: page - 1) { pdfView.go(to: target) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if pdfView.bounds.size != lastSize {
            lastSize = pdfView.bounds.size
            renderHighlights()
        }
    }

    private func configure(_ button: UIButton, title: String, image: String, id: String, action: @escaping () -> Void) {
        button.setImage(UIImage(systemName: image), for: .normal)
        button.accessibilityLabel = title
        button.accessibilityIdentifier = id
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    private func button(_ title: String, image: String, id: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        configure(button, title: title, image: image, id: id, action: action)
        return button
    }

    private func updateSelection() {
        let selection = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selection.isEmpty { selectedID = nil }
        highlightButton.isEnabled = !selection.isEmpty
        copyButton.isEnabled = selectedID != nil
        deleteButton.isEnabled = selectedID != nil
        if let fileError { status.text = fileError; return }
        if let error = payload["error"] as? String { status.text = error; return }
        if payload["loading"] as? Bool == true { status.text = "Loading annotations…"; return }
        let page = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) }.map { $0 + 1 } ?? 1
        status.text = selection.isEmpty ? "\(page) / \(pdfView.document?.pageCount ?? 0) · Select text to highlight" : "\(selection.count) characters selected"
    }

    @objc func highlightSelection() {
        guard let selection = pdfView.currentSelection, let document = pdfView.document else { return }
        for page in selection.pages {
            let lines = selection.selectionsByLine().filter { $0.pages.contains { $0 === page } }
            let text = lines.compactMap(\.string).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let viewport = pdfView.convert(page.bounds(for: .cropBox), from: page)
            guard !text.isEmpty, viewport.width > 0, viewport.height > 0 else { continue }
            let rects = lines.map { pdfView.convert($0.bounds(for: page), from: page).intersection(viewport) }
                .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            guard let first = rects.first else { continue }
            let bounding = rects.dropFirst().reduce(first) { $0.union($1) }
            func scaled(_ rect: CGRect) -> [String: Double] {
                ["x1": Double(rect.minX - viewport.minX), "y1": Double(rect.minY - viewport.minY),
                 "x2": Double(rect.maxX - viewport.minX), "y2": Double(rect.maxY - viewport.minY),
                 "width": Double(viewport.width), "height": Double(viewport.height)]
            }
            let number = document.index(for: page) + 1
            let id = UUID().uuidString.lowercased()
            selectedID = id
            send(["action": "save", "highlight": ["id": id, "page": number,
                "content": ["text": text], "properties": ["color": color],
                "position": ["page": number, "bounding": scaled(bounding), "rects": rects.map(scaled)]]])
        }
        pdfView.clearSelection()
        updateSelection()
    }

    private func recolorSelection() {
        guard let selectedID else { return }
        send(["action": "recolor", "id": selectedID, "color": color])
    }

    private func renderHighlights(force: Bool = false) {
        guard let document = pdfView.document, pdfView.bounds.width > 0, pdfView.bounds.height > 0 else { return }
        guard force || !NSArray(array: highlights).isEqual(to: renderedHighlights) else { return }
        appliedAnnotations.forEach { $0.page?.removeAnnotation($0) }
        appliedAnnotations = []
        renderedHighlights = highlights
        for highlight in highlights {
            guard let pageNumber = highlight["page"] as? Int, pageNumber > 0,
                  let page = document.page(at: pageNumber - 1),
                  let position = highlight["position"] as? [String: Any] else { continue }
            let viewport = pdfView.convert(page.bounds(for: .cropBox), from: page)
            let properties = highlight["properties"] as? [String: Any] ?? [:]
            var rectangles = position["rects"] as? [[String: Double]] ?? []
            if rectangles.isEmpty, let bounding = position["bounding"] as? [String: Double] { rectangles = [bounding] }
            for rect in rectangles {
                guard let x1 = rect["x1"], let y1 = rect["y1"], let x2 = rect["x2"], let y2 = rect["y2"],
                      let width = rect["width"], let height = rect["height"], width > 0, height > 0 else { continue }
                let viewRect = CGRect(x: viewport.minX + x1 / width * viewport.width,
                    y: viewport.minY + y1 / height * viewport.height,
                    width: (x2 - x1) / width * viewport.width, height: (y2 - y1) / height * viewport.height)
                let annotation = PDFAnnotation(bounds: pdfView.convert(viewRect, to: page), forType: .highlight, withProperties: nil)
                annotation.color = Self.highlightColor(properties["color"] as? String ?? "yellow").withAlphaComponent(0.35)
                annotation.userName = "logseq:" + (highlight["id"] as? String ?? "")
                annotation.contents = (highlight["content"] as? [String: Any])?["text"] as? String
                page.addAnnotation(annotation)
                appliedAnnotations.append(annotation)
            }
        }
    }

    private func recordPage() {
        visitTask?.cancel()
        guard restoredPage, let page = pdfView.currentPage, let document = pdfView.document else { return }
        let number = document.index(for: page) + 1
        visitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.send(["action": "visit", "page": number])
        }
    }

    private static func highlightColor(_ name: String) -> UIColor {
        switch name {
        case "red": .systemRed
        case "green": .systemGreen
        case "blue": .systemBlue
        case "purple": .systemPurple
        default: .systemYellow
        }
    }
}
#endif
