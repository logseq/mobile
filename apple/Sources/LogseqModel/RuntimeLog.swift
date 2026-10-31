import Foundation

public enum LogseqRuntimeLogLevel: String, Codable, Hashable, Sendable {
    case debug
    case info
    case error
}

public enum LogseqRuntimeLogSource: String, Codable, Hashable, Sendable {
    case ui
    case core
}

public struct LogseqRuntimeLogRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: Int
    public let timestampMilliseconds: Int
    public let level: LogseqRuntimeLogLevel
    public let source: LogseqRuntimeLogSource
    public let message: String
}

public final class LogseqRuntimeLog: @unchecked Sendable {
    public static let shared = LogseqRuntimeLog(persistenceURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logseq/last-error.json"), onError: { message in
        Task { @MainActor in LogseqErrorFeedback.shared.receive(message) }
    })

    private let onError: (@Sendable (String) -> Void)?
    private var lastErrorRecord: LogseqRuntimeLogRecord?
    public var lastError: LogseqRuntimeLogRecord? { lock.withLock { lastErrorRecord } }
    private let persistenceURL: URL?
    private let capacity: Int
    private let lock = NSLock()
    private var nextID = 0
    private var storage: [LogseqRuntimeLogRecord] = []

    public init(capacity: Int = 500, persistenceURL: URL? = nil, onError: (@Sendable (String) -> Void)? = nil) {
        self.persistenceURL = persistenceURL
        self.onError = onError
        self.capacity = max(1, capacity)
        if let persistenceURL, let data = try? Data(contentsOf: persistenceURL),
           let record = try? JSONDecoder().decode(LogseqRuntimeLogRecord.self, from: data) {
            lastErrorRecord = record
            nextID = record.id
        }
    }

    public func append(
        level: LogseqRuntimeLogLevel,
        source: LogseqRuntimeLogSource,
        message: String,
        timestampMilliseconds: Int = Int(Date().timeIntervalSince1970 * 1_000)
    ) {
        lock.lock()
        nextID += 1
        storage.append(LogseqRuntimeLogRecord(
            id: nextID,
            timestampMilliseconds: timestampMilliseconds,
            level: level,
            source: source,
            message: message
        ))
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
        if level == .error {
            lastErrorRecord = storage.last
            if let persistenceURL, let data = try? JSONEncoder().encode(lastErrorRecord) {
                try? FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: persistenceURL, options: .atomic)
            }
        }
        lock.unlock()
        if level == .error { onError?(message) }
    }

    public func records(
        source: LogseqRuntimeLogSource? = nil,
        errorsOnly: Bool = false,
        newestFirst: Bool = false
    ) -> [LogseqRuntimeLogRecord] {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        let filtered = snapshot.filter { record in
            (source == nil || record.source == source)
                && (!errorsOnly || record.level == .error)
        }
        return newestFirst ? Array(filtered.reversed()) : filtered
    }

    public func exportText() -> String {
        records().map { record in
            "\(record.timestampMilliseconds) \(record.level.rawValue.uppercased()) \(record.source.rawValue) \(record.message)"
        }.joined(separator: "\n")
    }
}
