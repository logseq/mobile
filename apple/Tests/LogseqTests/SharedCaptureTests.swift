import Foundation
import Testing
@testable import Logseq
import LogseqModel

@Suite struct SharedCaptureTests {
    @Test func formatsSharedTextAndLinkAsOneJournalBlock() {
        #expect(SharedCapturePayload(
            text: "A useful excerpt",
            title: "Example",
            url: "https://example.com/article"
        ).blockText == "A useful excerpt\n[Example](https://example.com/article)")
    }

    @Test func usesTheURLWhenAShareHasNoUsefulTitle() {
        #expect(SharedCapturePayload(
            text: nil,
            title: "https://example.com/article",
            url: "https://example.com/article"
        ).blockText == "https://example.com/article")
    }

    @Test func parsesTheAppCaptureURLWithoutTreatingPlusAsSpace() throws {
        let url = try #require(URL(string:
            "logseq://capture?text=C%2B%2B&title=Video&url=https%3A%2F%2Fyoutu.be%2Fabc"
        ))

        #expect(SharedCapturePayload(captureURL: url)?.blockText
            == "C++\n[Video](https://youtu.be/abc)")
    }

    @Test func duplicateCaptureParametersUseTheLastNonEmptyValue() throws {
        let url = try #require(URL(string:
            "logseq://capture?text=old&text=&text=new&title=Example"
        ))

        #expect(SharedCapturePayload(captureURL: url)?.blockText == "new\nExample")
    }

    @Test func distinguishesWidgetCaptureFromPopulatedQuickCaptureLinks() throws {
        let widgetURL = try #require(URL(string: "logseq://capture"))
        let populatedURL = try #require(URL(string: "logseq://capture?text=From%20widget"))
        let unrelatedURL = try #require(URL(string: "logseq://journal"))

        #expect(LogseqDeepLink(URL(string: "logseq://audio")!) == .openAudio)
        #expect(LogseqDeepLink(widgetURL) == .openCapture)
        #expect(LogseqDeepLink(populatedURL) == .captureText("From widget"))
        #expect(LogseqDeepLink(unrelatedURL) == .openJournal)
    }

    @Test func normalizesAndroidSharedURLsIntoMarkdownLinks() {
        #expect(SharedCapturePayload(sharedText: "https://example.com/article", title: "Example").blockText
            == "[Example](https://example.com/article)")
        #expect(SharedCapturePayload(sharedText: "A useful excerpt", title: "Example").blockText
            == "A useful excerpt\nExample")
    }

    @Test @MainActor func durableInboxDrainsEachCaptureExactlyOnce() {
        let suiteName = "SharedCaptureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let inbox = SharedCaptureInbox(defaults: defaults)

        inbox.enqueue(.text(id: "first", text: "First"))
        inbox.enqueue(.text(id: "second", text: "Second"))

        #expect(inbox.pendingItems() == [
            .text(id: "first", text: "First"),
            .text(id: "second", text: "Second")
        ])
        inbox.acknowledge(id: "first")
        #expect(inbox.pendingItems() == [.text(id: "second", text: "Second")])
        inbox.acknowledge(id: "second")
        #expect(inbox.pendingItems().isEmpty)
    }

    @Test @MainActor func durableInboxPreservesSharedAssetMetadata() throws {
        let suiteName = "SharedCaptureAssetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let inbox = SharedCaptureInbox(defaults: defaults)
        let asset = SharedCaptureAsset(
            title: "Voice note.m4a",
            assetType: "audio/mp4",
            size: 42,
            checksum: "abc123",
            stagedFileName: "voice-note.m4a"
        )

        inbox.enqueue(.asset(id: "asset-1", asset: asset))

        #expect(inbox.pendingItems() == [.asset(id: "asset-1", asset: asset)])
        inbox.acknowledge(id: "asset-1")
        #expect(inbox.pendingItems().isEmpty)
    }

    @Test @MainActor func appGroupFileInboxIsVisibleAcrossProcesses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-capture-inbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SharedCaptureInbox(directory: directory)
        let reader = SharedCaptureInbox(directory: directory)

        writer.enqueue(.text(id: "cross-process", text: "Shared text"))

        #expect(reader.pendingItems() == [
            .text(id: "cross-process", text: "Shared text")
        ])
        reader.acknowledge(id: "cross-process")
        #expect(writer.pendingItems().isEmpty)
    }

    @Test @MainActor func shortcutCaptureQueuesTrimmedTextForTheJournal() {
        let suiteName = "ShortcutCaptureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let inbox = SharedCaptureInbox(defaults: defaults)

        #expect(ShortcutCapture.enqueue("  Remember this  ", inbox: inbox, id: "shortcut-1"))
        #expect(inbox.pendingItems() == [.text(id: "shortcut-1", text: "Remember this")])
        #expect(!ShortcutCapture.enqueue("  \n", inbox: inbox, id: "shortcut-2"))
        #expect(inbox.pendingItems().count == 1)
    }

    @Test @MainActor func processorStopsAtFailureAndRetriesWithoutReordering() async {
        let suiteName = "SharedCaptureProcessorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let inbox = SharedCaptureInbox(defaults: defaults)
        inbox.enqueue(.text(id: "first", text: "First"))
        inbox.enqueue(.text(id: "second", text: "Second"))
        var attempts: [String] = []

        await SharedCaptureProcessor.process(inbox: inbox) { item in
            attempts.append(item.id)
            return item.id != "first"
        }

        #expect(attempts == ["first"])
        #expect(inbox.pendingItems().map(\.id) == ["first", "second"])

        await SharedCaptureProcessor.process(inbox: inbox) { item in
            attempts.append(item.id)
            return true
        }

        #expect(attempts == ["first", "first", "second"])
        #expect(inbox.pendingItems().isEmpty)
    }

    @Test func stagesBinaryAssetsWithStableMetadataAndImportsThemIntoDocuments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-capture-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let sharedDirectory = root.appendingPathComponent("shared", isDirectory: true)
        let documentsDirectory = root.appendingPathComponent("documents", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("Voice note.m4a")
        try Data("abc".utf8).write(to: source)

        let asset = try SharedCaptureAssetStager.stage(
            sourceURL: source,
            contentType: "audio/mp4",
            sharedDirectory: sharedDirectory
        )

        #expect(asset.title == "Voice note.m4a")
        #expect(asset.assetType == "audio/mp4")
        #expect(asset.size == 3)
        #expect(asset.checksum == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(!asset.stagedFileName.contains("/"))
        #expect(FileManager.default.fileExists(
            atPath: sharedDirectory.appendingPathComponent(asset.stagedFileName).path
        ))

        let imported = try SharedCaptureAssetImporter.importAsset(
            asset,
            sharedDirectory: sharedDirectory,
            documentsDirectory: documentsDirectory
        )

        #expect(imported.title == asset.title)
        #expect(imported.assetType == asset.assetType)
        #expect(imported.size == asset.size)
        #expect(imported.checksum == asset.checksum)
        #expect(imported.localPath.hasPrefix("Assets/"))
        #expect(try Data(contentsOf: documentsDirectory.appendingPathComponent(imported.localPath))
            == Data("abc".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: sharedDirectory.appendingPathComponent(asset.stagedFileName).path
        ))
    }

    @Test func missingStagedAssetFailsWithoutInventingAFile() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-shared-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = SharedCaptureAsset(
            title: "Missing.png",
            assetType: "image/png",
            size: 3,
            checksum: "checksum",
            stagedFileName: "missing.png"
        )

        #expect(throws: (any Error).self) {
            try SharedCaptureAssetImporter.importAsset(
                asset,
                sharedDirectory: root.appendingPathComponent("shared"),
                documentsDirectory: root.appendingPathComponent("documents")
            )
        }
    }
}
