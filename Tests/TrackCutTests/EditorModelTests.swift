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

            // The excluded track leaves no gap in the numbers
            let segments = editor.exportSegments()
            #expect(segments.map(\.fileBaseName) == ["01 Track 1", "02 Track 2"])
            #expect(close(segments[0].fadeIn.duration, 1))
            #expect(segments[1].tags?.trackNumber == 2)
            #expect(segments[1].tags?.trackTotal == 2)
            #expect(editor.tracks.indices.map(editor.exportNumber(ofTrackAt:)) == [1, nil, 2])
        }

        // MARK: - Projects

        @Test func projectRestoresTheWork() async throws {
            let (editor, undo) = try await loadedEditor()
            #expect(editor.source?.info.sampleRate == 44_100)
            #expect(!editor.hasUnsavedChanges)
            step(undo) { editor.applySplits([4, 9]) }
            step(undo) { editor.setEnabled(false, for: editor.tracks[1].id) }
            step(undo) { editor.setFade(.end, at: 12) }
            type("Live", into: .album(\.album), of: editor)
            type("Opener", into: .track(editor.tracks[0].id, \.title), of: editor)
            #expect(editor.hasUnsavedChanges)

            let url = editor.sourceURL!.deletingLastPathComponent().appendingPathComponent("Live.trackcut")
            #expect(editor.writeProject(to: url))
            #expect(editor.projectURL == url)
            #expect(!editor.hasUnsavedChanges)
            let saved = editor.tracks

            let reopened = EditorModel()
            reopened.open(url)
            try await waitUntilLoaded(reopened)
            #expect(reopened.projectURL == url)
            #expect(reopened.tracks == saved)
            #expect(reopened.albumTags.album == "Live")
            #expect(!reopened.hasUnsavedChanges)
            #expect(reopened.exportSegments().map(\.fileBaseName) == ["01 Opener", "02 Track 2"])
        }

        // MARK: - Joining files

        @Test func joinedFilesStartAsOneTrackEach() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let files = try ["10 Finale.wav", "01 - Opening.wav", "2. Ballad.wav"].map { try makeTestWAV(named: $0, in: folder) }
            try await TagWriter.write(AudioTags(title: "The Ballad", artist: "Guest", album: "Live"), to: files[2])
            try await TagWriter.write(AudioTags(artist: "Band", album: "Live"), to: files[1])

            let editor = EditorModel()
            // A folder is listed in Finder's order for the user to confirm
            editor.open(folder)
            #expect(editor.filesToJoin?.map(\.lastPathComponent) == ["01 - Opening.wav", "2. Ballad.wav", "10 Finale.wav"])
            editor.join(editor.filesToJoin!)
            try await waitUntilLoaded(editor)

            #expect(editor.source?.files.count == 3)
            #expect(abs(editor.duration - 39) < 0.001)
            #expect(editor.tracks.map(\.start) == [0, 13, 26])
            #expect(editor.tracks.map(\.title) == ["Opening", "The Ballad", "Finale"])
            // The files agree on the album but not on the artist, so each track keeps its file's artist
            #expect(editor.albumTags.album == "Live")
            #expect(editor.albumTags.artist == "")
            #expect(editor.tracks.map(\.artist) == ["Band", "Guest", ""])
            #expect(editor.displayName == folder.lastPathComponent)
            #expect(!editor.hasUnsavedChanges)

            // Saved and opened again as a project
            let url = folder.appendingPathComponent("Joined.trackcut")
            #expect(editor.writeProject(to: url))
            let reopened = EditorModel()
            reopened.open(url)
            try await waitUntilLoaded(reopened)
            #expect(reopened.source?.urls.map(\.lastPathComponent) == editor.source?.urls.map(\.lastPathComponent))
            #expect(reopened.tracks == editor.tracks)
        }

        @Test func filesChosenTogetherAreSortedButAFolderOfOneOpensDirectly() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let b = try makeTestWAV(named: "b.wav", in: folder)
            let a = try makeTestWAV(named: "a.wav", in: folder)
            let editor = EditorModel()
            editor.open([b, a, folder.appendingPathComponent("notes.txt")])
            #expect(editor.filesToJoin == [a, b])

            let single = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            _ = try makeTestWAV(named: "only.wav", in: single)
            let other = EditorModel()
            other.open(single)
            #expect(other.filesToJoin == nil)
            try await waitUntilLoaded(other)
            #expect(other.tracks.count == 1)
        }

        @Test func filesCanBeAddedReorderedAndRemovedAndUndone() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let files = try ["1 One.wav", "2 Two.wav", "3 Three.wav"].map { try makeTestWAV(named: $0, in: folder) }
            let (editor, undo) = try await loadedEditor()
            let first = editor.sourceURL!
            step(undo) { editor.addSplit(at: 9) }
            editor.seek(to: 10)

            // Adding analyzes the new files first, then puts them after the current one, a track each. The
            // arrangement is applied by a background task, outside any step, as in the app: the undo manager
            // groups it by event there.
            undo.groupsByEvent = true
            editor.arrangeFiles([.existing(0), .added(files[0]), .added(files[1])], of: editor.source!)
            #expect(editor.addingProgress != nil)
            // Nothing else can be arranged until the added files are in
            #expect(!editor.canArrangeFiles)
            while editor.addingProgress != nil { try await Task.sleep(for: .milliseconds(10)) }
            try await nextRunLoopPass()
            undo.groupsByEvent = false
            #expect(editor.source?.urls == [first, files[0], files[1]])
            #expect(abs(editor.duration - 39) < 0.001)
            #expect(editor.tracks.map(\.start) == [0, 9, 13, 26])
            #expect(editor.tracks.map(\.title) == ["", "", "One", "Two"])
            #expect(editor.player.currentTime == 10)

            // Moving the first file to the end moves its two tracks with it, without analyzing anything
            let firstTwo = Array(editor.tracks.prefix(2))
            step(undo) { editor.arrangeFiles([.existing(1), .existing(2), .existing(0)], of: editor.source!) }
            #expect(editor.addingProgress == nil)
            #expect(editor.tracks.map(\.title) == ["One", "Two", "", ""])
            #expect(editor.tracks.map(\.start) == [0, 13, 26, 35])
            #expect(editor.tracks.suffix(2).map(\.id) == firstTwo.map(\.id))
            #expect(abs(editor.peaks!.duration - 39) < 0.001)

            // Removing a file removes its track
            step(undo) { editor.arrangeFiles([.existing(0), .existing(2)], of: editor.source!) }
            #expect(editor.tracks.map(\.title) == ["One", "", ""])
            #expect(abs(editor.duration - 26) < 0.001)

            // Each step undoes back to the files and tracks before it
            undo.undo()
            #expect(editor.tracks.map(\.title) == ["One", "Two", "", ""])
            undo.undo()
            #expect(editor.source?.urls == [first, files[0], files[1]])
            #expect(editor.tracks.map(\.start) == [0, 9, 13, 26])
            undo.redo()
            #expect(editor.source?.urls == [files[0], files[1], first])
            #expect(editor.hasUnsavedChanges)
        }

        /// Review: the arrange sheet kept indices into the files as they were when it opened
        @Test func arrangingFilesThatChangedMeanwhileChangesNothing() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let other = try makeTestWAV(named: "other.wav", in: folder)
            let (editor, undo) = try await loadedEditor()
            let before = editor.source!
            step(undo) { editor.arrangeFiles([.existing(0), .existing(0)], of: before) }
            #expect(editor.source?.files.count == 2)

            // Indices into `before` no longer describe the files
            step(undo) { editor.arrangeFiles([.existing(0), .added(other)], of: before) }
            #expect(editor.errorMessage != nil)
            #expect(editor.source?.files.count == 2)
            #expect(editor.addingProgress == nil)
        }

        /// Review: the player was seeked before it was ready to play, which can be dropped
        @Test func playheadSurvivesLoadingAndSeekingEarly() async throws {
            let (editor, _) = try await loadedEditor()
            let player = editor.player
            player.load(editor.source!)
            player.seek(to: 5)
            #expect(!player.isReady)
            let deadline = Date().addingTimeInterval(10)
            while !player.isReady, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(player.isReady)
            // Pausing reads the time back from the player
            player.pause()
            #expect(abs(player.currentTime - 5) < 0.01)
        }

        @Test func aWindowShowsUnsavedChangesWhenItIsSet() async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.addSplit(at: 5) }
            let window = makeWindow()
            editor.window = window
            #expect(window.isDocumentEdited)
            editor.undoManager = undo
        }

        @Test func titlesFromFileNamesLoseTheTrackNumber() {
            func title(_ name: String) -> String { EditorModel.title(fromFileName: URL(fileURLWithPath: "/x/" + name)) }
            #expect(title("01 Song.flac") == "Song")
            #expect(title("01 - Song.flac") == "Song")
            #expect(title("1-02 Song.flac") == "Song")
            #expect(title("03. Song.flac") == "Song")
            #expect(title("04_Song.flac") == "Song")
            #expect(title("05-Song.flac") == "Song")
            #expect(title("1999.flac") == "1999")
            #expect(title("Song.flac") == "Song")
        }

        @Test func undoingBackToTheSavedStateClearsUnsavedChanges() async throws {
            let (editor, undo) = try await loadedEditor()
            step(undo) { editor.addSplit(at: 5) }
            #expect(editor.hasUnsavedChanges)
            undo.undo()
            #expect(!editor.hasUnsavedChanges)
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
