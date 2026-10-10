import AppKit
import Testing
@testable import TrackCut

extension AppTests {
    @Suite("Single-key shortcuts") @MainActor
    struct KeyCommandsTests {
        private func command(_ label: String) -> KeyCommand {
            KeyCommands.sections.flatMap(\.commands).first { $0.label == label }!
        }

        @Test func lettersMatchOnlyWithoutCommandAndWithTheRightShift() {
            #expect(command("M").matches(keyEvent("m", keyCode: 46)))
            #expect(!command("M").matches(keyEvent("m", keyCode: 46, modifiers: .command)))
            #expect(!command("M").matches(keyEvent("m", keyCode: 46, modifiers: .option)))
            #expect(command("I").matches(keyEvent("i", keyCode: 34)))
            #expect(!command("I").matches(keyEvent("I", keyCode: 34, modifiers: .shift)))
            #expect(command("⇧ I").matches(keyEvent("I", keyCode: 34, modifiers: .shift)))
        }

        @Test func lettersFollowTheLayoutAndFallBackToTheKeyPositionForKana() {
            // Dvorak: the key typing "m" is not at the US "M" position
            #expect(command("M").matches(keyEvent("m", keyCode: 41)))
            // Kana input types "も" on the "M" key
            #expect(command("M").matches(keyEvent("も", keyCode: 46)))
            #expect(!command("M").matches(keyEvent("の", keyCode: 45)))
        }

        @Test func zoomInMatchesWithOrWithoutShift() {
            // "=" is a key of its own on US keyboards and Shift + "-" on JIS keyboards
            #expect(command("=").matches(keyEvent("=", keyCode: 24)))
            #expect(command("=").matches(keyEvent("=", keyCode: 27, modifiers: .shift)))
            #expect(command("=").matches(keyEvent("+", keyCode: 24, modifiers: .shift)))
            #expect(!command("-").matches(keyEvent("=", keyCode: 27, modifiers: .shift)))
        }

        @Test func deleteAndForwardDeleteBothRemoveTheSplitPoint() {
            #expect(command("⌫").matches(keyEvent("\u{7F}", keyCode: 51)))
            #expect(command("⌫").matches(keyEvent("\u{F728}", keyCode: 117)))
        }

        @Test func noKeyRunsTwoCommands() {
            let commands = KeyCommands.sections.flatMap(\.commands)
            #expect(Set(commands.map(\.label)).count == commands.count)
            let events = [
                keyEvent(" ", keyCode: 49), keyEvent("m", keyCode: 46), keyEvent("i", keyCode: 34),
                keyEvent("I", keyCode: 34, modifiers: .shift), keyEvent("o", keyCode: 31),
                keyEvent("O", keyCode: 31, modifiers: .shift), keyEvent("z", keyCode: 6),
                keyEvent("Z", keyCode: 6, modifiers: .shift), keyEvent(",", keyCode: 43),
                keyEvent("<", keyCode: 43, modifiers: .shift), keyEvent("e", keyCode: 14),
                keyEvent("\u{F702}", keyCode: 123), keyEvent("\u{F702}", keyCode: 123, modifiers: .shift),
            ]
            for event in events {
                #expect(commands.filter { $0.matches(event) }.count == 1, "\(event.charactersIgnoringModifiers ?? "")")
            }
        }

        /// Single-key shortcuts are handled by an event monitor instead of being menu key equivalents, so
        /// that they never fire while typing. This keeps that promise.
        @Test func shortcutsAreIgnoredWhileATextFieldIsEditing() async throws {
            let (editor, undo) = try await loadedEditor()
            let window = makeWindow()
            let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
            window.contentView!.addSubview(field)
            editor.seek(to: 5)
            let m = keyEvent("m", keyCode: 46, window: window)

            #expect(window.makeFirstResponder(field))
            #expect(window.firstResponder is NSText)
            var handled = true
            step(undo) { handled = KeyCommands.handle(m, in: window, editor: editor) }
            #expect(!handled)
            #expect(editor.tracks.count == 1)

            window.makeFirstResponder(nil)
            step(undo) { handled = KeyCommands.handle(m, in: window, editor: editor) }
            #expect(handled)
            #expect(editor.tracks.map(\.start) == [0, 5])
        }

        @Test func shortcutsAreIgnoredWhileASheetIsOpen() async throws {
            let (editor, undo) = try await loadedEditor()
            let window = makeWindow()
            let sheet = makeWindow(width: 200, height: 100)
            editor.seek(to: 5)
            window.beginSheet(sheet) { _ in }
            defer { window.endSheet(sheet) }
            var handled = true
            step(undo) { handled = KeyCommands.handle(keyEvent("m", keyCode: 46, window: window), in: window, editor: editor) }
            #expect(!handled)
            #expect(editor.tracks.count == 1)
        }
    }
}
