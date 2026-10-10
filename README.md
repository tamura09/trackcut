# trackcut

A macOS app for splitting a long recording (a live set, a ripped album, a radio show) into one file per track while looking at the waveform. It reads FLAC, M4A and WAV, and writes each track as its own file with tags.

The user interface is in Japanese.

## Features

- Open FLAC / M4A (AAC, ALAC) / WAV files from the Open dialog (⌘O), by dropping them on the window, or with "Open With" in Finder
- Two waveform views: an overview of the whole file and a zoomable detail view with a time ruler
- Place split points by double-clicking the waveform, pressing `M` at the playhead, or from the context menu; drag them to adjust
- Detect split points automatically from silent gaps, with an adjustable threshold (dB) and minimum gap length
- Fade each track in at its start and out at its end, with a choice of curve (linear, equal power, S-curve, exponential). The waveform shows the result as it will be exported
- Name each track, choose which tracks to export, and set an artist per track
- Undo and redo every edit (⌘Z / ⇧⌘Z)
- Export every track to its own file named `01 Title.ext`
- On macOS 26 and later the window uses Liquid Glass: glass toolbar groups, floating playback controls over the waveform and a glass inspector

### Export formats

- **Same as source** (default)
  - WAV, FLAC and ALAC keep the source bit depth
  - AAC is cut without re-encoding, except for tracks with a fade, which are re-encoded at 256 kbps
- **WAV**
- **FLAC**
- **Apple Lossless (m4a)**
- **AAC 256 kbps (m4a)**: the source must be 48 kHz or lower. When the source is already AAC, it is cut without re-encoding (again, except for tracks with a fade)

### Tags

Exported files get the title, track number and total, artist, album, album artist, year and genre. Album-wide fields are prefilled from the source file's tags when it has any.

- **FLAC**: Vorbis comment
- **M4A**: iTunes metadata
- **WAV**: LIST/INFO chunk. INFO has no field for the album artist or the track total, so those two are not written

## Install

On an Apple silicon Mac with macOS 15 or later, install it with [Homebrew](https://brew.sh):

```sh
brew install --cask tamura09/tap/trackcut
```

or download `TrackCut-<version>-arm64.zip` from [Releases](https://github.com/tamura09/trackcut/releases).

The app is ad-hoc signed and not notarized, so macOS blocks it the first time. After the first attempt to open it, go to System Settings > Privacy & Security and choose "Open Anyway".

On an Intel Mac, build it from source as described below.

## Requirements

- Running: macOS 15 or later
- Building: Xcode 26 or later, or the Command Line Tools for it. The app uses the Liquid Glass APIs from the macOS 26 SDK; on older systems it checks at run time and falls back, but older SDKs cannot compile it

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

A binary built this way shows the pre-Liquid Glass design: SwiftPM records the deployment target (macOS 15) as the SDK version, and AppKit picks the design from it. `build-app.sh` passes the SDK to the link step so the bundle gets the current design.

## Usage

### Mouse and trackpad

- Click: move the playhead and select the track under it
- Drag: scrub
- Double-click: add a split point
- Drag a split point: move it
- Drag the round handles at the top of the selected track: set the length of its fade-in and fade-out. Where the two fades meet, the handles overlap: drag left to shorten the fade-in, right to shorten the fade-out
- Right-click: add or delete a split point, fade in up to / out from the clicked point, remove a fade, or include / exclude the track from the export
- Scroll: pan
- ⌘ or ⌥ + scroll, or pinch: zoom
- Click or drag in the overview: move the visible range

### Inspector

The inspector on the right (⌥⌘I) edits the selected track: title, artist, whether to export it, and the length and curve of its fades. "Apply these fades to all tracks" copies its fades to every track; on a track too short for both, they are shortened in proportion. The album-wide tags are at the bottom.

### Keyboard

Single-key shortcuts work anywhere in the window except while typing in a text field. Help > Keyboard Shortcuts (⌘/) lists them all.

- `Space`: play / pause
- `←` / `→`: move the playhead 1 second (with `⇧`: 10 seconds)
- `↑` / `↓`: previous / next track
- `Home` / `End`: start / end of the file
- `M`: split at the playhead
- `Delete`: remove the split point at the start of the selected track
- `,` / `.`: move that split point 10 ms earlier / later (with `⇧`: 100 ms)
- `E`: include / exclude the selected track from the export
- `I`: fade in from the start of the track to the playhead
- `O`: fade out from the playhead to the end of the track
- `⇧I` / `⇧O`: remove the fade-in / fade-out
- `=` / `-`: zoom in / out
- `Z`: zoom to the selected track; `⇧Z`: show the whole file

Menu shortcuts: ⌘O open, ⌘E export, ⇧⌘D split at silences, ⌘Z / ⇧⌘Z undo / redo, ⌘= / ⌘- / ⌘0 zoom in / out / fit, ⌥⌘I inspector.

## Development

The project is a Swift package with two targets.

- `TrackCutCore`: waveform analysis, silence detection, fades, export and tag reading/writing. No UI code
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
