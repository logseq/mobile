import Foundation

public enum LogseqGraphLocalStorage {
    private static func encodedID(_ graphID: String) -> String {
        graphID.addingPercentEncoding(withAllowedCharacters:
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"))!
    }

    private static func folderName(_ graphName: String) -> String {
        let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var prefix = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in graphName.unicodeScalars {
            let safe = unsafe.contains(scalar) ? Unicode.Scalar("_") : scalar
            let size = String(safe).utf8.count
            guard byteCount + size <= 120 else { break }
            prefix.append(safe)
            byteCount += size
        }
        let name = String(prefix).trimmingCharacters(in:
            CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return name.isEmpty ? "Graph" : name
    }

    public static func directoryURL(databasePath: String, graphID: String, graphName: String = "Graph") -> URL {
        let root = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
            .appendingPathComponent("graphs", isDirectory: true)
        let id = encodedID(graphID)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        if let existing = entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first(where: {
            $0.lastPathComponent.hasSuffix(" - " + id)
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }) { return existing }
        // Older iOS builds percent-encoded hyphens in graph identifiers.
        for legacyID in [graphID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!, id] {
            let legacy = root.appendingPathComponent(legacyID, isDirectory: true)
            if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        }
        return root.appendingPathComponent(folderName(graphName) + " - " + id, isDirectory: true)
    }

    /// Call before opening a graph so its database handles never outlive a directory move.
    public static func prepareDirectoryURL(databasePath: String, graphID: String, graphName: String) throws -> URL {
        let existing = directoryURL(databasePath: databasePath, graphID: graphID, graphName: graphName)
        if existing.lastPathComponent.hasSuffix(" - " + encodedID(graphID)) {
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
            return existing
        }
        let destination = existing.deletingLastPathComponent().appendingPathComponent(
            folderName(graphName) + " - " + encodedID(graphID), isDirectory: true)
        try FileManager.default.moveItem(at: existing, to: destination)
        return destination
    }

    public static func isDownloaded(databasePath: String, graphID: String) -> Bool {
        let directory = directoryURL(databasePath: databasePath, graphID: graphID)
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("graph.sqlite").path
        ) && FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("sync.checkpoint").path
        )
    }

    public static func delete(databasePath: String, graphID: String) throws {
        let directory = directoryURL(databasePath: databasePath, graphID: graphID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
