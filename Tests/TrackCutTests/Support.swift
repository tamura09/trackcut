import AppKit
import AVFoundation
import Testing
import TrackCutCore
@testable import TrackCut

/// All app tests run one at a time: they share the main actor, AppKit windows and the text-editing
/// notifications every EditorModel listens to.
@Suite(.serialized) @MainActor
struct AppTests {}

/// 3 s tone -> 2 s silence -> 3 s tone -> 2 s silence -> 3 s tone (13 s in total)
func makeTestWAV() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("source.wav")
    let sampleRate = 44_100.0
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    for (seconds, tone) in [(3.0, true), (2, false), (3, true), (2, false), (3, true)] {
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                p[i] = tone ? 0.5 * sin(Float(i) * 2 * .pi * 440 / Float(sampleRate)) : 0
            }
        }
        try file.write(from: buffer)
    }
    file.close()
    return url
}

/// An editor with the test file loaded and an undo manager of its own. The editor only holds the undo
/// manager weakly, so keep the returned one alive for the whole test.
///
/// The undo manager does not group by event, so that tests decide what makes up one step instead of
/// depending on when the run loop comes round. Wrap each user action in `step` so that it becomes one
/// undo step, as one event would in the app.
@MainActor
func loadedEditor() async throws -> (EditorModel, UndoManager) {
    let editor = EditorModel()
    editor.open(try makeTestWAV())
    let deadline = Date().addingTimeInterval(20)
    while editor.peaks == nil {
        if let message = editor.errorMessage { throw TestFailure(message) }
        guard Date() < deadline else { throw TestFailure("the test file did not load") }
        try await Task.sleep(for: .milliseconds(10))
    }
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    editor.undoManager = undoManager
    return (editor, undoManager)
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Lets the main run loop come round, which ends an event: an undo manager that groups by event closes
/// its group, and work queued on the main queue runs
func nextRunLoopPass() async throws {
    try await Task.sleep(for: .milliseconds(50))
}

/// Runs `action` as one event would: everything it registers is one undo step
@MainActor
func step(_ undoManager: UndoManager, _ action: () -> Void) {
    undoManager.beginUndoGrouping()
    action()
    undoManager.endUndoGrouping()
}

/// Types `text` into a field the way a text field does: one binding update per keystroke
@MainActor
func type(_ text: String, into target: EditorModel.TextTarget, of editor: EditorModel) {
    var typed = ""
    for character in text {
        typed.append(character)
        editor.setText(typed, for: target)
    }
}

/// A window that is never shown, for views and responders
@MainActor
func makeWindow(width: CGFloat = 1300, height: CGFloat = 300) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
}

func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
              window: NSWindow? = nil) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                     windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}
