import Foundation
import SwiftUI

enum LogseqThemeMode: String, CaseIterable {
    case system
    case light
    case dark
}

struct LogseqThemePalette {
    let backgroundHex: String
    let surfaceHex: String
    let primaryTextHex: String
    let secondaryTextHex: String

    private let backgroundRGB: (Int, Int, Int)
    private let surfaceRGB: (Int, Int, Int)
    private let primaryTextRGB: (Int, Int, Int)
    private let secondaryTextRGB: (Int, Int, Int)

    init(
        backgroundHex: String,
        backgroundRGB: (Int, Int, Int),
        surfaceHex: String,
        surfaceRGB: (Int, Int, Int),
        primaryTextHex: String,
        primaryTextRGB: (Int, Int, Int),
        secondaryTextHex: String,
        secondaryTextRGB: (Int, Int, Int)
    ) {
        self.backgroundHex = backgroundHex
        self.backgroundRGB = backgroundRGB
        self.surfaceHex = surfaceHex
        self.surfaceRGB = surfaceRGB
        self.primaryTextHex = primaryTextHex
        self.primaryTextRGB = primaryTextRGB
        self.secondaryTextHex = secondaryTextHex
        self.secondaryTextRGB = secondaryTextRGB
    }

    var background: Color { color(backgroundRGB) }
    var surface: Color { color(surfaceRGB) }
    var primaryText: Color { color(primaryTextRGB) }
    var secondaryText: Color { color(secondaryTextRGB) }

    private func color(_ rgb: (Int, Int, Int)) -> Color {
        Color(
            red: Double(rgb.0) / 255.0,
            green: Double(rgb.1) / 255.0,
            blue: Double(rgb.2) / 255.0
        )
    }
}

enum LogseqThemePolicy {
    static let accentHex = "#037DBA"
    static let accent = Color(red: 3.0 / 255.0, green: 125.0 / 255.0, blue: 186.0 / 255.0)

    static let light = LogseqThemePalette(
        backgroundHex: "#FCFCFC",
        backgroundRGB: (252, 252, 252),
        surfaceHex: "#F8F8F8",
        surfaceRGB: (248, 248, 248),
        primaryTextHex: "#171717",
        primaryTextRGB: (23, 23, 23),
        secondaryTextHex: "#6F6F6F",
        secondaryTextRGB: (111, 111, 111)
    )

    static let dark = LogseqThemePalette(
        backgroundHex: "#002D38",
        backgroundRGB: (0, 45, 56),
        surfaceHex: "#19394D",
        surfaceRGB: (25, 57, 77),
        primaryTextHex: "#EDFDFD",
        primaryTextRGB: (237, 253, 253),
        secondaryTextHex: "#9BD3D4",
        secondaryTextRGB: (155, 211, 212)
    )

    static func palette(mode: LogseqThemeMode, systemIsDark: Bool) -> LogseqThemePalette {
        switch mode {
        case .system:
            return systemIsDark ? dark : light
        case .light:
            return light
        case .dark:
            return dark
        }
    }
}

struct LogseqLanguageChoice: Identifiable {
    let id: String
    let title: String
}

struct LogseqCommunityLink: Identifiable {
    let title: String
    let url: URL

    var id: String { title }
}

enum LogseqSettingsPolicy {
    static let defaultBaseURL = "https://api.logseq.io"

    static func storedBaseURL(in defaults: UserDefaults = .standard) -> String {
        let value = defaults.string(forKey: "logseq.baseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultBaseURL : value
    }

    static let languages = [
        LogseqLanguageChoice(id: "system", title: "System"),
        LogseqLanguageChoice(id: "en", title: "English"),
        LogseqLanguageChoice(id: "fr", title: "Français"),
        LogseqLanguageChoice(id: "de", title: "Deutsch"),
        LogseqLanguageChoice(id: "nl", title: "Dutch (Nederlands)"),
        LogseqLanguageChoice(id: "zh-CN", title: "简体中文"),
        LogseqLanguageChoice(id: "zh-Hant", title: "繁體中文"),
        LogseqLanguageChoice(id: "af", title: "Afrikaans"),
        LogseqLanguageChoice(id: "ca", title: "Català"),
        LogseqLanguageChoice(id: "es", title: "Español"),
        LogseqLanguageChoice(id: "vi", title: "Tiếng Việt"),
        LogseqLanguageChoice(id: "nb-NO", title: "Norsk (bokmål)"),
        LogseqLanguageChoice(id: "pl", title: "Polski"),
        LogseqLanguageChoice(id: "pt-BR", title: "Português (Brasileiro)"),
        LogseqLanguageChoice(id: "pt-PT", title: "Português (Europeu)"),
        LogseqLanguageChoice(id: "ru", title: "Русский"),
        LogseqLanguageChoice(id: "ja", title: "日本語"),
        LogseqLanguageChoice(id: "it", title: "Italiano"),
        LogseqLanguageChoice(id: "tr", title: "Türkçe"),
        LogseqLanguageChoice(id: "uk", title: "Українська"),
        LogseqLanguageChoice(id: "ko", title: "한국어"),
        LogseqLanguageChoice(id: "sk", title: "Slovenčina"),
        LogseqLanguageChoice(id: "fa", title: "فارسی"),
        LogseqLanguageChoice(id: "id", title: "Bahasa Indonesia"),
        LogseqLanguageChoice(id: "cs", title: "Čeština"),
        LogseqLanguageChoice(id: "ar", title: "العربية"),
    ]

    static let communityLinks = [
        LogseqCommunityLink(
            title: "Report bug",
            url: URL(string: "https://github.com/logseq/db-test/issues")!
        ),
        LogseqCommunityLink(
            title: "Discord community",
            url: URL(string: "https://discord.com/invite/KpN4eHY")!
        ),
        LogseqCommunityLink(
            title: "Forum",
            url: URL(string: "https://discuss.logseq.com")!
        ),
        LogseqCommunityLink(
            title: "GitHub",
            url: URL(string: "https://github.com/logseq/logseq")!
        ),
    ]

    static func normalizedSyncServerURL(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let components = URLComponents(string: normalized),
            components.scheme == "http" || components.scheme == "https",
            components.host != nil
        else {
            return nil
        }
        return normalized
    }

    static func normalizedLanguageID(_ value: String) -> String {
        let migrated = value == "zh-Hans" ? "zh-CN" : value
        return languages.contains(where: { $0.id == migrated }) ? migrated : "system"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
    }

    static var revision: String {
        Bundle.main.object(forInfoDictionaryKey: "LogseqRevision") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "Development"
    }
}
