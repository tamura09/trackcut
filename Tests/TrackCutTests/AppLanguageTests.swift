import Foundation
import Testing
@testable import TrackCut

extension AppTests {
    @Suite("Language setting") @MainActor
    struct AppLanguageTests {
        /// Runs `body` with an empty defaults domain, then removes it
        private func withDomain(_ body: (String, UserDefaults) -> Void) {
            let name = "TrackCutTests.language.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            body(name, defaults)
        }

        @Test func storesTheChoiceAsAppleLanguages() {
            withDomain { name, defaults in
                #expect(AppLanguage.stored(in: defaults, domain: name) == .system)
                AppLanguage.japanese.store(in: defaults)
                #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] as? [String] == ["ja"])
                #expect(AppLanguage.stored(in: defaults, domain: name) == .japanese)
                AppLanguage.system.store(in: defaults)
                #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] == nil)
                #expect(AppLanguage.stored(in: defaults, domain: name) == .system)
            }
        }

        /// System Settings writes region-qualified codes such as "en-JP"
        @Test func readsTheChoiceMadeInSystemSettings() {
            withDomain { name, defaults in
                defaults.set(["en-JP"], forKey: "AppleLanguages")
                #expect(AppLanguage.stored(in: defaults, domain: name) == .english)
                defaults.set(["fr"], forKey: "AppleLanguages")
                #expect(AppLanguage.stored(in: defaults, domain: name) == .system)
            }
        }

        @Test func asksForARelaunchOnlyAfterAChange() {
            withDomain { name, defaults in
                AppLanguage.english.store(in: defaults)
                let settings = LanguageSettings(defaults: defaults, domain: name)
                #expect(settings.selection == .english)
                #expect(!settings.needsRelaunch)
                settings.selection = .japanese
                #expect(settings.needsRelaunch)
                #expect(AppLanguage.stored(in: defaults, domain: name) == .japanese)
                settings.selection = .english
                #expect(!settings.needsRelaunch)
            }
        }
    }
}
