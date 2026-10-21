import Foundation
import Testing
@testable import LogseqModel

@Suite struct GraphLocalStorageTests {
    @Test func graphDirectoryMatchesTheSnapshotStorageLayout() {
        let databasePath = "/tmp/logseq/catalog.sqlite"

        let directory = LogseqGraphLocalStorage.directoryURL(
            databasePath: databasePath,
            graphID: "graph id/一"
        )

        #expect(directory.path == "/tmp/logseq/graphs/Graph - graph%20id%2F%E4%B8%80")
    }

    @Test func namedGraphDirectoriesAreFoundByID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let named = root.appendingPathComponent("graphs/我的 Notes - graph-1")
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        try Data().write(to: named.appendingPathComponent("graph.sqlite"))
        try Data().write(to: named.appendingPathComponent("sync.checkpoint"))
        let database = root.appendingPathComponent("logseq.sqlite").path
        #expect(LogseqGraphLocalStorage.directoryURL(databasePath: database, graphID: "graph-1").resolvingSymlinksInPath().path == named.resolvingSymlinksInPath().path)
        #expect(LogseqGraphLocalStorage.isDownloaded(databasePath: database, graphID: "graph-1"))
        try LogseqGraphLocalStorage.delete(databasePath: database, graphID: "graph-1")
        #expect(!FileManager.default.fileExists(atPath: named.path))
    }

    @Test func namedDirectoriesMigrateLegacyDataWithoutChangingGraphIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("logseq.sqlite").path
        let old = root.appendingPathComponent("graphs/graph%2D1")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("database".utf8).write(to: old.appendingPathComponent("graph.sqlite"))
        try Data("checkpoint".utf8).write(to: old.appendingPathComponent("sync.checkpoint"))
        try Data("pending".utf8).write(to: old.appendingPathComponent("projection.sqlite"))
        let directory = try LogseqGraphLocalStorage.prepareDirectoryURL(
            databasePath: database, graphID: "graph-1", graphName: "我的/Notes: Work")
        #expect(directory.lastPathComponent == "我的_Notes_ Work - graph-1")
        #expect(try String(contentsOf: directory.appendingPathComponent("projection.sqlite"), encoding: .utf8) == "pending")
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(LogseqGraphLocalStorage.isDownloaded(databasePath: database, graphID: "graph-1"))
        #expect(try LogseqGraphLocalStorage.prepareDirectoryURL(
            databasePath: database, graphID: "graph-1", graphName: "Renamed").resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)
        let empty = try LogseqGraphLocalStorage.prepareDirectoryURL(
            databasePath: database, graphID: "other", graphName: " .. ")
        #expect(empty.lastPathComponent == "Graph - other")
        #expect(empty.deletingLastPathComponent().lastPathComponent == "graphs")
        let long = try LogseqGraphLocalStorage.prepareDirectoryURL(
            databasePath: database, graphID: "long", graphName: String(repeating: "😀我的", count: 100))
        #expect(long.lastPathComponent.utf8.count <= 255)
    }

    @Test func downloadedGraphRequiresBothDatabaseAndCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-graph-storage-\(UUID().uuidString)", isDirectory: true)
        let databasePath = root.appendingPathComponent("catalog.sqlite").path
        let directory = LogseqGraphLocalStorage.directoryURL(
            databasePath: databasePath,
            graphID: "graph-1"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!LogseqGraphLocalStorage.isDownloaded(databasePath: databasePath, graphID: "graph-1"))
        try Data().write(to: directory.appendingPathComponent("graph.sqlite"))
        #expect(!LogseqGraphLocalStorage.isDownloaded(databasePath: databasePath, graphID: "graph-1"))
        try Data().write(to: directory.appendingPathComponent("sync.checkpoint"))
        #expect(LogseqGraphLocalStorage.isDownloaded(databasePath: databasePath, graphID: "graph-1"))
    }

    @Test func deletingALocalGraphRemovesOnlyItsDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-graph-delete-\(UUID().uuidString)", isDirectory: true)
        let databasePath = root.appendingPathComponent("catalog.sqlite").path
        let target = LogseqGraphLocalStorage.directoryURL(databasePath: databasePath, graphID: "target")
        let neighbor = LogseqGraphLocalStorage.directoryURL(databasePath: databasePath, graphID: "neighbor")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try LogseqGraphLocalStorage.delete(databasePath: databasePath, graphID: "target")

        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(FileManager.default.fileExists(atPath: neighbor.path))
        try LogseqGraphLocalStorage.delete(databasePath: databasePath, graphID: "target")
    }
}
