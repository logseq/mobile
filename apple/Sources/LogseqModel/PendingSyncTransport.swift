import Foundation

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
                        + "url=\(pending.url) file=\(uploadURL.path) size=\(fileSize?.intValue ?? -1) "
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
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = pending.method
            request.setValue("Bearer \(pending.token)", forHTTPHeaderField: "Authorization")
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
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            if !(200..<300).contains(http.statusCode) {
                LogseqRuntimeLog.shared.append(
                    level: .error,
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
            LogseqRuntimeLog.shared.append(
                level: .error,
                source: .core,
                message: "Pending sync transport failed: \(error)"
            )
            #if DEBUG
            print("LOGSEQ_ASSET_SYNC transport_error id=\(pending.id) error=\(error)")
            #endif
            return LogseqPendingSyncResult(status: nil, body: nil, error: "\(error)")
        }
    }

}
