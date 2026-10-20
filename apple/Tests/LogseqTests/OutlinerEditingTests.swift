import CoreGraphics
import Foundation
@testable import LogseqModel
import Testing
@testable import Logseq

@Suite struct OutlinerEditingTests {
    @Test func keyboardHideDiagnosticsSpanInlineEditorHandoffs() {
        var counter = OutlinerKeyboardHideCounter()

        counter.editorAppeared(id: "first")
        counter.keyboardWillHide()
        #expect(counter.hideCount == 1)

        counter.editorDisappeared(id: "first")
        #expect(counter.hasPendingHandoff)
        counter.editorAppeared(id: "second")
        #expect(counter.hideCount == 1)

        counter.keyboardWillHide()
        #expect(counter.hideCount == 2)
        counter.editorDisappeared(id: "second")
        counter.finishPendingHandoff()
        #expect(!counter.isEditing)

        counter.editorAppeared(id: "third")
        #expect(counter.hideCount == 0)
    }

    @Test func keyboardHideDiagnosticsCountHidesDuringPendingHandoffs() {
        var counter = OutlinerKeyboardHideCounter()

        counter.editorAppeared(id: "first")
        counter.editorDisappeared(id: "first")
        counter.keyboardWillHide()

        #expect(counter.hideCount == 1)
        counter.finishPendingHandoff()
        counter.keyboardWillHide()
        #expect(counter.hideCount == 1)
    }

    @Test func typedMarkupLinksUseOneNodeRouteForPagesAndBlocks() throws {
        let pageURL = try #require(OutlinerMarkupLink.node(uuid: "page-uuid").url)
        let blockURL = try #require(OutlinerMarkupLink.node(uuid: "block-uuid").url)
        let tagURL = try #require(OutlinerMarkupLink.node(uuid: "tag-uuid").url)

        #expect(OutlinerMarkupLink(url: pageURL) == .node(uuid: "page-uuid"))
        #expect(OutlinerMarkupLink(url: blockURL) == .node(uuid: "block-uuid"))
        #expect(OutlinerMarkupLink(url: tagURL) == .node(uuid: "tag-uuid"))
        #expect(OutlinerMarkupLink(url: URL(string: "logseq-tag://tag-uuid")!) == nil)
        #expect(OutlinerMarkupLink(url: URL(string: "https://logseq.com")!) == nil)
    }

    @Test func typedMarkupLinksRejectIncompleteOrUnsupportedRoutes() throws {
        #expect(OutlinerMarkupLink(url: try #require(URL(string: "logseq-node:?kind=page"))) == nil)
        #expect(OutlinerMarkupLink(url: try #require(URL(string: "logseq-node://node"))) == .node(uuid: "node"))
        #expect(OutlinerMarkupLink(url: try #require(
            URL(string: "logseq-node://node?kind=object")
        )) == .node(uuid: "node"))
    }

    @Test func outlineDepthGridAlignsGuidesWithAncestorBullets() {
        #expect(OutlinerLayoutMetrics.outerHorizontalInset == 8)
        #expect(OutlinerLayoutMetrics.rootBulletCenterX == 12)
        #expect(OutlinerLayoutMetrics.bulletCenterX(depth: 0) == 12)
        #expect(OutlinerLayoutMetrics.bulletCenterX(depth: 1) == 34)
        #expect(OutlinerLayoutMetrics.guideCenterX(level: 0) == 12)
        #expect(OutlinerLayoutMetrics.guideCenterX(level: 1) == 34)
    }

    @Test func blockTitleAndBulletShareOneStableFirstLineHeight() {
        #expect(OutlinerLayoutMetrics.titleLineHeight == OutlinerLayoutMetrics.bulletHitSize)
        #expect(OutlinerLayoutMetrics.depthSpacerHeight == 0)
        #expect(OutlinerLayoutMetrics.rowVerticalPadding == 5)
        #expect(OutlinerLayoutMetrics.bulletContentSpacing == 2)
    }

    @Test func nativeEditorCentersEmptyAndNonEmptyTextInsideTheSharedFirstLineHeight() {
        #expect(OutlinerNativeTextLayoutPolicy.verticalInset(
            fontLineHeight: 20,
            minimumLineHeight: 24
        ) == 2)
        #expect(OutlinerNativeTextLayoutPolicy.verticalInset(
            fontLineHeight: 24,
            minimumLineHeight: 24
        ) == 0)
        #expect(OutlinerNativeTextLayoutPolicy.verticalInset(
            fontLineHeight: 28,
            minimumLineHeight: 24
        ) == 0)
    }

    @Test func audioRecordingMatchesLogseqMobileLimitsAndFormatting() {
        #expect(AudioRecordingPolicy.maximumDurationSeconds == 600)
        #expect(AudioRecordingPolicy.elapsedTitle(seconds: 0) == "00:00")
        #expect(AudioRecordingPolicy.elapsedTitle(seconds: 599) == "09:59")
        #expect(AudioRecordingPolicy.elapsedTitle(seconds: 600) == "10:00")
        #expect(AudioRecordingPolicy.fileExtension == "m4a")
        #expect(AudioRecordingPolicy.fileName(stamp: "2026-08-22 00-32-18") ==
            "Audio-2026-08-22 00-32-18.m4a")
        #expect(AudioRecordingPolicy.supportsTranscription(iOSMajorVersion: 25) == false)
        #expect(AudioRecordingPolicy.supportsTranscription(iOSMajorVersion: 26))
    }

    @Test func dropZoneMapsOnlyPointerGeometry() {
        #expect(OutlinerDropZone.placement(locationY: 10, rowHeight: 100) == .before)
        #expect(OutlinerDropZone.placement(locationX: 150, locationY: 50, rowHeight: 100) == .inside)
        #expect(OutlinerDropZone.placement(locationY: 90, rowHeight: 100) == .after)
        #expect(OutlinerDropZone.placement(locationY: 0, rowHeight: 0) == .before)
        #expect(OutlinerDropPlacement.before.eventValue == "before")
        #expect(OutlinerDropPlacement.inside.eventValue == "inside")
        #expect(OutlinerDropPlacement.after.eventValue == "after")
    }

    @Test func inlineEditorDoesNotReplaceUnacknowledgedLocalTyping() {
        #expect(InlineEditorTextReconciliationPolicy.decision(
            modelText: "H", localText: "Hello"
        ) == .keepLocal)
        #expect(InlineEditorTextReconciliationPolicy.decision(
            modelText: "Hello", localText: "Hello"
        ) == .acknowledgeLocal)
        #expect(InlineEditorTextReconciliationPolicy.decision(
            modelText: "Remote", localText: nil
        ) == .applyModel)
    }

    @Test func inlineEditorDoesNotEchoProgrammaticCaretChanges() {
        #expect(!InlineEditorCaretEmissionPolicy.shouldEmit(
            textMatchesModel: true,
            isApplyingModel: true
        ))
        #expect(InlineEditorCaretEmissionPolicy.shouldEmit(
            textMatchesModel: true,
            isApplyingModel: false
        ))
        #expect(!InlineEditorCaretEmissionPolicy.shouldEmit(
            textMatchesModel: false,
            isApplyingModel: false
        ))
    }

    @Test func inlineEditorKeepsAFocusRequestPendingUntilAttachment() {
        #expect(InlineEditorFocusPolicy.shouldRequestFocus(
            isAttachedToWindow: true, isFirstResponder: false
        ))
        #expect(InlineEditorFocusPolicy.shouldRequestFocus(
            isAttachedToWindow: false, isFirstResponder: false
        ))
        #expect(!InlineEditorFocusPolicy.shouldRequestFocus(
            isAttachedToWindow: true, isFirstResponder: true
        ))
    }

    @Test func richBlockPayloadsDecodeForNativeRenderingAndEmbeds() throws {
        let nodes = try JSONDecoder().decode(
            [LogseqMarkupNode].self,
            from: Data("""
            [
              {"type":"quote","children":[{"type":"text","text":"Quoted"}]},
              {"type":"math","text":"x^2","style":"display"},
              {"type":"codeBlock","text":"let x = 1","style":"swift"},
              {"type":"video","url":"https://youtu.be/dQw4w9WgXcQ"},
              {"type":"iframe","url":"https://example.com/embed"}
            ]
            """.utf8)
        )

        #expect(nodes.count == 5)
        #expect(nodes.compactMap(\.url) == [
            "https://youtu.be/dQw4w9WgXcQ",
            "https://example.com/embed",
        ])
    }

    @Test func androidMarkupKeepsPlainTextOnTheNonInteractiveRenderPath() {
        let plain = [LogseqMarkupNode(type: .text, text: "Plain block")]
        let linked = [
            LogseqMarkupNode(type: .text, text: "Open "),
            LogseqMarkupNode(type: .nodeReference, uuid: "page-id", title: "Page"),
        ]

        #expect(!OutlinerMarkupMarkdown.requiresAttributedText(plain))
        #expect(OutlinerMarkupMarkdown.requiresAttributedText(linked))
        #expect(OutlinerMarkupMarkdown.make(nodes: plain, fallback: "") == "Plain block")
        #expect(OutlinerMarkupMarkdown.make(nodes: linked, fallback: "") ==
            "Open [\\[\\[Page\\]\\]](logseq-node://page-id)")
    }

    @Test func androidMarkupEscapesMarkdownLabelsWithoutBreakingNodeRoutes() {
        let nodes = [
            LogseqMarkupNode(type: .nodeReference, uuid: "page id", title: "Page [One]"),
            LogseqMarkupNode(type: .text, text: " "),
            LogseqMarkupNode(type: .tagReference, uuid: "tag-id", title: "Project"),
        ]

        #expect(OutlinerMarkupMarkdown.make(nodes: nodes, fallback: "") ==
            "[\\[\\[Page \\[One\\]\\]\\]](logseq-node://page%20id) [\\#Project](logseq-node://tag-id)")
    }

    @Test func androidRichContentOnlyInterceptsTouchesForInteractiveNodes() {
        #expect(!OutlinerMarkupInteractionPolicy.hasInteractiveContent([
            LogseqMarkupNode(type: .text, text: "Plain"),
            LogseqMarkupNode(type: .math, text: "x^2"),
            LogseqMarkupNode(type: .codeBlock, text: "let x = 1"),
        ]))
        #expect(OutlinerMarkupInteractionPolicy.hasInteractiveContent([
            LogseqMarkupNode(
                type: .emphasis,
                children: [LogseqMarkupNode(type: .nodeReference, uuid: "page", title: "Page")]
            ),
        ]))
        #expect(OutlinerMarkupInteractionPolicy.hasInteractiveContent([
            LogseqMarkupNode(type: .video, url: "https://example.com/video.mp4"),
        ]))
    }

    @Test func youtubeLinksNormalizeToPrivacyEnhancedInlineEmbeds() throws {
        let videoID = "dQw4w9WgXcQ"
        let sources = [
            "https://youtu.be/\(videoID)",
            "https://www.youtube.com/watch?v=\(videoID)",
            "https://m.youtube.com/shorts/\(videoID)",
            "https://youtube.com/live/\(videoID)",
            "https://www.youtube-nocookie.com/embed/\(videoID)",
        ]

        for source in sources {
            let url = try #require(URL(string: source))
            let embed = try #require(EmbeddedMediaPolicy.youtubeEmbedURL(url))
            let components = try #require(URLComponents(url: embed, resolvingAgainstBaseURL: false))
            #expect(components.host == "www.youtube-nocookie.com")
            #expect(components.path == "/embed/\(videoID)")
            #expect(components.queryItems?.contains(URLQueryItem(name: "playsinline", value: "1")) == true)
        }
    }

    @Test func youtubeEmbedsPreserveNumericStartTimeAndRejectInvalidIDs() throws {
        let timed = try #require(URL(string: "https://youtu.be/dQw4w9WgXcQ?t=43"))
        let embed = try #require(EmbeddedMediaPolicy.youtubeEmbedURL(timed))
        let components = try #require(URLComponents(url: embed, resolvingAgainstBaseURL: false))

        #expect(components.queryItems?.contains(URLQueryItem(name: "start", value: "43")) == true)
        #expect(EmbeddedMediaPolicy.webRequestHeaders(for: embed)["Referer"] == "https://logseq.com/")
        #expect(EmbeddedMediaPolicy.youtubeEmbedURL(
            try #require(URL(string: "https://youtube.com/watch?v=not-valid"))
        ) == nil)
        #expect(EmbeddedMediaPolicy.youtubeEmbedURL(
            try #require(URL(string: "https://youtube.com.evil.test/watch?v=dQw4w9WgXcQ"))
        ) == nil)
    }

    @Test func youtubeTimestampTargetsTheNearestPlayerAndOverridesItsStartTime() throws {
        let source = "https://youtu.be/dQw4w9WgXcQ?t=12"
        let nodes = OutlinerYouTubeTimestampPolicy.associateTargets([
            LogseqMarkupNode(type: .video, url: source),
            LogseqMarkupNode(type: .youtubeTimestamp, text: "01:23", style: "83"),
        ])

        #expect(nodes[1].url == source)
        #expect(OutlinerYouTubeTimestampPolicy.seconds(nodes[1]) == 83)
        let sourceURL = try #require(URL(string: source))
        let embed = try #require(EmbeddedMediaPolicy.webVideoEmbedURL(
            sourceURL,
            startSeconds: 83
        ))
        let components = try #require(URLComponents(url: embed, resolvingAgainstBaseURL: false))
        let starts = components.queryItems?
            .filter { $0.name == "start" }
            .compactMap(\.value)
        #expect(starts == ["83"])
    }

    @Test func youtubeTimestampDoesNotAttachToUntrustedOrNonYouTubeVideoURLs() {
        let nodes = OutlinerYouTubeTimestampPolicy.associateTargets([
            LogseqMarkupNode(type: .video, url: "https://youtube.com.evil.test/watch?v=dQw4w9WgXcQ"),
            LogseqMarkupNode(type: .youtubeTimestamp, text: "00:05", style: "5"),
        ])

        #expect(nodes[1].url == nil)
    }


    @Test func inlineEditorAppliesTheNewBlockDuringResponderHandoff() {
        #expect(InlineEditorTextReconciliationPolicy.decision(
            modelText: "new block",
            localText: "previous draft",
            isSameBlock: false
        ) == .applyModel)
    }

    @Test func inlineEditorKeepsThePreSplitTextVisibleUntilTheHandoffArrives() {
        // Same block, handoff pending: keep showing the full pre-split text so
        // the current block does not flash the caret suffix.
        #expect(InlineEditorTextReconciliationPolicy.decision(
            modelText: "parent child",
            localText: "parent child",
            isSameBlock: true,
            isAwaitingBlockHandoff: true
        ) == .keepLocal)
        // Handoff arrives with the new block: apply its text in the same
        // render pass that moves the editor, so the split appears atomically.
        #expect(InlineEditorTextReconciliationPolicy.decision(
            modelText: "child",
            localText: "parent child",
            isSameBlock: false,
            isAwaitingBlockHandoff: true
        ) == .applyModel)
        #expect(InlineEditorTextReconciliationPolicy.decision(
            modelText: "child",
            localText: "child",
            isSameBlock: false,
            isAwaitingBlockHandoff: true
        ) == .applyModel)
    }

    @Test func typingBufferedDuringReturnHandoffLandsAtTheNewBlockCaret() {
        let merged = InlineEditorHandoffMerge.merged(
            modelText: "child",
            desiredCaretUTF16Offset: 0,
            bufferedTyping: "ab"
        )
        #expect(merged.text == "abchild")
        #expect(merged.caretUTF16Offset == 2)

        let untouched = InlineEditorHandoffMerge.merged(
            modelText: "child",
            desiredCaretUTF16Offset: 0,
            bufferedTyping: ""
        )
        #expect(untouched.text == "child")
        #expect(untouched.caretUTF16Offset == 0)

        let clamped = InlineEditorHandoffMerge.merged(
            modelText: "abc",
            desiredCaretUTF16Offset: 99,
            bufferedTyping: "x"
        )
        #expect(clamped.text == "abcx")
        #expect(clamped.caretUTF16Offset == 4)
    }

    @Test func richMarkupKeepsInlineRunsAroundEmbeddedNodes() {
        let chunks = OutlinerRichMarkupPolicy.chunks([
            LogseqMarkupNode(type: .text, text: "Before "),
            LogseqMarkupNode(type: .emphasis, style: "bold", children: [
                LogseqMarkupNode(type: .text, text: "video")
            ]),
            LogseqMarkupNode(type: .video, url: "https://example.com/video.mp4"),
            LogseqMarkupNode(type: .text, text: "After"),
            LogseqMarkupNode(type: .math, text: "x^2", style: "inline")
        ])

        #expect(chunks.count == 4)
        #expect(chunks[0].map(\.type) == [
            LogseqMarkupNodeType.text, LogseqMarkupNodeType.emphasis
        ])
        #expect(chunks[1].map(\.type) == [LogseqMarkupNodeType.video])
        #expect(chunks[2].map(\.type) == [LogseqMarkupNodeType.text])
        #expect(chunks[3].map(\.type) == [LogseqMarkupNodeType.math])
        #expect(OutlinerRichMarkupPolicy.containsInteractive([
            LogseqMarkupNode(type: .youtubeTimestamp, text: "01:23", style: "83")
        ]))
        #expect(!OutlinerRichMarkupPolicy.containsInteractive([
            LogseqMarkupNode(type: .quote, children: [
                LogseqMarkupNode(type: .text, text: "Quote")
            ])
        ]))
    }
}
