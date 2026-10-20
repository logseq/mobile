import UniformTypeIdentifiers

enum ShareCaptureRoute: Equatable, Sendable {
    case asset(String)
    case fileURL
    case url
    case text
}

enum ShareCaptureRoutePolicy {
    static func routes(for identifiers: [String]) -> [ShareCaptureRoute] {
        let types = identifiers.compactMap(UTType.init)
        var routes: [ShareCaptureRoute] = []
        let semanticAsset = types.first(where: isSemanticAsset)
        if let semanticAsset {
            routes.append(.asset(semanticAsset.identifier))
        }
        if types.contains(where: { $0.conforms(to: .fileURL) }) {
            routes.append(.fileURL)
        } else if types.contains(where: { $0.conforms(to: .url) }) {
            routes.append(.url)
        }
        if types.contains(where: { $0.conforms(to: .plainText) }) {
            routes.append(.text)
        }
        if semanticAsset == nil, let data = types.first(where: isGenericData) {
            routes.append(.asset(data.identifier))
        }
        return routes
    }

    private static func isSemanticAsset(_ type: UTType) -> Bool {
        type.conforms(to: .image) || type.conforms(to: .audio) ||
            type.conforms(to: .movie) || type.conforms(to: .pdf) ||
            type.preferredFilenameExtension?.lowercased() == "md"
    }

    private static func isGenericData(_ type: UTType) -> Bool {
        type.conforms(to: .data) && !type.conforms(to: .plainText) &&
            !type.conforms(to: .url)
    }
}

enum ShareCaptureRouteRunner {
    static func firstResult<Result>(
        in routes: [ShareCaptureRoute],
        load: @escaping (ShareCaptureRoute, @escaping (Result?) -> Void) -> Void,
        completion: @escaping (Result?) -> Void
    ) {
        run(routes[...], load: load, completion: completion)
    }

    private static func run<Result>(
        _ routes: ArraySlice<ShareCaptureRoute>,
        load: @escaping (ShareCaptureRoute, @escaping (Result?) -> Void) -> Void,
        completion: @escaping (Result?) -> Void
    ) {
        guard let route = routes.first else {
            completion(nil)
            return
        }
        load(route) { result in
            if let result {
                completion(result)
            } else {
                run(routes.dropFirst(), load: load, completion: completion)
            }
        }
    }
}
