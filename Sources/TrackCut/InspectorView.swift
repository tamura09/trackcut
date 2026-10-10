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
                    Button("このフェードをすべてのトラックに適用") { editor.applyFadesToAllTracks(from: i) }
                        .frame(maxWidth: .infinity)
                }
            }
            AlbumSection(tags: $editor.albumTags)
        }
        .formStyle(.grouped)
    }

    private func trackSection(_ i: Int) -> some View {
        let id = editor.tracks[i].id
        let start = editor.tracks[i].start
        return Section("トラック \(i + 1)") {
            TextField("タイトル", text: trackBinding(id, \.title), prompt: Text("Track \(i + 1)"))
            TextField("アーティスト", text: trackBinding(id, \.artist),
                      prompt: Text(editor.albumTags.artist.isEmpty ? "アルバムと同じ" : editor.albumTags.artist))
            Toggle("書き出す", isOn: Binding(get: { editor.index(of: id).map { editor.tracks[$0].isEnabled } ?? false },
                                          set: { editor.setEnabled($0, for: id) }))
            LabeledContent("開始", value: TimeFormat.string(start))
                .monospacedDigit()
            LabeledContent("長さ", value: TimeFormat.string(editor.end(ofTrackAt: i) - start))
                .monospacedDigit()
        }
    }

    private func trackBinding(_ id: Track.ID, _ keyPath: WritableKeyPath<Track, String>) -> Binding<String> {
        Binding(get: { editor.index(of: id).map { editor.tracks[$0][keyPath: keyPath] } ?? "" },
                set: { value in if let i = editor.index(of: id) { editor.tracks[i][keyPath: keyPath] = value } })
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
                TextField("秒", value: Binding(get: { fade.duration }, set: { value in
                    editor.performUndoable(edge.actionName) { editor.setFadeDuration(edge, value, ofTrackAt: index) }
                }), format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                Text("秒").foregroundStyle(.secondary)
            }
            Picker("カーブ", selection: Binding(get: { fade.curve },
                                              set: { editor.setFadeCurve(edge, $0, ofTrackAt: index) })) {
                ForEach(FadeCurve.allCases) { curve in
                    Text(curve.displayName).tag(curve)
                }
            }
        } header: {
            Text(edge == .start ? "フェードイン" : "フェードアウト")
        } footer: {
            if isShortened {
                Text("トラックより長いため短縮して適用されます")
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
    @Binding var tags: AudioTags

    var body: some View {
        Section("アルバム") {
            TextField("アルバム", text: $tags.album)
            TextField("アーティスト", text: $tags.artist)
            TextField("アルバムアーティスト", text: $tags.albumArtist)
            TextField("年", text: $tags.date)
            TextField("ジャンル", text: $tags.genre)
        }
    }
}
