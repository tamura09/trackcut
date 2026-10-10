import TrackCutCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var sheets = SheetState()

    var body: some View {
        Group {
            if editor.peaks != nil {
                VSplitView {
                    VStack(spacing: 0) {
                        WaveformView(mode: .overview, editor: editor, player: editor.player)
                            .frame(height: 44)
                        WaveformView(mode: .detail, editor: editor, player: editor.player)
                    }
                    .frame(minHeight: 220, idealHeight: 360)
                    TrackListView(editor: editor)
                        .frame(minHeight: 140, idealHeight: 240)
                }
            } else if let progress = editor.loadingProgress {
                VStack(spacing: 12) {
                    ProgressView(value: progress).frame(width: 280)
                    Text("波形を解析中…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 48)).foregroundStyle(.tertiary)
                    Text("FLAC / M4A / WAV ファイルをドロップ、または ⌘O で開く")
                        .foregroundStyle(.secondary)
                    Button("開く…") { editor.presentOpenPanel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(editor.sourceURL?.lastPathComponent ?? "TrackCut")
        .toolbar { toolbar }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in editor.open(url) }
            }
            return true
        }
        .alert("エラー", isPresented: Binding(get: { editor.errorMessage != nil },
                                             set: { if !$0 { editor.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(editor.errorMessage ?? "")
        }
        .sheet(isPresented: $sheets.showsSilence) { SilenceDetectionSheet(editor: editor) }
        .sheet(isPresented: $sheets.showsExport) { ExportSheet(editor: editor) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let loaded = editor.peaks != nil
        ToolbarItemGroup(placement: .navigation) {
            Button { editor.presentOpenPanel() } label: { Label("開く", systemImage: "folder") }
                .help("開く (⌘O)")
        }
        ToolbarItemGroup {
            PlaybackControls(player: editor.player).disabled(!loaded)
            Button { editor.addSplit(at: editor.player.currentTime) } label: {
                Label("分割", systemImage: "scissors")
            }
            .help("再生位置で分割 (M) — 波形のダブルクリックでも分割")
            .disabled(!loaded)
            Button { editor.removeSelectedSplit() } label: {
                Label("分割点を削除", systemImage: "arrow.right.and.line.vertical.and.arrow.left")
            }
            .help("選択中トラックの先頭の分割点を削除 (Delete)")
            .disabled(!editor.canRemoveSelectedSplit)
            Button { sheets.showsSilence = true } label: {
                Label("無音検出", systemImage: "waveform.badge.magnifyingglass")
            }
            .help("無音区間から分割点を自動検出")
            .disabled(!loaded)
        }
        ToolbarItemGroup {
            Button { editor.zoom(by: 0.5) } label: { Label("拡大", systemImage: "plus.magnifyingglass") }
                .help("拡大 (⌘ + スクロール / ピンチでも可)")
            Button { editor.zoom(by: 2) } label: { Label("縮小", systemImage: "minus.magnifyingglass") }
                .help("縮小")
            Button { editor.zoomToFit() } label: {
                Label("全体", systemImage: "arrow.left.and.right.square")
            }
            .help("全体を表示")
        }
        ToolbarItemGroup {
            Button { sheets.showsExport = true } label: {
                Label("書き出し", systemImage: "square.and.arrow.up")
            }
            .help("曲ごとに書き出し")
            .disabled(!loaded)
        }
    }
}

/// The Command Line Tools SDK ships without the @State macro plugin, so view state lives in an ObservableObject
private final class SheetState: ObservableObject {
    @Published var showsSilence = false
    @Published var showsExport = false
}

private struct PlaybackControls: View {
    @ObservedObject var player: PlayerModel

    var body: some View {
        Button { player.toggle() } label: {
            Label(player.isPlaying ? "一時停止" : "再生", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
        }
        .help("再生 / 一時停止 (Space)")
        Text(TimeFormat.string(player.currentTime))
            .font(.system(.body, design: .monospaced))
            .frame(minWidth: 90)
    }
}
