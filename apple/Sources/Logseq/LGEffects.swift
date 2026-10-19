import Foundation
import LUIAppleBackend
import Observation
import LogseqModel

public struct LGEffect: Decodable, Equatable, Sendable {
    public let id: Int
    public let kind: String
    public let text: String
    public let uuid: String?
    public let value: Int?
    public let metadata: String?

    public init(
        id: Int,
        kind: String,
        text: String,
        uuid: String? = nil,
        value: Int? = nil,
        metadata: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.uuid = uuid
        self.value = value
        self.metadata = metadata
    }
}

struct LGEffectDispatch: Decodable {
    let effect: LGEffect
    let patch: String
}

public enum LGEffectOutput: Equatable, Sendable {
    case coreResponse
    case hostUpdate(String)
    case discard
}

public struct LGEffectResolution: Equatable, Sendable {
    public let succeeded: Bool
    public let message: String
    public let output: LGEffectOutput

    public init(
        succeeded: Bool,
        message: String,
        output: LGEffectOutput = .coreResponse
    ) {
        self.succeeded = succeeded
        self.message = message
        self.output = output
    }
}

public struct LGSettingsPayload: Decodable, Equatable, Sendable {
    public let appearance: String
    public let language: String
    public let spellCheck: Bool
    public let autoCorrection: Bool
    public let sidebarTabs: [String]
    public let baseURL: String
}

public struct LGAssetPresentationPayload: Codable, Equatable, Sendable {
    public let title: String
    public let assetType: String
    public let localPath: String

    public init(title: String, assetType: String, localPath: String) {
        self.title = title
        self.assetType = assetType
        self.localPath = localPath
    }
}

public struct LGPageSharePayload: Equatable, Sendable {
    public let text: String
    public let localAssetPaths: [String]

    public init(text: String, localAssetPaths: [String]) {
        self.text = text
        self.localAssetPaths = localAssetPaths
    }
}

public struct LGRuntimeLogPayload: Codable, Equatable, Sendable {
    public let id: String
    public let level: String
    public let source: String
    public let timestamp: String
    public let message: String
}

@MainActor

public final class LGPlatformEffectHandler: LGEffectExecuting {
    private let saveSettings: @MainActor (LGSettingsPayload) async throws -> Void
    private let persistComposerDraft: @MainActor (String) -> Void
    private let runtimeLog: LogseqRuntimeLog
    private let copyText: @MainActor (String) -> Void
    private let signIn: (@MainActor () async -> String?)?
    private let signOut: @MainActor () async -> Void
    private let openExternalURL: (@MainActor (URL) async -> Bool)?
    private let exportGraphDatabase: (@MainActor () async -> Bool)?
    private let graphEffect: (@MainActor (LGEffect) async -> LGEffectResolution)?
    private let presentAttachment: (@MainActor (String) async -> Bool)?
    private let presentAsset: (@MainActor (LGAssetPresentationPayload) async -> URL?)?
    private let presentPageShare: (@MainActor (LGPageSharePayload) async -> Bool)?
    private let syncNow: (@MainActor () -> Void)?

    public init(
        saveSettings: @escaping @MainActor (LGSettingsPayload) async throws -> Void,
        persistComposerDraft: @escaping @MainActor (String) -> Void = { _ in },
        runtimeLog: LogseqRuntimeLog,
        copyText: @escaping @MainActor (String) -> Void,
        signIn: (@MainActor () async -> String?)? = nil,
        signOut: @escaping @MainActor () async -> Void,
        openExternalURL: (@MainActor (URL) async -> Bool)? = nil,
        exportGraphDatabase: (@MainActor () async -> Bool)? = nil,
        graphEffect: (@MainActor (LGEffect) async -> LGEffectResolution)? = nil,
        presentAttachment: (@MainActor (String) async -> Bool)? = nil,
        presentAsset: (@MainActor (LGAssetPresentationPayload) async -> URL?)? = nil,
        presentPageShare: (@MainActor (LGPageSharePayload) async -> Bool)? = nil,
        syncNow: (@MainActor () -> Void)? = nil
    ) {
        self.saveSettings = saveSettings
        self.persistComposerDraft = persistComposerDraft
        self.runtimeLog = runtimeLog
        self.copyText = copyText
        self.signIn = signIn
        self.signOut = signOut
        self.openExternalURL = openExternalURL
        self.exportGraphDatabase = exportGraphDatabase
        self.graphEffect = graphEffect
        self.presentAttachment = presentAttachment
        self.presentAsset = presentAsset
        self.presentPageShare = presentPageShare
        self.syncNow = syncNow
    }

    public func execute(_ effect: LGEffect) async -> LGEffectResolution {
        do {
            switch effect.kind {
            case "persist-ui-session":
                UserDefaults.standard.set(effect.text, forKey: "logseq.uiSession")
                return LGEffectResolution(succeeded: true, message: "", output: .discard)
            case "persist-composer-draft":
                persistComposerDraft(effect.text)
                return LGEffectResolution(
                    succeeded: true,
                    message: "",
                    output: .discard
                )
            case "save-settings":
                let settings = try JSONDecoder().decode(
                    LGSettingsPayload.self,
                    from: Data(effect.text.utf8)
                )
                try await saveSettings(settings)
                return LGEffectResolution(
                    succeeded: true,
                    message: "",
                    output: .discard
                )
            case "refresh-runtime-log":
                guard let source = LogseqRuntimeLogSource(rawValue: effect.text) else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Unknown runtime log source: \(effect.text)",
                        output: .discard
                    )
                }
                let flags = effect.value ?? 0
                let timeFormatter = DateFormatter()
                timeFormatter.dateStyle = .none
                timeFormatter.timeStyle = .short
                let records = runtimeLog.records(
                    source: source,
                    errorsOnly: flags & 1 != 0,
                    newestFirst: flags & 2 != 0
                ).map { record in
                    LGRuntimeLogPayload(
                        id: String(record.id),
                        level: record.level.rawValue.uppercased(),
                        source: record.source.rawValue,
                        timestamp: timeFormatter.string(from: Date(
                            timeIntervalSince1970:
                                Double(record.timestampMilliseconds) / 1_000
                        )),
                        message: record.message
                    )
                }
                let data = try JSONEncoder().encode(records)
                guard let payload = String(data: data, encoding: .utf8) else {
                    throw LGEffectEncodingError.invalidUTF8
                }
                return LGEffectResolution(
                    succeeded: true,
                    message: payload,
                    output: .hostUpdate("runtime-log")
                )
            case "copy-runtime-log":
                let records = try JSONDecoder().decode(
                    [LGRuntimeLogPayload].self,
                    from: Data(effect.text.utf8)
                )
                copyText(records.map { record in
                    "\(record.timestamp) \(record.level) \(record.source) \(record.message)"
                }.joined(separator: "\n"))
                return LGEffectResolution(
                    succeeded: true,
                    message: "",
                    output: .discard
                )
            case "sign-in":
                guard let signIn else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Hosted sign-in is unavailable",
                        output: .discard
                    )
                }
                if let message = await signIn() {
                    return LGEffectResolution(
                        succeeded: false,
                        message: message,
                        output: .discard
                    )
                }
                return LGEffectResolution(
                    succeeded: true,
                    message: "",
                    output: .discard
                )
            case "sign-out":
                await signOut()
                return LGEffectResolution(
                    succeeded: true,
                    message: "",
                    output: .discard
                )
            case "open-external-url":
                guard let url = URL(string: effect.text),
                      let scheme = url.scheme?.lowercased(),
                      (scheme == "http" || scheme == "https"),
                      url.host != nil,
                      let openExternalURL
                else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "External URL is unavailable",
                        output: .discard
                    )
                }
                let succeeded = await openExternalURL(url)
                return LGEffectResolution(
                    succeeded: succeeded,
                    message: succeeded ? "" : "Could not open the external URL",
                    output: .discard
                )
            case "export-graph-database":
                guard let exportGraphDatabase else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Graph database export is unavailable",
                        output: .discard
                    )
                }
                let succeeded = await exportGraphDatabase()
                return LGEffectResolution(
                    succeeded: succeeded,
                    message: succeeded ? "" : "The graph database is unavailable",
                    output: .discard
                )
            case "present-attachment":
                guard let presentAttachment else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Attachment presentation is unavailable",
                        output: .discard
                    )
                }
                let succeeded = await presentAttachment(effect.text)
                return LGEffectResolution(
                    succeeded: succeeded,
                    message: succeeded ? "" : "Unknown attachment service: \(effect.text)",
                    output: .discard
                )
            case "present-asset":
                guard let presentAsset, let metadata = effect.metadata else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Asset presentation is unavailable",
                        output: .discard
                    )
                }
                let asset = try JSONDecoder().decode(
                    LGAssetPresentationPayload.self,
                    from: Data(metadata.utf8)
                )
                guard let url = await presentAsset(asset) else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "The local asset is unavailable",
                        output: .discard
                    )
                }
                let payload = String(
                    data: try JSONEncoder().encode([
                        "title": asset.title,
                        "path": url.path,
                    ]),
                    encoding: .utf8
                ) ?? "{}"
                return LGEffectResolution(
                    succeeded: true,
                    message: payload,
                    output: .hostUpdate("asset-preview-resolved")
                )
            case "present-page-share":
                guard let presentPageShare, let metadata = effect.metadata else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Page sharing is unavailable",
                        output: .discard
                    )
                }
                let paths = try JSONDecoder().decode(
                    [String].self,
                    from: Data(metadata.utf8)
                )
                let succeeded = await presentPageShare(LGPageSharePayload(
                    text: effect.text,
                    localAssetPaths: paths
                ))
                return LGEffectResolution(
                    succeeded: succeeded,
                    message: succeeded ? "" : "Page sharing is unavailable",
                    output: .discard
                )
            case "sync-now":
                guard let syncNow else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Sync is unavailable",
                        output: .discard
                    )
                }
                syncNow()
                return LGEffectResolution(
                    succeeded: true,
                    message: "",
                    output: .discard
                )
            case "open-graph", "unlock-graph", "create-graph", "delete-local-graph":
                guard let graphEffect else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Graph platform handling is unavailable",
                        output: .discard
                    )
                }
                return await graphEffect(effect)
            default:
                return LGEffectResolution(
                    succeeded: false,
                    message: "Unsupported platform effect: \(effect.kind)",
                    output: .discard
                )
            }
        } catch {
            return LGEffectResolution(
                succeeded: false,
                message: String(describing: error),
                output: .discard
            )
        }
    }
}

@MainActor
public protocol LGPlatformCommandHandling: AnyObject {
    func handle(_ batch: LGPlatformCommandBatch)
}

@MainActor
public protocol LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution
}


private struct LGAssetTranscript: Decodable {
    let uuid: String
    let transcript: String?
    let transcriptUUID: String?
}

private struct LGAssetTranscriptChild: Encodable {
    let uuid: String
    let title: String
    let parentId: String
    let now: Int64
}

private struct LGSendCapturePayload: Encodable {
    let text: String
    let uuid: String
    let now: Int64
}

private struct LGSendTaskPayload: Encodable {
    let text: String
    let uuid: String
    let now: Int64
    let status: LGTaskStatusPayload
}

private struct LGTaskStatusPayload: Codable, Equatable, Sendable {
    let uuid: String
    let ident: String?
    let title: String
    let iconType: String?
    let iconId: String?
    let iconColor: String?
}

private struct LGReviewFlashcardPayload: Encodable {
    let uuid: String
    let rating: String
    let now: Int64
    let operationId: String
}

private struct LGCreateGraphPayload: Encodable {
    let name: String
    let isEncrypted: Bool
}

private struct LGSetPageFavoritePayload: Encodable {
    let pageUuid: String
    let favorite: Bool
    let operationId: String
    let now: Int64
}

private struct LGDeletePagePayload: Encodable {
    let pageUuid: String
    let operationId: String
    let now: Int64
}

private struct LGCoreEffectResponse: Decodable {
    let ok: Bool
    let error: LogseqCoreError?
}

public final class LGCoreEffectExecutor: LGEffectExecuting {
    private let callCore: @MainActor (LogseqRPCRequest) async -> String
    private let deleteLocalGraph: (@MainActor (String) async -> String)?
    private let platformEffect: (@MainActor (LGEffect) async -> LGEffectResolution)?

    public init(
        callCore: @escaping @MainActor (LogseqRPCRequest) async -> String = { request in
            await LogseqCore.callAsync(request)
        },
        deleteLocalGraph: (@MainActor (String) async -> String)? = nil,
        platformEffect: (@MainActor (LGEffect) async -> LGEffectResolution)? = nil
    ) {
        self.deleteLocalGraph = deleteLocalGraph
        self.platformEffect = platformEffect
        self.callCore = callCore
    }

    public func execute(_ effect: LGEffect) async -> LGEffectResolution {
        let request: LogseqRPCRequest
        switch effect.kind {
        case "send-asset":
            request = LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(action: "addAsset", payload: effect.text)
            )
        case "send-capture":
            do {
                let payload = LGSendCapturePayload(
                    text: effect.text,
                    uuid: UUID().uuidString.lowercased(),
                    now: Int64(Date().timeIntervalSince1970 * 1_000)
                )
                let payloadData = try JSONEncoder().encode(payload)
                guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Could not encode the capture payload as UTF-8"
                    )
                }
                request = LogseqRPCRequest(
                    method: "dispatch",
                    params: LogseqRPCParams(action: "send", payload: payloadJSON)
                )
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "send-task":
            do {
                guard let metadata = effect.metadata else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "The task capture effect did not include a task status"
                    )
                }
                let status = try JSONDecoder().decode(
                    LGTaskStatusPayload.self,
                    from: Data(metadata.utf8)
                )
                let payload = LGSendTaskPayload(
                    text: effect.text,
                    uuid: UUID().uuidString.lowercased(),
                    now: Int64(Date().timeIntervalSince1970 * 1_000),
                    status: status
                )
                let payloadData = try JSONEncoder().encode(payload)
                guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Could not encode the task capture payload as UTF-8"
                    )
                }
                request = LogseqRPCRequest(
                    method: "dispatch",
                    params: LogseqRPCParams(action: "sendTask", payload: payloadJSON)
                )
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "load-page-references":
            request = LogseqRPCRequest(method: "dispatch",
                params: LogseqRPCParams(action: "loadPageReferences", payload: effect.text))
        case "hydrate-outliner-rows":
            request = LogseqRPCRequest(method: "dispatch",
                params: LogseqRPCParams(action: "hydrateOutlinerRows", payload: effect.text))
        case "search-nodes":
            request = LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(action: "searchNodes", payload: effect.text)
            )
        case "open-node":
            do {
                let payloadData = try JSONEncoder().encode(
                    LogseqNodeRouteRequest(uuid: effect.text)
                )
                guard let payload = String(data: payloadData, encoding: .utf8) else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Could not encode the node route payload as UTF-8"
                    )
                }
                request = LogseqRPCRequest(
                    method: "dispatch",
                    params: LogseqRPCParams(action: "openNode", payload: payload)
                )
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "close-node":
            request = LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(action: "closeNode")
            )
        case "select-sidebar-page":
            request = LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(action: "selectPage", payload: effect.text)
            )
        case "clear-selected-page":
            request = LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(action: "clearSelectedPage")
            )
        case "load-older-journals":
            request = LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(action: "loadOlderJournals")
            )
        case "set-page-favorite":
            do {
                let data = try JSONEncoder().encode(LGSetPageFavoritePayload(
                    pageUuid: effect.text,
                    favorite: effect.value == 1,
                    operationId: UUID().uuidString.lowercased(),
                    now: Int64(Date().timeIntervalSince1970 * 1_000)
                ))
                guard let payload = String(data: data, encoding: .utf8) else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Could not encode the page favorite payload as UTF-8"
                    )
                }
                request = LogseqRPCRequest(
                    method: "dispatch",
                    params: LogseqRPCParams(action: "setPageFavorite", payload: payload)
                )
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "delete-page":
            do {
                let data = try JSONEncoder().encode(LGDeletePagePayload(
                    pageUuid: effect.text,
                    operationId: UUID().uuidString.lowercased(),
                    now: Int64(Date().timeIntervalSince1970 * 1_000)
                ))
                guard let payload = String(data: data, encoding: .utf8) else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Could not encode the page deletion payload as UTF-8"
                    )
                }
                request = LogseqRPCRequest(
                    method: "dispatch",
                    params: LogseqRPCParams(action: "deletePage", payload: payload)
                )
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "load-flashcards":
            request = LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(
                    action: "loadFlashcards",
                    payload: String(Int64(Date().timeIntervalSince1970 * 1_000))
                )
            )
        case "refresh-graphs":
            request = LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(action: "refresh")
            )
        case "open-graph":
            if let platformEffect {
                return await platformEffect(effect)
            }
            request = LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(action: "selectGraph", payload: effect.text)
            )
        case "unlock-graph":
            if let platformEffect {
                return await platformEffect(effect)
            }
            request = LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(action: "unlockGraph", payload: effect.text)
            )
        case "create-graph":
            if let platformEffect {
                return await platformEffect(effect)
            }
            do {
                let data = try JSONEncoder().encode(LGCreateGraphPayload(
                    name: effect.text,
                    isEncrypted: effect.value == 1
                ))
                guard let payload = String(data: data, encoding: .utf8) else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Could not encode the graph creation payload as UTF-8"
                    )
                }
                request = LogseqRPCRequest(
                    method: "dispatch",
                    params: LogseqRPCParams(action: "createSyncGraph", payload: payload)
                )
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "delete-local-graph":
            if let platformEffect {
                return await platformEffect(effect)
            }
            guard let deleteLocalGraph else {
                return LGEffectResolution(
                    succeeded: false,
                    message: "Local graph deletion is unavailable"
                )
            }
            return await Self.resolution(from: await deleteLocalGraph(effect.text))
        case "persist-ui-session", "persist-composer-draft", "sign-in", "save-settings", "refresh-runtime-log",
             "copy-runtime-log", "sign-out", "export-graph-database", "open-external-url",
             "present-attachment", "present-asset", "present-page-share", "sync-now":
            guard let platformEffect else {
                return LGEffectResolution(
                    succeeded: false,
                    message: "Platform settings handling is unavailable"
                )
            }
            return await platformEffect(effect)
        case "review-flashcard":
            guard let uuid = effect.uuid else {
                return LGEffectResolution(
                    succeeded: false,
                    message: "Flashcard review is missing its card UUID"
                )
            }
            do {
                let payload = LGReviewFlashcardPayload(
                    uuid: uuid,
                    rating: effect.text,
                    now: Int64(Date().timeIntervalSince1970 * 1_000),
                    operationId: UUID().uuidString.lowercased()
                )
                let data = try JSONEncoder().encode(payload)
                guard let payloadJSON = String(data: data, encoding: .utf8) else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Could not encode the flashcard review payload as UTF-8"
                    )
                }
                request = LogseqRPCRequest(
                    method: "dispatch",
                    params: LogseqRPCParams(action: "reviewFlashcard", payload: payloadJSON)
                )
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "tap-outliner-block", "toggle-outliner-collapsed",
             "long-press-outliner-block", "add-root-block":
            do {
                let eventType = switch effect.kind {
                case "toggle-outliner-collapsed": "toggleCollapsed"
                case "long-press-outliner-block": "longPressBlock"
                case "add-root-block": "addRootBlock"
                default: "tapBlock"
                }
                request = try Self.outlinerRequest(
                    LogseqOutlinerEvent(type: eventType, uuid: effect.text)
                )
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "drop-outliner-blocks":
            guard let placement = effect.metadata else {
                return LGEffectResolution(
                    succeeded: false,
                    message: "The outliner drop effect is missing its placement"
                )
            }
            do {
                request = try Self.outlinerRequest(LogseqOutlinerEvent(
                    type: "dropBlocks",
                    targetUuid: effect.text,
                    placement: placement
                ))
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "set-outliner-task-status":
            do {
                guard let metadata = effect.metadata else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "The task status effect is missing its status payload"
                    )
                }
                let status = try JSONDecoder().decode(
                    LGTaskStatusPayload.self,
                    from: Data(metadata.utf8)
                )
                request = try Self.outlinerRequest(LogseqOutlinerEvent(
                    type: "setTaskStatus",
                    uuid: effect.text,
                    statusIdent: status.ident,
                    statusUuid: status.uuid
                ))
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "outliner-toolbar":
            do {
                request = try Self.outlinerRequest(
                    LogseqOutlinerEvent(type: "toolbar", action: effect.text)
                )
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "choose-outliner-autocomplete":
            do {
                request = try Self.outlinerRequest(
                    LogseqOutlinerEvent(type: "chooseAutocomplete", value: effect.text)
                )
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "save-outliner-editing":
            do {
                request = try Self.outlinerRequest(
                    LogseqOutlinerEvent(type: "saveEditing")
                )
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "cancel-outliner-editing":
            do {
                request = try Self.outlinerRequest(
                    LogseqOutlinerEvent(type: "cancelEditing")
                )
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "change-outliner-text", "return-outliner-editor",
             "backspace-outliner-editor", "move-outliner-caret":
            guard let uuid = effect.uuid, let value = effect.value else {
                return LGEffectResolution(
                    succeeded: false,
                    message: "The LG outliner effect is missing its UUID or integer value"
                )
            }
            let event: LogseqOutlinerEvent
            switch effect.kind {
            case "change-outliner-text":
                event = LogseqOutlinerEvent(
                    type: "textChanged",
                    uuid: uuid,
                    title: effect.text,
                    caretUTF16Offset: value
                )
            case "return-outliner-editor":
                event = LogseqOutlinerEvent(
                    type: "returnPressed",
                    uuid: uuid,
                    title: effect.text,
                    caretUTF16Offset: value
                )
            case "backspace-outliner-editor":
                event = LogseqOutlinerEvent(
                    type: "backspacePressed",
                    uuid: uuid,
                    title: effect.text,
                    selectionLength: value
                )
            default:
                event = LogseqOutlinerEvent(
                    type: "caretMoved",
                    uuid: uuid,
                    caretUTF16Offset: value
                )
            }
            do {
                request = try Self.outlinerRequest(event)
            } catch {
                return LGEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        default:
            return LGEffectResolution(
                succeeded: false,
                message: "Unsupported LG effect: \(effect.kind)"
            )
        }

        let responseJSON = await callCore(request)
        let resolution = await Self.resolution(from: responseJSON)
        if effect.kind == "send-asset", resolution.succeeded,
           let asset = try? JSONDecoder().decode(LGAssetTranscript.self, from: Data(effect.text.utf8)),
           let title = asset.transcript, !title.isEmpty, let uuid = asset.transcriptUUID {
            do {
                let payload = try JSONEncoder().encode(LGAssetTranscriptChild(
                    uuid: uuid, title: title, parentId: asset.uuid,
                    now: Int64(Date().timeIntervalSince1970 * 1_000)
                ))
                return await Self.resolution(from: await callCore(LogseqRPCRequest(
                    method: "dispatch", params: LogseqRPCParams(
                        action: "addChildBlock", payload: String(decoding: payload, as: UTF8.self)
                    )
                )))
            } catch {
                return LGEffectResolution(succeeded: false, message: String(describing: error))
            }
        }
        return resolution
    }

    private static func resolution(from responseJSON: String) async -> LGEffectResolution {
        await Task.detached { decodeResolution(responseJSON) }.value
    }

    private nonisolated static func decodeResolution(_ responseJSON: String) -> LGEffectResolution {
        do {
            let response = try JSONDecoder().decode(
                LGCoreEffectResponse.self,
                from: Data(responseJSON.utf8)
            )
            if response.ok {
                return LGEffectResolution(succeeded: true, message: responseJSON)
            }
            let errorCode = response.error?.code ?? "core_error"
            let errorMessage = response.error?.message ?? "The OCaml core rejected the effect"
            return LGEffectResolution(
                succeeded: false,
                message: errorCode + "\n" + errorMessage
            )
        } catch {
            return LGEffectResolution(
                succeeded: false,
                message: String(describing: error)
            )
        }
    }

    private static func outlinerRequest(
        _ event: LogseqOutlinerEvent
    ) throws -> LogseqRPCRequest {
        let payloadData = try JSONEncoder().encode(event)
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw LGEffectEncodingError.invalidUTF8
        }
        return LogseqRPCRequest(
            method: "dispatch",
            params: LogseqRPCParams(action: "outlinerEvent", payload: payloadJSON)
        )
    }
}

private enum LGEffectEncodingError: Error {
    case invalidUTF8
}

