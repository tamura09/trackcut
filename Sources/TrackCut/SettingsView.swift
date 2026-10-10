import AppKit
import SwiftUI

/// The language the app runs in. It is stored as AppleLanguages in the app's own defaults domain, the
/// same value that System Settings > General > Language & Region > Applications writes, so the two stay
/// in step. AppKit reads it at launch, so a change takes effect when the app relaunches.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", japanese = "ja"

    static let key = "AppleLanguages"

    var id: String { rawValue }

    /// The choice saved in `domain`. Only that domain is read: `defaults.object(forKey:)` would fall back
    /// to the system-wide language list.
    static func stored(in defaults: UserDefaults, domain: String) -> AppLanguage {
        guard let first = (defaults.persistentDomain(forName: domain)?[key] as? [String])?.first else { return .system }
        if first.hasPrefix("ja") { return .japanese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    func store(in defaults: UserDefaults) {
        if self == .system {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set([rawValue], forKey: Self.key)
        }
    }
}

@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()

    /// The choice the app was launched with
    let launchSelection: AppLanguage

    @Published var selection: AppLanguage {
        didSet { selection.store(in: defaults) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         domain: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) {
        self.defaults = defaults
        launchSelection = AppLanguage.stored(in: defaults, domain: domain)
        selection = launchSelection
    }

    var needsRelaunch: Bool { selection != launchSelection }

    /// Only the app bundle can be reopened; a binary started with `swift run` cannot
    var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Quits and reopens the app once this process has exited, after a confirmation when a file is open
    func relaunch(closing editor: EditorModel) {
        guard canRelaunch else { return }
        if editor.peaks != nil {
            let alert = NSAlert()
            alert.messageText = String(localized: "Relaunch TrackCut now?")
            alert.informativeText = String(localized: "The open file is closed, and its split points are not kept.")
            alert.addButton(withTitle: String(localized: "Relaunch"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; open \"$0\"",
                            Bundle.main.bundleURL.path]
        do {
            try reopen.run()
        } catch {
            editor.errorMessage = error.localizedDescription
            return
        }
        NSApp.terminate(nil)
    }
}

/// TrackCut > Settings (⌘,)
struct SettingsView: View {
    @ObservedObject var language: LanguageSettings
    @ObservedObject var editor: EditorModel

    var body: some View {
        Form {
            Picker("Language", selection: $language.selection) {
                Text("System Default").tag(AppLanguage.system)
                Divider()
                // Each language is named in itself, so it can be found whichever one is in use
                Text(verbatim: "English").tag(AppLanguage.english)
                Text(verbatim: "日本語").tag(AppLanguage.japanese)
            }
            if language.needsRelaunch {
                LabeledContent {
                    if language.canRelaunch {
                        Button("Relaunch Now") { language.relaunch(closing: editor) }
                    }
                } label: {
                    Text("TrackCut switches to the new language when it relaunches.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}
