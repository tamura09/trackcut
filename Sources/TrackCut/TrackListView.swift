import TrackCutCore
import SwiftUI

struct TrackListView: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("書出").frame(width: 30)
                Text("#").frame(width: 24, alignment: .trailing)
                Text("タイトル")
                Spacer()
                Text("アーティスト").frame(width: 180, alignment: .leading)
                Text("フェード").frame(width: 92, alignment: .center)
                Text("開始").frame(width: 84, alignment: .trailing)
                Text("長さ").frame(width: 76, alignment: .trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollViewReader { proxy in
                List(selection: Binding(get: { editor.selectedTrackID },
                                        set: { editor.selectTrack($0, seek: true) })) {
                    ForEach($editor.tracks) { $track in
                        let i = editor.index(of: track.id) ?? 0
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(get: { track.isEnabled },
                                                     set: { editor.setEnabled($0, for: track.id) }))
                                .labelsHidden()
                                .help("書き出す (E)")
                                .frame(width: 30)
                            Text(String(format: "%02d", i + 1))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            TextField("Track \(i + 1)", text: $track.title)
                                .textFieldStyle(.plain)
                            TextField(editor.albumTags.artist.isEmpty ? "アーティスト" : editor.albumTags.artist,
                                      text: $track.artist)
                                .textFieldStyle(.plain)
                                .frame(width: 180)
                            FadeSummary(envelope: editor.envelope(ofTrackAt: i))
                                .frame(width: 92)
                            Text(TimeFormat.string(track.start))
                                .monospacedDigit()
                                .frame(width: 84, alignment: .trailing)
                            Text(TimeFormat.string(editor.end(ofTrackAt: i) - track.start))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 76, alignment: .trailing)
                        }
                        .opacity(track.isEnabled ? 1 : 0.5)
                        .tag(track.id)
                        .id(track.id)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onChange(of: editor.selectedTrackID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }
}

/// Fade-in and fade-out lengths of a track, or a dash for none
private struct FadeSummary: View {
    let envelope: FadeEnvelope

    var body: some View {
        HStack(spacing: 8) {
            item(envelope.fadeIn, isFadeOut: false)
            item(envelope.fadeOut, isFadeOut: true)
        }
        .font(.caption)
        .monospacedDigit()
    }

    private func item(_ fade: Fade, isFadeOut: Bool) -> some View {
        HStack(spacing: 3) {
            FadeGlyph(curve: fade.curve, isFadeOut: isFadeOut)
                .fill(fade.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .frame(width: 10, height: 8)
            Text(fade.isEnabled ? String(format: "%.1f", fade.duration) : "–")
                .foregroundStyle(fade.isEnabled ? .primary : .tertiary)
                .frame(minWidth: 22, alignment: .leading)
        }
    }
}
