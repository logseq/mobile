import Foundation

@MainActor
public final class LogseqAccountEvents {
    struct Incoming: Decodable {
        let type: String
        let subscription: String?
        let frame: String?
        let message: String?
        let expiresAt: Double?
    }

    struct GraphFrame: Encodable {
        let type: String
        let subscription: String
        var graphId: String? = nil
        var frame: String? = nil
    }

    @MainActor
    final class Graph {
        let frames: AsyncThrowingStream<String, Error>
        let continuation: AsyncThrowingStream<String, Error>.Continuation
        let id = UUID().uuidString.lowercased()
        private weak var transport: LogseqAccountEvents?

        init(transport: LogseqAccountEvents) {
            self.transport = transport
            (frames, continuation) = AsyncThrowingStream.makeStream()
        }

        func send(_ frame: String) async throws {
            guard let transport else { throw URLError(.networkConnectionLost) }
            try await transport.sendGraphFrame(self, frame: frame)
        }

        func close() {
            continuation.finish()
            transport?.removeGraph(self)
        }
    }

    private var generation = UUID()
    private var socket: URLSessionWebSocketTask?
    private var graph: Graph?
    private var ready = false
    private var unsupported = false

    public init() {}

    public func run(
        baseURL: String,
        accessToken: () async -> String?,
        refreshBots: (String) -> Void
    ) async {
        guard var url = URLComponents(string: baseURL), let scheme = url.scheme,
              scheme == "http" || scheme == "https" else { return }
        let prefix = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        url.path = prefix.isEmpty ? "/events" : "/\(prefix)/events"
        guard let probe = url.url else { return }
        url.scheme = scheme == "https" ? "wss" : "ws"
        guard let address = url.url else { return }
        let current = UUID()
        generation = current
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        ready = false
        unsupported = false
        graph?.continuation.finish(throwing: URLError(.networkConnectionLost))
        graph = nil
        defer {
            if generation == current {
                socket = nil
                ready = false
                graph?.continuation.finish(throwing: URLError(.networkConnectionLost))
                graph = nil
            }
        }

        refreshBots("null")
        var retrySeconds = 1
        var checked = false
        while !Task.isCancelled && generation == current {
            if !checked {
                var request = URLRequest(url: probe)
                request.timeoutInterval = 5
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   let status = (response as? HTTPURLResponse)?.statusCode,
                   generation == current, !Task.isCancelled {
                    checked = status == 426 || status == 404
                    unsupported = status == 404
                }
            }
            if checked, !unsupported, let token = await accessToken(), !Task.isCancelled && generation == current {
                var request = URLRequest(url: address)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let connection = URLSession.shared.webSocketTask(with: request)
                connection.maximumMessageSize = 64 * 1024 * 1024
                socket = connection
                connection.resume()
                let receivedReady = await listen(connection, refreshBots: refreshBots)
                connection.cancel(with: .goingAway, reason: nil)
                guard generation == current, !Task.isCancelled else { return }
                if let status = (connection.response as? HTTPURLResponse)?.statusCode {
                    unsupported = status == 404 || status == 426
                }
                ready = false
                socket = nil
                graph?.continuation.finish(throwing: URLError(.networkConnectionLost))
                graph = nil
                if receivedReady { retrySeconds = 1 }
            }
            refreshBots("null")
            let waitSeconds = unsupported ? 3 : retrySeconds
            do { try await Task.sleep(for: .seconds(waitSeconds)) } catch { return }
            retrySeconds = min(30, retrySeconds * 2)
        }
    }

    func subscribe(graphID: String) async throws -> Graph? {
        if unsupported { return nil }
        guard ready, let socket else { throw URLError(.cannotConnectToHost) }
        graph?.close()
        let next = Graph(transport: self)
        graph = next
        do {
            try await send(GraphFrame(type: "graph.subscribe", subscription: next.id, graphId: graphID), on: socket)
            return next
        } catch {
            next.close()
            throw error
        }
    }

    private func listen(_ connection: URLSessionWebSocketTask, refreshBots: (String) -> Void) async -> Bool {
        var receivedReady = false
        return await withTaskCancellationHandler {
            var expiration: Task<Void, Never>? = Task {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                connection.cancel(with: .goingAway, reason: nil)
            }
            defer { expiration?.cancel() }
            do {
                while !Task.isCancelled && socket === connection {
                    let data: Data
                    switch try await connection.receive() {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    guard socket === connection, !Task.isCancelled,
                          let message = try? JSONDecoder().decode(Incoming.self, from: data)
                    else { continue }
                    switch message.type {
                    case "ready":
                        guard !receivedReady else { continue }
                        receivedReady = true
                        ready = true
                        refreshBots("null")
                        expiration?.cancel()
                        if let expiresAt = message.expiresAt {
                            let seconds = max(0, expiresAt / 1000 - Date().timeIntervalSince1970)
                            expiration = Task {
                                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                                connection.cancel(with: .goingAway, reason: nil)
                            }
                        }
                    case "bots.changed":
                        refreshBots(String(decoding: data, as: UTF8.self))
                    case "graph.frame":
                        if let graph, graph.id == message.subscription, let frame = message.frame {
                            graph.continuation.yield(frame)
                        }
                    case "graph.error":
                        if let graph, graph.id == message.subscription {
                            let error = NSError(domain: "LogseqGraphEvents", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: message.message ?? "Graph sync failed"])
                            graph.continuation.finish(throwing: error)
                        }
                    default:
                        continue
                    }
                }
            } catch {
                return receivedReady
            }
            return receivedReady
        } onCancel: {
            connection.cancel(with: .goingAway, reason: nil)
        }
    }

    private func sendGraphFrame(_ graph: Graph, frame: String) async throws {
        guard ready, self.graph === graph, let socket else { throw URLError(.networkConnectionLost) }
        try await send(GraphFrame(type: "graph.frame", subscription: graph.id, frame: frame), on: socket)
    }

    private func removeGraph(_ graph: Graph) {
        guard self.graph === graph else { return }
        self.graph = nil
        guard ready, let socket else { return }
        Task { try? await send(GraphFrame(type: "graph.unsubscribe", subscription: graph.id), on: socket) }
    }

    private func send(_ frame: GraphFrame, on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder().encode(frame)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
}
