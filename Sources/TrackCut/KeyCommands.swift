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
    }

    private static func command(_ key: KeyCommand.Key, shift: Bool? = false, _ label: String, _ title: String,
                                _ perform: @escaping @MainActor (EditorModel) -> Void) -> KeyCommand {
        KeyCommand(key: key, shift: shift, label: label, title: title, perform: perform)
    }

    private static func key(_ character: String, fallbackCode: UInt16) -> KeyCommand.Key {
        .characters([character], fallbackCode: fallbackCode)
    }

    static let sections: [Section] = [
        Section(title: "再生", commands: [
            command(.code(49), "Space", "再生 / 一時停止") { $0.player.toggle() },
            command(.code(123), "←", "1 秒戻る") { $0.seek(by: -1) },
            command(.code(124), "→", "1 秒進む") { $0.seek(by: 1) },
            command(.code(123), shift: true, "⇧ ←", "10 秒戻る") { $0.seek(by: -10) },
            command(.code(124), shift: true, "⇧ →", "10 秒進む") { $0.seek(by: 10) },
            command(.code(126), "↑", "前のトラックへ") { $0.selectAdjacentTrack(-1) },
            command(.code(125), "↓", "次のトラックへ") { $0.selectAdjacentTrack(1) },
            command(.code(115), "Home", "先頭へ") { $0.seek(to: 0) },
            command(.code(119), "End", "末尾へ") { $0.seek(to: $0.duration) },
        ]),
        Section(title: "分割", commands: [
            command(key("m", fallbackCode: 46), "M", "再生位置で分割") { $0.addSplit(at: $0.player.currentTime) },
            command(.codes([51, 117]), "⌫", "選択トラックの先頭の分割点を削除") { $0.removeSelectedSplit() },
            command(.code(43), ",", "分割点を 10 ミリ秒前へ") { $0.nudgeSelectedSplit(by: -0.01) },
            command(.code(47), ".", "分割点を 10 ミリ秒後ろへ") { $0.nudgeSelectedSplit(by: 0.01) },
            command(.code(43), shift: true, "⇧ ,", "分割点を 100 ミリ秒前へ") { $0.nudgeSelectedSplit(by: -0.1) },
            command(.code(47), shift: true, "⇧ .", "分割点を 100 ミリ秒後ろへ") { $0.nudgeSelectedSplit(by: 0.1) },
            command(key("e", fallbackCode: 14), "E", "選択トラックを書き出す / 書き出さない") { $0.toggleSelectedEnabled() },
        ]),
        Section(title: "フェード", commands: [
            command(key("i", fallbackCode: 34), "I", "トラックの先頭から再生位置までフェードイン") { $0.setFade(.start, at: $0.player.currentTime) },
            command(key("o", fallbackCode: 31), "O", "再生位置からトラックの末尾までフェードアウト") { $0.setFade(.end, at: $0.player.currentTime) },
            command(key("i", fallbackCode: 34), shift: true, "⇧ I", "フェードインを解除") { editor in
                if let i = editor.trackIndex(containing: editor.player.currentTime) { editor.removeFade(.start, ofTrackAt: i) }
            },
            command(key("o", fallbackCode: 31), shift: true, "⇧ O", "フェードアウトを解除") { editor in
                if let i = editor.trackIndex(containing: editor.player.currentTime) { editor.removeFade(.end, ofTrackAt: i) }
            },
        ]),
        Section(title: "表示", commands: [
            command(.characters(["=", "+"], fallbackCode: 24), shift: nil, "=", "拡大") { $0.zoom(by: 0.5) },
            command(key("-", fallbackCode: 27), "-", "縮小") { $0.zoom(by: 2) },
            command(key("z", fallbackCode: 6), "Z", "選択トラックに合わせて拡大") { $0.zoomToSelectedTrack() },
            command(key("z", fallbackCode: 6), shift: true, "⇧ Z", "全体を表示") { $0.zoomToFit() },
        ]),
    ]

    /// Shortcuts that live in the menu bar, listed alongside the single-key ones
    static let menuShortcuts: [(label: String, title: String)] = [
        ("⌘ O", "開く"),
        ("⌘ E", "書き出し"),
        ("⇧ ⌘ D", "無音区間で分割"),
        ("⌘ Z", "取り消す"),
        ("⇧ ⌘ Z", "やり直す"),
        ("⌘ =", "拡大"),
        ("⌘ -", "縮小"),
        ("⌘ 0", "全体を表示"),
        ("⌥ ⌘ I", "インスペクタを表示 / 隠す"),
        ("⌘ /", "キーボードショートカット"),
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
