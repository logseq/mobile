import Foundation

enum CaptureLocalization {
    private static let translations: [String: [String: String]] = {
        guard let url = Bundle.module.url(forResource: "CaptureLocalizations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: values.map { ($0.key.lowercased(), $0.value) })
    }()

    static func text(_ source: String, locale: Locale) -> String {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        let language: String
        if translations[identifier] != nil {
            language = identifier
        } else if identifier.hasPrefix("zh") {
            let parts = identifier.split(separator: "-")
            language = parts.contains(where: { ["hant", "tw", "hk", "mo"].contains(String($0)) }) ? "zh-hant" : "zh-cn"
        } else {
            language = identifier.split(separator: "-").first.map(String.init) ?? "en"
        }
        return translations[language]?[source] ?? translations["en"]?[source] ?? source
    }
}
