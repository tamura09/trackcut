import AppKit
import SwiftUI

@main
struct TrackCutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var editor = EditorModel.shared
    @ObservedObject private var sheets = SheetState.shared
    @ObservedObject private var updater = AppUpdater.shared
    @AppStorage("showsInspector") private var showsInspector = true

    var body: some Scene {
        WindowGroup("TrackCut", id: "main") {
            // The inspector adds its own column to this width
            ContentView(editor: editor)
                .frame(minWidth: 640, minHeight: 560)
                // "Open With" in Finder and drops onto the Dock icon
                .onOpenURL { editor.open($0) }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1180, height: 780)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands { commands }
    }

    // Single-key shortcuts (Space, M, I, O, ...) are not menu key equivalents; see KeyCommands.
    @CommandsBuilder
    private var commands: some Commands {
        let isLoaded = editor.peaks != nil
        CommandGroup(after: .appInfo) {
            Button("アップデートを確認…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        CommandGroup(replacing: .newItem) {
            Button("開く…") { editor.presentOpenPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("書き出し…") { sheets.showsExport = true }
                .keyboardShortcut("e")
                .disabled(!isLoaded)
        }
        CommandMenu("トラック") {
            Group {
                Button("再生位置で分割") { editor.addSplit(at: editor.player.currentTime) }
                Button("分割点を削除") { editor.removeSelectedSplit() }
                    .disabled(!editor.canRemoveSelectedSplit)
                Button("無音区間で分割…") { sheets.showsSilence = true }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("再生位置までフェードイン") { editor.setFade(.start, at: editor.player.currentTime) }
                Button("再生位置からフェードアウト") { editor.setFade(.end, at: editor.player.currentTime) }
                Button("フェードをすべてのトラックに適用") {
                    if let i = editor.selectedIndex { editor.applyFadesToAllTracks(from: i) }
                }
                .disabled(editor.selectedIndex == nil)
                Divider()
                Button("前のトラック") { editor.selectAdjacentTrack(-1) }
                Button("次のトラック") { editor.selectAdjacentTrack(1) }
                Button("選択トラックを書き出す / 書き出さない") { editor.toggleSelectedEnabled() }
            }
            .disabled(!isLoaded)
        }
        CommandGroup(before: .toolbar) {
            Button("拡大") { editor.zoom(by: 0.5) }
                .keyboardShortcut("=")
                .disabled(!isLoaded)
            Button("縮小") { editor.zoom(by: 2) }
                .keyboardShortcut("-")
                .disabled(!isLoaded)
            Button("全体を表示") { editor.zoomToFit() }
                .keyboardShortcut("0")
                .disabled(!isLoaded)
            Button("選択トラックに合わせて拡大") { editor.zoomToSelectedTrack() }
                .disabled(!isLoaded)
            Divider()
            Button(showsInspector ? "インスペクタを隠す" : "インスペクタを表示") { showsInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(!isLoaded)
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("キーボードショートカット") { sheets.showsShortcuts = true }
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
}
