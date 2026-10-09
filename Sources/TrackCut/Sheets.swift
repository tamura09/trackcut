import AppKit
import TrackCutCore
import SwiftUI

struct SilenceDetectionSheet: View {
    @ObservedObject var editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("silenceThresholdDB") private var thresholdDB = -45.0
    @AppStorage("silenceMinDuration") private var minDuration = 1.5

    private var splits: [Double] {
        guard let peaks = editor.peaks else { return [] }
        return SilenceDetector.splitPoints(in: peaks, thresholdDB: thresholdDB, minDuration: minDuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("無音区間で分割").font(.headline)
            Form {
                LabeledContent("しきい値") {
                    HStack {
                        Slider(value: $thresholdDB, in: -80...(-20), step: 1)
                        Text("\(Int(thresholdDB)) dB").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                LabeledContent("最短の無音") {
                    HStack {
                        Slider(value: $minDuration, in: 0.3...5, step: 0.1)
                        Text(String(format: "%.1f 秒", minDuration)).monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
            }
            Text("\(splits.count + 1) 曲に分割されます（現在の分割点は置き換えられます）")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("適用") {
                    editor.applySplits(splits)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

@MainActor
private final class ExportState: ObservableObject {
    @Published var progress: Double?
    @Published var exportedURLs: [URL] = []
    @Published var errorText: String?
    var exportTask: Task<Void, Never>?
}

struct ExportSheet: View {
    @ObservedObject var editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportFormat") private var formatRaw = ExportFormat.sameAsSource.rawValue
    @StateObject private var state = ExportState()

    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .sameAsSource }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("曲ごとに書き出し").font(.headline)
            Picker("形式", selection: $formatRaw) {
                ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .disabled(state.progress != nil)
            Text("\(editor.exportSegments().count) 曲を「01 タイトル」形式のファイル名で書き出し、タイトル・トラック番号・アルバム情報のタグを書き込みます")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            if let progress = state.progress {
                ProgressView(value: progress)
            }
            if let errorText = state.errorText {
                Text(errorText).foregroundStyle(.red)
            }
            if !state.exportedURLs.isEmpty {
                HStack {
                    Text("\(state.exportedURLs.count) ファイルを書き出しました")
                    Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting(state.exportedURLs) }
                }
            }

            HStack {
                Spacer()
                if state.progress != nil {
                    Button("中止") { state.exportTask?.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("書き出し先を選んで書き出す…") { chooseAndExport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(editor.exportSegments().isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func chooseAndExport() {
        guard let source = editor.sourceURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "書き出し"
        panel.directoryURL = source.deletingLastPathComponent()
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let segments = editor.exportSegments()
        let format = self.format
        state.errorText = nil
        state.exportedURLs = []

        do {
            let targets = try AudioExporter.outputURLs(source: source, segments: segments, format: format,
                                                       directory: directory)
            let existing = targets.filter { FileManager.default.fileExists(atPath: $0.path) }
            if let clash = existing.first(where: { FileIdentity.isSameFile($0, source) }) {
                state.errorText = AudioError.outputIsSource(clash.lastPathComponent).localizedDescription
                return
            }
            if !existing.isEmpty {
                let alert = NSAlert()
                alert.messageText = "\(existing.count) 個のファイルが既に存在します。上書きしますか？"
                alert.informativeText = existing.prefix(5).map(\.lastPathComponent).joined(separator: "\n")
                alert.addButton(withTitle: "上書き")
                alert.addButton(withTitle: "キャンセル")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        } catch {
            state.errorText = error.localizedDescription
            return
        }

        state.progress = 0
        state.exportTask = Task {
            do {
                state.exportedURLs = try await AudioExporter.export(
                    source: source, segments: segments, format: format, to: directory
                ) { p in
                    Task { @MainActor in
                        if state.progress != nil { state.progress = p }
                    }
                }
            } catch is CancellationError {
                state.errorText = "中止しました"
            } catch {
                state.errorText = error.localizedDescription
            }
            state.progress = nil
        }
    }
}
