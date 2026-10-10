import AppKit
import Testing
import TrackCutCore
@testable import TrackCut

private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

extension AppTests {
    @Suite("Editing and undo") @MainActor
    struct EditorModelTests {
        // MARK: - Fades stay where they are in the file

        @Test func splittingHandsTheFadeOutToTheNewLastPart() async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.setFade(.end, at: 10) }
            #expect(close(editor.tracks[0].fadeOut.duration, 3))

            step(undo) { editor.addSplit(at: 5) }
            #expect(!editor.tracks[0].fadeOut.isEnabled)
            #expect(close(editor.tracks[1].fadeOut.duration, 3))

            step(undo) { editor.removeSplit(editor.tracks[1].id) }
            #expect(close(editor.tracks[0].fadeOut.duration, 3))
        }

        /// PR #4 review: silence detection carried fades over by track number, so the fade-out at the end of
        /// the file ended up at the end of track 1
        @Test func silenceDetectionKeepsTheFadeOutAtTheEndOfTheFile() async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.setFade(.end, at: 11) }
            let splits = SilenceDetector.splitPoints(in: editor.peaks!, thresholdDB: -50, minDuration: 1)
            step(undo) { editor.applySplits(splits) }

            #expect(editor.tracks.count == 3)
            #expect(editor.tracks.map(\.fadeOut.isEnabled) == [false, false, true])
            #expect(close(editor.envelope(ofTrackAt: 2).fadeOut.duration, 2))
        }

        /// PR #4 review: "apply to all tracks" limited the fade-in first, which left no room for the
        /// fade-out on tracks shorter than both
        @Test func applyingFadesToAllTracksKeepsBothOnShortTracks() async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.addSplit(at: 1) }
            step(undo) {
                editor.setFadeDuration(.start, 4, ofTrackAt: 1)
                editor.setFadeDuration(.end, 4, ofTrackAt: 1)
            }
            step(undo) { editor.applyFadesToAllTracks(from: 1) }

            // Track 1 is 1 s long: both fades are shortened in proportion, neither is dropped
            let short = editor.envelope(ofTrackAt: 0)
            #expect(close(short.fadeIn.duration, 0.5))
            #expect(close(short.fadeOut.duration, 0.5))
        }

        /// PR #4 review: editing one fade of a track that had become too short for both limited it by the
        /// other's stored length, which changed the length the other one is applied with
        @Test func editingAShortenedFadeKeepsTheOtherAsApplied() async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.addSplit(at: 10) }
            step(undo) {
                editor.setFadeDuration(.start, 4, ofTrackAt: 0)
                editor.setFadeDuration(.end, 4, ofTrackAt: 0)
            }
            // Shorten the track to 5 s: both fades are applied at 2.5 s
            step(undo) { editor.moveSplit(editor.tracks[1].id, to: 5) }
            #expect(close(editor.envelope(ofTrackAt: 0).fadeOut.duration, 2.5))

            step(undo) { editor.setFadeDuration(.start, 2, ofTrackAt: 0) }
            #expect(close(editor.tracks[0].fadeIn.duration, 2))
            #expect(close(editor.envelope(ofTrackAt: 0).fadeOut.duration, 2.5))
        }

        // MARK: - Undo

        @Test func undoAndRedoRestoreSplitsAndFades() async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.addSplit(at: 5) }
            step(undo) { editor.setFade(.start, at: 7) }
            #expect(close(editor.tracks[1].fadeIn.duration, 2))

            undo.undo()
            #expect(!editor.tracks[1].fadeIn.isEnabled)
            undo.undo()
            #expect(editor.tracks.count == 1)
            undo.redo()
            #expect(editor.tracks.map(\.start) == [0, 5])
            undo.redo()
            #expect(close(editor.tracks[1].fadeIn.duration, 2))
        }

        /// PR #4 review: text fields wrote straight into the model, so once a field stopped editing ⌘Z
        /// skipped the rename and undid the split before it
        @Test func committedTextEditsAreUndoSteps() async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.addSplit(at: 5) }
            let first = editor.tracks[0].id
            type("Intro", into: .track(first, \.title), of: editor)
            step(undo) { editor.commitTextEdits() }
            type("Someone", into: .album(\.artist), of: editor)
            step(undo) { editor.commitTextEdits() }

            undo.undo()
            #expect(editor.albumTags.artist == "")
            #expect(editor.text(.track(first, \.title)) == "Intro")
            undo.undo()
            #expect(editor.text(.track(first, \.title)) == "")
            #expect(editor.tracks.count == 2)
            undo.undo()
            #expect(editor.tracks.count == 1)
        }

        /// A text field reports the end of editing with a notification; the edit is registered on the next pass
        @Test func endOfEditingNotificationRegistersTheTextEdit() async throws {
            let (editor, undo) = try await loadedEditor()
            undo.groupsByEvent = true
            type("Intro", into: .track(editor.tracks[0].id, \.title), of: editor)
            NotificationCenter.default.post(name: NSControl.textDidEndEditingNotification, object: nil)
            try await nextRunLoopPass()

            #expect(undo.canUndo)
            undo.undo()
            #expect(editor.tracks[0].title == "")
        }

        /// PR #4 review: typing a title and removing its track before the field committed lost the undo of
        /// the title, because the late commit could no longer find the track
        @Test func pendingTextEditIsRegisteredBeforeItsTrackIsRemoved() async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.addSplit(at: 5) }
            let second = editor.tracks[1].id

            // One event as in the app, where the undo manager groups everything registered until the run
            // loop comes round: the title is still being typed when the split point is removed
            undo.groupsByEvent = true
            type("Intro", into: .track(second, \.title), of: editor)
            editor.removeSplit(second)
            try await nextRunLoopPass()
            #expect(editor.tracks.count == 1)

            // Two separate steps: first the removal, then the title
            undo.undo()
            #expect(editor.tracks.count == 2)
            #expect(editor.text(.track(second, \.title)) == "Intro")
            undo.undo()
            #expect(editor.text(.track(second, \.title)) == "")
            #expect(editor.tracks.count == 2)
        }

        @Test func openingAFileClearsUndo() async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.addSplit(at: 5) }
            type("Intro", into: .album(\.album), of: editor)
            editor.open(try makeTestWAV())
            #expect(!undo.canUndo)
            // The text typed for the previous file is not registered against the new one
            #expect(!editor.commitTextEdits())
        }

        // MARK: - Export and navigation

        @Test func exportSegmentsSkipExcludedTracksAndCarryFades() async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.applySplits([4, 9]) }
            step(undo) { editor.setEnabled(false, for: editor.tracks[1].id) }
            step(undo) { editor.setFade(.start, at: 1) }

            let segments = editor.exportSegments()
            #expect(segments.map(\.fileBaseName) == ["01 Track 1", "03 Track 3"])
            #expect(close(segments[0].fadeIn.duration, 1))
            #expect(segments[1].tags?.trackNumber == 3)
            #expect(segments[1].tags?.trackTotal == 3)
        }

        @Test func previousTrackReturnsToTheStartOfTheCurrentOneFirst() async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.addSplit(at: 5) }
            editor.seek(to: 7)
            editor.selectAdjacentTrack(-1)
            #expect(editor.player.currentTime == 5)
            editor.selectAdjacentTrack(-1)
            #expect(editor.player.currentTime == 0)
            editor.selectAdjacentTrack(1)
            #expect(editor.player.currentTime == 5)
            #expect(editor.selectedTrackID == editor.tracks[1].id)
        }
    }
}
