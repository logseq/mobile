import Foundation

let pendingSyncNetworkUnavailable = "network_unavailable"

func pendingSyncConnectionError(_ error: Error) -> String? {
    switch (error as? URLError)?.code {
    case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
         .cannotFindHost, .dnsLookupFailed, .timedOut, .dataNotAllowed:
        return pendingSyncNetworkUnavailable
    default:
        break
    }
    switch (error as? POSIXError)?.code {
    case .ENOTCONN, .ECONNRESET, .ECONNREFUSED, .ECONNABORTED, .EPIPE,
         .ETIMEDOUT, .ENETDOWN, .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH:
        return pendingSyncNetworkUnavailable
    default:
        return nil
    }
}

func pendingSyncErrorIsOffline(_ message: String) -> Bool {
    // The core may combine several retry failures, some with a resource prefix.
    let reasons = message.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    return !reasons.isEmpty && reasons.allSatisfy {
        if $0 == pendingSyncNetworkUnavailable { return true }
        let parts = $0.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].hasPrefix("Sync server ") &&
            parts[1] == " " + pendingSyncNetworkUnavailable
    }
}

@MainActor final class LogseqPendingWebSocket {
    private let sendFrame: (String) async throws -> Void
    private let closeSocket: () -> Void
    private let url: String
    private var active: (id: Int, attempt: UUID, continuation: CheckedContinuation<LogseqPendingSyncResult, Never>)?
    private var timeout: Task<Void, Never>?
    private var closed = false

    init(url: String, sendFrame: @escaping (String) async throws -> Void, close: @escaping () -> Void) {
        self.sendFrame = sendFrame
        closeSocket = close
        self.url = url
    }

    func send(_ request: LogseqPendingSyncRequest) async -> LogseqPendingSyncResult {
        guard !closed, request.url == url, let body = request.body, active == nil else {
            return LogseqPendingSyncResult(status: nil, body: nil, error: pendingSyncNetworkUnavailable)
        }
        let attempt = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                active = (request.id, attempt, continuation)
                timeout = Task {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard active?.attempt == attempt else { return }
                    close()
                }
                Task {
                    do { try await sendFrame(body) }
                    catch {
                        guard active?.attempt == attempt else { return }
                        close(pendingSyncConnectionError(error) ?? error.localizedDescription)
                    }
                }
                if Task.isCancelled { close("WebSocket upload cancelled") }
            }
        } onCancel: {
            Task { @MainActor in
                guard self.active?.attempt == attempt else { return }
                self.close("WebSocket upload cancelled")
            }
        }
    }

    func complete(id: Int, body: String) {
        guard active?.id == id else { return }
        finish(LogseqPendingSyncResult(status: 200, body: body, error: nil))
    }

    func close(_ message: String = pendingSyncNetworkUnavailable) {
        guard !closed else { return }
        closed = true
        closeSocket()
        finish(LogseqPendingSyncResult(status: nil, body: nil, error: message))
    }

    private func finish(_ result: LogseqPendingSyncResult) {
        timeout?.cancel()
        timeout = nil
        let continuation = active?.continuation
        active = nil
        continuation?.resume(returning: result)
    }
}

public enum LogseqPendingSyncFilePath {
    public static func resolve(
        _ path: String,
        documentsDirectory: URL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0],
        fileManager: FileManager = .default
    ) -> URL? {
        guard !path.isEmpty else { return nil }
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : documentsDirectory.appendingPathComponent(path)
        let standardizedURL = url.standardizedFileURL
        return fileManager.fileExists(atPath: standardizedURL.path) ? standardizedURL : nil
    }
}

public enum LogseqPendingSyncHTTPTransport {
    public static func send(_ pending: LogseqPendingSyncRequest) async -> LogseqPendingSyncResult {
        do {
            try Task.checkCancellation()
            guard let url = URL(string: pending.url) else {
                LogseqRuntimeLog.shared.append(
                    level: .error,
                    source: .core,
                    message: "Invalid pending sync URL"
                )
                return LogseqPendingSyncResult(status: nil, body: nil, error: "Invalid pending sync URL")
            }
            let uploadURL: URL?
            if let filePath = pending.filePath {
                guard let resolvedURL = LogseqPendingSyncFilePath.resolve(filePath) else {
                    LogseqRuntimeLog.shared.append(
                        level: .error,
                        source: .core,
                        message: "Pending sync asset file does not exist: \(filePath)"
                    )
                    return LogseqPendingSyncResult(
                        status: nil,
                        body: nil,
                        error: "Pending sync asset file does not exist: \(filePath)"
                    )
                }
                uploadURL = resolvedURL
            } else {
                uploadURL = nil
            }
            #if DEBUG
            if let uploadURL {
                let attributes = try? FileManager.default.attributesOfItem(atPath: uploadURL.path)
                let fileSize = attributes?[.size] as? NSNumber
                print(
                    "LOGSEQ_ASSET_SYNC request id=\(pending.id) method=\(pending.method) "
                        + "host=\(url.host ?? "") path=\(url.path) file=\(uploadURL.path) "
                        + "size=\(fileSize?.intValue ?? -1) "
                        + "content_type=\(pending.contentType)"
                )
            } else {
                print(
                    "LOGSEQ_PENDING_SYNC request id=\(pending.id) method=\(pending.method) "
                        + "url=\(pending.url) body_bytes=\(pending.body?.utf8.count ?? 0) "
                        + "content_type=\(pending.contentType)"
                )
            }
            #endif
            // Image encryption and slow mobile uplinks need a longer transfer
            // budget than the small JSON requests used by the sync protocol.
            var request = URLRequest(url: url, timeoutInterval: uploadURL == nil ? 30 : 120)
            request.httpMethod = pending.method
            if !pending.token.isEmpty {
                request.setValue("Bearer \(pending.token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(pending.contentType, forHTTPHeaderField: "Content-Type")
            for (name, value) in pending.headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let data: Data
            let response: URLResponse
            if let uploadURL {
                (data, response) = try await URLSession.shared.upload(
                    for: request,
                    fromFile: uploadURL
                )
            } else {
                request.httpBody = pending.body.map { Data($0.utf8) }
                (data, response) = try await URLSession.shared.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else {
                return LogseqPendingSyncResult(status: nil, body: nil, error: "Pending sync response was not HTTP")
            }
            let responseBody = pending.token.isEmpty ? "" : String(data: data, encoding: .utf8) ?? ""
            if !(200..<300).contains(http.statusCode) {
                LogseqRuntimeLog.shared.append(
                    level: .info,
                    source: .core,
                    message: "Pending sync HTTP \(http.statusCode): \(responseBody)"
                )
            }
            #if DEBUG
            if pending.filePath != nil
                || !(200..<300).contains(http.statusCode)
                || responseBody.contains("\"type\":\"tx/reject\"")
            {
                print(
                    "LOGSEQ_PENDING_SYNC response id=\(pending.id) status=\(http.statusCode) "
                        + "body=\(responseBody)"
                )
            }
            #endif
            return LogseqPendingSyncResult(
                status: http.statusCode,
                body: responseBody,
                error: nil
            )
        } catch {
            // The shared pump owns retries and reports terminal failures. A
            // single interrupted attempt must not produce a failure toast.
            let message = pending.token.isEmpty
                ? "Asset upload failed (\((error as NSError).code))"
                : String(describing: error)
            LogseqRuntimeLog.shared.append(
                level: .info,
                source: .core,
                message: "Pending sync transport failed: \(message)"
            )
            #if DEBUG
            print("LOGSEQ_ASSET_SYNC transport_error id=\(pending.id) error=\(message)")
            #endif
            return LogseqPendingSyncResult(
                status: nil, body: nil, error: pendingSyncConnectionError(error) ?? message
            )
        }
    }

}
