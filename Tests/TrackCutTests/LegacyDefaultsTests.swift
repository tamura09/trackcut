import Foundation
import Testing
@testable import TrackCut

extension AppTests {
    @Suite("Settings from the old bundle id") @MainActor
    struct LegacyDefaultsTests {
        /// Runs `body` with an old domain holding `legacy` and an empty current domain, then removes both
        private func withDomains(legacy: [String: Any], _ body: (String, UserDefaults) -> Void) {
            let legacyName = "TrackCutTests.legacy.\(UUID().uuidString)"
            let currentName = "TrackCutTests.current.\(UUID().uuidString)"
            let current = UserDefaults(suiteName: currentName)!
            current.setPersistentDomain(legacy, forName: legacyName)
            defer {
                current.removePersistentDomain(forName: legacyName)
                current.removePersistentDomain(forName: currentName)
            }
            body(legacyName, current)
        }

        @Test func copiesSettingsButKeepsValuesAlreadySet() {
            withDomains(legacy: ["exportFormat": "flac", "silenceThresholdDB": -60.0, "showsInspector": false]) { legacy, current in
                current.set(true, forKey: "showsInspector")
                LegacyDefaults.migrate(from: legacy, into: current)
                #expect(current.string(forKey: "exportFormat") == "flac")
                #expect(current.double(forKey: "silenceThresholdDB") == -60)
                #expect(current.bool(forKey: "showsInspector"))
            }
        }

        @Test func runsOnlyOnce() {
            withDomains(legacy: ["exportFormat": "flac"]) { legacy, current in
                LegacyDefaults.migrate(from: legacy, into: current)
                current.removeObject(forKey: "exportFormat")
                LegacyDefaults.migrate(from: legacy, into: current)
                #expect(current.object(forKey: "exportFormat") == nil)
            }
        }

        @Test func doesNothingWithoutOldSettings() {
            withDomains(legacy: [:]) { _, current in
                LegacyDefaults.migrate(from: "TrackCutTests.missing.\(UUID().uuidString)", into: current)
                #expect(current.object(forKey: "exportFormat") == nil)
                #expect(current.bool(forKey: LegacyDefaults.migratedKey))
            }
        }
    }
}
