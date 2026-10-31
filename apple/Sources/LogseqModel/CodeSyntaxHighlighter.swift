import Foundation
import LogseqCoreABI

public struct CodeSyntaxToken: Decodable, Sendable {
    public let start: Int
    public let end: Int
    public let style: String

    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        start = try values.decode(Int.self)
        end = try values.decode(Int.self)
        style = try values.decode(String.self)
    }
}

/// Tokenization has its own worker and never acquires the graph runtime lock.
public actor CodeSyntaxHighlighter {
    public static let shared = CodeSyntaxHighlighter()

    private final class CachedTokens: NSObject {
        let tokens: [CodeSyntaxToken]
        init(_ tokens: [CodeSyntaxToken]) { self.tokens = tokens }
    }
    private let cache = NSCache<NSString, CachedTokens>()

    public init() { cache.totalCostLimit = 512 * 1024 }

    public func tokens(code: String, language: String) -> [CodeSyntaxToken] {
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty, code.utf16.count <= 100_000,
              !["", "plaintext", "text", "calc"].contains(language),
              let request = try? JSONSerialization.data(withJSONObject: ["text": code, "language": language]),
              let json = String(data: request, encoding: .utf8) else { return [] }
        let key = json as NSString
        if let cached = cache.object(forKey: key) { return cached.tokens }
        #if LOGSEQ_CORE
        guard let result = logseq_highlight_code(json) else { return [] }
        defer { free(result) }
        let data = Data(bytes: result, count: strlen(result))
        let tokens = (try? JSONDecoder().decode([CodeSyntaxToken].self, from: data)) ?? []
        cache.setObject(CachedTokens(tokens), forKey: key, cost: code.utf16.count * 2 + tokens.count * 48)
        return tokens
        #else
        return []
        #endif
    }
}
