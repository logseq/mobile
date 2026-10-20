import CryptoKit
import Foundation
import OSLog
import UIKit
import UniformTypeIdentifiers

private enum SharedCaptureConstants {
    static let appGroup = "group.com.logseq.logseq"
    static let logger = Logger(subsystem: "com.logseq.logseq.ShareViewController", category: "SharedCapture")
}

struct SharedAsset: Codable, Sendable {
    let title: String
    let assetType: String
    let size: Int
    let checksum: String
    let stagedFileName: String
}

struct SharedPayload: Codable, Sendable {
    let text: String?
    let title: String?
    let url: String?
}

struct SharedItem: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case asset
        case payload
    }

    let id: String
    let kind: Kind
    let captureText: String?
    let captureAsset: SharedAsset?
    let capturePayload: SharedPayload?

    static func text(_ text: String) -> SharedItem {
        SharedItem(
            id: UUID().uuidString.lowercased(),
            kind: .text,
            captureText: text,
            captureAsset: nil,
            capturePayload: nil
        )
    }

    static func asset(_ asset: SharedAsset) -> SharedItem {
        SharedItem(
            id: UUID().uuidString.lowercased(),
            kind: .asset,
            captureText: nil,
            captureAsset: asset,
            capturePayload: nil
        )
    }
}

enum LoadedProviderCapture: Sendable {
    case text(String)
    case url(String)
    case asset(SharedItem)
}

private final class CaptureAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    private var url: String?
    private var assets: [SharedItem] = []

    func setText(_ value: String) {
        lock.withLock { text = value }
    }

    func setURL(_ value: String) {
        lock.withLock { url = value }
    }

    func append(_ asset: SharedItem) {
        lock.withLock { assets.append(asset) }
    }

    func append(_ capture: LoadedProviderCapture) {
        switch capture {
        case .text(let value): setText(value)
        case .url(let value): setURL(value)
        case .asset(let value): append(value)
        }
    }

    func snapshot() -> (text: String?, url: String?, assets: [SharedItem]) {
        lock.withLock { (text, url, assets) }
    }
}

@MainActor final class ShareViewController: UIViewController {
    private var didStart = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        view.backgroundColor = .systemBackground
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.accessibilityLabel = "Saving to Logseq"
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        captureInput()
    }

    private func captureInput() {
        let inputItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let title = inputItems.compactMap { $0.attributedTitle?.string.trimmed }.first
        let providers = inputItems.flatMap { $0.attachments ?? [] }
        SharedCaptureConstants.logger.notice("Capture started with \(providers.count) providers")
        let group = DispatchGroup()
        let accumulator = CaptureAccumulator()

        for provider in providers {
            let routes = ShareCaptureRoutePolicy.routes(for: provider.registeredTypeIdentifiers)
            guard !routes.isEmpty else { continue }
            group.enter()
            ShareCaptureRouteRunner.firstResult(in: routes) { route, finish in
                Self.load(route, from: provider, completion: finish)
            } completion: { capture in
                if let capture { accumulator.append(capture) }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let snapshot = accumulator.snapshot()
            var captures: [SharedItem] = []
            if snapshot.text != nil || snapshot.url != nil || title != nil {
                captures.append(SharedItem(id: UUID().uuidString.lowercased(), kind: .payload,
                    captureText: nil, captureAsset: nil,
                    capturePayload: SharedPayload(text: snapshot.text, title: title, url: snapshot.url)))
            }
            captures.append(contentsOf: snapshot.assets)
            guard !captures.isEmpty, Self.persist(captures) else {
                let alert = UIAlertController(title: "Could not save to Logseq",
                    message: "The shared content could not be saved. Please try sharing it again.",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Close", style: .cancel) { _ in
                    self.extensionContext?.cancelRequest(withError: CocoaError(.fileWriteUnknown))
                })
                self.present(alert, animated: true)
                return
            }
            SharedCaptureConstants.logger.notice("Capture completed with \(captures.count) items")
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    nonisolated static func load(
        _ route: ShareCaptureRoute,
        from provider: NSItemProvider,
        completion: @escaping (LoadedProviderCapture?) -> Void
    ) {
        switch route {
        case .asset(let identifier):
            guard let type = UTType(identifier) else {
                completion(nil)
                return
            }
            loadAsset(type: type, from: provider) { asset in
                guard let asset else {
                    completion(nil)
                    return
                }
                completion(.asset(.asset(asset)))
            }
        case .fileURL:
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                let url = (item as? URL) ?? (item as? NSURL).map { $0 as URL }
                    ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                guard let url, url.isFileURL else { completion(nil); return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                    ?? UTType(filenameExtension: url.pathExtension) ?? .data
                completion((try? stage(url, type: type)).map { .asset(.asset($0)) })
            }
        case .url:
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                let value = (item as? URL)?.absoluteString
                    ?? (item as? NSURL)?.absoluteString
                    ?? (item as? String)
                completion(value?.trimmed.map(LoadedProviderCapture.url))
            }
        case .text:
            let identifier = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .plainText) == true
            } ?? UTType.plainText.identifier
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                let encoding: String.Encoding = identifier.contains("utf16") ? .utf16 : .utf8
                if let data, let value = String(data: data, encoding: encoding)?.trimmed {
                    completion(.text(value))
                    return
                }
                provider.loadItem(forTypeIdentifier: identifier) { item, _ in
                    let value = (item as? String) ?? (item as? NSString).map { String($0) }
                        ?? (item as? NSAttributedString)?.string
                    completion(value?.trimmed.map(LoadedProviderCapture.text))
                }
            }
        }
    }

    nonisolated private static func loadAsset(
        type: UTType,
        from provider: NSItemProvider,
        completion: @escaping (SharedAsset?) -> Void
    ) {
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { fileURL, _ in
            if let fileURL, let asset = try? stage(fileURL, type: type) {
                completion(asset)
                return
            }
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                if let data,
                   let asset = try? stage(
                        data,
                        suggestedName: provider.suggestedName,
                        type: type
                      ) {
                    completion(asset)
                    return
                }
                guard type.conforms(to: .image), provider.canLoadObject(ofClass: UIImage.self) else {
                    completion(nil)
                    return
                }
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    guard let image = object as? UIImage, let data = image.pngData() else {
                        completion(nil)
                        return
                    }
                    completion(try? stage(data, suggestedName: provider.suggestedName, type: .png))
                }
            }
        }
    }

    nonisolated private static func stage(_ source: URL, type: UTType) throws -> SharedAsset {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedCaptureConstants.appGroup
        ) else { throw CocoaError(.fileNoSuchFile) }
        let directory = container.appendingPathComponent("SharedCapture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let title = source.lastPathComponent.isEmpty ? "Attachment" : source.lastPathComponent
        let stagedName = "\(UUID().uuidString.lowercased())-\(title.replacingOccurrences(of: "/", with: "-"))"
        let destination = directory.appendingPathComponent(stagedName, isDirectory: false)
        try FileManager.default.copyItem(at: source, to: destination)
        let data = try Data(contentsOf: destination)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SharedAsset(
            title: title,
            assetType: type.preferredMIMEType ?? type.preferredFilenameExtension ?? type.identifier,
            size: data.count,
            checksum: checksum,
            stagedFileName: stagedName
        )
    }

    nonisolated private static func stage(
        _ data: Data,
        suggestedName: String?,
        type: UTType
    ) throws -> SharedAsset {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedCaptureConstants.appGroup
        ) else { throw CocoaError(.fileNoSuchFile) }
        let directory = container.appendingPathComponent("SharedCapture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var title = suggestedName?.trimmed ?? "Attachment"
        if URL(fileURLWithPath: title).pathExtension.isEmpty,
           let pathExtension = type.preferredFilenameExtension {
            title += ".\(pathExtension)"
        }
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
        let stagedName = "\(UUID().uuidString.lowercased())-\(safeTitle)"
        let destination = directory.appendingPathComponent(stagedName, isDirectory: false)
        try data.write(to: destination, options: .atomic)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SharedAsset(
            title: title,
            assetType: type.preferredMIMEType ?? type.preferredFilenameExtension ?? type.identifier,
            size: data.count,
            checksum: checksum,
            stagedFileName: stagedName
        )
    }

    nonisolated static func persist(_ additions: [SharedItem]) -> Bool {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedCaptureConstants.appGroup
        ) else {
            SharedCaptureConstants.logger.error("App group container is unavailable")
            return false
        }
        let directory = container.appendingPathComponent("SharedCaptureQueue", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for item in additions {
                let name = SHA256.hash(data: Data(item.id.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
                let destination = directory.appendingPathComponent("\(name).json")
                try JSONEncoder().encode(item).write(to: destination, options: .atomic)
            }
        } catch {
            SharedCaptureConstants.logger.error("Failed to persist shared captures: \(error)")
            return false
        }
        SharedCaptureConstants.logger.notice("Persisted \(additions.count) shared captures")
        return true
    }
}

private extension String {
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
