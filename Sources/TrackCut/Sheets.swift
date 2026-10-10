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
            Text("Split at Silences").font(.headline)
            Form {
                LabeledContent("Threshold") {
                    HStack {
                        Slider(value: $thresholdDB, in: -80...(-20), step: 1)
                        Text("\(Int(thresholdDB)) dB").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                LabeledContent("Minimum gap") {
                    HStack {
                        Slider(value: $minDuration, in: 0.3...5, step: 0.1)
                        Text("\(minDuration, specifier: "%.1f") s").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
            }
            Text("Results in \(splits.count + 1) tracks. The current split points are replaced.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
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
    private var fadedCount: Int { editor.exportSegments().filter { !$0.envelope.isFlat }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Tracks").font(.headline)
            Picker("Format", selection: $formatRaw) {
                ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .disabled(state.progress != nil)
            Text("Exports \(editor.exportSegments().count) tracks as files named “01 Title”, tagged with the title, track number and album info")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            if fadedCount > 0 {
                Label("Applies fades to \(fadedCount) tracks. They are re-encoded even when AAC is otherwise cut as is",
                      systemImage: "waveform.path")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }

            if let progress = state.progress {
                ProgressView(value: progress)
            }
            if let errorText = state.errorText {
                Text(errorText).foregroundStyle(.red)
            }
            if !state.exportedURLs.isEmpty {
                HStack {
                    Text("Exported \(state.exportedURLs.count) files")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(state.exportedURLs) }
                }
            }

            HStack {
                Spacer()
                if state.progress != nil {
                    Button("Stop") { state.exportTask?.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Choose Folder and Export…") { chooseAndExport() }
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
        panel.prompt = String(localized: "Export")
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
                alert.messageText = String(localized: "\(existing.count) files already exist. Do you want to replace them?")
                alert.informativeText = existing.prefix(5).map(\.lastPathComponent).joined(separator: "\n")
                alert.addButton(withTitle: String(localized: "Replace"))
                alert.addButton(withTitle: String(localized: "Cancel"))
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
                state.errorText = String(localized: "Export stopped.")
            } catch {
                state.errorText = error.localizedDescription
            }
            state.progress = nil
        }
    }
}

/// List of every keyboard shortcut (Help > Keyboard Shortcuts, ⌘/)
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 28) {
                        column(KeyCommands.sections.prefix(2))
                        VStack(alignment: .leading, spacing: 20) {
                            column(KeyCommands.sections.dropFirst(2))
                            ShortcutGroup(title: String(localized: "Menu"), rows: KeyCommands.menuShortcuts)
                        }
                    }
                    Text("Single-key shortcuts work anywhere in the window except while typing in a text field.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 760, height: 600)
    }

    private func column(_ sections: ArraySlice<KeyCommands.Section>) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(sections)) { section in
                ShortcutGroup(title: section.title, rows: section.commands.map { ($0.label, $0.title) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShortcutGroup: View {
    let title: String
    let rows: [(label: String, title: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(rows, id: \.label) { row in
                    GridRow {
                        HStack(spacing: 3) {
                            ForEach(row.label.split(separator: " ").map(String.init), id: \.self) { KeyCap(key: $0) }
                        }
                        .gridColumnAlignment(.trailing)
                        Text(row.title)
                    }
                }
            }
        }
    }
}

private struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 22)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
    }
}
