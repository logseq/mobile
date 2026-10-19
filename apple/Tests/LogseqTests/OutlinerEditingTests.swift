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

    @Test func autocompleteHeightFitsItsRowsUntilTheScrollLimit() {
        #expect(OutlinerAutocompleteLayoutPolicy.height(candidateCount: 0) == 0)
        #expect(OutlinerAutocompleteLayoutPolicy.height(candidateCount: 1) == 60)
        #expect(OutlinerAutocompleteLayoutPolicy.height(candidateCount: 3) == 148)
        #expect(OutlinerAutocompleteLayoutPolicy.height(candidateCount: 20) == 220)
    }

    @Test func logseqAndOutlinerUseDifferentEditorSurfaces() {
        #expect(BlockEditingPolicy.presentation(for: LogseqContentMode.logseq) == BlockEditPresentation.composer)
        #expect(BlockEditingPolicy.presentation(for: LogseqContentMode.outliner) == BlockEditPresentation.inline)
    }

    @Test func blockSelectionStartsWithLongPress() {
        #expect(BlockSelectionGesturePolicy.activation == .longPress)
    }

    @Test func copiedNodeReferencesUseTheDbGraphBracketSyntax() {
        #expect(OutlinerClipboardPolicy.nodeReferences(["page-uuid", "block-uuid"]) ==
            "[[page-uuid]]\n[[block-uuid]]")
        #expect(OutlinerClipboardPolicy.nodeReferences([]).isEmpty)
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

    @Test func typedMarkupPresentationPreservesTextAndLinkDestinations() throws {
        let nodes = [
            LogseqMarkupNode(type: .text, text: "See "),
            LogseqMarkupNode(
                type: .nodeReference, uuid: "page-uuid", title: "Page"
            ),
            LogseqMarkupNode(type: .text, text: " and "),
            LogseqMarkupNode(type: .tagReference, uuid: "tag-uuid", title: "Project"),
        ]
        let presentation = OutlinerMarkupPresentation.make(nodes: nodes, fallback: "fallback")

        #expect(presentation.plainText == "See Page and #Project")
        #expect(presentation.links == [
            OutlinerMarkupLink.node(uuid: "page-uuid"),
            OutlinerMarkupLink.node(uuid: "tag-uuid"),
        ])
        #expect(OutlinerMarkupPresentation.make(nodes: [], fallback: "((legacy))").plainText ==
            "((legacy))")
    }

    @Test func typedMarkupPresentationCoversNestedAndIncompleteMldocNodes() {
        let nodes = [
            LogseqMarkupNode(type: .text),
            LogseqMarkupNode(
                type: .emphasis,
                children: [LogseqMarkupNode(type: .code, text: "nested")]
            ),
            LogseqMarkupNode(type: .link),
            LogseqMarkupNode(type: .link, url: "https://logseq.com"),
            LogseqMarkupNode(
                type: .link,
                children: [LogseqMarkupNode(type: .text, text: "label")]
            ),
            LogseqMarkupNode(type: .nodeReference),
            LogseqMarkupNode(type: .tagReference),
        ]

        let presentation = OutlinerMarkupPresentation.make(nodes: nodes, fallback: "unused")
        #expect(presentation.plainText == "nestedhttps://logseq.comlabel#")
        #expect(presentation.links.isEmpty)
    }

    @Test func inlineTagsStayInContentAndOnlyNonInlineTagsTrailTheBlock() throws {
        let summaries = try JSONDecoder().decode(
            [LogseqEntitySummary].self,
            from: Data("""
            [
              {"uuid":"inline","title":"Inline"},
              {"uuid":"trailing","title":"Trailing"}
            ]
            """.utf8)
        )
        let inline = summaries[0]
        let trailing = summaries[1]
        let markup = [
            LogseqMarkupNode(
                type: .emphasis,
                children: [
                    LogseqMarkupNode(type: .tagReference, uuid: "inline", title: "Inline"),
                    LogseqMarkupNode(type: .tagReference, uuid: "inline", title: "Inline"),
                    LogseqMarkupNode(type: .tagReference, title: "Incomplete")
                ]
            )
        ]

        #expect(BlockTagPresentationPolicy.inlineTagIDs(markup) == Set(["inline"]))
        #expect(BlockTagPresentationPolicy.trailingTags(
            tags: [inline, trailing, trailing],
            markup: markup
        ) == [trailing])
        #expect(BlockTagPresentationPolicy.trailingTags(tags: [], markup: []).isEmpty)
    }

    @Test func toolbarDoesNotExposeUndoOrRedoYet() {
        #expect(!OutlinerToolbarPolicy.editorActions.contains(OutlinerToolbarAction.undo))
        #expect(!OutlinerToolbarPolicy.editorActions.contains(OutlinerToolbarAction.redo))
        #expect(!OutlinerToolbarPolicy.selectionActions.contains(OutlinerToolbarAction.undo))
        #expect(!OutlinerToolbarPolicy.selectionActions.contains(OutlinerToolbarAction.redo))
        #expect(OutlinerToolbarAction.undo.eventValue == nil)
        #expect(OutlinerToolbarAction.redo.eventValue == nil)
        #expect(OutlinerToolbarAction.undo.systemImageName == "arrow.uturn.backward")
        #expect(OutlinerToolbarAction.redo.systemImageName == "arrow.uturn.forward")
        #expect(OutlinerToolbarAction.undo.accessibilityTitle == "Undo")
        #expect(OutlinerToolbarAction.redo.accessibilityTitle == "Redo")
    }

    @Test func editorToolbarMatchesCurrentLogseqMobileOrderAndSymbols() {
        let expected: [OutlinerToolbarAction] = [
            .task, .outdent, .indent, .tag, .camera, .audio, .pageReference,
        ]
        #expect(OutlinerToolbarPolicy.editorActions == expected)
        #expect(OutlinerToolbarPolicy.trailingEditorAction == .hideKeyboard)
        #expect(OutlinerToolbarPolicy.editorActions.map(\.systemImageName) == [
            "checkmark.square", "arrow.left", "arrow.right", "number", "camera",
            "mic", "parentheses",
        ])
        #expect(OutlinerToolbarPolicy.trailingEditorAction.systemImageName == "keyboard.chevron.compact.down")
    }

    @Test func taskToolbarAccessibilityTracksTheEditingBlockStatus() {
        #expect(OutlinerToolbarPolicy.taskAccessibilityTitle(statusTitle: nil) == "Task: None")
        #expect(OutlinerToolbarPolicy.taskAccessibilityTitle(statusTitle: "Todo") == "Task: Todo")
        #expect(OutlinerToolbarPolicy.taskAccessibilityTitle(statusTitle: "Doing") == "Task: Doing")
        #expect(OutlinerToolbarPolicy.taskAccessibilityTitle(statusTitle: "Done") == "Task: Done")
    }

    @Test func selectionToolbarMatchesCurrentLogseqMobileOrderAndSymbols() {
        let expected: [OutlinerToolbarAction] = [
            .copy, .outdent, .indent, .delete, .copyReference, .copyURL,
        ]
        #expect(OutlinerToolbarPolicy.selectionActions == expected)
        #expect(OutlinerToolbarPolicy.selectionActions.map(\.systemImageName) == [
            "doc.on.doc", "arrow.left", "arrow.right", "trash", "r.square", "link",
        ])
        #expect(OutlinerToolbarPolicy.trailingSelectionAction == .unselect)
        #expect(OutlinerToolbarPolicy.trailingSelectionAction.systemImageName == "xmark")
    }

    @Test func toolbarItemsStayCompactInsideHorizontalScrollViews() {
        #expect(OutlinerToolbarPolicy.editorItemWidth == 42)
        #expect(OutlinerToolbarPolicy.selectionItemWidth == 58)
        #expect(OutlinerToolbarPolicy.selectionItemSpacing == 6)
        #expect(OutlinerToolbarPolicy.iconSize == 18)
        #expect(OutlinerToolbarPolicy.iconBoxSize == 22)
        #expect(OutlinerToolbarPolicy.captionHeight == 14)
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

    @Test func editorVisibilityIsRecheckedOnlyWhenTheViewportShrinks() {
        #expect(OutlinerEditorViewportPolicy.viewportChangeCanOccludeEditor(
            previousHeight: 700,
            currentHeight: 400
        ))
        #expect(!OutlinerEditorViewportPolicy.viewportChangeCanOccludeEditor(
            previousHeight: 400,
            currentHeight: 700
        ))
        #expect(!OutlinerEditorViewportPolicy.viewportChangeCanOccludeEditor(
            previousHeight: 400,
            currentHeight: 400
        ))
    }

    @Test func editorScrollsOnlyWhenTheFocusedBlockIsOutsideTheViewport() {
        #expect(OutlinerEditorViewportPolicy.isFullyVisible(
            frame: CGRect(x: 0, y: 20, width: 100, height: 40),
            viewportHeight: 100
        ))
        #expect(!OutlinerEditorViewportPolicy.isFullyVisible(
            frame: CGRect(x: 0, y: 80, width: 100, height: 40),
            viewportHeight: 100
        ))
        #expect(!OutlinerEditorViewportPolicy.isFullyVisible(
            frame: CGRect(x: 0, y: -1, width: 100, height: 40),
            viewportHeight: 100
        ))
        #expect(OutlinerEditorViewportPolicy.shouldEnsureVisible(
            previousBlockID: nil,
            blockID: "block",
            viewportChanged: false,
            isBlockVisible: false
        ))
        #expect(!OutlinerEditorViewportPolicy.shouldEnsureVisible(
            previousBlockID: "previous",
            blockID: "block",
            viewportChanged: false,
            isBlockVisible: true
        ))
        #expect(OutlinerEditorViewportPolicy.shouldEnsureVisible(
            previousBlockID: "block",
            blockID: "block",
            viewportChanged: true,
            isBlockVisible: false
        ))
        #expect(!OutlinerEditorViewportPolicy.shouldEnsureVisible(
            previousBlockID: "block",
            blockID: "block",
            viewportChanged: true,
            isBlockVisible: true
        ))
        #expect(!OutlinerEditorViewportPolicy.shouldEnsureVisible(
            previousBlockID: "block",
            blockID: nil,
            viewportChanged: true,
            isBlockVisible: false
        ))
    }

    @Test func editorEndsOnlyAfterItsRenderedPlaceholderLeavesTheLazyStack() {
        #expect(OutlinerEditorViewportPolicy.shouldEndEditing(
            blockID: "block",
            renderedEditorBlockID: "block",
            renderedBlockIDs: [],
            isUserScrolling: true,
            isScrollExitArmed: true
        ))
        #expect(!OutlinerEditorViewportPolicy.shouldEndEditing(
            blockID: "next",
            renderedEditorBlockID: "previous",
            renderedBlockIDs: [],
            isUserScrolling: true,
            isScrollExitArmed: true
        ))
        #expect(!OutlinerEditorViewportPolicy.shouldEndEditing(
            blockID: "block",
            renderedEditorBlockID: "block",
            renderedBlockIDs: ["block"],
            isUserScrolling: true,
            isScrollExitArmed: true
        ))
        #expect(!OutlinerEditorViewportPolicy.shouldEndEditing(
            blockID: "block",
            renderedEditorBlockID: "block",
            renderedBlockIDs: [],
            isUserScrolling: false,
            isScrollExitArmed: true
        ))
        #expect(!OutlinerEditorViewportPolicy.shouldEndEditing(
            blockID: "block",
            renderedEditorBlockID: "block",
            renderedBlockIDs: [],
            isUserScrolling: true,
            isScrollExitArmed: false
        ))
    }

    @Test func journalProjectionUpdatesRetainTheVisibleScrollAnchor() {
        #expect(OutlinerScrollAnchorPolicy.retainedAnchor(
            current: "visible",
            previousRowIDs: ["top", "visible", "bottom"],
            rowIDs: ["top", "visible", "inserted", "bottom"]
        ) == "visible")
        #expect(OutlinerScrollAnchorPolicy.retainedAnchor(
            current: "removed",
            previousRowIDs: ["top", "removed", "next"],
            rowIDs: ["top", "next"]
        ) == "next")
        #expect(OutlinerScrollAnchorPolicy.retainedAnchor(
            current: nil,
            previousRowIDs: ["top"],
            rowIDs: ["top", "new"]
        ) == nil)
    }

    @Test func olderJournalPaginationIsExplicitAndAccessible() {
        #expect(OutlinerPaginationPolicy.buttonTitle == "Load earlier journals")
        #expect(OutlinerPaginationPolicy.accessibilityIdentifier == "button.outliner.load-older-journals")
    }

    @Test func journalSectionTitlesNavigateToTheirPage() {
        #expect(OutlinerSectionNavigationPolicy.pageUUID(
            isJournalHome: true,
            sectionBlockPageIDs: ["journal-page", "journal-page"]
        ) == "journal-page")
        #expect(OutlinerSectionNavigationPolicy.pageUUID(
            isJournalHome: false,
            sectionBlockPageIDs: ["ordinary-page"]
        ) == nil)
        #expect(OutlinerSectionNavigationPolicy.pageUUID(
            isJournalHome: true,
            sectionBlockPageIDs: []
        ) == nil)
    }

    @Test func outlineControlsNameTheirBlockForAccessibleNavigation() {
        #expect(OutlinerAccessibilityTitle.zoom(blockTitle: "Parent") == "Zoom into Parent")
        #expect(OutlinerAccessibilityTitle.collapse(
            blockTitle: "Parent", isCollapsed: false
        ) == "Collapse Parent")
        #expect(OutlinerAccessibilityTitle.collapse(
            blockTitle: "Parent", isCollapsed: true
        ) == "Expand Parent")
        #expect(OutlinerAccessibilityTitle.zoom(blockTitle: "") == "Zoom into Untitled block")
    }

    @Test func nativeOutlinerNavigationOnlyDispatchesMissingBackSteps() {
        #expect(OutlinerNavigationPolicy.backStepCount(
            presentedPath: ["parent"],
            modelPath: ["parent", "child"]
        ) == 1)
        #expect(OutlinerNavigationPolicy.backStepCount(
            presentedPath: [],
            modelPath: ["parent", "child"]
        ) == 2)
        #expect(OutlinerNavigationPolicy.backStepCount(
            presentedPath: ["parent", "child"],
            modelPath: ["parent", "child"]
        ) == 0)
        #expect(OutlinerNavigationPolicy.backStepCount(
            presentedPath: ["other"],
            modelPath: ["parent"]
        ) == 0)
    }

    @Test func nativeBackClosesExactlyOneCoreNodeProjection() {
        let previousPath: [AppNavigationRoute] = [.node("parent"), .node("child")]
        let path: [AppNavigationRoute] = [.node("parent")]
        #expect(
            AppNavigationPathPolicy.nodeCount(previousPath)
                - AppNavigationPathPolicy.nodeCount(path) == 1
        )
    }

    @Test func backButtonPopsThePresentedNativeNavigationPathFirst() {
        #expect(OutlinerNavigationPolicy.pathAfterBackButton(["parent", "child"]) == ["parent"])
        #expect(OutlinerNavigationPolicy.pathAfterBackButton(["parent"]) == [])
        #expect(OutlinerNavigationPolicy.pathAfterBackButton([String]()) == [])
    }

    @Test func pagesBlocksTagsAndOutlinerZoomUseOneNativeNodeRoute() {
        let path: [AppNavigationRoute] = [
            .node("parent"),
            .node("child"),
        ]
        #expect(AppNavigationPathPolicy.nodeCount(path) == 2)
    }

    @Test func nativeNavigationPathContainsOnlyNodeDestinations() {
        let node = AppNavigationRoute.node("result")

        #expect(AppNavigationPathPolicy.nodeCount([node]) == 1)
        #expect(AppNavigationPathPolicy.coreCloseCount(
            previousPath: [node],
            path: [],
            projectedNodeCount: 1
        ) == 1)
    }

    @Test func markupNavigationDoesNotPushTheCurrentDestinationAgain() {
        let node = AppNavigationRoute.node("node-1")
        let tag = AppNavigationRoute.node("tag-1")

        #expect(!AppNavigationPathPolicy.shouldAppend(node, to: [node]))
        #expect(!AppNavigationPathPolicy.shouldAppend(tag, to: [node, tag]))
        #expect(AppNavigationPathPolicy.shouldAppend(tag, to: [node]))
        #expect(AppNavigationPathPolicy.shouldAppend(node, to: []))
    }

    @Test func outlinerNodeNavigationPresentsImmediatelyBeforeCoreResolution() {
        let journal = AppNavigationRoute.node("journal")
        let link = AppNavigationRoute.node("linked-node")

        #expect(AppNavigationPathPolicy.pathAfterRequest(journal, in: []) == [journal])
        #expect(
            AppNavigationPathPolicy.pathAfterRequest(link, in: [journal])
                == [journal, link]
        )
    }

    @Test func journalNavigationPreviewUsesVisibleTitleAndRowsBeforeCoreResolution() {
        let journalBlock = LogseqBlock(
            uuid: "journal-block",
            title: "Journal content",
            pageId: "journal-page",
            parentId: nil,
            createdAt: 1,
            updatedAt: 1,
            syncStatus: "synced",
            journalTitle: "Aug 21st, 2026",
            journalDay: 20260821
        )
        let otherBlock = LogseqBlock(
            uuid: "other-block",
            title: "Other content",
            pageId: "other-page",
            parentId: nil,
            createdAt: 1,
            updatedAt: 1,
            syncStatus: "synced",
            journalTitle: "Aug 20th, 2026",
            journalDay: 20260820
        )
        let journalSection = LogseqBlockSection(
            id: "20260821",
            title: "Aug 21st, 2026",
            blocks: [journalBlock]
        )
        let otherSection = LogseqBlockSection(
            id: "20260820",
            title: "Aug 20th, 2026",
            blocks: [otherBlock]
        )

        let preview = NodeNavigationPreviewPolicy.make(
            uuid: "journal-page",
            rows: [
                LogseqOutlineRow(
                    block: journalBlock, depth: 0, hasChildren: false, isCollapsed: false
                ),
                LogseqOutlineRow(
                    block: otherBlock, depth: 0, hasChildren: false, isCollapsed: false
                ),
            ],
            sections: [journalSection, otherSection],
            linkedTitle: nil
        )

        #expect(preview.title == "Aug 21st, 2026")
        #expect(preview.rows.map(\.block.uuid) == ["journal-block"])
        #expect(preview.sections.map(\.id) == ["20260821"])
    }

    @Test func linkedNodeNavigationPreviewNeverFallsBackToGenericNodeOrSpinner() {
        let preview = NodeNavigationPreviewPolicy.make(
            uuid: "linked-page",
            rows: [],
            sections: [],
            linkedTitle: "Linked page"
        )
        let untitledPreview = NodeNavigationPreviewPolicy.make(
            uuid: "unknown-page",
            rows: [],
            sections: [],
            linkedTitle: nil
        )

        #expect(preview.title == "Linked page")
        #expect(preview.rows.isEmpty)
        #expect(preview.sections.isEmpty)
        #expect(untitledPreview.title == "Untitled")
    }

    @Test func repeatedFastOutlinerNavigationDoesNotAppendDuplicateRoutes() {
        let route = AppNavigationRoute.node("node")
        #expect(AppNavigationPathPolicy.pathAfterRequest(route, in: [route]) == [route])
    }

    @Test func unresolvedOptimisticNodeRouteIsRemovedWithoutPoppingNewerRoutes() {
        let parent = AppNavigationRoute.node("parent")
        let unresolved = AppNavigationRoute.node("missing")
        let newer = AppNavigationRoute.node("newer")

        #expect(
            AppNavigationPathPolicy.pathAfterResolution(
                unresolved,
                resolved: false,
                in: [parent, unresolved]
            ) == [parent]
        )
        #expect(
            AppNavigationPathPolicy.pathAfterResolution(
                unresolved,
                resolved: false,
                in: [parent, unresolved, newer]
            ) == [parent, newer]
        )
        #expect(
            AppNavigationPathPolicy.pathAfterResolution(
                unresolved,
                resolved: true,
                in: [parent, unresolved]
            ) == [parent, unresolved]
        )
    }

    @Test func optimisticRollbackDoesNotCloseAnExistingCoreNodeProjection() {
        let parent = AppNavigationRoute.node("parent")
        let optimistic = AppNavigationRoute.node("optimistic")

        #expect(AppNavigationPathPolicy.coreCloseCount(
            previousPath: [parent, optimistic],
            path: [parent],
            projectedNodeCount: 1
        ) == 0)
        #expect(AppNavigationPathPolicy.coreCloseCount(
            previousPath: [parent, optimistic],
            path: [parent],
            projectedNodeCount: 2
        ) == 1)
        #expect(AppNavigationPathPolicy.coreCloseCount(
            previousPath: [parent, optimistic],
            path: [],
            projectedNodeCount: 2
        ) == 2)
    }

    @Test func resolvedNodeProjectionClosesWhenUserAlreadyNavigatedBack() {
        let parent = AppNavigationRoute.node("parent")
        let child = AppNavigationRoute.node("child")

        #expect(AppNavigationPathPolicy.shouldKeepResolvedProjection(
            child,
            requestedDepth: 2,
            in: [parent, child]
        ))
        #expect(!AppNavigationPathPolicy.shouldKeepResolvedProjection(
            child,
            requestedDepth: 2,
            in: [parent]
        ))
        #expect(!AppNavigationPathPolicy.shouldKeepResolvedProjection(
            child,
            requestedDepth: 2,
            in: [parent, AppNavigationRoute.node("newer")]
        ))
    }

    @Test func relatedContentUsesLogseqSectionNamesForPopulatedNodeAndTagViews() {
        #expect(RelatedContentPolicy.sectionTitle(
            isTag: false,
            hasBlocks: true
        ) == "Linked references")
        #expect(RelatedContentPolicy.sectionTitle(
            isTag: false,
            hasBlocks: false
        ) == nil)
        #expect(RelatedContentPolicy.sectionTitle(
            isTag: true,
            hasBlocks: true
        ) == "Tagged nodes")
        #expect(RelatedContentPolicy.sectionTitle(
            isTag: true,
            hasBlocks: false
        ) == "Tagged nodes")
        #expect(RelatedContentPolicy.emptyTitle(
            isTag: true,
            hasBlocks: false
        ) == "No tagged nodes")
        #expect(RelatedContentPolicy.emptyTitle(
            isTag: true,
            hasBlocks: true
        ) == nil)
        #expect(RelatedContentPolicy.sectionTitle(isTag: false, hasBlocks: false) == nil)
    }

    @Test func relatedBlockMarkupShowsTitlesInsteadOfCanonicalUUIDs() {
        let nodes = [
            LogseqMarkupNode(type: .text, text: "E2E links "),
            LogseqMarkupNode(
                type: .nodeReference,
                uuid: "page-uuid",
                title: "E2E Page Target"
            ),
            LogseqMarkupNode(type: .text, text: " "),
            LogseqMarkupNode(
                type: .nodeReference,
                uuid: "block-uuid",
                title: "E2E Block Target"
            ),
            LogseqMarkupNode(type: .text, text: " "),
            LogseqMarkupNode(
                type: .tagReference,
                uuid: "tag-uuid",
                title: "E2E Project"
            ),
        ]
        let presentation = OutlinerMarkupPresentation.make(nodes: nodes, fallback: "unused")

        #expect(presentation.plainText ==
            "E2E links E2E Page Target E2E Block Target #E2E Project")
        #expect(!presentation.plainText.contains("page-uuid"))
        #expect(!presentation.plainText.contains("block-uuid"))
        #expect(!presentation.plainText.contains("tag-uuid"))
    }

    @Test func linkedReferencesAndTaggedNodesGroupBlocksByImmediateParent() {
        let page = LogseqEntitySummary(uuid: "page", title: "Page")
        let parent = LogseqEntitySummary(uuid: "parent", title: "Parent")
        func block(_ uuid: String, parentID: String?, breadcrumbs: [LogseqEntitySummary]) -> LogseqBlock {
            LogseqBlock(
                uuid: uuid,
                title: uuid,
                pageId: "page",
                parentId: parentID,
                createdAt: 1,
                updatedAt: 1,
                syncStatus: "synced",
                breadcrumbs: breadcrumbs
            )
        }
        let groups = RelatedBlockGrouping.groups([
            block("first", parentID: "parent", breadcrumbs: [page, parent]),
            block("second", parentID: "parent", breadcrumbs: [page, parent]),
            block("third", parentID: "page", breadcrumbs: [page]),
            block("fourth", parentID: "orphan-parent", breadcrumbs: []),
            block("fifth", parentID: nil, breadcrumbs: []),
        ])

        #expect(groups.map(\.id) == ["parent", "page", "orphan-parent"])
        #expect(groups[0].breadcrumbs == [page, parent])
        #expect(groups[0].blocks.map(\.uuid) == ["first", "second"])
        #expect(groups[2].blocks.map(\.uuid) == ["fourth"])
        #expect(groups[1].blocks.map(\.uuid) == ["third", "fifth"])
    }

    @Test func everySupportedToolbarCommandHasAnEventIconAndAccessibleTitle() {
        let expected: [OutlinerToolbarAction: (String, String, String, Bool)] = [
            .task: ("task", "checkmark.square", "Task", true),
            .outdent: ("outdent", "arrow.left", "Outdent", true),
            .indent: ("indent", "arrow.right", "Indent", true),
            .tag: ("tag", "number", "Tag", true),
            .pageReference: ("pageReference", "parentheses", "Page reference", true),
            .camera: ("camera", "camera", "Photo", false),
            .audio: ("audio", "mic", "Record audio", false),
            .hideKeyboard: ("hideKeyboard", "keyboard.chevron.compact.down", "Hide keyboard", false),
            .copy: ("copy", "doc.on.doc", "Copy", false),
            .delete: ("delete", "trash", "Delete", false),
            .copyReference: ("copyReference", "r.square", "Copy reference", false),
            .copyURL: ("copyURL", "link", "Copy URL", false),
            .unselect: ("unselect", "xmark", "Unselect", false),
        ]
        let supported = Set(
            OutlinerToolbarPolicy.editorActions
                + [OutlinerToolbarPolicy.trailingEditorAction]
                + OutlinerToolbarPolicy.selectionActions
                + [OutlinerToolbarPolicy.trailingSelectionAction]
        )

        #expect(supported == Set(expected.keys))
        for (action, contract) in expected {
            #expect(action.eventValue == contract.0)
            #expect(action.systemImageName == contract.1)
            #expect(action.accessibilityTitle == contract.2)
            #expect(action.preservesInlineEditorFocus == contract.3)
        }
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

    @Test func structuralEditingCommandsKeepTheInlineEditorFocused() {
        let focusPreservingActions: [OutlinerToolbarAction] = [
            .task, .outdent, .indent, .tag, .pageReference,
        ]
        for action in focusPreservingActions {
            #expect(action.preservesInlineEditorFocus)
        }
        #expect(!OutlinerToolbarAction.hideKeyboard.preservesInlineEditorFocus)
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

    @Test func androidInlineEditorSeparatesLocalTypingFromStructuralInput() {
        #expect(AndroidInlineEditorInputPolicy.transition(
            previousText: "Hello",
            updatedText: "Hello!",
            updatedCaretUTF16Offset: 6
        ) == .textChange(text: "Hello!", caretUTF16Offset: 6))

        #expect(AndroidInlineEditorInputPolicy.transition(
            previousText: "Hello",
            updatedText: "Hel\nlo",
            updatedCaretUTF16Offset: 4
        ) == .returnKey(text: "Hello", caretUTF16Offset: 3))

        #expect(AndroidInlineEditorInputPolicy.transition(
            previousText: "你😀好",
            updatedText: "你😀\n好",
            updatedCaretUTF16Offset: 4
        ) == .returnKey(text: "你😀好", caretUTF16Offset: 3))

        #expect(AndroidInlineEditorInputPolicy.shouldMergeBackward(
            text: "Block",
            selectionStartUTF16Offset: 0,
            selectionEndUTF16Offset: 0
        ))
        #expect(!AndroidInlineEditorInputPolicy.shouldMergeBackward(
            text: "Block",
            selectionStartUTF16Offset: 1,
            selectionEndUTF16Offset: 1
        ))
        #expect(!AndroidInlineEditorInputPolicy.shouldMergeBackward(
            text: "Block",
            selectionStartUTF16Offset: 0,
            selectionEndUTF16Offset: 2
        ))
    }

    @Test func unchangedRowsKeepTheSameRenderIdentityAcrossUnrelatedSnapshots() throws {
        let block = try JSONDecoder().decode(
            LogseqBlock.self,
            from: Data(#"{"uuid":"block","title":"Title","pageId":"page","parentId":null,"createdAt":1,"updatedAt":1,"syncStatus":null}"#.utf8)
        )
        let row = try JSONDecoder().decode(
            LogseqOutlineRow.self,
            from: Data(#"{"block":{"uuid":"block","title":"Title","pageId":"page","parentId":null,"createdAt":1,"updatedAt":1,"syncStatus":null},"depth":0,"hasChildren":false,"isCollapsed":false}"#.utf8)
        )
        let idle = OutlinerRowRenderKey(
            row: row,
            statuses: [LogseqTaskStatus.todo, LogseqTaskStatus.done],
            isEditing: false,
            isSelected: false,
            isSelectionActive: false,
            editingTitle: block.title,
            desiredCaretUTF16Offset: nil
        )

        #expect(idle == idle)
        #expect(idle != OutlinerRowRenderKey(
            row: row,
            statuses: [LogseqTaskStatus.todo, LogseqTaskStatus.done],
            isEditing: true,
            isSelected: false,
            isSelectionActive: false,
            editingTitle: block.title,
            desiredCaretUTF16Offset: 2
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
            "Open [Page](logseq-node://page-id)")
    }

    @Test func androidMarkupEscapesMarkdownLabelsWithoutBreakingNodeRoutes() {
        let nodes = [
            LogseqMarkupNode(type: .nodeReference, uuid: "page id", title: "Page [One]"),
            LogseqMarkupNode(type: .text, text: " "),
            LogseqMarkupNode(type: .tagReference, uuid: "tag-id", title: "Project"),
        ]

        #expect(OutlinerMarkupMarkdown.make(nodes: nodes, fallback: "") ==
            "[Page \\[One\\]](logseq-node://page%20id) [\\#Project](logseq-node://tag-id)")
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

    @Test func youtubeTimestampTargetsTheNearestPlayerAcrossBlocks() {
        let source = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let targets = OutlinerYouTubeTimestampPolicy.targetURLsByBlockID([
            (
                id: "video-block",
                nodes: [LogseqMarkupNode(type: .video, url: source)]
            ),
            (
                id: "timestamp-block",
                nodes: [LogseqMarkupNode(type: .youtubeTimestamp, text: "01:23", style: "83")]
            ),
        ])

        #expect(targets["timestamp-block"] == source)
        #expect(targets["video-block"] == nil)
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
