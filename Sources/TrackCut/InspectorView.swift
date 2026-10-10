import TrackCutCore
import SwiftUI

/// Selected track (names, export, fades) and the album-wide tags
struct InspectorView: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        Form {
            if let i = editor.selectedIndex {
                trackSection(i)
                FadeSection(editor: editor, edge: .start, index: i)
                FadeSection(editor: editor, edge: .end, index: i)
                Section {
                    Button("Apply These Fades to All Tracks") { editor.applyFadesToAllTracks(from: i) }
                        .frame(maxWidth: .infinity)
                }
            }
            AlbumSection(editor: editor)
        }
        .formStyle(.grouped)
    }

    private func trackSection(_ i: Int) -> some View {
        let id = editor.tracks[i].id
        let start = editor.tracks[i].start
        return Section("Track \(i + 1)") {
            TextField("Title", text: editor.textBinding(.track(id, \.title)), prompt: Text(verbatim: "Track \(i + 1)"))
            TextField("Artist", text: editor.textBinding(.track(id, \.artist)),
                      prompt: Text(editor.albumTags.artist.isEmpty ? String(localized: "Same as album") : editor.albumTags.artist))
            Toggle("Include in Export", isOn: Binding(get: { editor.index(of: id).map { editor.tracks[$0].isEnabled } ?? false },
                                          set: { editor.setEnabled($0, for: id) }))
            LabeledContent("Start", value: TimeFormat.string(start))
                .monospacedDigit()
            LabeledContent("Length", value: TimeFormat.string(editor.end(ofTrackAt: i) - start))
                .monospacedDigit()
        }
    }
}

private struct FadeSection: View {
    @ObservedObject var editor: EditorModel
    let edge: FadeEdge
    let index: Int

    private var fade: Fade { editor.fade(edge, ofTrackAt: index) }
    private var trackLength: Double { editor.end(ofTrackAt: index) - editor.tracks[index].start }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                FadeGlyph(curve: fade.curve, isFadeOut: edge == .end)
                    .fill(Color.accentColor.opacity(fade.isEnabled ? 0.8 : 0.25))
                    .frame(width: 36, height: 22)
                Slider(value: duration, in: 0...max(0.1, min(trackLength, 30))) { editing in
                    if editing {
                        editor.beginContinuousEdit()
                    } else {
                        editor.endContinuousEdit(edge.actionName)
                    }
                }
                .labelsHidden()
                TextField("Seconds", value: Binding(get: { fade.duration }, set: { value in
                    editor.performUndoable(edge.actionName) { editor.setFadeDuration(edge, value, ofTrackAt: index) }
                }), format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                Text("s").foregroundStyle(.secondary)
            }
            Picker("Curve", selection: Binding(get: { fade.curve },
                                              set: { editor.setFadeCurve(edge, $0, ofTrackAt: index) })) {
                ForEach(FadeCurve.allCases) { curve in
                    Text(curve.displayName).tag(curve)
                }
            }
        } header: {
            Text(edge.title)
        } footer: {
            if isShortened {
                Text("Shortened to fit the track")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Whether the track has become too short for both fades since they were set
    private var isShortened: Bool {
        let envelope = editor.envelope(ofTrackAt: index)
        return (edge == .start ? envelope.fadeIn : envelope.fadeOut).duration + 0.0005 < fade.duration
    }

    /// Slider binding: changes are not registered for undo one by one but as one step when the drag ends
    private var duration: Binding<Double> {
        Binding(get: { fade.duration }, set: { editor.setFadeDuration(edge, $0, ofTrackAt: index) })
    }
}

/// Tags shared by the whole album
private struct AlbumSection: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        Section("Album") {
            TextField("Album", text: editor.textBinding(.album(\.album)))
            TextField("Artist", text: editor.textBinding(.album(\.artist)))
            TextField("Album Artist", text: editor.textBinding(.album(\.albumArtist)))
            TextField("Year", text: editor.textBinding(.album(\.date)))
            TextField("Genre", text: editor.textBinding(.album(\.genre)))
        }
    }
}
