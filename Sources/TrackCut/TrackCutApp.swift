import AppKit
import SwiftUI

@main
struct TrackCutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var editor = EditorModel.shared
    @ObservedObject private var sheets = SheetState.shared
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject private var language = LanguageSettings.shared
    @AppStorage("showsInspector") private var showsInspector = true

    init() {
        LegacyDefaults.migrate()
    }

    var body: some Scene {
        WindowGroup("TrackCut", id: "main") {
            // The inspector adds its own column to this width
            ContentView(editor: editor)
                .frame(minWidth: 640, minHeight: 560)
                // "Open With" in Finder and drops onto the Dock icon
                .onOpenURL { editor.receiveOpenedURL($0) }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1180, height: 780)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands { commands }

        Settings {
            SettingsView(language: language, editor: editor)
        }
    }

    // Single-key shortcuts (Space, M, I, O, ...) are not menu key equivalents; see KeyCommands.
    @CommandsBuilder
    private var commands: some Commands {
        let isLoaded = editor.peaks != nil
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        CommandGroup(replacing: .newItem) {
            Button("Open…") { editor.presentOpenPanel() }
                .keyboardShortcut("o")
        }
        // After the group, not in place of it: it holds Close (⌘W)
        CommandGroup(after: .saveItem) {
            Button("Save Project") { editor.saveProject() }
                .keyboardShortcut("s")
                .disabled(!isLoaded)
            Button("Save Project As…") { editor.saveProjectAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!isLoaded)
        }
        CommandGroup(after: .newItem) {
            Button("Add Files…") { editor.presentAddFilesPanel() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(!editor.canArrangeFiles)
            Button("Arrange Files…") { sheets.showsArrange = true }
                .disabled(!editor.canArrangeFiles)
            Divider()
            Button("Export…") { sheets.showsExport = true }
                .keyboardShortcut("e")
                .disabled(!isLoaded)
        }
        CommandMenu("Track") {
            Group {
                Button("Split at Playhead") { editor.addSplit(at: editor.player.currentTime) }
                Button("Delete Split Point") { editor.removeSelectedSplit() }
                    .disabled(!editor.canRemoveSelectedSplit)
                Button("Split at Silences…") { sheets.showsSilence = true }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Fade In to Playhead") { editor.setFade(.start, at: editor.player.currentTime) }
                Button("Fade Out from Playhead") { editor.setFade(.end, at: editor.player.currentTime) }
                Button("Apply Fades to All Tracks") {
                    if let i = editor.selectedIndex { editor.applyFadesToAllTracks(from: i) }
                }
                .disabled(editor.selectedIndex == nil)
                Divider()
                Button("Previous Track") { editor.selectAdjacentTrack(-1) }
                Button("Next Track") { editor.selectAdjacentTrack(1) }
                Button("Include / Exclude Selected Track") { editor.toggleSelectedEnabled() }
            }
            .disabled(!isLoaded)
        }
        CommandGroup(before: .toolbar) {
            Button("Zoom In") { editor.zoom(by: 0.5) }
                .keyboardShortcut("=")
                .disabled(!isLoaded)
            Button("Zoom Out") { editor.zoom(by: 2) }
                .keyboardShortcut("-")
                .disabled(!isLoaded)
            Button("Zoom to Fit") { editor.zoomToFit() }
                .keyboardShortcut("0")
                .disabled(!isLoaded)
            Button("Zoom to Selected Track") { editor.zoomToSelectedTrack() }
                .disabled(!isLoaded)
            Divider()
            Button(showsInspector ? String(localized: "Hide Inspector") : String(localized: "Show Inspector")) { showsInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(!isLoaded)
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { sheets.showsShortcuts = true }
                .keyboardShortcut("/")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bring the app to the front even when launched with `swift run`
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Offers to save unsaved changes first. When the window has already been closed (closing the last
    /// window quits the app) and the user cancels, the window opens again with the work still in it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if EditorModel.shared.confirmDiscardingChanges() { return .terminateNow }
            if EditorModel.shared.window?.isVisible != true { SheetState.shared.reopenWindow?() }
            return .terminateCancel
        }
    }
}
