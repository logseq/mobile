import Foundation

public enum LogseqPendingSyncDuplicateAssetResolver {
    public static func isDuplicate(status: Int, body: String) -> Bool {
        guard status == 409,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["error"] as? String == "asset checksum already exists"
    }

    public static func assetBody(
        matchingChecksum checksum: String,
        listBody: String
    ) throws -> String? {
        guard let data = listBody.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["checksum"] as? String == checksum })
        else { return nil }
        let encoded = try JSONSerialization.data(withJSONObject: asset, options: [.sortedKeys])
        return String(data: encoded, encoding: .utf8)
    }

    static func nextCursor(listBody: String) throws -> String? {
        guard let data = listBody.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["next-cursor"] as? String
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
        await send(pending, retriesRemaining: 2)
    }

    private static func send(_ pending: LogseqPendingSyncRequest, retriesRemaining: Int) async -> LogseqPendingSyncResult {
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
            if uploadURL != nil,
               LogseqPendingSyncDuplicateAssetResolver.isDuplicate(
                   status: http.statusCode,
                   body: responseBody
               ),
               let existingAssetBody = try await existingAssetBody(
                   forUploadURL: url,
                   token: pending.token
               ) {
                return LogseqPendingSyncResult(
                    status: 200,
                    body: existingAssetBody,
                    error: nil
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
            // Reuse the exact request: raw PUTs keep their asset UUID, and journal
            // transactions keep their tx-id and cursor when an acknowledgement is lost.
            if !Task.isCancelled, retriesRemaining > 0,
               let networkError = error as? URLError,
               [.networkConnectionLost, .timedOut, .cannotConnectToHost].contains(networkError.code) {
                do {
                    try await Task.sleep(for: .milliseconds(500 * (3 - retriesRemaining)))
                    return await send(pending, retriesRemaining: retriesRemaining - 1)
                } catch {
                    return LogseqPendingSyncResult(status: nil, body: nil, error: "Pending sync was cancelled")
                }
            }
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

    private static func existingAssetBody(
        forUploadURL uploadURL: URL,
        token: String
    ) async throws -> String? {
        guard let upload = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false),
              let checksum = upload.queryItems?.first(where: { $0.name == "checksum" })?.value
        else { return nil }
        var cursor: String?
        repeat {
            var list = upload
            list.queryItems = [URLQueryItem(name: "limit", value: "100")]
            if let cursor {
                list.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
            }
            guard let listURL = list.url else { return nil }
            var request = URLRequest(url: listURL, timeoutInterval: 30)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let body = String(data: data, encoding: .utf8)
            else { return nil }
            if let asset = try LogseqPendingSyncDuplicateAssetResolver.assetBody(
                matchingChecksum: checksum,
                listBody: body
            ) {
                return asset
            }
            cursor = try LogseqPendingSyncDuplicateAssetResolver.nextCursor(listBody: body)
        } while cursor != nil
        return nil
    }
}
