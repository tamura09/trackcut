import TrackCutCore
import SwiftUI

/// Selected track (names, export, fades) and the album-wide tags
struct InspectorView: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        Form {
            if let i = editor.selectedIndex {
                trackSection(i)
                FadeSection(editor: editor, edge: .start, trackID: editor.tracks[i].id)
                FadeSection(editor: editor, edge: .end, trackID: editor.tracks[i].id)
                Section {
                    Button("Apply These Fades to All Tracks") { editor.applyFadesToAllTracks(from: i) }
                        .frame(maxWidth: .infinity)
                }
            }
            AlbumSection(editor: editor)
            if let source = editor.source {
                if source.files.count == 1 {
                    SourceFileSection(url: source.urls[0], info: source.files[0].info)
                } else {
                    SourceFilesSection(source: source)
                }
                Section {
                    HStack {
                        Button("Add Files…") { editor.presentAddFilesPanel() }
                        Button("Arrange Files…") { SheetState.shared.showsArrange = true }
                    }
                    .disabled(!editor.canArrangeFiles)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func trackSection(_ i: Int) -> some View {
        let id = editor.tracks[i].id
        let start = editor.tracks[i].start
        let header = editor.exportNumber(ofTrackAt: i).map { String(localized: "Track \($0)") }
            ?? String(localized: "Track (Not Exported)")
        return Section(header) {
            TextField("Title", text: editor.textBinding(.track(id, \.title)), prompt: Text(verbatim: editor.defaultTitle(at: i)))
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
    /// The track is looked up by ID every time: SwiftUI can still read the bindings of this section after
    /// the track is gone (e.g. while another file opens), and an index kept from then would be out of range.
    let trackID: Track.ID

    private var index: Int? { editor.index(of: trackID) }
    private var fade: Fade { index.map { editor.fade(edge, ofTrackAt: $0) } ?? Fade() }
    private var trackLength: Double { index.map { editor.end(ofTrackAt: $0) - editor.tracks[$0].start } ?? 0 }

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
                    guard let index else { return }
                    editor.performUndoable(edge.actionName) { editor.setFadeDuration(edge, value, ofTrackAt: index) }
                }), format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                Text("s").foregroundStyle(.secondary)
            }
            Picker("Curve", selection: Binding(get: { fade.curve },
                                              set: { if let index { editor.setFadeCurve(edge, $0, ofTrackAt: index) } })) {
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
        guard let index else { return false }
        let envelope = editor.envelope(ofTrackAt: index)
        return (edge == .start ? envelope.fadeIn : envelope.fadeOut).duration + 0.0005 < fade.duration
    }

    /// Slider binding: changes are not registered for undo one by one but as one step when the drag ends
    private var duration: Binding<Double> {
        Binding(get: { fade.duration }, set: { if let index { editor.setFadeDuration(edge, $0, ofTrackAt: index) } })
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

/// Format of the source file
private struct SourceFileSection: View {
    let url: URL
    let info: SourceAudioInfo

    var body: some View {
        Section("Source File") {
            LabeledContent("Format", value: format)
            LabeledContent("Sample Rate", value: AudioFormatText.sampleRate(info.sampleRate))
            if info.isLossless {
                LabeledContent("Bit Depth", value: AudioFormatText.bitDepth(info.bitDepth, isFloat: info.isFloat))
            }
            LabeledContent("Channels", value: channels)
            if let bitRate = info.bitRate {
                LabeledContent("Bit Rate", value: AudioFormatText.bitRate(bitRate))
            }
            LabeledContent("Duration", value: TimeFormat.string(info.duration))
            if let size = info.fileSize {
                LabeledContent("File Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
        }
        .monospacedDigit()
    }

    private var format: String { AudioFormatText.format(url: url, info: info) }
    private var channels: String { AudioFormatText.channels(info.channelCount) }
}

/// The joined files, one row each, and the format they are played and exported in
private struct SourceFilesSection: View {
    let source: AudioSource

    var body: some View {
        Section {
            ForEach(Array(source.files.enumerated()), id: \.offset) { _, file in
                (Text(file.url.lastPathComponent + "\n")
                    + Text(summary(file)).font(.caption).foregroundColor(.secondary))
                    .help(file.url.path)
            }
            // A row rather than a footer: with a footer, a grouped form leaves the last ForEach row out of
            // the section's background
            if source.files.contains(where: { $0.info.sampleRate != source.sampleRate || $0.info.channelCount != source.channelCount }) {
                Text(String(localized: "Joined as \(joinedFormat)") + "\n")
                    + Text("Files with a different sample rate or channel count are converted to match.")
                        .font(.caption).foregroundColor(.secondary)
            } else {
                Text("Joined as \(joinedFormat)")
            }
        } header: {
            Text("Source Files")
        }
    }

    /// e.g. "48 kHz · Stereo · 12:34"
    private var joinedFormat: String {
        [AudioFormatText.sampleRate(source.sampleRate), AudioFormatText.channels(source.channelCount),
         TimeFormat.string(source.duration, fractionDigits: 0)].joined(separator: " · ")
    }

    /// e.g. "FLAC · 44.1 kHz · 16-bit · Stereo · 4:05"
    private func summary(_ file: AudioSource.File) -> String {
        let info = file.info
        var parts = [AudioFormatText.format(url: file.url, info: info), AudioFormatText.sampleRate(info.sampleRate)]
        if info.isLossless { parts.append(AudioFormatText.bitDepth(info.bitDepth, isFloat: info.isFloat)) }
        if !info.isLossless, let bitRate = info.bitRate { parts.append(AudioFormatText.bitRate(bitRate)) }
        parts.append(AudioFormatText.channels(info.channelCount))
        parts.append(TimeFormat.string(info.duration, fractionDigits: 0))
        return parts.joined(separator: " · ")
    }
}

/// Audio format values as they are shown to the user
enum AudioFormatText {
    /// The container and the codec, e.g. "M4A (AAC)", or just "FLAC" when they are the same
    static func format(url: URL, info: SourceAudioInfo) -> String {
        let container = url.pathExtension.uppercased()
        return container == info.codecName ? container : "\(container) (\(info.codecName))"
    }

    static func channels(_ count: Int) -> String {
        switch count {
        case 1: String(localized: "Mono")
        case 2: String(localized: "Stereo")
        default: String(localized: "\(count) channels")
        }
    }

    /// e.g. "44.1 kHz"
    static func sampleRate(_ rate: Double) -> String {
        (rate / 1000).formatted(.number.precision(.fractionLength(0...1))) + " kHz"
    }

    static func bitDepth(_ bits: Int, isFloat: Bool = false) -> String {
        isFloat ? String(localized: "\(bits)-bit float") : String(localized: "\(bits)-bit")
    }

    /// e.g. "256 kbps"
    static func bitRate(_ bitsPerSecond: Int) -> String {
        "\(Int((Double(bitsPerSecond) / 1000).rounded())) kbps"
    }
}
