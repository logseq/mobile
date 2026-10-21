import Foundation
import LogseqCoreABI

public struct LogseqGraphSnapshotArtifact: Sendable {
    public let metadataBody: String
    public let filePath: String
}

struct LogseqBootstrapPlan: Decodable {
    let kind: String
    let generation: Int?
    let syncAllowed: Bool?
    let isEncrypted: Bool
}
struct LogseqBootstrapEnvelope: Decodable {
    struct Result: Decodable { let graphBootstrap: LogseqBootstrapPlan? }
    let result: Result?
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


public enum LogseqGraphSyncHTTP {
    private struct Plan: Decodable { let metadataURL: String }
    private struct Download: Decodable { let metadataBody: String; let downloadURL: String; let contentEncoding: String }
    private struct Response<T: Decodable>: Decodable { let ok: Bool; let result: T?; let error: LogseqCoreError? }

    private static func shared<T: Decodable>(_ action: String, _ fields: [String: String], callCore: @Sendable (String) async -> String, as type: T.Type) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: fields)
        let request = LogseqRPCRequest(method: "dispatch", params: LogseqRPCParams(
            action: action, payload: String(decoding: body, as: UTF8.self)))
        let raw = await callCore(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        let response = try JSONDecoder().decode(Response<T>.self, from: Data(raw.utf8))
        guard response.ok, let result = response.result else {
            throw NSError(domain: "LogseqSnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: response.error?.message ?? "The shared core rejected the snapshot download"])
        }
        return result
    }

    private static func request(_ url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    public static func downloadSnapshot(
        baseURL: String, graphID: String, accessToken: String,
        graphSchemaVersion: String? = nil,
        progress: @escaping @Sendable (String) async -> Void = { _ in },
        callCore: @escaping @Sendable (String) async -> String = { request in
            await LogseqCore.performUIAsync { LogseqCore.shared.logseq_call(request) }
        }
    ) async throws -> LogseqGraphSnapshotArtifact {
        await progress("preparing")
        let plan = try await shared("snapshotDownloadPlan", ["baseUrl": baseURL, "graphId": graphID], callCore: callCore, as: Plan.self)
        guard let metadataURL = URL(string: plan.metadataURL) else {
            throw URLError(.badURL)
        }
        let (metadataData, metadataResponse) = try await URLSession.shared.data(for: request(metadataURL, accessToken: accessToken))
        try requireSuccess(metadataResponse)
        let resolved = try await shared("resolveSnapshotDownload", [
            "metadataBody": String(decoding: metadataData, as: UTF8.self),
            "graphSchemaVersion": graphSchemaVersion ?? ""
        ], callCore: callCore, as: Download.self)
        guard let downloadURL = URL(string: resolved.downloadURL, relativeTo: metadataURL) else { throw URLError(.badURL) }
        await progress("downloading")
        let (temporaryURL, downloadResponse) = try await URLSession.shared.download(for: request(downloadURL.absoluteURL, accessToken: accessToken))
        try requireSuccess(downloadResponse)
        let ownedDownloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-graph-\(UUID().uuidString).download")
        try FileManager.default.moveItem(at: temporaryURL, to: ownedDownloadURL)
        do {
            await progress("decoding")
            let snapshotURL = try decodeSnapshotFile(
                at: ownedDownloadURL,
                contentEncoding: resolved.contentEncoding
            )
            if snapshotURL != ownedDownloadURL {
                try? FileManager.default.removeItem(at: ownedDownloadURL)
            }
            return LogseqGraphSnapshotArtifact(metadataBody: resolved.metadataBody, filePath: snapshotURL.path)
        } catch {
            try? FileManager.default.removeItem(at: ownedDownloadURL)
            throw error
        }
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
