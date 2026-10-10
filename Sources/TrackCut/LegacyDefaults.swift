import Foundation

/// 0.1.0 was built with the bundle id wtf.tmrh.TrackCut, so the settings it saved (export format, silence
/// detection, inspector) are in that id's defaults domain. Copies them over once, keeping any value
/// already set under the current id.
enum LegacyDefaults {
    static let domain = "wtf.tmrh.TrackCut"
    static let migratedKey = "migratedLegacyDefaults"

    static func migrate(from domain: String = domain, into defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        for (key, value) in defaults.persistentDomain(forName: domain) ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: migratedKey)
    }
}
