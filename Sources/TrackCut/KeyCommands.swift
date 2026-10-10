import AppKit

/// A single-key shortcut. These work anywhere in the editor window except while typing in a text field.
/// They are handled by an event monitor instead of being menu key equivalents, because a menu key
/// equivalent without ⌘ would also fire while typing.
struct KeyCommand: Identifiable {
    enum Key {
        case codes(Set<UInt16>)
        /// Matched against the typed characters, so letters follow the keyboard layout. With a layout
        /// that does not type them (e.g. kana input), the key at the US position `fallbackCode` is used.
        case characters(Set<String>, fallbackCode: UInt16)

        static func code(_ code: UInt16) -> Key { .codes([code]) }
    }

    let key: Key
    /// nil when Shift does not matter, e.g. for "=" which needs Shift on some layouts
    let shift: Bool?
    /// The keys as shown in the shortcut list
    let label: String
    let title: String
    let perform: @MainActor (EditorModel) -> Void

    var id: String { label }

    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return false }
        if let shift, flags.contains(.shift) != shift { return false }
        switch key {
        case .codes(let codes):
            return codes.contains(event.keyCode)
        case .characters(let characters, let fallbackCode):
            let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
            return characters.contains(typed) || (!typed.allSatisfy(\.isASCII) && event.keyCode == fallbackCode)
        }
    }
}

enum KeyCommands {
    struct Section: Identifiable {
        let title: String
        let commands: [KeyCommand]
        var id: String { title }

        init(title: String.LocalizationValue, commands: [KeyCommand]) {
            self.title = String(localized: title)
            self.commands = commands
        }
    }

    private static func command(_ key: KeyCommand.Key, shift: Bool? = false, _ label: String,
                                _ title: String.LocalizationValue,
                                _ perform: @escaping @MainActor (EditorModel) -> Void) -> KeyCommand {
        KeyCommand(key: key, shift: shift, label: label, title: String(localized: title), perform: perform)
    }

    private static func key(_ character: String, fallbackCode: UInt16) -> KeyCommand.Key {
        .characters([character], fallbackCode: fallbackCode)
    }

    static let sections: [Section] = [
        Section(title: "Playback", commands: [
            command(.code(49), "Space", "Play / pause") { $0.player.toggle() },
            command(.code(123), "←", "Back 1 second") { $0.seek(by: -1) },
            command(.code(124), "→", "Forward 1 second") { $0.seek(by: 1) },
            command(.code(123), shift: true, "⇧ ←", "Back 10 seconds") { $0.seek(by: -10) },
            command(.code(124), shift: true, "⇧ →", "Forward 10 seconds") { $0.seek(by: 10) },
            command(.code(126), "↑", "Previous track") { $0.selectAdjacentTrack(-1) },
            command(.code(125), "↓", "Next track") { $0.selectAdjacentTrack(1) },
            command(.code(115), "Home", "Go to the start") { $0.seek(to: 0) },
            command(.code(119), "End", "Go to the end") { $0.seek(to: $0.duration) },
        ]),
        Section(title: "Splitting", commands: [
            command(key("m", fallbackCode: 46), "M", "Split at the playhead") { $0.addSplit(at: $0.player.currentTime) },
            command(.codes([51, 117]), "⌫", "Remove the split point at the start of the selected track") { $0.removeSelectedSplit() },
            command(.code(43), ",", "Move that split point 10 ms earlier") { $0.nudgeSelectedSplit(by: -0.01) },
            command(.code(47), ".", "Move that split point 10 ms later") { $0.nudgeSelectedSplit(by: 0.01) },
            command(.code(43), shift: true, "⇧ ,", "Move that split point 100 ms earlier") { $0.nudgeSelectedSplit(by: -0.1) },
            command(.code(47), shift: true, "⇧ .", "Move that split point 100 ms later") { $0.nudgeSelectedSplit(by: 0.1) },
            command(key("e", fallbackCode: 14), "E", "Include / exclude the selected track from the export") { $0.toggleSelectedEnabled() },
        ]),
        Section(title: "Fades", commands: [
            command(key("i", fallbackCode: 34), "I", "Fade in from the start of the track to the playhead") { $0.setFade(.start, at: $0.player.currentTime) },
            command(key("o", fallbackCode: 31), "O", "Fade out from the playhead to the end of the track") { $0.setFade(.end, at: $0.player.currentTime) },
            command(key("i", fallbackCode: 34), shift: true, "⇧ I", "Remove the fade-in") { editor in
                if let i = editor.trackIndex(containing: editor.player.currentTime) { editor.removeFade(.start, ofTrackAt: i) }
            },
            command(key("o", fallbackCode: 31), shift: true, "⇧ O", "Remove the fade-out") { editor in
                if let i = editor.trackIndex(containing: editor.player.currentTime) { editor.removeFade(.end, ofTrackAt: i) }
            },
        ]),
        Section(title: "View", commands: [
            command(.characters(["=", "+"], fallbackCode: 24), shift: nil, "=", "Zoom in") { $0.zoom(by: 0.5) },
            command(key("-", fallbackCode: 27), "-", "Zoom out") { $0.zoom(by: 2) },
            command(key("z", fallbackCode: 6), "Z", "Zoom to the selected track") { $0.zoomToSelectedTrack() },
            command(key("z", fallbackCode: 6), shift: true, "⇧ Z", "Zoom to fit") { $0.zoomToFit() },
        ]),
    ]

    /// Shortcuts that live in the menu bar, listed alongside the single-key ones
    static let menuShortcuts: [(label: String, title: String)] = [
        ("⌘ O", String(localized: "Open")),
        ("⌘ E", String(localized: "Export")),
        ("⇧ ⌘ D", String(localized: "Split at silences")),
        ("⌘ Z", String(localized: "Undo")),
        ("⇧ ⌘ Z", String(localized: "Redo")),
        ("⌘ =", String(localized: "Zoom in")),
        ("⌘ -", String(localized: "Zoom out")),
        ("⌘ 0", String(localized: "Zoom to fit")),
        ("⌥ ⌘ I", String(localized: "Show / hide the inspector")),
        ("⌘ /", String(localized: "Keyboard shortcuts")),
    ]

    /// Runs the command for `event`. Returns false when the event is not a shortcut here, or when the
    /// focus is in a text field, so the event is delivered as usual.
    @MainActor
    static func handle(_ event: NSEvent, in window: NSWindow, editor: EditorModel) -> Bool {
        guard event.window === window, window.attachedSheet == nil, editor.peaks != nil,
              !(window.firstResponder is NSText)
        else { return false }
        for section in sections {
            for command in section.commands where command.matches(event) {
                command.perform(editor)
                return true
            }
        }
        return false
    }
}

/// Installs the key monitor for one window while it is alive
@MainActor
final class KeyCommandMonitor {
    private var monitor: Any?

    func install(window: NSWindow, editor: EditorModel) {
        uninstall()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak editor] event in
            guard let window, let editor else { return event }
            let handled = MainActor.assumeIsolated { KeyCommands.handle(event, in: window, editor: editor) }
            return handled ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
