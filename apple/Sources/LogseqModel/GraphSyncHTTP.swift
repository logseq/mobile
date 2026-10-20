import Foundation
import LogseqCoreABI

public struct LogseqGraphSnapshotArtifact: Sendable {
    public let metadataBody: String
    public let filePath: String
}

struct LogseqSyncTransport: Decodable {
    struct Command: Decodable {
        let type: String
        let url: String?
        let body: String?
        let delayMs: Int?
    }

    let generation: Int
    let graphId: String
    let error: String?
    let commands: [Command]
}

struct LogseqSyncTransportEnvelope: Decodable {
    struct Result: Decodable {
        let syncTransport: LogseqSyncTransport?
        let pendingSyncError: String?
    }
    let result: Result?
}

struct LogseqSyncTransportEvent: Encodable {
    let generation: Int
    let graphId: String
    let type: String
    var body: String? = nil
    var message: String? = nil
}

final class LogseqSocketCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var cancelled = false

    func install(_ socket: URLSessionWebSocketTask) {
        lock.lock()
        defer { lock.unlock() }
        self.socket = socket
        if cancelled { socket.cancel(with: .goingAway, reason: nil) }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        socket?.cancel(with: .goingAway, reason: nil)
    }
}

public enum LogseqGraphWebSocketFailurePolicy {
    public static func userFacingMessage(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        switch urlError.code {
        case .timedOut:
            return "The sync server timed out. Check that it is running and reachable, then try again."
        case .notConnectedToInternet:
            return "No network connection. Sync will resume automatically when the network is available."
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost:
            return "The sync server is unreachable. Check that it is running and reachable."
        case .badURL, .unsupportedURL:
            return "The sync server address is invalid."
        default:
            return urlError.localizedDescription
        }
    }
}


public enum LogseqGraphSnapshotRefreshPolicy {
    public static func shouldApplyDownloadedSnapshot(
        forceSnapshot: Bool,
        isEditingOutlinerBlock: Bool,
        hasPendingLocalChanges: Bool
    ) -> Bool {
        _ = hasPendingLocalChanges
        return !forceSnapshot || !isEditingOutlinerBlock
    }
}

public enum LogseqOutlinerAutosavePolicy {
    public static func serverSyncDelayNanoseconds(eventType: String) -> UInt64 {
        switch eventType {
        case "textChanged", "returnPressed", "backspacePressed":
            return UInt64(1_000_000_000)
        default:
            return UInt64(150_000_000)
        }
    }
}

public enum LogseqPendingSyncPumpPolicy {
    public static func shouldRestartAfterFinishing(
        requestedWhileFinishing: Bool
    ) -> Bool {
        requestedWhileFinishing
    }
}

public enum LogseqGraphSyncHTTP {
    private static func apiRoot(_ baseURL: String) throws -> URL {
        guard var root = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw URLError(.badURL)
        }
        if root.path.hasSuffix("/api") {
            root.deleteLastPathComponent()
        }
        return root
    }

    public static func snapshotMetadataRequest(
        baseURL: String, graphID: String, accessToken: String
    ) throws -> URLRequest {
        let root = try apiRoot(baseURL)
        let url = root
            .appendingPathComponent("sync")
            .appendingPathComponent(graphID)
            .appendingPathComponent("snapshot")
            .appendingPathComponent("download")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    public static func snapshotCursorRequest(
        baseURL: String, graphID: String, accessToken: String
    ) throws -> URLRequest {
        let endpoint = try apiRoot(baseURL)
            .appendingPathComponent("sync")
            .appendingPathComponent(graphID)
            .appendingPathComponent("pull")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        // Read only the watermark, matching dev's snapshot bootstrap.
        components.queryItems = [URLQueryItem(name: "since", value: "9007199254740991")]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    public static func downloadSnapshot(
        baseURL: String, graphID: String, accessToken: String,
        graphSchemaVersion: String? = nil,
        progress: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> LogseqGraphSnapshotArtifact {
        await progress("preparing")
        let metadataRequest = try snapshotMetadataRequest(
            baseURL: baseURL, graphID: graphID, accessToken: accessToken
        )
        let cursorRequest = try snapshotCursorRequest(
            baseURL: baseURL, graphID: graphID, accessToken: accessToken
        )
        let (cursorData, cursorResponse) = try await URLSession.shared.data(for: cursorRequest)
        try requireSuccess(cursorResponse)
        let (metadataData, metadataResponse) = try await URLSession.shared.data(for: metadataRequest)
        try requireSuccess(metadataResponse)
        let metadata = try JSONDecoder().decode(SnapshotDownloadMetadata.self, from: metadataData)
        guard metadata.ok, let downloadURL = URL(string: metadata.url, relativeTo: metadataRequest.url) else {
            throw URLError(.cannotParseResponse)
        }
        var downloadRequest = URLRequest(url: downloadURL.absoluteURL)
        downloadRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        await progress("downloading")
        let (temporaryURL, downloadResponse) = try await URLSession.shared.download(for: downloadRequest)
        try requireSuccess(downloadResponse)
        guard let snapshotMetadataBody = String(data: metadataData, encoding: .utf8),
              let pullBody = String(data: cursorData, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        let metadataBody = try importMetadataBody(
            snapshotMetadataBody: snapshotMetadataBody,
            pullBody: pullBody,
            rowCount: nil,
            graphSchemaVersion: graphSchemaVersion
        )
        let ownedDownloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-graph-\(UUID().uuidString).download")
        try FileManager.default.moveItem(at: temporaryURL, to: ownedDownloadURL)
        do {
            await progress("decoding")
            let snapshotURL = try decodeSnapshotFile(
                at: ownedDownloadURL,
                contentEncoding: metadata.contentEncoding
            )
            if snapshotURL != ownedDownloadURL {
                try? FileManager.default.removeItem(at: ownedDownloadURL)
            }
            return LogseqGraphSnapshotArtifact(metadataBody: metadataBody, filePath: snapshotURL.path)
        } catch {
            try? FileManager.default.removeItem(at: ownedDownloadURL)
            throw error
        }
    }

    static func importMetadataBody(
        snapshotMetadataBody: String,
        pullBody: String,
        rowCount: Int?,
        graphSchemaVersion: String? = nil
    ) throws -> String {
        guard rowCount.map({ $0 >= 0 }) ?? true,
              var metadata = try JSONSerialization.jsonObject(
                with: Data(snapshotMetadataBody.utf8)
              ) as? [String: Any],
              metadata["ok"] as? Bool == true,
              let pull = try JSONSerialization.jsonObject(
                with: Data(pullBody.utf8)
              ) as? [String: Any],
              pull["type"] as? String == "pull/ok",
              let cursor = pull["t"] as? Int,
              cursor >= 0 else {
            throw URLError(.cannotParseResponse)
        }
        // The sync API supplies the schema in the graph catalog; newer servers
        // can also include it in the snapshot metadata.
        let schemaVersion = [metadata["schema-version"] as? String, graphSchemaVersion]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        metadata["schema-version"] = schemaVersion
        metadata["t"] = cursor
        // Row count is optional; the native importer validates the framed
        // stream and restored DataScript root without server extensions.
        metadata["row-count"] = rowCount
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return result
    }

    static func decodeSnapshotFile(at inputURL: URL, contentEncoding: String?) throws -> URL {
        if let contentEncoding {
            let normalizedEncoding = contentEncoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalizedEncoding == "identity" || normalizedEncoding == "gzip" else {
                throw SnapshotDecodingError.unsupportedEncoding(contentEncoding)
            }
        }

        // HTTP decoding and snapshot compression are separate layers. Inspect
        // the downloaded bytes to determine whether a gzip layer remains.
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        guard try input.read(upToCount: 2) == Data([0x1F, 0x8B]) else { return inputURL }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-graph-\(UUID().uuidString).snapshot")
        let result = inputURL.path.withCString { inputPath in
            outputURL.path.withCString { outputPath in
                logseq_gunzip_file(inputPath, outputPath)
            }
        }
        guard result == 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw SnapshotDecodingError.gzipFailed(result)
        }
        return outputURL
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private struct SnapshotDownloadMetadata: Decodable {
        let ok: Bool
        let url: String
        let contentEncoding: String?

        private enum CodingKeys: String, CodingKey {
            case ok
            case url
            case contentEncoding = "content-encoding"
        }
    }

    private enum SnapshotDecodingError: LocalizedError {
        case unsupportedEncoding(String)
        case gzipFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .unsupportedEncoding(let encoding):
                return "Unsupported snapshot content encoding: \(encoding)"
            case .gzipFailed(let code):
                return "Could not decompress gzip snapshot (zlib error \(code))"
            }
        }
    }
}
