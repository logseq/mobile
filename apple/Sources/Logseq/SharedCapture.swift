import Foundation

import CryptoKit

public struct SharedCapturePayload: Codable, Sendable, Equatable {
    public let text: String?
    public let title: String?
    public let url: String?

    public init(text: String?, title: String?, url: String?) {
        self.text = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.url = url?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public struct SharedDeepLink: Codable, Sendable, Equatable {
    public struct QueryItem: Codable, Sendable, Equatable {
        let name: String
        let value: String?
    }
    var uuid: String?
    let scheme: String?
    let host: String?
    let path: String?
    let query: [QueryItem]

    public init(_ url: URL) {
        uuid = nil
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        scheme = components?.scheme
        host = components?.host
        path = components?.path
        query = (components?.queryItems ?? []).map { QueryItem(name: $0.name, value: $0.value) }
    }
}

extension SharedDeepLink {
    static func blockURL(graphName: String, blockID: String) -> String {
        var components = URLComponents()
        components.scheme = "logseq"
        components.host = "graph"
        components.path = "/" + graphName
        components.queryItems = [URLQueryItem(name: "block-id", value: blockID)]
        return components.url?.absoluteString ?? ""
    }
}

public struct SharedCaptureAsset: Codable, Sendable, Equatable {
    public let title: String
    public let assetType: String
    public let size: Int
    public let checksum: String
    public let stagedFileName: String

    public init(
        title: String,
        assetType: String,
        size: Int,
        checksum: String,
        stagedFileName: String
    ) {
        self.title = title
        self.assetType = assetType
        self.size = size
        self.checksum = checksum
        self.stagedFileName = stagedFileName
    }
}

public struct SharedCaptureItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case text
        case asset
        case payload
        case deepLink
    }

    public let id: String
    public let kind: Kind
    public let captureText: String?
    public let captureAsset: SharedCaptureAsset?
    public let capturePayload: SharedCapturePayload?
    public let captureLink: SharedDeepLink?

    public init(id: String, kind: Kind, captureText: String? = nil, captureAsset: SharedCaptureAsset? = nil,
                capturePayload: SharedCapturePayload? = nil, captureLink: SharedDeepLink? = nil) {
        self.id = id
        self.kind = kind
        self.captureText = captureText
        self.captureAsset = captureAsset
        self.capturePayload = capturePayload
        self.captureLink = captureLink
    }

    public static func text(id: String, text: String) -> SharedCaptureItem {
        SharedCaptureItem(id: id, kind: .text, captureText: text, captureAsset: nil)
    }

    public static func asset(id: String, asset: SharedCaptureAsset) -> SharedCaptureItem {
        SharedCaptureItem(id: id, kind: .asset, captureText: nil, captureAsset: asset)
    }
}

@MainActor public final class SharedCaptureInbox {
    public static let shared = SharedCaptureInbox(directory: SharedCaptureStorage.queueDirectory)

    private let defaults: UserDefaults
    private let storageKey = "logseq.pendingSharedCaptureItems"
    private let directory: URL?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.directory = nil
    }

    public init(directory: URL) {
        self.defaults = .standard
        self.directory = directory
    }

    public func enqueue(_ item: SharedCaptureItem) {
        guard !pendingItems().contains(where: { $0.id == item.id }) else { return }
        if let directory {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            guard let data = try? JSONEncoder().encode(item) else { return }
            try? data.write(to: itemURL(id: item.id, in: directory), options: .atomic)
            return
        }
        var pending = pendingItems()
        pending.append(item)
        save(pending)
    }

    public func enqueueText(_ text: String, id: String = UUID().uuidString.lowercased()) {
        guard let text = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return
        }
        enqueue(.text(id: id, text: text))
    }

    public func enqueue(payload: SharedCapturePayload, id: String = UUID().uuidString.lowercased()) {
        guard payload.text != nil || payload.title != nil || payload.url != nil else { return }
        enqueue(SharedCaptureItem(id: id, kind: .payload, capturePayload: payload))
    }

    public func pendingItems() -> [SharedCaptureItem] {
        if let directory {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return urls
                .filter { $0.pathExtension == "json" }
                .sorted { lhs, rhs in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    if lhsDate == rhsDate { return lhs.lastPathComponent < rhs.lastPathComponent }
                    return lhsDate < rhsDate
                }
                .compactMap { url in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? JSONDecoder().decode(SharedCaptureItem.self, from: data)
                }
        }
        guard let value = defaults.string(forKey: storageKey),
              let data = value.data(using: .utf8),
              let pending = try? JSONDecoder().decode([SharedCaptureItem].self, from: data)
        else { return [] }
        return pending
    }

    public func acknowledge(id: String) {
        if let directory {
            try? FileManager.default.removeItem(at: itemURL(id: id, in: directory))
            return
        }
        let remaining = pendingItems().filter { $0.id != id }
        if remaining.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            save(remaining)
        }
    }

    private func save(_ pending: [SharedCaptureItem]) {
        guard let data = try? JSONEncoder().encode(pending),
              let value = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(value, forKey: storageKey)
    }

    private func itemURL(id: String, in directory: URL) -> URL {
        let name = SHA256.hash(data: Data(id.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("\(name).json", isDirectory: false)
    }
}

@MainActor public enum SharedCaptureProcessor {
    public static func process(
        inbox: SharedCaptureInbox,
        handle: @MainActor (SharedCaptureItem) async -> Bool
    ) async {
        while let item = inbox.pendingItems().first {
            guard await handle(item) else { return }
            inbox.acknowledge(id: item.id)
        }
    }
}

@MainActor public enum ShortcutCapture {
    @discardableResult public static func enqueue(
        _ text: String,
        inbox: SharedCaptureInbox = .shared,
        id: String = UUID().uuidString.lowercased()
    ) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        inbox.enqueueText(text, id: id)
        return true
    }
}

public enum SharedCaptureStorage {
    public static let appGroupIdentifier = "group.com.logseq.logseq"

    public static var sharedDirectory: URL {
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SharedCapture", isDirectory: true)
    }

    public static var queueDirectory: URL {
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SharedCaptureQueue", isDirectory: true)
    }
}

public struct ImportedSharedCaptureAsset: Sendable, Equatable {
    public let title: String
    public let assetType: String
    public let size: Int
    public let checksum: String
    public let localPath: String
}

public enum SharedCaptureAssetError: Error, Equatable {
    case missingStagedFile
    case invalidSize
    case invalidChecksum
}

public enum SharedCaptureAssetStager {
    public static func stage(
        sourceURL: URL,
        contentType: String,
        sharedDirectory: URL
    ) throws -> SharedCaptureAsset {
        let manager = FileManager.default
        try manager.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        let prepared = LGImageCompression.prepare(try Data(contentsOf: sourceURL),
            title: sourceURL.lastPathComponent, contentType: contentType)
        let title = prepared.title
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
        let safeName = "\(UUID().uuidString.lowercased())-\(safeTitle)"
        let destination = sharedDirectory.appendingPathComponent(safeName, isDirectory: false)
        let data = prepared.data
        try data.write(to: destination, options: .atomic)
        return SharedCaptureAsset(
            title: title,
            assetType: prepared.contentType,
            size: data.count,
            checksum: sha256(data),
            stagedFileName: safeName
        )
    }

    fileprivate static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SharedCaptureAssetImporter {
    public static func importAsset(
        _ asset: SharedCaptureAsset,
        sharedDirectory: URL,
        documentsDirectory: URL
    ) throws -> ImportedSharedCaptureAsset {
        let manager = FileManager.default
        let assetsDirectory = documentsDirectory.appendingPathComponent("Assets", isDirectory: true)
        try manager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        let destinationName = asset.stagedFileName
        let destination = assetsDirectory.appendingPathComponent(destinationName, isDirectory: false)
        let source = sharedDirectory.appendingPathComponent(asset.stagedFileName, isDirectory: false)

        if manager.fileExists(atPath: destination.path) {
            try validate(destination, against: asset)
            if manager.fileExists(atPath: source.path) {
                try manager.removeItem(at: source)
            }
        } else {
            guard manager.fileExists(atPath: source.path) else {
                throw SharedCaptureAssetError.missingStagedFile
            }
            try validate(source, against: asset)
            try manager.copyItem(at: source, to: destination)
            try manager.removeItem(at: source)
        }
        return ImportedSharedCaptureAsset(
            title: asset.title,
            assetType: asset.assetType,
            size: asset.size,
            checksum: asset.checksum,
            localPath: "Assets/\(destinationName)"
        )
    }

    private static func validate(_ file: URL, against asset: SharedCaptureAsset) throws {
        let data = try Data(contentsOf: file)
        guard data.count == asset.size else { throw SharedCaptureAssetError.invalidSize }
        guard SharedCaptureAssetStager.sha256(data) == asset.checksum else {
            throw SharedCaptureAssetError.invalidChecksum
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
