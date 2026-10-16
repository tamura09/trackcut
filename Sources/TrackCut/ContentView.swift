import TrackCutCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject private var sheets = SheetState.shared
    @AppStorage("showsInspector") private var showsInspector = true
    @Environment(\.openWindow) private var openWindow

    private var isLoaded: Bool { editor.peaks != nil }

    var body: some View {
        Group {
            if isLoaded {
                VSplitView {
                    WaveformPanel(editor: editor)
                        .frame(minHeight: 260, idealHeight: 400)
                    TrackListView(editor: editor)
                        .frame(minHeight: 140, idealHeight: 240)
                }
            } else if let progress = editor.loadingProgress {
                LoadingView(fileName: editor.displayName, progress: progress)
            } else {
                EmptyStateView(isTargeted: sheets.isDropTargeted) { editor.presentOpenPanel() }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .inspector(isPresented: Binding(get: { isLoaded && showsInspector }, set: { showsInspector = $0 })) {
            InspectorView(editor: editor)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .onDrop(of: [.fileURL], isTargeted: $sheets.isDropTargeted) { providers in
            guard !providers.isEmpty else { return false }
            Task {
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url { urls.append(url) }
                }
                editor.openAfterConfirming(urls)
            }
            return true
        }
        .alert("Error", isPresented: Binding(get: { editor.errorMessage != nil },
                                             set: { if !$0 { editor.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(editor.errorMessage ?? "")
        }
        .sheet(isPresented: $sheets.showsSilence) { SilenceDetectionSheet(editor: editor) }
        .sheet(isPresented: $sheets.showsExport) { ExportSheet(editor: editor) }
        .sheet(isPresented: $sheets.showsShortcuts) { ShortcutsSheet() }
        .sheet(isPresented: Binding(get: { editor.filesToJoin != nil }, set: { if !$0 { editor.filesToJoin = nil } })) {
            FilesSheet(editor: editor, mode: .join(editor.filesToJoin ?? []))
        }
        .sheet(isPresented: $sheets.showsArrange) { FilesSheet(editor: editor, mode: .arrange) }
        // The dot in the close button
        .onChange(of: editor.hasUnsavedChanges, initial: true) { _, edited in editor.window?.isDocumentEdited = edited }
        .onAppear { sheets.reopenWindow = { openWindow(id: "main") } }
    }

    private var title: String { editor.displayName }

    private var subtitle: String {
        guard isLoaded else { return "" }
        let exported = editor.tracks.filter(\.isEnabled).count
        let total = TimeFormat.string(editor.duration, fractionDigits: 0)
        return exported == editor.tracks.count
            ? String(localized: "\(editor.tracks.count) tracks · \(total)")
            : String(localized: "\(editor.tracks.count) tracks (\(exported) exported) · \(total)")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { editor.presentOpenPanel() } label: { Label("Open", systemImage: "folder") }
                .help("Open (⌘O)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { sheets.showsSilence = true } label: {
                Label("Detect Silence", systemImage: "waveform.badge.magnifyingglass")
            }
            .help("Detect split points from silent gaps (⇧⌘D)")
            .disabled(!isLoaded)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { sheets.showsExport = true } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export each track to its own file (⌘E)")
            .disabled(!isLoaded)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showsInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show / hide the inspector (⌥⌘I)")
            .disabled(!isLoaded)
        }
    }
}

/// Sheet and drop state. Shared so that menu commands can open the sheets.
final class SheetState: ObservableObject {
    static let shared = SheetState()

    @Published var showsSilence = false
    @Published var showsExport = false
    @Published var showsShortcuts = false
    @Published var showsArrange = false
    @Published var isDropTargeted = false
    /// Opens the editor window again after it was closed
    var reopenWindow: (() -> Void)?
}

/// Overview, detail waveform and the floating transport controls
private struct WaveformPanel: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        VStack(spacing: 8) {
            WaveformView(mode: .overview, editor: editor, player: editor.player)
                .frame(height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            WaveformView(mode: .detail, editor: editor, player: editor.player)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
                .overlay(alignment: .bottom) {
                    TransportBar(editor: editor, player: editor.player)
                        .padding(.bottom, 12)
                        .padding(.horizontal, 12)
                }
                .overlay(alignment: .top) {
                    if let progress = editor.addingProgress {
                        HStack(spacing: 10) {
                            Text("Analyzing Added Files…").font(.callout)
                            ProgressView(value: progress).frame(width: 140)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassSurface(in: Capsule())
                        .padding(.top, 36)
                    }
                }
        }
        .padding(12)
    }
}

private struct EmptyStateView: View {
    var isTargeted: Bool
    var open: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 104, height: 104)
                .glassSurface(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            VStack(spacing: 6) {
                Text("Drop a File to Get Started")
                    .font(.title2.weight(.semibold))
                Text("Supports FLAC, M4A and WAV")
                    .foregroundStyle(.secondary)
            }
            Button(action: open) {
                Label("Open…", systemImage: "folder")
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .prominentButtonStyle()
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(.tint)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(20)
                .opacity(isTargeted ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: isTargeted)
        }
    }
}

private struct LoadingView: View {
    var fileName: String
    var progress: Double

    var body: some View {
        VStack(spacing: 14) {
            Text("Analyzing Waveform…").font(.headline)
            ProgressView(value: progress).frame(width: 260)
            Text(fileName).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
