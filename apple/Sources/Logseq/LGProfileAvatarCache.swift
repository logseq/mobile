import CryptoKit
import ImageIO
import UIKit

// Each sandbox can keep its own disposable copy, including the notification service extension.
enum LGProfileAvatarCache {
    private static let lifetime: TimeInterval = 3600
    private static let byteLimit = 128 * 1024
    private static let entryLimit = 64
    private static let profileBucket = "logseq-user-public-metadata-bucket-prod"
    private static let hosts = [
        "assets.logseq.com", "assets.logseq.io", "avatars.githubusercontent.com", "lh3.googleusercontent.com",
    ]

    static func isProfileBucketHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "\(profileBucket).s3.amazonaws.com" { return true }
        let prefix = "\(profileBucket).s3."
        let suffix = ".amazonaws.com"
        guard host.hasPrefix(prefix), host.hasSuffix(suffix) else { return false }
        let region = host.dropFirst(prefix.count).dropLast(suffix.count)
        return !region.isEmpty && region.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
        }
    }

    @concurrent static func image(at url: URL) async -> UIImage? {
        guard supports(url) else { return nil }
        let file = fileURL(for: url)
        let resource = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let cached: UIImage? = if let size = resource?.fileSize, (1...byteLimit).contains(size),
                                   let data = try? Data(contentsOf: file) { thumbnail(data) } else { nil }
        let modified = resource?.contentModificationDate
        let mustRevalidate = url.host.map(isProfileBucketHost) == true
        if let cached, let modified, !mustRevalidate, Date().timeIntervalSince(modified) < lifetime { return cached }
        if let result = await download(url, since: cached == nil ? nil : modified) {
            if result.notModified {
                touch(file)
                return cached
            }
            if let data = result.data, let image = thumbnail(data) {
                store(data, for: url)
                return image
            }
        }
        return cached
    }

    static func store(_ data: Data, for url: URL) {
        guard supports(url), (1...byteLimit).contains(data.count) else { return }
        let file = fileURL(for: url)
        let directory = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            for (expired, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(entryLimit) {
                try? FileManager.default.removeItem(at: expired)
            }
        } catch {
            // A full or cleared cache should not keep an avatar from being displayed.
        }
    }

    private static func supports(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return url.scheme == "https" && (hosts.contains(host) || isProfileBucketHost(host))
            && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil
    }

    private static func fileURL(for url: URL) -> URL {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL.cachesDirectory.appending(path: "ProfileAvatars").appending(path: key)
    }

    private static func thumbnail(_ data: Data) -> UIImage? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: thumbnail)
    }

    private static func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    private static func download(_ url: URL, since modified: Date?) async -> (data: Data?, notModified: Bool)? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoAvatarRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        if let modified { request.setValue(httpDate(modified), forHTTPHeaderField: "If-Modified-Since") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { return nil }
            if response.statusCode == 304 { return (nil, true) }
            guard response.statusCode == 200,
                  response.expectedContentLength <= byteLimit, response.mimeType?.hasPrefix("image/") == true else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < byteLimit else { return nil }
                data.append(byte)
            }
            return (data, false)
        } catch {
            return nil
        }
    }
}

private final class NoAvatarRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
