import Foundation
import Testing
@testable import Logseq
import LogseqModel
import LUIAppleBackend

@MainActor
@Suite("LG renderer")
struct LGRendererTests {
    @Test("sidebar icons use the same native symbols as main on Apple platforms")
    func sidebarIconsMatchMain() {
        #expect(LGIconPolicy.icons["calendar"] == .systemName("calendar"))
        #expect(LGIconPolicy.icons["document"] == .systemName("doc.text"))
        #expect(LGIconPolicy.icons["folder"] == .systemName("folder"))
        #expect(LGIconPolicy.icons["history"] == .systemName("clock"))
        #expect(LGIconPolicy.icons["star"] == .systemName("star"))
    }

    @Test("native List routes use the platform grouped page surface")
    func nativeListRoutesUseSystemSurface() {
        #expect(LGNavigationSurfacePolicy.usesSystemGroupedBackground(
            contentPreference: true
        ))
        #expect(!LGNavigationSurfacePolicy.usesSystemGroupedBackground(
            contentPreference: false
        ))
        #expect(LGNavigationSurfacePolicy.bottomPadding(
            occupiesLayoutSpace: true
        ) == 7)
        #expect(LGNavigationSurfacePolicy.androidContentTopPadding == 0)
        #expect(LGNavigationSurfacePolicy.systemToolbarItemWidth(
            iconWidth: 24,
            minimumHitTarget: 44
        ) == 44)
        #expect(LGNavigationSurfacePolicy.systemToolbarItemWidth(
            iconWidth: 48,
            minimumHitTarget: 44
        ) == 48)
    }

    @Test("audio assets use the inline player when a local file is available")
    func audioAssetPreviewPolicy() {
        #expect(LGAssetPreviewPolicy.usesInlineAudioPlayer(
            assetType: "audio/m4a",
            localPath: "Assets/recording.m4a"
        ))
        #expect(!LGAssetPreviewPolicy.usesInlineAudioPlayer(
            assetType: "application/pdf",
            localPath: "Assets/report.pdf"
        ))
        #expect(!LGAssetPreviewPolicy.usesInlineAudioPlayer(
            assetType: "audio/m4a",
            localPath: ""
        ))
    }

    @Test("applies retained patches and exposes the stable runtime root")
    func appliesRetainedPatches() throws {
        let renderer = LGRenderer()

        try renderer.apply(patchJSON: """
        {"generation":1,"ops":[
          {"op":"create-node","id":1,"kind":"root"},
          {"op":"create-node","id":2,"kind":"text"},
          {"op":"set-prop","id":2,"property":"text","value":"Before"},
          {"op":"insert-child","parent":1,"child":2,"index":0}
        ]}
        """)

        #expect(renderer.rootID == 1)

        try renderer.apply(patchJSON: """
        {"generation":2,"ops":[
          {"op":"set-prop","id":2,"property":"text","value":"After"}
        ]}
        """)

        #expect(renderer.rootID == 1)
    }

    @Test("registers the native rich block renderer with the LG fingerprint")
    func registersRichBlockRenderer() throws {
        let renderer = LGRenderer()

        try renderer.apply(patchJSON: """
        {"generation":1,"ops":[
          {"op":"create-node","id":1,"kind":"root"},
          {"op":"create-extension","id":2,"identifier":"outliner-block-content","fingerprint":"lui-extension-v1|22:outliner-block-content|profiles:android/kotlin,ios/swiftui|standard-children:0|children:|properties:10:asset-type:string:required:none,10:local-path:string:required:none,11:markup-json:string:required:none,12:is-completed:bool:required:none,18:youtube-target-url:string:required:none,5:title:string:required:none,8:block-id:string:required:none,8:is-asset:bool:required:none|events:10:drag-start[4:uuid:string:required],4:drop[4:uuid:string:required,9:placement:string:required],4:edit[4:uuid:string:required],9:open-node[4:uuid:string:required]"},
          {"op":"set-extension-prop","id":2,"property":"block-id","value":"block-a"},
          {"op":"set-extension-prop","id":2,"property":"title","value":"Project"},
          {"op":"set-extension-prop","id":2,"property":"markup-json","value":"[]"},
          {"op":"set-extension-prop","id":2,"property":"youtube-target-url","value":""},
          {"op":"set-extension-prop","id":2,"property":"is-asset","value":false},
          {"op":"set-extension-prop","id":2,"property":"is-completed","value":false},
          {"op":"set-extension-prop","id":2,"property":"asset-type","value":""},
          {"op":"set-extension-prop","id":2,"property":"local-path","value":""},
          {"op":"insert-child","parent":1,"child":2,"index":0}
        ]}
        """)

        #expect(renderer.rootID == 1)
    }

    @Test("registers native navigation with standard retained children")
    func registersNativeNavigation() throws {
        let renderer = LGRenderer()

        try renderer.apply(patchJSON: """
        {"generation":1,"ops":[
          {"op":"create-node","id":1,"kind":"root"},
          {"op":"create-extension","id":2,"identifier":"native-navigation-stack","fingerprint":"\(LGNavigationExtension.fingerprint)"},
          {"op":"set-extension-prop","id":2,"property":"depth","value":0},
          {"op":"set-extension-prop","id":2,"property":"back-depth","value":0},
          {"op":"set-extension-prop","id":2,"property":"bottom-occupies-layout-space","value":false},
          {"op":"set-extension-prop","id":2,"property":"composer-dismissal-enabled","value":false},
          {"op":"set-extension-prop","id":2,"property":"title","value":"Journal"},
          {"op":"create-node","id":3,"kind":"column"},
          {"op":"insert-child","parent":2,"child":3,"index":0},
          {"op":"insert-child","parent":1,"child":2,"index":0}
        ]}
        """)

        #expect(renderer.rootID == 1)
    }

    @Test("registers native full-screen search navigation")
    func registersNativeSearchNavigation() throws {
        let renderer = LGRenderer()

        try renderer.apply(patchJSON: """
        {"generation":1,"ops":[
          {"op":"create-node","id":1,"kind":"root"},
          {"op":"create-extension","id":2,"identifier":"native-search-presentation","fingerprint":"\(LGSearchPresentationExtension.fingerprint)"},
          {"op":"set-extension-prop","id":2,"property":"presented","value":false},
          {"op":"set-extension-prop","id":2,"property":"bottom-occupies-layout-space","value":false},
          {"op":"set-extension-prop","id":2,"property":"depth","value":0},
          {"op":"set-extension-prop","id":2,"property":"query","value":""},
          {"op":"set-extension-prop","id":2,"property":"title","value":"Search"},
          {"op":"create-node","id":3,"kind":"column"},
          {"op":"create-node","id":4,"kind":"column"},
          {"op":"insert-child","parent":2,"child":3,"index":0},
          {"op":"insert-child","parent":2,"child":4,"index":1},
          {"op":"insert-child","parent":1,"child":2,"index":0}
        ]}
        """)

        #expect(renderer.rootID == 1)
    }


    @Test("forwards renderer events without owning application state")
    func forwardsEvents() {
        let renderer = LGRenderer()
        var received: LGRendererEvent?
        renderer.onEvent = { received = $0 }

        renderer.receiveForTesting(
            LGRendererEvent(kind: LGRendererEventKind.press, nodeID: 42)
        )

        #expect(received == LGRendererEvent(
            kind: LGRendererEventKind.press,
            nodeID: 42
        ))
    }

    @Test("routes renderer events through the LG native runtime")
    func routesEventsThroughNativeRuntime() async throws {
        let native = LGNativeRuntimeProbe()
        let runtime = LGRuntime(native: native)

        try runtime.start(platformCode: 2)
        #expect(runtime.renderer.rootID == 1)

        runtime.renderer.receiveForTesting(
            LGRendererEvent(kind: .press, nodeID: 7)
        )

        await runtime.drainEffectsForTesting()
        #expect(native.startedPlatforms == [2])
        #expect(native.pressedNodes == [7])
        #expect(runtime.renderer.rootID == 1)
    }

    @Test("rejects an empty initialization patch")
    func rejectsEmptyInitializationPatch() {
        let native = LGNativeRuntimeProbe()
        native.initialPatch = ""
        let runtime = LGRuntime(native: native)

        #expect(throws: LGRuntimeError.emptyInitializationPatch) {
            try runtime.start(platformCode: 2)
        }
        #expect(!runtime.isStarted)
    }

    @Test("routes native extension events through one LG bridge")
    func routesNativeExtensionEvents() async throws {
        let native = LGNativeRuntimeProbe()
        let runtime = LGRuntime(native: native)
        try runtime.start(platformCode: 2)

        runtime.renderer.receiveForTesting(
            LGRendererEvent(
                kind: .extension,
                nodeID: 17,
                extensionIdentifier: "outliner-editor",
                extensionName: "text-change",
                extensionValues: [
                    "title": LUIExtensionValue.string("Updated"),
                    "caret-utf16-offset": LUIExtensionValue.int(7),
                ]
            )
        )
        runtime.renderer.receiveForTesting(
            LGRendererEvent(
                kind: .extension,
                nodeID: 21,
                extensionIdentifier: "native-navigation-stack",
                extensionName: "back",
                extensionValues: ["count": LUIExtensionValue.int(2)]
            )
        )
        runtime.renderer.receiveForTesting(
            LGRendererEvent(
                kind: .extension,
                nodeID: 20,
                extensionIdentifier: "native-search-presentation",
                extensionName: "query-changed",
                extensionValues: [
                    "query": LUIExtensionValue.string("project alpha"),
                ]
            )
        )
        runtime.renderer.receiveForTesting(
            LGRendererEvent(
                kind: .extension,
                nodeID: 21,
                extensionIdentifier: "native-navigation-stack",
                extensionName: "viewport-changed",
                extensionValues: ["width": LUIExtensionValue.int(820)]
            )
        )
        runtime.renderer.receiveForTesting(
            LGRendererEvent(
                kind: .extension,
                nodeID: 18,
                extensionIdentifier: "outliner-block-content",
                extensionName: "open-node",
                extensionValues: ["uuid": LUIExtensionValue.string("page-a")]
            )
        )
        runtime.renderer.receiveForTesting(
            LGRendererEvent(
                kind: .extension,
                nodeID: 22,
                extensionIdentifier: "outliner-block-content",
                extensionName: "edit",
                extensionValues: ["uuid": LUIExtensionValue.string("block-a")]
            )
        )
        runtime.renderer.receiveForTesting(
            LGRendererEvent(
                kind: .extension,
                nodeID: 19,
                extensionIdentifier: "outliner-block-content",
                extensionName: "drop",
                extensionValues: [
                    "uuid": LUIExtensionValue.string("target-a"),
                    "placement": LUIExtensionValue.string("inside"),
                ]
            )
        )

        await runtime.drainEffectsForTesting()
        #expect(native.extensionEvents == [
            LGExtensionEventProbe(
                node: 17,
                identifier: "outliner-editor",
                name: "text-change",
                text: "Updated",
                value: 7
            ),
            LGExtensionEventProbe(
                node: 21,
                identifier: "native-navigation-stack",
                name: "back",
                text: "",
                value: 2
            ),
            LGExtensionEventProbe(
                node: 20,
                identifier: "native-search-presentation",
                name: "query-changed",
                text: "project alpha",
                value: 0
            ),
            LGExtensionEventProbe(
                node: 21,
                identifier: "native-navigation-stack",
                name: "viewport-changed",
                text: "",
                value: 820
            ),
            LGExtensionEventProbe(
                node: 18,
                identifier: "outliner-block-content",
                name: "open-node",
                text: "page-a",
                value: 0
            ),
            LGExtensionEventProbe(
                node: 22,
                identifier: "outliner-block-content",
                name: "edit",
                text: "block-a",
                value: 0
            ),
            LGExtensionEventProbe(
                node: 19,
                identifier: "outliner-block-content",
                name: "drop",
                text: "target-a",
                value: 1
            ),
        ])
        #expect(runtime.lastError == nil)
    }

    @Test("executes and resolves typed LG effects")
    func executesTypedEffects() async {
        let native = LGNativeRuntimeProbe()
        native.effects = [
            "{\"id\":7,\"kind\":\"send-capture\",\"text\":\"Project note\"}"
        ]
        let executor = LGEffectExecutorProbe()
        let runtime = LGRuntime(native: native, effectExecutor: executor)

        await runtime.drainEffectsForTesting()

        #expect(executor.effects == [
            LGEffect(id: 7, kind: "send-capture", text: "Project note")
        ])
        #expect(native.resolutions == [
            LGEffectResolutionProbe(id: 7, succeeded: true, message: "core response")
        ])
        await runtime.drainEffectsForTesting()
        #expect(native.appliedSnapshots == ["core response"])
        #expect(native.effectApplicationCalls == ["snapshot", "resolution"])
        #expect(native.effects.isEmpty)
        #expect(runtime.lastError == nil)
    }

    @Test("applies core snapshots before completing their originating effect")
    func appliesCoreSnapshotsBeforeCompletingEffect() async {
        let native = LGNativeRuntimeProbe()
        native.effects = [
            "{\"id\":9,\"kind\":\"load-older-journals\",\"text\":\"\"}"
        ]
        let executor = LGEffectExecutorProbe()
        let runtime = LGRuntime(native: native, effectExecutor: executor)

        await runtime.drainEffectsForTesting()

        #expect(native.effectApplicationCalls == ["snapshot", "resolution"])
    }

    @Test("applies the dequeue patch before the effect resolution patch")
    func appliesDequeuePatchBeforeResolution() async {
        let native = LGNativeRuntimeProbe()
        let executor = LGEffectExecutorProbe()
        executor.resolution = LGEffectResolution(
            succeeded: false,
            message: "Connection refused",
            output: .discard
        )
        let runtime = LGRuntime(native: native, effectExecutor: executor)
        native.effects = [
            """
            {"effect":{"id":8,"kind":"refresh-graphs","text":""},"patch":"{\\"generation\\":1,\\"ops\\":[{\\"op\\":\\"create-node\\",\\"id\\":1,\\"kind\\":\\"root\\"},{\\"op\\":\\"create-node\\",\\"id\\":2,\\"kind\\":\\"text\\"},{\\"op\\":\\"insert-child\\",\\"parent\\":1,\\"child\\":2,\\"index\\":0}]}"}
            """
        ]
        native.resolutionPatch = """
        {"generation":2,"ops":[
          {"op":"set-prop","id":2,"property":"text","value":"Resolved"}
        ]}
        """

        await runtime.drainEffectsForTesting()

        #expect(executor.effects == [
            LGEffect(id: 8, kind: "refresh-graphs", text: "")
        ])
        #expect(runtime.lastError == "Connection refused")
    }

    @Test("native core effects forward opaque metadata to the shared executor")
    func forwardsOpaqueCoreEffects() async throws {
        var captured: LogseqRPCRequest?
        let executor = LGCoreEffectExecutor { request in
            captured = request
            return #"{"apiVersion":1,"ok":false,"error":{"code":"invalid_effect","message":"Rejected by shared core"}}"#
        }
        let effect = LGEffect(id: 42, kind: "send-task", text: "A note", uuid: "block", value: 3, metadata: "opaque metadata")
        let result = await executor.execute(effect)
        let request = try #require(captured)
        #expect(request.params.action == "executeEffect")
        let payload = try JSONSerialization.jsonObject(with: Data(try #require(request.params.payload).utf8)) as? [String: Any]
        #expect(payload?["id"] as? Int == 42)
        #expect(payload?["metadata"] as? String == "opaque metadata")
        #expect(payload?["value"] as? Int == 3)
        #expect(!result.succeeded)
        #expect(result.message == "invalid_effect\nRejected by shared core")
    }

    @Test("applies a launch snapshot that arrives before the renderer starts")
    func queuesLaunchSnapshotUntilStart() async throws {
        let native = LGNativeRuntimeProbe()
        let runtime = LGRuntime(native: native)

        try runtime.applyCoreResponse("launch response")
        #expect(native.appliedSnapshots.isEmpty)

        try runtime.start(platformCode: 2)

        await runtime.drainEffectsForTesting()
        #expect(native.startedPlatforms == [2])
        #expect(native.appliedSnapshots == ["launch response"])
        #expect(runtime.isStarted)
    }

    @Test("graph catalog effects reuse the existing core graph lifecycle")
    func graphEffectsUseCoreLifecycle() async throws {
        var capturedRequests: [LogseqRPCRequest] = []
        var deletedGraphID: String?
        let executor = LGCoreEffectExecutor { request in
            capturedRequests.append(request)
            return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
        }

        let refresh = await executor.execute(
            LGEffect(id: 27, kind: "refresh-graphs", text: "")
        )
        let open = await executor.execute(
            LGEffect(id: 28, kind: "open-graph", text: "graph-a")
        )
        let create = await executor.execute(
            LGEffect(id: 29, kind: "create-graph", text: "New graph", value: 1)
        )
        let platformExecutor = LGCoreEffectExecutor(
            callCore: { _ in
                return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
            },
            deleteLocalGraph: { graphID in
                deletedGraphID = graphID
                return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
            }
        )
        let delete = await platformExecutor.execute(
            LGEffect(id: 30, kind: "delete-local-graph", text: "graph-a")
        )

        #expect(capturedRequests.map(\.params.action) == [
            "executeEffect", "executeEffect", "executeEffect",
        ])
        #expect(capturedRequests[1].params.payload?.contains("graph-a") == true)
        let createPayload = try #require(capturedRequests[2].params.payload)
        #expect(createPayload.contains("New graph"))
        #expect(createPayload.contains("value"))
        #expect(createPayload.contains("1"))
        #expect(deletedGraphID == "graph-a")
        #expect(refresh.succeeded)
        #expect(open.succeeded)
        #expect(create.succeeded)
        #expect(delete.succeeded)
    }

    @Test("graph catalog failures preserve the core error code and message")
    func graphFailuresPreserveStructuredReason() async {
        let executor = LGCoreEffectExecutor { _ in
            """
            {"apiVersion":1,"ok":false,"result":null,"error":{
              "code":"graph_discovery_failed","message":"Connection refused"
            }}
            """
        }

        let resolution = await executor.execute(
            LGEffect(id: 31, kind: "refresh-graphs", text: "")
        )

        #expect(!resolution.succeeded)
        #expect(resolution.message == "graph_discovery_failed\nConnection refused")
    }

    @Test("settings and diagnostics effects stay on the platform boundary")
    func settingsEffectsUsePlatformBoundary() async {
        var platformKinds: [String] = []
        var coreCallCount = 0
        let executor = LGCoreEffectExecutor(
            callCore: { _ in
                coreCallCount += 1
                return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
            },
            platformEffect: { effect in
                platformKinds.append(effect.kind)
                return LGEffectResolution(succeeded: true, message: "ok")
            }
        )

        let effects = [
            LGEffect(id: 30, kind: "persist-composer-draft", text: "Draft"),
            LGEffect(id: 31, kind: "sign-in", text: ""),
            LGEffect(id: 32, kind: "save-settings", text: "{}"),
            LGEffect(id: 33, kind: "refresh-runtime-log", text: "ui", value: 3),
            LGEffect(id: 34, kind: "copy-runtime-log", text: "[]"),
            LGEffect(id: 35, kind: "sign-out", text: ""),
            LGEffect(id: 36, kind: "open-graph", text: "graph-a"),
            LGEffect(id: 37, kind: "unlock-graph", text: "secret"),
            LGEffect(id: 38, kind: "create-graph", text: "New", value: 0),
            LGEffect(id: 39, kind: "delete-local-graph", text: "graph-a"),
            LGEffect(id: 40, kind: "present-attachment", text: "photos"),
            LGEffect(
                id: 41,
                kind: "present-asset",
                text: "",
                metadata: #"{"title":"Photo.jpg","assetType":"image/jpeg","localPath":"Assets/Photo.jpg"}"#
            ),
        ]
        for effect in effects {
            #expect((await executor.execute(effect)).succeeded)
        }

        #expect(platformKinds == effects.map(\.kind))
        #expect(coreCallCount == 0)
    }

    @Test("Hosted sign-in stays on the platform authentication boundary")
    func signInEffectsUseAuthenticationService() async {
        var signInCount = 0
        let handler = LGPlatformEffectHandler(
            saveSettings: { _ in },
            runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in },
            signIn: {
                signInCount += 1
                return nil
            },
            signOut: {}
        )
        let succeeded = await handler.execute(
            LGEffect(id: 30, kind: "sign-in", text: "")
        )
        let failingHandler = LGPlatformEffectHandler(
            saveSettings: { _ in },
            runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in },
            signIn: { "Authorization was cancelled" },
            signOut: {}
        )
        let failed = await failingHandler.execute(
            LGEffect(id: 31, kind: "sign-in", text: "")
        )

        #expect(signInCount == 1)
        #expect(succeeded.succeeded)
        #expect(succeeded.output == .discard)
        #expect(!failed.succeeded)
        #expect(failed.message == "Authorization was cancelled")
    }

    @Test("attachment effects preserve the selected system service")
    func attachmentEffectsUsePlatformBoundary() async {
        var selectedKind: String?
        let handler = LGPlatformEffectHandler(
            saveSettings: { _ in },
            runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in },
            signOut: {},
            presentAttachment: { kind in
                selectedKind = kind
                return true
            }
        )

        let resolution = await handler.execute(
            LGEffect(id: 40, kind: "present-attachment", text: "photos")
        )

        #expect(selectedKind == "photos")
        #expect(resolution.succeeded)
    }

    @Test("asset presentation effects preserve the local asset descriptor")
    func assetPresentationEffectsUsePlatformBoundary() async {
        var presented: LGAssetPresentationPayload?
        let handler = LGPlatformEffectHandler(
            saveSettings: { _ in },
            runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in },
            signOut: {},
            presentAsset: { asset in
                presented = asset
                return URL(fileURLWithPath: "/tmp/Photo.jpg")
            }
        )

        let resolution = await handler.execute(LGEffect(
            id: 41,
            kind: "present-asset",
            text: "",
            metadata: #"{"title":"Photo.jpg","assetType":"image/jpeg","localPath":"Assets/Photo.jpg"}"#
        ))

        #expect(presented == LGAssetPresentationPayload(
            title: "Photo.jpg",
            assetType: "image/jpeg",
            localPath: "Assets/Photo.jpg"
        ))
        #expect(resolution.succeeded)
        #expect(resolution.output == .hostUpdate("asset-preview-resolved"))
        let descriptor = try? JSONSerialization.jsonObject(with: Data(resolution.message.utf8)) as? [String: Any]
        #expect(descriptor?["path"] as? String == "/tmp/Photo.jpg")
    }

    @Test("page sharing stays on the platform presentation boundary")
    func pageSharingEffectsUsePlatformBoundary() async {
        var presented: LGPageSharePayload?
        let handler = LGPlatformEffectHandler(
            saveSettings: { _ in },
            runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in },
            signOut: {},
            presentPageShare: { payload in
                presented = payload
                return true
            }
        )

        let resolution = await handler.execute(LGEffect(
            id: 44,
            kind: "present-page-share",
            text: "Project\n- Photo.jpg",
            metadata: #"["Assets/Photo.jpg"]"#
        ))

        #expect(presented == LGPageSharePayload(
            text: "Project\n- Photo.jpg",
            localAssetPaths: ["Assets/Photo.jpg"]
        ))
        #expect(resolution.succeeded)
        #expect(resolution.output == .discard)
    }

    @Test("graph database export stays on the platform presentation boundary")
    func graphDatabaseExportUsesPlatformBoundary() async {
        var presented = false
        let handler = LGPlatformEffectHandler(
            saveSettings: { _ in },
            runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in },
            signOut: {},
            exportGraphDatabase: {
                presented = true
                return true
            }
        )

        let resolution = await handler.execute(LGEffect(
            id: 45,
            kind: "export-graph-database",
            text: ""
        ))

        #expect(presented)
        #expect(resolution.succeeded)
        #expect(resolution.output == .discard)
    }

    @Test("external URLs stay on the platform presentation boundary")
    func externalURLsUsePlatformBoundary() async {
        var openedURL: URL?
        let handler = LGPlatformEffectHandler(
            saveSettings: { _ in },
            runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in },
            signOut: {},
            openExternalURL: { url in
                openedURL = url
                return true
            }
        )

        let resolution = await handler.execute(LGEffect(
            id: 46,
            kind: "open-external-url",
            text: "https://github.com/logseq/logseq"
        ))

        #expect(openedURL?.absoluteString == "https://github.com/logseq/logseq")
        #expect(resolution.succeeded)
        #expect(resolution.output == .discard)
    }

    @Test("external URL effects reject non-web schemes")
    func externalURLsRejectNonWebSchemes() async {
        var presentationCount = 0
        let handler = LGPlatformEffectHandler(
            saveSettings: { _ in },
            runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in },
            signOut: {},
            openExternalURL: { _ in
                presentationCount += 1
                return true
            }
        )

        let resolution = await handler.execute(LGEffect(
            id: 47,
            kind: "open-external-url",
            text: "file:///private/data"
        ))

        #expect(presentationCount == 0)
        #expect(!resolution.succeeded)
        #expect(resolution.output == .discard)
    }

    @Test("sync now reuses the platform sync pump")
    func syncNowEffectsUsePlatformBoundary() async {
        var syncCount = 0
        let handler = LGPlatformEffectHandler(
            saveSettings: { _ in },
            runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in },
            signOut: {},
            syncNow: { syncCount += 1 }
        )

        let resolution = await handler.execute(
            LGEffect(id: 45, kind: "sync-now", text: "")
        )

        #expect(syncCount == 1)
        #expect(resolution.succeeded)
        #expect(resolution.output == .discard)
    }

    @Test("automatic sync reaches the pending pump through the platform boundary")
    func automaticSyncUsesPlatformBoundary() async {
        var platformKinds: [String] = []
        var coreRequests = 0
        let executor = LGCoreEffectExecutor(
            callCore: { _ in
                coreRequests += 1
                return #"{"apiVersion":1,"ok":false,"error":{"code":"unexpected","message":"Unexpected RPC"}}"#
            },
            platformEffect: { effect in
                platformKinds.append(effect.kind)
                return LGEffectResolution(succeeded: true, message: "", output: .discard)
            }
        )
        for kind in ["sync-pending", "sync-now"] {
            let resolution = await executor.execute(LGEffect(id: 1, kind: kind, text: ""))
            #expect(resolution.succeeded)
            #expect(resolution.output == .discard)
        }
        #expect(platformKinds == ["sync-pending", "sync-now"])
        #expect(coreRequests == 0)
    }

    @Test("automatic upload requests never invoke manual reconnect")
    func pendingSyncDoesNotInvokeManualReconnect() async {
        var uploads = 0
        var reconnects = 0
        let handler = LGPlatformEffectHandler(
            saveSettings: { _ in }, runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in }, signOut: {},
            syncPending: { uploads += 1 }, syncNow: { reconnects += 1 }
        )
        for _ in 0..<10 {
            let result = await handler.execute(LGEffect(id: 1, kind: "sync-pending", text: ""))
            #expect(result.succeeded && result.output == .discard)
        }
        #expect(uploads == 10 && reconnects == 0)
        _ = await handler.execute(LGEffect(id: 2, kind: "sync-now", text: ""))
        #expect(uploads == 10 && reconnects == 1)
        let unavailable = LGPlatformEffectHandler(
            saveSettings: { _ in }, runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in }, signOut: {}, syncNow: { reconnects += 1 }
        )
        let result = await unavailable.execute(LGEffect(id: 3, kind: "sync-pending", text: ""))
        #expect(!result.succeeded && reconnects == 1)
    }

    @Test("composer draft effects persist through the platform boundary")
    func composerDraftEffectsUsePlatformPersistence() async {
        var persistedDrafts: [String] = []
        let handler = LGPlatformEffectHandler(
            saveSettings: { _ in },
            persistComposerDraft: { persistedDrafts.append($0) },
            runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in },
            signOut: {}
        )

        let saved = await handler.execute(
            LGEffect(id: 41, kind: "persist-composer-draft", text: "稍后\nLater")
        )
        let cleared = await handler.execute(
            LGEffect(id: 42, kind: "persist-composer-draft", text: "")
        )

        #expect(persistedDrafts == ["稍后\nLater", ""])
        #expect(saved.succeeded)
        #expect(saved.output == .discard)
        #expect(cleared.succeeded)
    }

    @Test("platform settings handler preserves persisted values and multiline logs")
    func platformSettingsHandlerPreservesValuesAndLogs() async throws {
        var saved: LGSettingsPayload?
        var copied = ""
        var signedOut = false
        let log = LogseqRuntimeLog(capacity: 10)
        log.append(
            level: .error,
            source: .ui,
            message: "第一行\nsecond line",
            timestampMilliseconds: 1_000
        )
        log.append(level: .info, source: .core, message: "core")
        let handler = LGPlatformEffectHandler(
            saveSettings: { saved = $0 },
            runtimeLog: log,
            copyText: { copied = $0 },
            signOut: { signedOut = true }
        )

        let save = await handler.execute(LGEffect(
            id: 40,
            kind: "save-settings",
            text: #"{"appearance":"dark","language":"zh-CN","spellCheck":false,"autoCorrection":true,"sidebarTabs":["journals","graphs"],"baseURL":"https://example.com"}"#
        ))
        let refresh = await handler.execute(LGEffect(
            id: 41,
            kind: "refresh-runtime-log",
            text: "ui",
            value: 1
        ))
        let copy = await handler.execute(LGEffect(
            id: 42,
            kind: "copy-runtime-log",
            text: refresh.message
        ))
        let signOut = await handler.execute(
            LGEffect(id: 43, kind: "sign-out", text: "")
        )

        #expect(saved?.appearance == "dark")
        #expect(saved?.language == "zh-CN")
        #expect(saved?.sidebarTabs == ["journals", "graphs"])
        #expect(save.output == .discard)
        #expect(refresh.output == LGEffectOutput.hostUpdate("runtime-log"))
        let records = try JSONDecoder().decode(
            [LGRuntimeLogPayload].self,
            from: Data(refresh.message.utf8)
        )
        #expect(records.map(\.message) == ["第一行\nsecond line"])
        #expect(records.first?.timestamp != "1000")
        #expect(copied.contains("第一行\nsecond line"))
        #expect(copy.succeeded)
        #expect(signedOut)
        #expect(signOut.succeeded)
    }

    @Test("graph lifecycle effects stay on the platform service boundary")
    func graphLifecycleEffectsUsePlatformServices() async {
        var graphKinds: [String] = []
        let handler = LGPlatformEffectHandler(
            saveSettings: { _ in },
            runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in },
            signOut: {},
            graphEffect: { effect in
                graphKinds.append(effect.kind)
                return LGEffectResolution(
                    succeeded: true,
                    message: "",
                    output: .discard
                )
            }
        )

        for effect in [
            LGEffect(id: 45, kind: "open-graph", text: "a"),
            LGEffect(id: 46, kind: "unlock-graph", text: "secret"),
            LGEffect(id: 47, kind: "create-graph", text: "New", value: 0),
            LGEffect(id: 48, kind: "delete-local-graph", text: "a"),
        ] {
            #expect((await handler.execute(effect)).succeeded)
        }

        #expect(graphKinds == [
            "open-graph", "unlock-graph", "create-graph", "delete-local-graph",
        ])
    }

    @Test("successful graph lifecycle effects publish the authoritative graph snapshot")
    func graphLifecycleEffectsPublishSnapshot() throws {
        let snapshot = try JSONDecoder().decode(
            LogseqSnapshot.self,
            from: Data(
                #"{"revision":3,"blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"New graph","selectedGraphId":"graph-new","graphs":[{"id":"graph-new","name":"New graph","schemaVersion":"65.33","isEncrypted":true,"isReady":true}]}"#.utf8
            )
        )

        let resolution = LGGraphEffectResolution.make(
            succeeded: true,
            snapshot: snapshot,
            errorMessage: nil
        )

        #expect(resolution.succeeded)
        #expect(resolution.output == .coreResponse)
        let envelope = try JSONDecoder().decode(
            LGGraphSnapshotEnvelope.self,
            from: Data(resolution.message.utf8)
        )
        #expect(envelope.ok)
        #expect(envelope.result.selectedGraphId == "graph-new")
        #expect(envelope.result.graphs?.map(\.id) == ["graph-new"])
    }

    @Test("creating a graph persists the authoritative selected graph")
    func graphCreationPersistsSelectedGraph() async {
        let defaults = UserDefaults.standard
        let key = "logseq.selectedGraphId"
        let previousValue = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        let store = LogseqStore { _ in
            #"{"apiVersion":1,"ok":true,"result":{"revision":3,"blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"New graph","selectedGraphId":"graph-new","graphs":[{"id":"graph-new","name":"New graph","schemaVersion":"65.33","isEncrypted":true,"isReady":true}]}}"#
        }
        let lifecycle = LGGraphLifecycle(
            store: store,
            authentication: LogseqAuthenticationStore(
                provider: LGGraphLifecycleCognitoProbe()
            ),
            syncCoordinator: GraphSyncCoordinator(),
            databasePath: "/tmp/unused-logseq.sqlite",
            openCreatedGraph: { _ in
                LGEffectResolution(
                    succeeded: true,
                    message: "",
                    output: .discard
                )
            }
        )

        let resolution = await lifecycle.execute(
            LGEffect(id: 49, kind: "create-graph", text: "New graph", value: 1)
        )

        #expect(resolution.succeeded)
        #expect(defaults.string(forKey: key) == "graph-new")
    }

    @Test("failed graph creation preserves the previous selected graph")
    func failedGraphCreationPreservesSelectedGraph() async {
        let defaults = UserDefaults.standard
        let key = "logseq.selectedGraphId"
        let previousValue = defaults.object(forKey: key)
        defaults.set("graph-old", forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        let store = LogseqStore { _ in
            #"{"apiVersion":1,"ok":false,"error":{"code":"graph_create_failed","message":"Could not create graph"}}"#
        }
        let lifecycle = LGGraphLifecycle(
            store: store,
            authentication: LogseqAuthenticationStore(
                provider: LGGraphLifecycleCognitoProbe()
            ),
            syncCoordinator: GraphSyncCoordinator(),
            databasePath: "/tmp/unused-logseq.sqlite"
        )

        let resolution = await lifecycle.execute(
            LGEffect(id: 50, kind: "create-graph", text: "New graph", value: 0)
        )

        #expect(!resolution.succeeded)
        #expect(defaults.string(forKey: key) == "graph-old")
    }

    @Test("runtime routes platform output to host updates instead of core snapshots")
    func runtimeRoutesPlatformOutputToHostUpdates() async {
        let native = LGNativeRuntimeProbe()
        native.effects = [
            "{\"id\":44,\"kind\":\"refresh-runtime-log\",\"text\":\"ui\",\"value\":0}"
        ]
        let executor = LGEffectExecutorProbe()
        executor.resolution = LGEffectResolution(
            succeeded: true,
            message: "[]",
            output: LGEffectOutput.hostUpdate("runtime-log")
        )
        let runtime = LGRuntime(native: native, effectExecutor: executor)

        await runtime.drainEffectsForTesting()

        #expect(native.hostUpdates == [LGHostUpdateProbe(
            kind: "runtime-log",
            payload: "[]"
        )])
        #expect(native.appliedSnapshots.isEmpty)
    }

    @Test("host updates wait for renderer initialization")
    func hostUpdatesWaitForRendererInitialization() throws {
        let native = LGNativeRuntimeProbe()
        let runtime = LGRuntime(native: native)

        try runtime.applyHostUpdate(kind: "local-graph-ids", payload: #"["a"]"#)
        #expect(native.hostUpdates.isEmpty)

        try runtime.start(platformCode: 2)
        #expect(native.hostUpdates == [LGHostUpdateProbe(
            kind: "local-graph-ids",
            payload: #"["a"]"#
        )])
    }

    @Test("successful outliner autosave starts the sync pump")
    func successfulOutlinerAutosaveStartsSyncPump() async {
        let native = LGNativeRuntimeProbe()
        native.effects = [
            "{\"id\":19,\"kind\":\"change-outliner-text\",\"text\":\"Updated\"}",
            "{\"waitMs\":1}",
            "{\"id\":20,\"kind\":\"save-outliner-editing\",\"text\":\"editing\"}",
            "{\"id\":21,\"kind\":\"sync-pending\",\"text\":\"\"}",
        ]
        let executor = LGEffectExecutorProbe()
        executor.resolve = { effect in
            if effect.kind == "sync-pending" {
                return LGEffectResolution(
                    succeeded: true,
                    message: "",
                    output: .discard
                )
            }
            return LGEffectResolution(
                succeeded: true,
                message: #"{"apiVersion":1,"ok":true,"result":{"hasPendingSemanticOperations":true}}"#
            )
        }
        let runtime = LGRuntime(
            native: native,
            effectExecutor: executor
        )

        await runtime.drainEffectsForTesting()
        for _ in 0..<10 {
            await Task.yield()
            await runtime.drainEffectsForTesting()
        }

        #expect(executor.effects.map(\.kind) == [
            "change-outliner-text",
            "save-outliner-editing",
            "sync-pending",
        ])
    }

    @Test("pending outliner mutation starts the sync pump")
    func pendingOutlinerMutationStartsSyncPump() async {
        let native = LGNativeRuntimeProbe()
        native.effects = [
            "{\"id\":20,\"kind\":\"outliner-toolbar\",\"text\":\"task\"}",
            "{\"id\":21,\"kind\":\"sync-pending\",\"text\":\"\"}",
        ]
        let executor = LGEffectExecutorProbe()
        executor.resolve = { effect in
            if effect.kind == "sync-pending" {
                return LGEffectResolution(
                    succeeded: true,
                    message: "",
                    output: .discard
                )
            }
            return LGEffectResolution(
                succeeded: true,
                message: #"{"apiVersion":1,"ok":true,"result":{"hasPendingSemanticOperations":true}}"#
            )
        }
        let runtime = LGRuntime(native: native, effectExecutor: executor)

        await runtime.drainEffectsForTesting()

        #expect(executor.effects.map(\.kind) == [
            "outliner-toolbar",
            "sync-pending",
        ])
    }

    @Test("delivers each core platform command revision exactly once")
    func deliversPlatformCommandsOnce() async throws {
        let native = LGNativeRuntimeProbe()
        let platformCommands = LGPlatformCommandHandlerProbe()
        let runtime = LGRuntime(
            native: native,
            platformCommandHandler: platformCommands
        )
        try runtime.start(platformCode: 2)
        let response = """
        {"apiVersion":1,"ok":true,"result":{
          "graphName":"Work","outlinerCommandRevision":7,
          "outlinerCommands":[{"type":"setClipboardText","text":"Copied"}]
        }}
        """

        try runtime.applyCoreResponse(response)
        try runtime.applyCoreResponse(response)

        await runtime.drainEffectsForTesting()
        #expect(platformCommands.batches.count == 1)
        let batch = try #require(platformCommands.batches.first)
        #expect(batch.revision == 7)
        #expect(batch.graphName == "Work")
        #expect(batch.commands.map(\.type) == ["setClipboardText"])
    }

    @Test("skips unchanged core snapshots without hiding later sync changes")
    func skipsUnchangedCoreSnapshots() async throws {
        let native = LGNativeRuntimeProbe()
        let runtime = LGRuntime(native: native)
        try runtime.start(platformCode: 2)
        let authoritative = """
        {"apiVersion":1,"ok":true,"result":{
          "revision":1,"blocks":[],"hasPendingSemanticOperations":false,
          "pendingSyncRequest":null
        }}
        """
        let unchangedPendingSync = """
        {"apiVersion":1,"ok":true,"result":{
          "isPendingSyncPatch":true,"hasPendingSemanticOperations":false,
          "pendingSyncRequest":null
        }}
        """
        let changedPendingSync = """
        {"apiVersion":1,"ok":true,"result":{
          "isPendingSyncPatch":true,"hasPendingSemanticOperations":true,
          "pendingSyncRequest":{}
        }}
        """

        try runtime.applyCoreResponse(authoritative)
        try runtime.applyCoreResponse(authoritative)
        try runtime.applyCoreResponse(unchangedPendingSync)
        try runtime.applyCoreResponse(changedPendingSync)
        try runtime.applyCoreResponse(changedPendingSync)
        try runtime.applyCoreResponse(authoritative)
        await runtime.drainEffectsForTesting()

        #expect(native.appliedSnapshots == [
            authoritative,
            changedPendingSync,
            authoritative,
        ])
    }

    @Test("routes core commands into platform services and presentation intents")
    func routesPlatformCommands() {
        var clipboardValues: [String] = []
        var hapticStyles: [String?] = []
        var presentations: [LGPlatformPresentation] = []
        let router = LGPlatformCommandRouter(
            setClipboardText: { clipboardValues.append($0) },
            performHaptic: { hapticStyles.append($0) },
            present: { presentations.append($0) }
        )

        router.handle(LGPlatformCommandBatch(
            revision: 8,
            graphName: "Work",
            commands: [
                LogseqOutlinerCommand(
                    type: "setClipboardReferences",
                    style: nil,
                    uuid: nil,
                    uuids: ["a", "b"],
                    text: nil
                ),
                LogseqOutlinerCommand(
                    type: "setClipboardURLs",
                    style: nil,
                    uuid: nil,
                    uuids: ["a"],
                    text: nil
                ),
                LogseqOutlinerCommand(
                    type: "haptic",
                    style: "selection",
                    uuid: nil,
                    uuids: nil,
                    text: nil
                ),
                LogseqOutlinerCommand(
                    type: "pickAttachment",
                    style: nil,
                    uuid: "target",
                    uuids: nil,
                    text: nil
                ),
            ]
        ))

        #expect(clipboardValues == [
            "[[a]]\n[[b]]",
            "logseq://graph/Work?block-id=a",
        ])
        #expect(hapticStyles == ["selection"])
        #expect(presentations == [.pickAttachment(blockID: "target")])
    }
}

private struct FlashcardReviewPayload: Decodable {
    let uuid: String
    let rating: String
    let now: Int64
    let operationId: String
}

private struct LGEffectResolutionProbe: Equatable {
    let id: Int
    let succeeded: Bool
    let message: String
}

private struct LGExtensionEventProbe: Equatable {
    let node: Int
    let identifier: String
    let name: String
    let text: String
    let value: Int
}

private struct LGHostUpdateProbe: Equatable {
    let kind: String
    let payload: String
}

@MainActor
private final class LGEffectExecutorProbe: LGEffectExecuting {
    var effects: [LGEffect] = []
    var resolution = LGEffectResolution(succeeded: true, message: "core response")
    var resolve: ((LGEffect) -> LGEffectResolution)?

    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        effects.append(effect)
        return resolve?(effect) ?? resolution
    }
}

private struct LGGraphLifecycleCognitoProbe: LogseqCognitoProviding {
    func apiToken() async throws -> String? { nil }
    func signIn() async throws -> String { "" }
    func signOut() async throws {}
}

@MainActor
private final class LGPlatformCommandHandlerProbe: LGPlatformCommandHandling {
    var batches: [LGPlatformCommandBatch] = []

    func handle(_ batch: LGPlatformCommandBatch) {
        batches.append(batch)
    }
}

@MainActor
private final class LGNativeRuntimeProbe: @preconcurrency LGNativeCalling {
    var initialPatch = """
    {"generation":1,"ops":[
      {"op":"create-node","id":1,"kind":"root"},
      {"op":"create-node","id":2,"kind":"text"},
      {"op":"set-prop","id":2,"property":"text","value":"Ready"},
      {"op":"insert-child","parent":1,"child":2,"index":0}
    ]}
    """
    var startedPlatforms: [Int] = []
    var pressedNodes: [Int] = []
    var effects: [String] = []
    var resolutions: [LGEffectResolutionProbe] = []
    var resolutionPatch = ""
    var appliedSnapshots: [String] = []
    var effectApplicationCalls: [String] = []
    var extensionEvents: [LGExtensionEventProbe] = []
    var hostUpdates: [LGHostUpdateProbe] = []

    func initialize(
        platformCode: Int,
        hostCode: Int,
        authenticationCode: Int
    ) -> String {
        startedPlatforms.append(platformCode)
        return initialPatch
    }

    func appear(node: Int) -> String { "" }

    func press(node: Int) -> String {
        pressedNodes.append(node)
        return """
        {"generation":2,"ops":[
          {"op":"create-node","id":2,"kind":"text"},
          {"op":"set-prop","id":2,"property":"text","value":"Opened"},
          {"op":"insert-child","parent":1,"child":2,"index":0}
        ]}
        """
    }

    func longPress(node: Int) -> String { "" }
    func textChanged(node: Int, text: String) -> String { "" }
    func submit(node: Int) -> String { "" }
    func toggleChanged(node: Int, checked: Bool) -> String { "" }
    func change(node: Int) -> String { "" }
    func valueChanged(node: Int, value: Double) -> String { "" }
    func dismiss(node: Int) -> String { "" }
    func doublePress(node: Int) -> String { "" }
    func picked(node: Int, payload: String) -> String { "" }
    func visibleRange(node: Int, first: Int, last: Int) -> String { "" }
    func scrollCompleted(node: Int, token: Int, outcome: String) -> String { "" }
    func extensionEvent(
        node: Int,
        identifier: String,
        name: String,
        text: String,
        value: Int
    ) -> String {
        extensionEvents.append(LGExtensionEventProbe(
            node: node,
            identifier: identifier,
            name: name,
            text: text,
            value: value
        ))
        return ""
    }
    func dispose() -> String { "" }
    func takeEffect() -> String {
        effects.isEmpty ? "" : effects.removeFirst()
    }
    func resolveEffect(id: Int, succeeded: Bool, message: String) -> String {
        effectApplicationCalls.append("resolution")
        resolutions.append(LGEffectResolutionProbe(
            id: id,
            succeeded: succeeded,
            message: message
        ))
        return resolutionPatch
    }
    func applySnapshot(_ response: String) -> String {
        effectApplicationCalls.append("snapshot")
        appliedSnapshots.append(response)
        return ""
    }
    func applyHostUpdate(kind: String, payload: String) -> String {
        hostUpdates.append(LGHostUpdateProbe(kind: kind, payload: payload))
        return ""
    }
}
