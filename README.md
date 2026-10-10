# trackcut

A macOS app for splitting a long recording (a live set, a ripped album, a radio show) into one file per track while looking at the waveform. It reads FLAC, M4A and WAV, and writes each track as its own file with tags.

The user interface is in Japanese.

## Features

- Open FLAC / M4A (AAC, ALAC) / WAV files from the Open dialog (⌘O), by dropping them on the window, or with "Open With" in Finder
- Two waveform views: an overview of the whole file and a zoomable detail view with a time ruler
- Place split points by double-clicking the waveform, pressing `M` at the playhead, or from the context menu; drag them to adjust
- Detect split points automatically from silent gaps, with an adjustable threshold (dB) and minimum gap length
- Name each track, choose which tracks to export, and set an artist per track
- Export every track to its own file named `01 Title.ext`

### Export formats

- **Same as source** (default)
  - WAV, FLAC and ALAC keep the source bit depth
  - AAC is cut without re-encoding
- **WAV**
- **FLAC**
- **Apple Lossless (m4a)**
- **AAC 256 kbps (m4a)**: the source must be 48 kHz or lower. When the source is already AAC, it is cut without re-encoding

### Tags

Exported files get the title, track number and total, artist, album, album artist, year and genre. Album-wide fields are prefilled from the source file's tags when it has any.

- **FLAC**: Vorbis comment
- **M4A**: iTunes metadata
- **WAV**: LIST/INFO chunk. INFO has no field for the album artist or the track total, so those two are not written

## Requirements

- macOS 15 or later
- Swift 6 toolchain (Xcode or the Command Line Tools)

## Build and run

```sh
./build-app.sh
open build/TrackCut.app
```

`build-app.sh` builds a release binary with SwiftPM, wraps it in an app bundle with an `Info.plist` (so Finder can open audio files with it), and signs it ad hoc.

During development you can also run it straight from SwiftPM:

```sh
swift run TrackCut
```

## Usage

### Mouse and trackpad

- Click: move the playhead and select the track under it
- Drag: scrub
- Double-click: add a split point
- Drag a split point: move it
- Right-click: add or delete a split point
- Scroll: pan
- ⌘ or ⌥ + scroll, or pinch: zoom
- Click or drag in the overview: move the visible range

### Keyboard (when the waveform has focus)

- `Space`: play / pause
- `M`: split at the playhead
- `Delete`: remove the split point at the start of the selected track

## Development

The project is a Swift package with two targets.

- `TrackCutCore`: waveform analysis, silence detection, export and tag reading/writing. No UI code
- `TrackCut`: the SwiftUI / AppKit app

Run the tests with:

```sh
swift test
```

With only the Command Line Tools installed (no Xcode), the Swift Testing macro plugin is not found by default. Pass its path explicitly:

```sh
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

For the same reason, the app avoids the `@State` macro and keeps view state in `ObservableObject`s, so it builds with either toolchain.
