import TrackCutCore
import SwiftUI

/// Floating glass controls over the detail waveform: playback, the time, editing at the playhead and zoom
struct TransportBar: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var player: PlayerModel

    var body: some View {
        GlassGroup(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    playback
                    time
                    editing
                    zoom
                }
                HStack(spacing: 10) {
                    playback
                    editing
                    zoom
                }
                HStack(spacing: 10) {
                    playback
                    editing
                }
            }
        }
        .buttonStyle(GlassIconButtonStyle())
    }

    private var playback: some View {
        HStack(spacing: 2) {
            Button { editor.selectAdjacentTrack(-1) } label: { Image(systemName: "backward.end.fill") }
                .help("Previous track (↑)")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(GlassIconButtonStyle(size: 36))
            .help("Play / pause (Space)")
            Button { editor.selectAdjacentTrack(1) } label: { Image(systemName: "forward.end.fill") }
                .help("Next track (↓)")
        }
        .padding(3)
        .glassSurface(in: Capsule(), interactive: true)
    }

    private var time: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(TimeFormat.string(player.currentTime))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("/ " + TimeFormat.string(editor.duration))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .padding(.horizontal, 16)
        .frame(height: 42)
        .glassSurface(in: Capsule())
    }

    private var editing: some View {
        HStack(spacing: 2) {
            Button { editor.addSplit(at: player.currentTime) } label: { Image(systemName: "scissors") }
                .help("Split at the playhead (M)")
            Button { editor.removeSelectedSplit() } label: {
                Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
            }
            .help("Remove the split point at the start of the selected track (⌫)")
            .disabled(!editor.canRemoveSelectedSplit)
            Button { editor.setFade(.start, at: player.currentTime) } label: {
                Image(systemName: "righttriangle.fill")
            }
            .help("Fade in from the start of the track to the playhead (I)")
            Button { editor.setFade(.end, at: player.currentTime) } label: {
                Image(systemName: "righttriangle.fill").scaleEffect(x: -1)
            }
            .help("Fade out from the playhead to the end of the track (O)")
        }
        .padding(3)
        .glassSurface(in: Capsule(), interactive: true)
    }

    private var zoom: some View {
        HStack(spacing: 2) {
            Button { editor.zoom(by: 2) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out (⌘-)")
            Button { editor.zoomToFit() } label: { Image(systemName: "arrow.left.and.right.square") }
                .help("Zoom to fit (⌘0)")
            Button { editor.zoom(by: 0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in (⌘=), or ⌘ + scroll, or pinch")
        }
        .padding(3)
        .glassSurface(in: Capsule(), interactive: true)
    }
}
