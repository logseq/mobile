import Testing
@testable import Logseq

@Suite struct LogseqThemeSettingsTests {
    @Test func classicPaletteMatchesTheOfficialLogseqThemeTokens() {
        #expect(LogseqThemePolicy.light.backgroundHex == "#FCFCFC")
        #expect(LogseqThemePolicy.light.surfaceHex == "#FFFFFF")
        #expect(LogseqThemePolicy.light.primaryTextHex == "#171717")
        #expect(LogseqThemePolicy.dark.backgroundHex == "#002D38")
        #expect(LogseqThemePolicy.dark.surfaceHex == "#143D48")
        #expect(LogseqThemePolicy.dark.primaryTextHex == "#EDFDFD")
        #expect(LogseqThemePolicy.accentHex == "#037DBA")
    }

    @Test func appearanceModesResolveWithoutDuplicatingSystemState() {
        #expect(LogseqThemeMode(rawValue: "system") == .system)
        #expect(LogseqThemeMode(rawValue: "light") == .light)
        #expect(LogseqThemeMode(rawValue: "dark") == .dark)
        #expect(LogseqThemeMode(rawValue: "unknown") == nil)
    }

    @Test func darkPaletteFollowsAppearanceAndDefaultsToBlack() {
        #expect(LogseqDarkTheme(storedValue: nil) == .black)
        #expect(LogseqDarkTheme(storedValue: "unknown") == .black)
        #expect(LogseqDarkTheme(storedValue: "solarized") == .solarized)
        #expect(LogseqThemePolicy.palette(mode: .system, systemIsDark: true).backgroundHex == "#000000")
        #expect(LogseqThemePolicy.palette(mode: .system, systemIsDark: true, darkTheme: .solarized).backgroundHex == "#002D38")
        #expect(LogseqThemePolicy.palette(mode: .dark, systemIsDark: false, darkTheme: .black).backgroundHex == "#000000")
        #expect(LogseqThemePolicy.palette(mode: .light, systemIsDark: true, darkTheme: .black).backgroundHex == "#FCFCFC")
    }

    @Test func languageChoicesCoverEveryShippedLocalization() {
        #expect(LogseqSettingsPolicy.languages.map(\.id) == [
            "system", "en", "fr", "de", "nl", "zh-CN", "zh-Hant", "af", "ca",
            "es", "vi", "nb-NO", "pl", "pt-BR", "pt-PT", "ru", "ja", "it", "tr",
            "uk", "ko", "sk", "fa", "id", "cs", "ar",
        ])
        #expect(LogseqSettingsPolicy.normalizedLanguageID("zh-Hans") == "zh-CN")
        #expect(LogseqSettingsPolicy.normalizedLanguageID("fr") == "fr")
        #expect(LogseqSettingsPolicy.normalizedLanguageID("unknown") == "system")
    }

    @Test func customSyncServerAcceptsOnlyHttpURLsAndNormalizesWhitespace() {
        #expect(
            LogseqSettingsPolicy.normalizedSyncServerURL(" https://sync.example.com/path ")
                == "https://sync.example.com/path"
        )
        #expect(
            LogseqSettingsPolicy.normalizedSyncServerURL("http://127.0.0.1:8787")
                == "http://127.0.0.1:8787"
        )
        #expect(LogseqSettingsPolicy.normalizedSyncServerURL("ftp://example.com") == nil)
        #expect(LogseqSettingsPolicy.normalizedSyncServerURL("example.com") == nil)
        #expect(LogseqSettingsPolicy.normalizedSyncServerURL("   ") == nil)
    }

    @Test func communityAndSupportDestinationsMatchLogseqMobile() {
        #expect(LogseqSettingsPolicy.communityLinks.map(\.title) == [
            "Report bug", "Discord community", "Forum", "GitHub",
        ])
        #expect(LogseqSettingsPolicy.communityLinks.allSatisfy { $0.url.scheme == "https" })
    }
}
