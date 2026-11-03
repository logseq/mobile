import Foundation
import CryptoKit
import UniformTypeIdentifiers

struct LGImportedAsset: Sendable {
    let title: String
    let assetType: String
    let size: Int
    let checksum: String
    let path: String
}

struct LGStagedAssetPayload: Encodable {
    let uuid: String
    let title: String
    let now: Int64
    let assetType: String
    let assetSize: Int
    let assetChecksum: String
    let localPath: String
    let targetBlockId: String?
    let transcript: String?
    let transcriptUUID: String?

    init(_ asset: LGImportedAsset, targetBlockID: String? = nil, transcript: String? = nil) {
        uuid = UUID().uuidString.lowercased()
        title = asset.title
        now = Int64(Date().timeIntervalSince1970 * 1_000)
        assetType = asset.assetType
        assetSize = asset.size
        assetChecksum = asset.checksum
        localPath = LocalAssetPath.storedPath(asset.path)
        targetBlockId = targetBlockID
        self.transcript = transcript
        transcriptUUID = transcript == nil ? nil : UUID().uuidString.lowercased()
    }
}

enum LGAssetImporter {
    nonisolated static func persist(_ sourceURL: URL) async throws -> LGImportedAsset {
        try await Task.detached(priority: .utility) {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
            if UTType(filenameExtension: sourceURL.pathExtension)?.conforms(to: .image) == true {
                return try await persist(data: Data(contentsOf: sourceURL), title: sourceURL.lastPathComponent)
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("logseq-asset-imports", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent(
                UUID().uuidString + "-" + sourceURL.lastPathComponent
            )
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let handle = try FileHandle(forReadingFrom: destination)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hash.update(data: chunk)
            }
            let checksum = hash.finalize().map { String(format: "%02x", $0) }.joined()
            return LGImportedAsset(
                title: sourceURL.lastPathComponent,
                assetType: destination.pathExtension.lowercased(),
                size: size,
                checksum: checksum,
                path: destination.path
            )
        }.value
    }

    nonisolated static func persist(
        data: Data,
        title: String
    ) async throws -> LGImportedAsset {
        try await Task.detached(priority: .utility) {
            let prepared = LGImageCompression.prepare(data, title: title,
                contentType: UTType(filenameExtension: (title as NSString).pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream")
            let data = prepared.data
            let title = prepared.title
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("logseq-asset-imports", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent(UUID().uuidString + "-" + title)
            try data.write(to: destination, options: .atomic)
            let checksum = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            return LGImportedAsset(
                title: title,
                assetType: destination.pathExtension.lowercased(),
                size: data.count,
                checksum: checksum,
                path: destination.path
            )
        }.value
    }
}

