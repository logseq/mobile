import Foundation
import OSLog
import SwiftUI
import LogseqModel
import LUIAppleBackend

@preconcurrency import BackgroundTasks
import UIKit

struct LogseqAppLogger {
    private let systemLogger = os.Logger(subsystem: "com.logseq.logseq", category: "Logseq")

    func debug(_ message: String) {
        LogseqRuntimeLog.shared.append(level: .debug, source: .ui, message: message)
        systemLogger.debug("\(message, privacy: .public)")
    }

    func info(_ message: String) {
        LogseqRuntimeLog.shared.append(level: .info, source: .ui, message: message)
        systemLogger.info("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        LogseqRuntimeLog.shared.append(level: .error, source: .ui, message: message)
        systemLogger.error("\(message, privacy: .public)")
    }
}

let logger = LogseqAppLogger()

@MainActor
private final class LGCoreResponseRelay {
    var apply: ((String) -> Void)?

    func send(_ response: String) {
        if let apply {
            apply(response)
        }
    }
}

/// The shared top-level view for the app, loaded from the platform-specific App delegates below.
public struct LogseqRootView : View {
    @AppStorage("logseq.appearance") private var appearance = "system"
    @AppStorage("logseq.language") private var language = "system"
    @Environment(\.colorScheme) private var colorScheme

    private let runtime = LogseqLogseqRuntime.shared

    public init() {
    }

    public var body: some View {
        appContent
        .preferredColorScheme(
            appearance == "light" ? .light : (appearance == "dark" ? .dark : nil)
        )
        .environment(\.locale, preferredLocale)
        .tint(LogseqThemePolicy.accent)
        .foregroundStyle(themePalette.primaryText)
        // Semantic colors inside the LUI tree come from the `theme` prop the
        // OCaml view emits (adaptive light/dark tokens), not a host-side
        // dictionary — the shell keeps its palette for chrome below.
        .background(themePalette.background.ignoresSafeArea())
    }

    private var appContent: some View {
        LGRendererRoot(renderer: runtime.lgRuntime.renderer)
            .onAppear {
                LogseqAppDelegate.shared.reportLaunchStage("root_appeared")
                DispatchQueue.main.async {
                    LogseqAppDelegate.shared.onFirstUIRendered()
                }
            }
            .task {
                await runtime.runLGApplication()
                logger.info("App logs are viewable in the Xcode console on Apple platforms")
            }
            .task {
                for await available in NetworkAvailabilityStream.values() {
                    await runtime.setNetworkAvailable(available)
                }
            }
            .onChange(of: runtime.authentication.state) { previousState, state in
                runtime.publishAuthenticationState()
                guard state == .signedIn, previousState != .restoring else { return }
                Task { await runtime.resumeLGApplication() }
            }
            .onOpenURL { url in
                runtime.acceptSharedCaptureURL(url)
            }
            .modifier(LGPlatformPresentationHost(
                coordinator: runtime.presentationCoordinator,
                store: runtime.store,
                stageAsset: { payload in
                    try runtime.lgRuntime.applyHostUpdate(kind: "composer-asset", payload: payload)
                },
                openJournal: { day in
                    let json = await LogseqCore.callAsync(LogseqRPCRequest(method: "dispatch",
                        params: LogseqRPCParams(action: "ensureJournal", payload: String(day))))
                    let response = try JSONDecoder().decode(LGJournalCalendarResponse.self, from: Data(json.utf8))
                    guard response.ok, let uuid = response.result?.uuid else {
                        throw NSError(domain: "LogseqJournal", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: response.error?.message ?? "Could not open journal"])
                    }
                    let encoded = String(decoding: try JSONEncoder().encode(uuid), as: UTF8.self)
                    try runtime.lgRuntime.applyHostUpdate(kind: "open-node", payload: encoded)
                }
            ))
    }

    private var preferredLocale: Locale {
        let identifier = LogseqSettingsPolicy.normalizedLanguageID(language)
        return identifier == "system" ? Locale.current : Locale(identifier: identifier)
    }

    private var themePalette: LogseqThemePalette {
        LogseqThemePolicy.palette(
            mode: LogseqThemeMode(rawValue: appearance) ?? .system,
            systemIsDark: colorScheme == .dark
        )
    }

}

@MainActor public final class LogseqLogseqRuntime {
    public static let shared = LogseqLogseqRuntime()

    public let store: LogseqStore
    public let lgRuntime: LGRuntime
    public let authentication: LogseqAuthenticationStore
    public let presentationCoordinator: LGPlatformPresentationCoordinator
    let syncCoordinator: GraphSyncCoordinator
    private struct LocalLaunchResult: Sendable {
        let catalogResponse: String
        let graphResponse: String?
        let isEncrypted: Bool?
    }
    private var localLaunchResult: LocalLaunchResult?
    private var didApplyLocalLaunchResult = false
    private var sharedCaptureTask: Task<Void, Never>?
    private var authenticationRestoreTask: Task<Void, Never>?
    private var didStartLGRenderer = false
    private var didStartLGApplication = false
    private var isLGApplicationReady = false
    private var isResumingLGApplication = false
    private var didResumeCurrentActivation = false
    private let graphLifecycle: LGGraphLifecycle
    private let platformCommandRouter: LGPlatformCommandRouter

    private struct SettingsHostPayload: Encodable {
        let appearance: String
        let language: String
        let spellCheck: Bool
        let autoCorrection: Bool
        let sidebarTabs: [String]
        let baseURL: String
        let version: String
        let revision: String
    }

    private struct AuthenticationHostPayload: Encodable {
        let state: String
        let errorMessage: String?
    }

    private init() {
        #if DEBUG
        NSSetUncaughtExceptionHandler { exception in
            NSLog(
                "LUICRASH %@: %@\n%@",
                exception.name.rawValue,
                exception.reason ?? "",
                exception.callStackSymbols.joined(separator: "\n")
            )
        }
        #endif
        try? FileManager.default.removeItem(
            at: URL.documentsDirectory.appendingPathComponent("cached-home-snapshot.json")
        )
        let responseRelay = LGCoreResponseRelay()
        let store = LogseqStore(
            call: { request in LogseqCore.shared.logseq_call(request) },
            responseObserver: responseRelay.send
        )
        let configuration = LogseqCognitoConfiguration.load()
        let authentication = LogseqAuthenticationStore(
            provider: CognitoAuthProvider(
                region: configuration.region,
                userPoolId: configuration.userPoolId,
                appClientId: configuration.appClientId,
                oauthDomain: configuration.oauthDomain,
                redirectURI: configuration.redirectURI,
                logoutURI: configuration.logoutURI,
                scopes: configuration.scopes
            )
        )
        let syncCoordinator = GraphSyncCoordinator()
        let presentationCoordinator = LGPlatformPresentationCoordinator()
        let databasePath = URL.documentsDirectory
            .appendingPathComponent("logseq.sqlite")
            .path
        let graphLifecycle = LGGraphLifecycle(
            store: store,
            authentication: authentication,
            syncCoordinator: syncCoordinator,
            databasePath: databasePath
        )
        let platformHandler = LGPlatformEffectHandler(
            saveSettings: { settings in
                let defaults = UserDefaults.standard
                let previousBaseURL = LogseqSettingsPolicy.storedBaseURL(in: defaults)
                defaults.set(settings.appearance, forKey: "logseq.appearance")
                defaults.set(
                    LogseqSettingsPolicy.normalizedLanguageID(settings.language),
                    forKey: "logseq.language"
                )
                defaults.set(settings.spellCheck, forKey: "logseq.editor.spellCheck")
                defaults.set(
                    settings.autoCorrection,
                    forKey: "logseq.editor.autoCorrection"
                )
                defaults.set(
                    settings.sidebarTabs.joined(separator: ","),
                    forKey: "logseq.mobile.sidebarTabs"
                )
                defaults.set(settings.baseURL, forKey: "logseq.baseURL")
                if LogseqSettingsPolicy.storedBaseURL(in: defaults) != previousBaseURL {
                    try await graphLifecycle.reconfigureAPI()
                }
            },
            persistComposerDraft: { draft in
                UserDefaults.standard.set(draft, forKey: "logseq.composerDraft")
            },
            runtimeLog: .shared,
            copyText: { text in Self.copyText(text) },
            signIn: {
                await authentication.signIn()
                let message = authentication.state == .signedIn
                    ? nil
                    : authentication.errorMessage ?? "Hosted sign-in failed"
                return message
            },
            signOut: {
                await syncCoordinator.stopForeground()
                await authentication.signOut()
                let defaults = UserDefaults.standard
                defaults.set("", forKey: "logseq.selectedGraphId")
                defaults.removeObject(forKey: "logseq.uiSession")
                store.configure(
                    baseURL: LogseqSettingsPolicy.storedBaseURL(in: defaults),
                    token: "",
                    refreshAfterApply: false
                )
            },
            openExternalURL: { url in
                return await UIApplication.shared.open(url)
            },
            exportGraphDatabase: {
                guard let graphID = store.snapshot.selectedGraphId,
                      !graphID.isEmpty
                else { return false }
                let databaseURL = LogseqGraphLocalStorage.directoryURL(
                    databasePath: databasePath,
                    graphID: graphID
                ).appendingPathComponent("graph.sqlite")
                #if os(iOS)
                return presentationCoordinator.presentFile(databaseURL)
                #else
                return false
                #endif
            },
            graphEffect: { effect in await graphLifecycle.execute(effect) },
            presentJournalCalendar: { presentationCoordinator.presentJournalCalendar() },
            presentAttachment: { kind in
                presentationCoordinator.presentAttachment(kind)
            },
            // Asset preview is presented by the file-preview node on iOS; the
            // effect reports the resolved file URL back to the core so the
            // preview only mounts for a path that exists on disk.
            presentAsset: { asset in
                LocalAssetPath.resolve(
                    asset.localPath,
                    title: asset.title,
                    assetType: asset.assetType
                )
            },
            presentPageShare: { payload in
                return presentationCoordinator.presentPageShare(payload)
            },
            syncNow: {
                store.syncPending()
                Task { await syncCoordinator.kickForeground() }
            }
        )
        let platformCommandRouter = LGPlatformCommandRouter(
            setClipboardText: { text in Self.copyText(text) },
            performHaptic: { style in Self.performHaptic(style) },
            present: { presentation in
                switch presentation {
                case .confirmDelete(let blockIDs):
                    presentationCoordinator.confirmDeletion(of: blockIDs)
                case .pickAttachment(let blockID):
                    _ = presentationCoordinator.presentAttachment(
                        "files",
                        targetBlockID: blockID
                    )
                case .takePhoto(let blockID):
                    _ = presentationCoordinator.presentAttachment(
                        "camera",
                        targetBlockID: blockID
                    )
                case .recordAudio(let blockID):
                    _ = presentationCoordinator.presentAttachment(
                        "audio",
                        targetBlockID: blockID
                    )
                case .focusBlock:
                    break
                }
            }
        )
        let effectExecutor = LGCoreEffectExecutor(
            platformEffect: { effect in await platformHandler.execute(effect) }
        )
        self.store = store
        self.authentication = authentication
        self.presentationCoordinator = presentationCoordinator
        self.syncCoordinator = syncCoordinator
        self.graphLifecycle = graphLifecycle
        self.platformCommandRouter = platformCommandRouter
        let lgRuntime = LGRuntime(
            native: LGCoreNativeCaller(),
            effectExecutor: effectExecutor,
            platformCommandHandler: platformCommandRouter
        )
        self.lgRuntime = lgRuntime
        responseRelay.apply = { [weak lgRuntime] response in
            do {
                try lgRuntime?.applyCoreResponse(response)
            } catch {
                logger.error(
                    "Could not relay a platform core response into LG: "
                        + String(describing: error)
                )
                #if DEBUG
                print("LOGSEQ_LG_PATCH_ERROR source=core-response error=\(error)")
                #endif
            }
        }
        store.graphDownloadProgressChanged = { [weak presentationCoordinator] progress in
            presentationCoordinator?.graphDownloadProgress = progress
        }
        graphLifecycle.localGraphIDsChanged = { [weak lgRuntime] graphIDs in
            guard let data = try? JSONEncoder().encode(graphIDs),
                  let payload = String(data: data, encoding: .utf8)
            else { return }
            do {
                try lgRuntime?.applyHostUpdate(kind: "local-graph-ids", payload: payload)
            } catch {
                logger.error(
                    "Could not relay local graph identifiers into LG: "
                        + String(describing: error)
                )
                #if DEBUG
                print("LOGSEQ_LG_PATCH_ERROR source=local-graph-ids error=\(error)")
                #endif
            }
        }
    }

    public var databasePath: String {
        URL.documentsDirectory
            .appendingPathComponent("logseq.sqlite")
            .path
    }

    public func startLGRenderer() {
        guard !didStartLGRenderer else { return }
        do {
            try lgRuntime.start(
                platformCode: Self.lgPlatformCode,
                authenticationCode: Self.authenticationCode(authentication.state)
            )
            didStartLGRenderer = true
            try lgRuntime.applyHostUpdate(
                kind: "graph-loading",
                payload: !didApplyLocalLaunchResult ? "true" : "false"
            )
            try lgRuntime.applyHostUpdate(
                kind: "settings",
                payload: try Self.settingsHostPayload()
            )
            try lgRuntime.applyHostUpdate(
                kind: "authentication",
                payload: try authenticationHostPayload()
            )
            let persistedDraft = UserDefaults.standard.string(
                forKey: "logseq.composerDraft"
            ) ?? ""
            let persistedDraftData = try JSONEncoder().encode(persistedDraft)
            try lgRuntime.applyHostUpdate(
                kind: "composer-draft",
                payload: String(data: persistedDraftData, encoding: .utf8) ?? "\"\""
            )
        } catch {
            logger.error("Could not start LG renderer: \(String(describing: error))")
            #if DEBUG
            print("LOGSEQ_LG_PATCH_ERROR source=start error=\(error)")
            #endif
        }
    }

    public func runLGApplication() async {
        guard !didStartLGApplication else { return }
        didStartLGApplication = true
        startLGRenderer()
        await waitForAuthenticationRestore()
        publishAuthenticationState()
        LogseqAppDelegate.shared.reportLaunchStage("authentication_published")
        await waitForLocalLaunchLoad()
        if let session = UserDefaults.standard.string(forKey: "logseq.uiSession") {
            do {
                try lgRuntime.applyHostUpdate(kind: "restore-ui-session", payload: session)
            } catch {
                logger.error("Could not restore UI session: \(error)")
            }
        }
        isLGApplicationReady = true
        presentPendingQuickAction()
        await resumeLGApplication()
        await store.runPendingSyncLoop()
    }

    public func startAuthenticationRestore() {
        guard authenticationRestoreTask == nil else { return }
        authenticationRestoreTask = Task { [weak self] in
            guard let self else { return }
            LogseqAppDelegate.shared.reportLaunchStage("authentication_restore_started")
            await authentication.restore()
            LogseqAppDelegate.shared.reportLaunchStage("authentication_restore_returned")
        }
    }

    private func waitForAuthenticationRestore() async {
        startAuthenticationRestore()
        await authenticationRestoreTask?.value
    }

    private static func authenticationCode(_ state: LogseqAuthenticationState) -> Int {
        switch state {
        case .restoring: 0
        case .signedOut: 1
        case .signingIn: 2
        case .signedIn: 3
        case .signingOut: 4
        }
    }

    public func resumeLGApplication() async {
        guard isLGApplicationReady, !isResumingLGApplication else { return }
        processSharedCaptures()
        guard authentication.state == .signedIn else { return }
        guard !didResumeCurrentActivation else { return }
        isResumingLGApplication = true
        defer { isResumingLGApplication = false }
        let connected = await graphLifecycle.connectStoredGraph()
        do {
            try lgRuntime.applyHostUpdate(kind: "graph-loading", payload: "false")
        } catch {
            logger.error(
                "Could not finish LG graph catalog loading: "
                    + String(describing: error)
            )
        }
        if !connected {
            logger.error("Could not restore the stored graph connection")
        } else {
            didResumeCurrentActivation = true
        }
    }

    public func pauseLGApplication() {
        if didApplyLocalLaunchResult {
            do {
                try lgRuntime.applyHostUpdate(kind: "save-ui-session", payload: "null")
            } catch {
                logger.error("Could not preserve UI session: \(error)")
            }
        }
        didResumeCurrentActivation = false
    }

    public func setNetworkAvailable(_ available: Bool) async {
        await syncCoordinator.setNetworkAvailable(available)
    }

    public func publishAuthenticationState() {
        do {
            try lgRuntime.applyHostUpdate(
                kind: "authentication",
                payload: try authenticationHostPayload()
            )
        } catch {
            logger.error(
                "Could not publish authentication state to LG: "
                    + String(describing: error)
            )
        }
    }

    private func authenticationHostPayload() throws -> String {
        let payload = AuthenticationHostPayload(
            state: authentication.state.rawValue,
            errorMessage: authentication.errorMessage
        )
        return String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? "{}"
    }

    private static func settingsHostPayload() throws -> String {
        let defaults = UserDefaults.standard
        let rawTabs = defaults.string(forKey: "logseq.mobile.sidebarTabs") ?? ""
        let payload = SettingsHostPayload(
            appearance: defaults.string(forKey: "logseq.appearance") ?? "system",
            language: LogseqSettingsPolicy.normalizedLanguageID(
                defaults.string(forKey: "logseq.language") ?? "system"
            ),
            spellCheck: defaults.object(forKey: "logseq.editor.spellCheck") as? Bool ?? true,
            autoCorrection: defaults.object(forKey: "logseq.editor.autoCorrection") as? Bool
                ?? true,
            sidebarTabs: rawTabs.isEmpty
                ? []
                : rawTabs.split(separator: ",").map { value in String(value) },
            baseURL: LogseqSettingsPolicy.storedBaseURL(in: defaults),
            version: LogseqSettingsPolicy.version,
            revision: LogseqSettingsPolicy.revision
        )
        return String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? "{}"
    }

    private static func copyText(_ text: String) {
        UIPasteboard.general.string = text
    }

    private static func performHaptic(_ style: String?) {
        if style == "selection" {
            UISelectionFeedbackGenerator().selectionChanged()
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private static var lgPlatformCode: Int {
        2
    }

    public func startLocalLaunchLoad() {
        guard localLaunchResult == nil else { return }
        let graphID = UserDefaults.standard.string(forKey: "logseq.selectedGraphId") ?? ""
        let databasePath = databasePath
        let baseURL = LogseqSettingsPolicy.storedBaseURL()
        localLaunchResult = {
            LogseqAppDelegate.shared.reportLaunchStage("local_load_started")
            func configureGraph() {
                let payloadObject: [String: Any] = [
                    "baseUrl": baseURL,
                    "graphId": graphID,
                    "token": ""
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: payloadObject),
                      let payload = String(data: data, encoding: .utf8) else { return }
                _ = LogseqStore.callForLaunch(
                    LogseqRPCRequest(
                        method: "dispatch",
                        params: LogseqRPCParams(action: "configure", payload: payload)
                    )
                )
                LogseqAppDelegate.shared.reportLaunchStage("graph_configured")
            }

            func openGraph(isEncrypted: Bool) -> String? {
                guard !graphID.isEmpty else { return nil }
                let graphDirectory = LogseqGraphLocalStorage.directoryURL(
                    databasePath: databasePath,
                    graphID: graphID
                )
                let payloadObject: [String: Any] = [
                    "graphId": graphID,
                    "activePath": graphDirectory.appendingPathComponent("graph.sqlite").path,
                    "checkpointPath": graphDirectory.appendingPathComponent("sync.checkpoint").path,
                    "isEncrypted": isEncrypted
                ]
                guard let payloadData = try? JSONSerialization.data(withJSONObject: payloadObject),
                      let payload = String(data: payloadData, encoding: .utf8) else { return nil }
                LogseqAppDelegate.shared.reportLaunchStage("open_graph_started")
                let response = LogseqStore.callForLaunch(
                    LogseqRPCRequest(
                        method: "dispatch",
                        params: LogseqRPCParams(action: "openGraph", payload: payload)
                    )
                )
                LogseqAppDelegate.shared.reportLaunchStage("open_graph_returned")
                return response
            }

            let catalogResponse = LogseqStore.callForLaunch(
                LogseqRPCRequest(
                    method: "open",
                    params: LogseqRPCParams(action: nil, path: databasePath)
                )
            )
            LogseqAppDelegate.shared.reportLaunchStage("catalog_opened")
            guard !graphID.isEmpty,
                  let catalogData = catalogResponse.data(using: .utf8),
                  let catalog = try? JSONDecoder().decode(
                    LogseqRPCResponse.self,
                    from: catalogData
                  ) else {
                return LocalLaunchResult(
                    catalogResponse: catalogResponse,
                    graphResponse: nil,
                    isEncrypted: nil
                )
            }
            let isEncrypted = catalog.result?.graphs?
                .first(where: { $0.id == graphID })?.isEncrypted ?? false
            configureGraph()
            let graphResponse = openGraph(isEncrypted: isEncrypted)
            return LocalLaunchResult(
                catalogResponse: catalogResponse,
                graphResponse: graphResponse,
                isEncrypted: isEncrypted
            )
        }()
        applyLocalLaunchResultWhenReady()
    }

    public func waitForLocalLaunchLoad() async {
        startLocalLaunchLoad()
        applyLocalLaunchResultWhenReady()
    }

    private func applyLocalLaunchResultWhenReady() {
        guard let result = localLaunchResult,
              !didApplyLocalLaunchResult else { return }
        LogseqAppDelegate.shared.reportLaunchStage("local_result_received")
        didApplyLocalLaunchResult = true
        applyLocalGraphIDsToLG(from: result.catalogResponse)
        if let isEncrypted = result.isEncrypted {
            UserDefaults.standard.set(isEncrypted, forKey: "logseq.selectedGraphEncrypted")
        }
        if let graphResponse = result.graphResponse {
            store.applyLaunchResponse(
                graphResponse,
                actionName: "openGraph",
                databasePath: databasePath
            )
            LogseqAppDelegate.shared.reportLaunchStage("store_opened")
            LogseqAppDelegate.shared.reportLaunchStage("graph_loaded")
        } else {
            store.applyLaunchResponse(
                result.catalogResponse,
                actionName: "open",
                databasePath: databasePath
            )
            LogseqAppDelegate.shared.reportLaunchStage("store_opened")
        }
        if lgRuntime.isStarted, result.graphResponse != nil {
            do {
                try lgRuntime.applyHostUpdate(kind: "graph-loading", payload: "false")
            } catch {
                logger.error(
                    "Could not finish LG graph loading: " + String(describing: error)
                )
            }
        }
        if result.graphResponse != nil {
            LogseqAppDelegate.shared.onJournalsUIReady()
        }
        drainSharedCapturesIfReady()
    }

    private func applyLocalGraphIDsToLG(from catalogResponse: String) {
        guard let data = catalogResponse.data(using: .utf8),
              let response = try? JSONDecoder().decode(LogseqRPCResponse.self, from: data)
        else { return }
        let graphIDs = (response.result?.graphs ?? []).compactMap { graph in
            LogseqGraphLocalStorage.isDownloaded(
                databasePath: databasePath,
                graphID: graph.id
            ) ? graph.id : nil
        }
        guard let payloadData = try? JSONEncoder().encode(graphIDs),
              let payload = String(data: payloadData, encoding: .utf8)
        else { return }
        do {
            try lgRuntime.applyHostUpdate(kind: "local-graph-ids", payload: payload)
        } catch {
            logger.error("Could not project local graphs into LG: \(String(describing: error))")
        }
    }

    private var pendingQuickAction: String?

    private func presentPendingQuickAction() {
        guard isLGApplicationReady, let action = pendingQuickAction else { return }
        pendingQuickAction = nil
        do {
            let data = try JSONEncoder().encode(action)
            try lgRuntime.applyHostUpdate(kind: "open-quick-action", payload: String(decoding: data, as: UTF8.self))
        } catch {
            logger.error("Could not open quick action: \(error)")
        }
    }

    public func acceptSharedCaptureURL(_ url: URL) {
        guard let deepLink = LogseqDeepLink(url) else { return }
        switch deepLink {
        case .captureText(let text):
            SharedCaptureInbox.shared.enqueueText(text)
            drainSharedCapturesIfReady()
        case .openCapture:
            pendingQuickAction = "capture"
            presentPendingQuickAction()
        case .openAudio:
            pendingQuickAction = "audio"
            presentPendingQuickAction()
        case .openJournal:
            pendingQuickAction = "journal"
            presentPendingQuickAction()
        }
    }

    public func acceptSharedText(_ text: String) {
        SharedCaptureInbox.shared.enqueueText(text)
        drainSharedCapturesIfReady()
    }

    public func acceptSharedAsset(
        title: String,
        assetType: String,
        size: Int,
        checksum: String,
        stagedFileName: String
    ) {
        let asset = SharedCaptureAsset(
            title: title,
            assetType: assetType,
            size: size,
            checksum: checksum,
            stagedFileName: stagedFileName
        )
        SharedCaptureInbox.shared.enqueue(.asset(
            id: UUID().uuidString.lowercased(),
            asset: asset
        ))
        drainSharedCapturesIfReady()
    }

    public func processSharedCaptures() {
        drainSharedCapturesIfReady()
    }

    private func drainSharedCapturesIfReady() {
        guard didApplyLocalLaunchResult, sharedCaptureTask == nil else { return }
        sharedCaptureTask = Task { [weak self] in
            guard let self else { return }
            await SharedCaptureProcessor.process(inbox: SharedCaptureInbox.shared) { item in
                switch item.kind {
                case .text:
                    guard let text = item.captureText else { return true }
                    return await self.store.captureSharedText(text, id: item.id)
                case .asset:
                    guard let asset = item.captureAsset else { return true }
                    guard let imported = try? SharedCaptureAssetImporter.importAsset(
                        asset,
                        sharedDirectory: SharedCaptureStorage.sharedDirectory,
                        documentsDirectory: .documentsDirectory
                    ) else { return false }
                    return await self.store.captureSharedAsset(
                        id: item.id,
                        title: imported.title,
                        assetType: imported.assetType,
                        assetSize: imported.size,
                        assetChecksum: imported.checksum,
                        localPath: imported.localPath
                    )
                }
            }
            self.sharedCaptureTask = nil
        }
    }

    public func openStore() {
        store.open(path: databasePath)
    }

    public func syncFromStoredConnection() async -> Bool {
        await waitForLocalLaunchLoad()
        let defaults = UserDefaults.standard
        let baseURL = LogseqSettingsPolicy.storedBaseURL(in: defaults)
        guard let graphID = defaults.string(forKey: "logseq.selectedGraphId"), !graphID.isEmpty else {
            return false
        }
        guard let token = try? await authentication.apiToken() else { return false }
        await store.configureAndSelectGraph(
            baseURL: baseURL,
            token: token,
            selectedGraphID: graphID,
            refreshGraphCatalog: false
        )
        guard store.lastError == nil else { return false }
        let isEncrypted = store.snapshot.graphs?.first(where: { $0.id == graphID })?.isEncrypted ?? false
        if isEncrypted && store.snapshot.isGraphUnlocked != true { return false }
        guard await store.bootstrapSelectedGraph(
            graphID: graphID,
            baseURL: baseURL,
            accessToken: token,
            allowSnapshotDownload: false,
            isEncrypted: isEncrypted
        ) else { return false }
        await store.syncPendingForBackground()
        guard store.lastError == nil else { return false }
        _ = await store.runGraphEventsOnce(
            graphID: graphID,
            baseURL: baseURL,
            accessToken: token,
            stopAfterFirstFrame: true
        )
        return store.lastError == nil && store.syncError == nil
    }

    public func runExclusiveBackgroundSync() async -> Bool {
        await syncCoordinator.runBackground {
            await LogseqLogseqRuntime.shared.syncFromStoredConnection()
        }
    }

    public func cancelBackgroundSync() async {
        await syncCoordinator.cancelBackground()
    }
}

struct LogseqCognitoConfiguration: Decodable {
    let region: String
    let userPoolId: String
    let appClientId: String
    let oauthDomain: String
    let redirectURI: String
    let logoutURI: String
    let scopes: [String]

    static func load() -> LogseqCognitoConfiguration {
        guard
            let url = Bundle.module.url(forResource: "logseq-auth", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let configuration = try? JSONDecoder().decode(LogseqCognitoConfiguration.self, from: data)
        else {
            return LogseqCognitoConfiguration(
                region: "",
                userPoolId: "",
                appClientId: "",
                oauthDomain: "",
                redirectURI: "",
                logoutURI: "",
                scopes: []
            )
        }
        return configuration
    }
}

public enum LogseqBackgroundRefresh {
    public static let identifier = "com.logseq.logseq.refresh"

    @MainActor public static func syncNow() {
        #if os(iOS)
        BackgroundSyncExecution().start()
        #endif
    }

    @MainActor private static func runOnce() async -> Bool {
        await LogseqLogseqRuntime.shared.runExclusiveBackgroundSync()
    }

    public static func register() {
        #if os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            handle(task)
        }
        #endif
    }

    public static func schedule(after seconds: TimeInterval = 300) {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.debug("Scheduled background refresh")
        } catch {
            logger.error("Could not schedule background refresh: \(String(describing: error))")
        }
        #endif
    }

    #if os(iOS)
    private static func handle(_ task: BGTask) {
        schedule()
        let completion = BackgroundTaskCompletion()
        let refreshTask = Task {
            let success = await runOnce()
            await completion.finish(success: success) { result in
                task.setTaskCompleted(success: result)
            }
        }
        task.expirationHandler = {
            Task { @MainActor in
                refreshTask.cancel()
                completion.finish(success: false) { result in
                    task.setTaskCompleted(success: result)
                }
                await LogseqLogseqRuntime.shared.cancelBackgroundSync()
            }
        }
    }
    #endif
}

#if os(iOS)
@MainActor private final class BackgroundSyncExecution {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var syncTask: Task<Void, Never>?

    func start() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Logseq graph sync") { [weak self] in
            self?.expire()
        }
        syncTask = Task { [self] in
            _ = await LogseqLogseqRuntime.shared.runExclusiveBackgroundSync()
            finish()
        }
    }

    private func expire() {
        syncTask?.cancel()
        // Relinquish the iOS assertion before awaiting potentially slow network cleanup.
        finish()
        Task {
            await LogseqLogseqRuntime.shared.cancelBackgroundSync()
        }
    }

    private func finish() {
        syncTask = nil
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif

/// Global application delegate functions.
///
/// These functions can update a shared observable object to communicate app state changes to interested views.
public final class LogseqAppDelegate : Sendable {
    public static let shared = LogseqAppDelegate()

    private init() {
    }

    private nonisolated(unsafe) var launchStartedAt: TimeInterval?

    @MainActor public func onInit() {
        let now = Date().timeIntervalSince1970
        launchStartedAt = now
        print(String(format: "LOGSEQ_LAUNCH_METRIC start=%.6f", now))
        let runtime = LogseqLaunchTiming.measure("runtime_initialization") { LogseqLogseqRuntime.shared }
        LogseqLaunchTiming.measure("local_graph_load") { runtime.startLocalLaunchLoad() }
        runtime.startAuthenticationRestore()
        LogseqLaunchTiming.measure("renderer_start") { runtime.startLGRenderer() }
        logger.debug("onInit")
    }

    public func onLaunch() {
        reportLaunchMetric("did_finish_launching")
        logger.debug("onLaunch")
    }

    @MainActor public func onFirstUIRendered() {
        reportLaunchMetric("first_ui_rendered")
        LogseqLaunchTiming.finish()
    }

    public func onJournalsUIReady() {
        reportLaunchMetric("journals_ui_ready")
    }

    public func launchElapsedMilliseconds() -> Double? {
        guard let launchStartedAt else { return nil }
        return (Date().timeIntervalSince1970 - launchStartedAt) * 1_000.0
    }

    public func reportLaunchStage(_ name: String) {
        reportLaunchMetric(name)
    }

    private func reportLaunchMetric(_ name: String) {
        guard let elapsedMilliseconds = launchElapsedMilliseconds() else { return }
        print(String(format: "LOGSEQ_LAUNCH_METRIC %@_ms=%.3f", name, elapsedMilliseconds))
        if let processElapsed = LogseqLaunchTiming.elapsedMilliseconds() {
            print(String(format: "LOGSEQ_PROCESS_LAUNCH_METRIC %@_ms=%.3f", name, processElapsed))
        }
    }

    @MainActor public func onResume() {
        LogseqLogseqRuntime.shared.processSharedCaptures()
        Task { await LogseqLogseqRuntime.shared.resumeLGApplication() }
        logger.debug("onResume")
    }

    public func onPause() {
        Task { @MainActor in LogseqLogseqRuntime.shared.pauseLGApplication() }
        logger.debug("onPause")
    }

    public func onStop() {
        logger.debug("onStop")
    }

    public func onDestroy() {
        logger.debug("onDestroy")
    }

    public func onLowMemory() {
        logger.debug("onLowMemory")
    }
}

private struct LGJournalCalendarResponse: Decodable {
    struct Result: Decodable { let uuid: String }
    let ok: Bool
    let result: Result?
    let error: LogseqCoreError?
}
