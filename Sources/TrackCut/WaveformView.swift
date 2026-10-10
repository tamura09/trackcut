import AppKit
import TrackCutCore
import SwiftUI

struct WaveformView: NSViewRepresentable {
    let mode: WaveformNSView.Mode
    @ObservedObject var editor: EditorModel
    @ObservedObject var player: PlayerModel

    func makeNSView(context: Context) -> WaveformNSView {
        let view = WaveformNSView()
        view.mode = mode
        return view
    }

    func updateNSView(_ view: WaveformNSView, context: Context) {
        view.editor = editor
        view.player = player
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

/// Waveform display. detail = zoomed view for editing, overview = whole file for moving the visible range.
final class WaveformNSView: NSView {
    enum Mode { case detail, overview }

    var mode: Mode = .detail
    weak var editor: EditorModel?
    weak var player: PlayerModel?

    private var draggingTrackID: Track.ID?
    private var isScrubbing = false
    private let rulerHeight: CGFloat = 18
    private let markerHitWidth: CGFloat = 5

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { mode == .detail }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Coordinates

    private var visibleRange: (start: Double, length: Double) {
        guard let editor else { return (0, 1) }
        switch mode {
        case .detail: return (editor.visibleStart, max(editor.visibleDuration, 0.001))
        case .overview: return (0, max(editor.duration, 0.001))
        }
    }

    private func x(for time: Double) -> CGFloat {
        let r = visibleRange
        return CGFloat((time - r.start) / r.length) * bounds.width
    }

    private func time(for x: CGFloat) -> Double {
        let r = visibleRange
        return r.start + Double(x / max(bounds.width, 1)) * r.length
    }

    private var waveRect: NSRect {
        mode == .detail
            ? NSRect(x: 0, y: rulerHeight, width: bounds.width, height: bounds.height - rulerHeight)
            : bounds
    }

    private func markerTrackID(near px: CGFloat) -> Track.ID? {
        guard let editor else { return nil }
        let candidates = editor.tracks.dropFirst()
            .map { (id: $0.id, distance: abs(x(for: $0.start) - px)) }
            .filter { $0.distance <= markerHitWidth }
        return candidates.min { $0.distance < $1.distance }?.id
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        (mode == .detail ? NSColor.textBackgroundColor : NSColor.controlBackgroundColor).setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let editor, let peaks = editor.peaks else { return }

        drawTrackRegions(editor)
        drawWaveform(ctx, peaks: peaks)
        drawDisabledOverlay(editor)
        drawMarkers(editor)
        if mode == .detail {
            drawRuler()
        } else {
            drawVisibleWindow(editor)
        }
        drawPlayhead()

        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    private func trackRect(_ editor: EditorModel, _ i: Int) -> NSRect {
        let x0 = x(for: editor.tracks[i].start)
        let x1 = x(for: editor.end(ofTrackAt: i))
        return NSRect(x: x0, y: waveRect.minY, width: x1 - x0, height: waveRect.height)
    }

    private func drawTrackRegions(_ editor: EditorModel) {
        for i in editor.tracks.indices {
            let rect = trackRect(editor, i)
            guard rect.maxX >= 0, rect.minX <= bounds.width else { continue }
            if editor.tracks[i].id == editor.selectedTrackID {
                NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                rect.fill()
            } else if i % 2 == 1 {
                NSColor.labelColor.withAlphaComponent(0.04).setFill()
                rect.fill()
            }
        }
    }

    private func drawWaveform(_ ctx: CGContext, peaks: WaveformPeaks) {
        let rect = waveRect
        let mid = rect.midY
        let half = rect.height / 2 * 0.95
        let width = Int(bounds.width.rounded(.up))
        guard width > 0, peaks.count > 0 else { return }
        let r = visibleRange
        let secondsPerPixel = r.length / Double(bounds.width)
        let binDuration = peaks.binDuration

        peaks.mins.withUnsafeBufferPointer { mins in
            peaks.maxs.withUnsafeBufferPointer { maxs in
                for px in 0..<width {
                    let t0 = r.start + Double(px) * secondsPerPixel
                    let t1 = t0 + secondsPerPixel
                    let b0 = max(0, Int(t0 / binDuration))
                    let b1 = min(peaks.count, max(Int(t1 / binDuration), b0 + 1))
                    guard b0 < b1 else { continue }
                    var lo: Float = 0, hi: Float = 0
                    for b in b0..<b1 {
                        if mins[b] < lo { lo = mins[b] }
                        if maxs[b] > hi { hi = maxs[b] }
                    }
                    let top = mid - CGFloat(hi) * half
                    let bottom = mid - CGFloat(lo) * half
                    ctx.addRect(CGRect(x: CGFloat(px), y: top, width: 1, height: max(1, bottom - top)))
                }
            }
        }
        NSColor.systemBlue.setFill()
        ctx.fillPath()
    }

    private func drawDisabledOverlay(_ editor: EditorModel) {
        NSColor.textBackgroundColor.withAlphaComponent(0.6).setFill()
        for i in editor.tracks.indices where !editor.tracks[i].isEnabled {
            trackRect(editor, i).fill()
        }
    }

    private func drawMarkers(_ editor: EditorModel) {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        for (i, track) in editor.tracks.enumerated() {
            let px = x(for: track.start).rounded() + 0.5
            guard px >= -300, px <= bounds.width + 1 else { continue }
            let selected = track.id == editor.selectedTrackID
            let color = selected ? NSColor.controlAccentColor : NSColor.systemOrange

            if i > 0 {
                color.setFill()
                NSRect(x: px - 0.5, y: waveRect.minY, width: mode == .detail ? 1.5 : 1, height: waveRect.height).fill()
            }
            guard mode == .detail else { continue }

            let label = "\(i + 1)  \(editor.displayTitle(at: i))"
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let size = (label as NSString).size(withAttributes: attrs)
            let maxWidth = max(0, x(for: editor.end(ofTrackAt: i)) - px - 4)
            let box = NSRect(x: max(px, 0), y: waveRect.minY + 2, width: min(size.width + 8, maxWidth), height: size.height + 2)
            guard box.width > 12 else { continue }
            color.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: box).addClip()
            (label as NSString).draw(at: NSPoint(x: box.minX + 4, y: box.minY + 1), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawRuler() {
        let rulerRect = NSRect(x: 0, y: 0, width: bounds.width, height: rulerHeight)
        NSColor.windowBackgroundColor.setFill()
        rulerRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: rulerHeight - 1, width: bounds.width, height: 1).fill()

        let r = visibleRange
        let pixelsPerSecond = Double(bounds.width) / r.length
        let steps: [Double] = [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let step = steps.first { $0 * pixelsPerSecond >= 80 } ?? 3600
        let digits = step < 0.1 ? 2 : (step < 1 ? 1 : 0)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let first = Int((r.start / step).rounded(.down))
        let last = Int(((r.start + r.length) / step).rounded(.up))
        guard first <= last else { return }
        for k in first...last {
            let t = Double(k) * step
            let px = x(for: t).rounded() + 0.5
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: px - 0.5, y: rulerHeight - 6, width: 1, height: 5).fill()
            (TimeFormat.string(t, fractionDigits: digits) as NSString)
                .draw(at: NSPoint(x: px + 3, y: 2), withAttributes: attrs)
        }
    }

    private func drawVisibleWindow(_ editor: EditorModel) {
        let x0 = x(for: editor.visibleStart)
        let x1 = x(for: editor.visibleStart + editor.visibleDuration)
        let rect = NSRect(x: x0, y: 0.5, width: max(x1 - x0, 2), height: bounds.height - 1.5)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        rect.fill()
        NSColor.controlAccentColor.setStroke()
        NSBezierPath(rect: rect).stroke()
    }

    private func drawPlayhead() {
        guard let player else { return }
        let px = x(for: player.currentTime).rounded() + 0.5
        guard px >= 0, px <= bounds.width else { return }
        NSColor.systemRed.setFill()
        NSRect(x: px - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }

    // MARK: - Mouse

    override func resetCursorRects() {
        guard mode == .detail, let editor else { return }
        for track in editor.tracks.dropFirst() {
            let px = x(for: track.start)
            addCursorRect(NSRect(x: px - markerHitWidth, y: 0, width: markerHitWidth * 2, height: bounds.height),
                          cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let editor, editor.peaks != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let t = time(for: p.x)

        if mode == .overview {
            editor.centerVisible(on: t)
            return
        }
        window?.makeFirstResponder(self)

        if event.clickCount == 2 {
            editor.addSplit(at: t)
            return
        }
        if let id = markerTrackID(near: p.x) {
            draggingTrackID = id
            editor.selectedTrackID = id
            return
        }
        isScrubbing = true
        player?.seek(to: t)
        editor.selectTrack(containing: t)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let editor, editor.peaks != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let t = time(for: p.x)

        if mode == .overview {
            editor.centerVisible(on: t)
        } else if let id = draggingTrackID {
            editor.moveSplit(id, to: t)
        } else if isScrubbing {
            player?.seek(to: t)
            editor.selectTrack(containing: t)
        }
    }

    override func mouseUp(with event: NSEvent) {
        draggingTrackID = nil
        isScrubbing = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard mode == .detail, let editor, editor.peaks != nil else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let t = time(for: p.x)
        let menu = NSMenu()
        if let id = markerTrackID(near: p.x) {
            menu.addItem(ClosureMenuItem(title: "この分割点を削除") { editor.removeSplit(id) })
        } else {
            menu.addItem(ClosureMenuItem(title: "ここで分割") { editor.addSplit(at: t) })
        }
        return menu
    }

    override func scrollWheel(with event: NSEvent) {
        guard mode == .detail, let editor, editor.peaks != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10

        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            editor.zoom(by: exp(-Double(event.scrollingDeltaY * scale) * 0.01), around: time(for: p.x))
        } else {
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            editor.pan(by: -Double(delta * scale) * visibleRange.length / Double(max(bounds.width, 1)))
        }
    }

    override func magnify(with event: NSEvent) {
        guard mode == .detail, let editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        editor.zoom(by: 1 / (1 + Double(event.magnification)), around: time(for: p.x))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let editor, let player else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 49: // space
            player.toggle()
        case 51, 117: // delete, forward delete
            editor.removeSelectedSplit()
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "m" {
                editor.addSplit(at: player.currentTime)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
