import AppKit
import Testing
import TrackCutCore
@testable import TrackCut

private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

extension AppTests {
    /// Mouse handling of the detail waveform, driven with synthesized events
    @Suite("Waveform mouse handling") @MainActor
    struct WaveformViewTests {
        /// A detail view filling a window that is never shown. It shows the whole 13 s file at 100 points
        /// per second.
        private func makeView(_ editor: EditorModel, undo: UndoManager) -> WaveformNSView {
            let window = makeWindow(width: 1300, height: 300)
            let view = WaveformNSView(frame: NSRect(x: 0, y: 0, width: 1300, height: 300))
            view.mode = .detail
            window.contentView = view
            view.editor = editor
            view.player = editor.player
            // Attaching the view handed the window's undo manager to the editor
            editor.undoManager = undo
            editor.zoomToFit()
            return view
        }

        private func event(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)!
        }

        /// A press, a drag and a release in one undo step, as in the app where the release registers it
        private func drag(in view: WaveformNSView, from start: NSPoint, to end: NSPoint, undo: UndoManager) {
            step(undo) {
                view.mouseDown(with: event(.leftMouseDown, at: start, in: view))
                view.mouseDragged(with: event(.leftMouseDragged, at: end, in: view))
                view.mouseUp(with: event(.leftMouseUp, at: end, in: view))
            }
        }

        /// PR #4 review: when the two fades of a track meet, their handles are in the same place, and the
        /// press always picked the fade-in, so the fade-out could not be shortened
        @Test(arguments: [(-100.0, 4.0, 5.0), (100.0, 5.0, 4.0)])
        func meetingFadeHandlesFollowTheDragDirection(dx: Double, fadeIn: Double, fadeOut: Double) async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.addSplit(at: 10) }
            editor.selectedTrackID = editor.tracks[0].id
            step(undo) {
                editor.setFadeDuration(.start, 5, ofTrackAt: 0)
                editor.setFadeDuration(.end, 5, ofTrackAt: 0)
            }
            let view = makeView(editor, undo: undo)
            let centers = view.fadeHandleCenters(editor).map(\.center)
            #expect(centers.count == 2 && abs(centers[0].x - centers[1].x) < 0.5)

            drag(in: view, from: centers[0], to: NSPoint(x: centers[0].x + dx, y: centers[0].y), undo: undo)
            #expect(close(editor.tracks[0].fadeIn.duration, fadeIn))
            #expect(close(editor.tracks[0].fadeOut.duration, fadeOut))

            // The drag is one undo step
            undo.undo()
            #expect(close(editor.tracks[0].fadeIn.duration, 5))
            #expect(close(editor.tracks[0].fadeOut.duration, 5))
        }

        @Test func draggingASplitPointIsOneUndoStep() async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.addSplit(at: 10) }
            let view = makeView(editor, undo: undo)

            drag(in: view, from: NSPoint(x: 1000, y: 200), to: NSPoint(x: 1100, y: 200), undo: undo)
            #expect(close(editor.tracks[1].start, 11))
            undo.undo()
            #expect(close(editor.tracks[1].start, 10))
        }

        @Test func clickingMovesThePlayheadAndSelectsTheTrack() async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.addSplit(at: 10) }
            editor.selectedTrackID = editor.tracks[1].id
            let view = makeView(editor, undo: undo)

            view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 300, y: 200), in: view))
            view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 300, y: 200), in: view))
            #expect(close(editor.player.currentTime, 3))
            #expect(editor.selectedTrackID == editor.tracks[0].id)
            // Clicking registers no undo step: the last one is still the split
            #expect(undo.undoActionName == "Split")
        }
    }
}
