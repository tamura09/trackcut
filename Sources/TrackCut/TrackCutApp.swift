import AppKit
import SwiftUI

@main
struct TrackCutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var editor = EditorModel.shared

    var body: some Scene {
        WindowGroup("TrackCut", id: "main") {
            ContentView(editor: editor)
                .frame(minWidth: 900, minHeight: 560)
                // "Open With" in Finder and drops onto the Dock icon
                .onOpenURL { editor.open($0) }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("開く…") { editor.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
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
