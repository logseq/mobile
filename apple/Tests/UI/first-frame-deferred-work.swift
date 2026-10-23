import Foundation
import SwiftUI
import LogseqModel

private final class LaunchRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var sidebarRequests = 0

    func send(_ request: String) -> String {
        if let json = try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
           let params = json["params"] as? [String: Any], params["action"] as? String == "loadSidebar" {
            lock.lock()
            sidebarRequests += 1
            lock.unlock()
        }
        return LogseqCore.shared.logseq_call(request)
    }

    var sidebarCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sidebarRequests
    }
}

// Run with the isolated graph produced by shared/bench/page_fixture.exe.
@main struct FirstFrameDeferredWorkCheck: App {
    var body: some Scene {
        WindowGroup {
            Text("Launch presentation check").task {
                do {
                    try await Self.check()
                    print("RUNTIME_CHECK_COMPLETE")
                    exit(0)
                } catch {
                    print("RUNTIME_CHECK_FAILED: \(error)")
                    exit(1)
                }
            }
        }
    }

    @MainActor private static func check() async throws {
        func call(_ method: String = "dispatch", action: String? = nil,
                  payload: String? = nil, path: String? = nil) throws -> String {
            let response = LogseqStore.callForLaunch(LogseqRPCRequest(method: method,
                params: LogseqRPCParams(action: action, payload: payload, path: path)))
            let decoded = try JSONDecoder().decode(LogseqRPCResponse.self, from: Data(response.utf8))
            guard decoded.ok else { throw NSError(domain: "LaunchPresentation", code: 2,
                userInfo: [NSLocalizedDescriptionKey: decoded.error?.message ?? response]) }
            return response
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "LaunchPresentation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let documents = URL.documentsDirectory
        let database = documents.appendingPathComponent("logseq.sqlite").path
        _ = try call("open", path: database)
        _ = try call(action: "configure", payload: #"{"graphId":"uiregression","baseUrl":"http://127.0.0.1:1","token":""}"#)
        let graph = documents.appendingPathComponent("graphs/uiregression")
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: [
            "graphId": "uiregression", "activePath": graph.appendingPathComponent("graph.sqlite").path,
            "checkpointPath": graph.appendingPathComponent("sync.checkpoint").path, "isEncrypted": false
        ]), as: UTF8.self)
        let opened = try call(action: "openGraph", payload: payload)
        let requests = LaunchRequests()
        let store = LogseqStore(call: { requests.send($0) }, pendingTransport: { _ in
            fatalError("Launch presentation must not start HTTP synchronization")
        })
        store.applyLaunchResponse(opened, actionName: "openGraph", databasePath: database)
        // Give eagerly queued main-actor work an opportunity to run before presentation.
        try await Task.sleep(for: .milliseconds(50))
        try require(requests.sidebarCount == 0,
            "Sidebar loading must wait for the first content frame, rather than starting when the launch snapshot is decoded")
        try require(store.snapshot.selectedGraphId == "uiregression",
            "The actual local graph must be usable before deferred loading")
        await store.completeLaunchPresentation()
        try require(requests.sidebarCount == 1, "The first presented frame must release deferred sidebar loading")
        await store.completeLaunchPresentation()
        try require(requests.sidebarCount == 1, "Repeated appearance must not reload the launch sidebar")

        store.applyLaunchResponse(opened, actionName: "openGraph", databasePath: database)
        let switched = try call(action: "configure", payload: #"{"graphId":"other","baseUrl":"http://127.0.0.1:1","token":""}"#)
        store.applyLaunchResponse(switched, actionName: "configure", databasePath: database)
        await store.completeLaunchPresentation()
        try require(requests.sidebarCount == 1,
            "Deferred launch work must not target a graph that was replaced before presentation")
        print("PASS: real graph launch defers sidebar work until presentation, runs once, and rejects stale graph work")
    }
}
