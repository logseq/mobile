import Foundation
import LUIAppleBackend
import Observation
import LogseqModel

private enum LGEffectEncodingError: Error {
    case invalidUTF8
}

public struct LGEffect: Codable, Equatable, Sendable {
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
    private let presentJournalCalendar: (@MainActor () -> Bool)?
    private let presentAttachment: (@MainActor (String) async -> Bool)?
    private let presentAsset: (@MainActor (LGAssetPresentationPayload) async -> URL?)?
    private let presentPageShare: (@MainActor (LGPageSharePayload) async -> Bool)?
    private let syncNow: (@MainActor () -> Void)?
    private let syncPending: (@MainActor () -> Void)?

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
        presentJournalCalendar: (@MainActor () -> Bool)? = nil,
        presentAttachment: (@MainActor (String) async -> Bool)? = nil,
        presentAsset: (@MainActor (LGAssetPresentationPayload) async -> URL?)? = nil,
        presentPageShare: (@MainActor (LGPageSharePayload) async -> Bool)? = nil,
        syncPending: (@MainActor () -> Void)? = nil,
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
        self.presentJournalCalendar = presentJournalCalendar
        self.presentAttachment = presentAttachment
        self.presentAsset = presentAsset
        self.presentPageShare = presentPageShare
        self.syncNow = syncNow
        self.syncPending = syncPending
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
            case "present-journal-calendar":
                return LGEffectResolution(succeeded: presentJournalCalendar?() ?? false,
                    message: "", output: .discard)
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
            case "sync-now", "sync-pending":
                guard let requestSync = effect.kind == "sync-now" ? syncNow : syncPending else {
                    return LGEffectResolution(
                        succeeded: false,
                        message: "Sync is unavailable",
                        output: .discard
                    )
                }
                requestSync()
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
        switch effect.kind {
        case "persist-ui-session", "persist-composer-draft", "sign-in", "save-settings", "refresh-runtime-log",
             "copy-runtime-log", "sign-out", "export-graph-database", "open-external-url",
             "present-attachment", "present-journal-calendar", "present-asset", "present-page-share", "sync-now", "sync-pending":
            guard let platformEffect else {
                return LGEffectResolution(succeeded: false, message: "Platform settings handling is unavailable")
            }
            return await platformEffect(effect)
        case "open-graph", "unlock-graph", "create-graph":
            if let platformEffect { return await platformEffect(effect) }
        case "delete-local-graph":
            if let platformEffect { return await platformEffect(effect) }
            guard let deleteLocalGraph else {
                return LGEffectResolution(succeeded: false, message: "Local graph deletion is unavailable")
            }
            return await Self.resolution(from: await deleteLocalGraph(effect.text))
        default:
            break
        }
        do {
            if effect.kind == "refresh-graphs" {
                return await Self.resolution(from: try await refreshGraphCatalog())
            }
            let payload = String(decoding: try JSONEncoder().encode(effect), as: UTF8.self)
            let request = LogseqRPCRequest(method: "dispatch", params: LogseqRPCParams(
                action: "executeEffect", payload: payload
            ))
            let resolution = await Self.resolution(from: await callCore(request))
            if effect.kind == "maintain-search-index", resolution.succeeded {
                return LGEffectResolution(succeeded: true, message: resolution.message, output: .discard)
            }
            return resolution
        } catch {
            return LGEffectResolution(succeeded: false, message: String(describing: error))
        }
    }

    private func refreshGraphCatalog() async throws -> String {
        func call(_ action: String, _ payload: [String: Any]) async throws -> String {
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            return await callCore(LogseqRPCRequest(method: "dispatch", params: LogseqRPCParams(action: action, payload: encoded)))
        }
        let prepared = try await call("prepareGraphCatalog", [:])
        guard let envelope = try JSONSerialization.jsonObject(with: Data(prepared.utf8)) as? [String: Any],
              envelope["ok"] as? Bool == true,
              let result = envelope["result"] as? [String: Any],
              let request = result["request"] as? [String: Any],
              let url = (request["url"] as? String).flatMap(URL.init(string:)) else { return prepared }
        var completion: [String: Any] = ["baseUrl": result["baseUrl"] ?? "", "token": result["token"] ?? ""]
        do {
            var pending = URLRequest(url: url)
            pending.httpMethod = "GET"
            pending.timeoutInterval = 30
            pending.setValue("Bearer " + (request["token"] as? String ?? ""), forHTTPHeaderField: "Authorization")
            let (body, response) = try await URLSession.shared.data(for: pending)
            completion["status"] = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion["body"] = String(decoding: body, as: UTF8.self)
        } catch is CancellationError { throw CancellationError() }
        catch { completion["error"] = error.localizedDescription }
        return try await call("completeGraphCatalog", completion)
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

}
