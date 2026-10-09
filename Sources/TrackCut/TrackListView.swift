import TrackCutCore
import SwiftUI

struct TrackListView: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            AlbumTagsBar(tags: $editor.albumTags)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()

            HStack(spacing: 8) {
                Text("書出").frame(width: 30)
                Text("#").frame(width: 24, alignment: .trailing)
                Text("タイトル")
                Spacer()
                Text("アーティスト").frame(width: 180, alignment: .leading)
                Text("開始").frame(width: 90, alignment: .trailing)
                Text("長さ").frame(width: 80, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            Divider()

            ScrollViewReader { proxy in
                List(selection: Binding(get: { editor.selectedTrackID },
                                        set: { editor.selectTrack($0, seek: true) })) {
                    ForEach($editor.tracks) { $track in
                        let i = editor.index(of: track.id) ?? 0
                        HStack(spacing: 8) {
                            Toggle("", isOn: $track.isEnabled)
                                .labelsHidden()
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
                            Text(TimeFormat.string(track.start))
                                .monospacedDigit()
                                .frame(width: 90, alignment: .trailing)
                            Text(TimeFormat.string(editor.end(ofTrackAt: i) - track.start))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .trailing)
                        }
                        .opacity(track.isEnabled ? 1 : 0.5)
                        .tag(track.id)
                        .id(track.id)
                    }
                }
                .onChange(of: editor.selectedTrackID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }
}

/// Input fields for the tags shared by the whole album
private struct AlbumTagsBar: View {
    @Binding var tags: AudioTags

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            field("アルバム", $tags.album)
            field("アーティスト", $tags.artist)
            field("アルバムアーティスト", $tags.albumArtist)
            field("年", $tags.date).frame(width: 70)
            field("ジャンル", $tags.genre).frame(width: 120)
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }
    }
}
