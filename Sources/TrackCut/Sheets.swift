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
    /// 0 keeps the source's
    @AppStorage("exportBitDepth") private var bitDepth = 0
    /// 0 keeps the source's
    @AppStorage("exportSampleRate") private var sampleRate = 0.0
    @AppStorage("exportAACBitRate") private var aacBitRate = 256_000
    @StateObject private var state = ExportState()

    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .sameAsSource }

    /// The stored choices, limited to what the current format offers
    private var options: ExportOptions {
        ExportOptions(bitDepth: format.bitDepths.contains(bitDepth) ? bitDepth : nil,
                      sampleRate: format.sampleRates.contains(sampleRate) ? sampleRate : nil,
                      aacBitRate: ExportOptions.aacBitRates.contains(aacBitRate) ? aacBitRate : 256_000)
    }
    private var fadedCount: Int { editor.exportSegments().filter { !$0.envelope.isFlat }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Tracks").font(.headline)
            Form {
                Picker("Format", selection: $formatRaw) {
                    ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                if format == .aac {
                    Picker("Bit Rate", selection: Binding(get: { options.aacBitRate }, set: { aacBitRate = $0 })) {
                        ForEach(ExportOptions.aacBitRates, id: \.self) { Text(AudioFormatText.bitRate($0)).tag($0) }
                    }
                }
                if !format.bitDepths.isEmpty {
                    Picker("Bit Depth", selection: Binding(get: { options.bitDepth ?? 0 }, set: { bitDepth = $0 })) {
                        Text(sameAsSource(sourceBitDepth)).tag(0)
                        ForEach(format.bitDepths, id: \.self) { Text(AudioFormatText.bitDepth($0)).tag($0) }
                    }
                }
                if !format.sampleRates.isEmpty {
                    Picker("Sample Rate", selection: Binding(get: { options.sampleRate ?? 0 }, set: { sampleRate = $0 })) {
                        Text(sameAsSource(sourceSampleRate)).tag(0.0)
                        ForEach(format.sampleRates, id: \.self) { Text(AudioFormatText.sampleRate($0)).tag($0) }
                    }
                }
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

    /// "Same as Source" with the value it stands for, e.g. "Same as Source (44.1 kHz)"
    private func sameAsSource(_ value: String?) -> String {
        guard let value else { return String(localized: "Same as Source") }
        return String(localized: "Same as Source (\(value))")
    }

    /// The depth "same as source" is written at in this format (FLAC tops out at 24 bit, for example)
    private var sourceBitDepth: String? {
        guard let info = editor.source?.info else { return nil }
        var options = self.options
        options.bitDepth = nil
        return AudioExporter.outputBitDepth(source: info, format: format, options: options)
            .map { AudioFormatText.bitDepth($0.bits, isFloat: $0.isFloat) }
    }

    /// The source's rate, or the rate AAC lowers it to
    private var sourceSampleRate: String? {
        guard let info = editor.source?.info else { return nil }
        var options = self.options
        options.sampleRate = nil
        return AudioFormatText.sampleRate(AudioExporter.outputSampleRate(source: info, format: format, options: options))
    }

    private func chooseAndExport() {
        guard let source = editor.source else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export")
        panel.directoryURL = source.urls[0].deletingLastPathComponent()
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let segments = editor.exportSegments()
        let format = self.format
        let options = self.options
        state.errorText = nil
        state.exportedURLs = []

        let targets = AudioExporter.outputURLs(source: source, segments: segments, format: format, directory: directory)
        let existing = targets.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let clash = existing.first(where: { url in source.urls.contains { FileIdentity.isSameFile(url, $0) } }) {
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

        state.progress = 0
        state.exportTask = Task {
            do {
                state.exportedURLs = try await AudioExporter.export(
                    source: source, segments: segments, format: format, options: options, to: directory
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

/// The files in FilesSheet. A class rather than @State, which needs a compiler plugin that only Xcode has,
/// and the app also builds with the Command Line Tools.
@MainActor
private final class FileList: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let slot: EditorModel.FileSlot
        let url: URL
        /// nil if the file cannot be read
        let duration: Double?
    }

    @Published var items: [Item]
    @Published var selection: Item.ID?
    /// The source the existing items' indices refer to, when arranging
    let base: AudioSource?

    /// Reads the files' lengths, so it is made once per sheet (as a StateObject), not on every update
    init(_ mode: FilesSheet.Mode, source: AudioSource?) {
        switch mode {
        case .join(let urls):
            items = Self.added(urls)
            base = nil
        case .arrange:
            items = source.map { source in
                source.files.enumerated().map { Item(slot: .existing($0), url: $1.url, duration: $1.info.duration) }
            } ?? []
            base = source
        }
    }

    /// Files that are not part of the source yet
    static func added(_ urls: [URL]) -> [Item] {
        urls.map { Item(slot: .added($0), url: $0, duration: try? SourceAudioInfo(url: $0).duration) }
    }
}

/// The files of the source in their order: either files about to be joined into a new recording, or the
/// files of the one being edited. Files can be added, left out and put in another order.
struct FilesSheet: View {
    enum Mode {
        /// Files to open as a new recording
        case join([URL])
        /// The files of the recording being edited
        case arrange
    }

    @ObservedObject var editor: EditorModel
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @StateObject private var list: FileList

    init(editor: EditorModel, mode: Mode) {
        self.editor = editor
        self.mode = mode
        _list = StateObject(wrappedValue: FileList(mode, source: editor.source))
    }

    private var items: [FileList.Item] { list.items }
    private var selectedIndex: Int? { list.items.firstIndex { $0.id == list.selection } }
    private var isJoining: Bool { if case .join = mode { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isJoining ? "Join Files" : "Arrange Files").font(.headline)
            Text(isJoining
                 ? "The files are played one after another as one recording, with a split point where each file starts. Drag them to change the order."
                 : "Tracks move with the file they start in. Where two files are no longer next to each other, a track running from one into the other is split. Added files get a track each.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            List(selection: $list.selection) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    HStack(spacing: 8) {
                        Text(String(format: "%02d", i + 1))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(item.url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !isJoining, case .added = item.slot {
                            Text("New")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .background(.tint.opacity(0.2), in: Capsule())
                        }
                        Spacer()
                        if let duration = item.duration {
                            Text(TimeFormat.string(duration, fractionDigits: 0))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            Label("Cannot be read", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                    }
                    .help(item.url.path)
                    .tag(item.id)
                }
                .onMove { list.items.move(fromOffsets: $0, toOffset: $1) }
                // Files dragged in from Finder go where they are dropped
                .onInsert(of: [.fileURL]) { index, providers in
                    Task { insert(await Self.urls(from: providers), at: index) }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 260)
            HStack {
                Button { addFiles() } label: { Image(systemName: "plus") }
                    .help("Add files or folders after the selected file")
                Button { remove() } label: { Image(systemName: "minus") }
                    .help("Leave out (⌫)")
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(selectedIndex == nil)
                Button { move(by: -1) } label: { Image(systemName: "arrow.up") }
                    .help("Move up (⌥⌘↑)")
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled((selectedIndex ?? 0) == 0)
                Button { move(by: 1) } label: { Image(systemName: "arrow.down") }
                    .help("Move down (⌥⌘↓)")
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled((selectedIndex ?? items.count - 1) >= items.count - 1)
                Text(totalDuration)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isJoining ? "Join and Open" : "Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty || items.contains { $0.duration == nil }
                              || (!isJoining && !editor.canArrangeFiles))
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var totalDuration: String {
        String(localized: "\(items.count) files · \(TimeFormat.string(items.compactMap(\.duration).reduce(0, +), fractionDigits: 0))")
    }

    private func apply() {
        let items = self.items
        dismiss()
        if isJoining {
            editor.join(items.map(\.url))
        } else if let base = list.base {
            editor.arrangeFiles(items.map(\.slot), of: base)
        }
    }

    private func move(by offset: Int) {
        guard let i = selectedIndex, items.indices.contains(i + offset) else { return }
        list.items.swapAt(i, i + offset)
    }

    private func remove() {
        guard let i = selectedIndex else { return }
        list.items.remove(at: i)
        list.selection = items.indices.contains(i) ? items[i].id : items.last?.id
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = EditorModel.audioTypes + [.folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        insert(panel.urls, at: selectedIndex.map { $0 + 1 } ?? items.count)
    }

    /// Inserts the audio files among `urls` (folders stand for the files in them) and selects the first
    private func insert(_ urls: [URL], at index: Int) {
        let added = FileList.added(EditorModel.audioFiles(in: urls))
        guard !added.isEmpty else { return }
        list.items.insert(contentsOf: added, at: min(index, items.count))
        list.selection = added[0].id
    }

    private static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            if let url { urls.append(url) }
        }
        return urls
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
