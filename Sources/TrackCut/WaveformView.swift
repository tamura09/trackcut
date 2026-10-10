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

    /// A fade handle of the selected track
    struct FadeHandle {
        let trackID: Track.ID
        let edge: FadeEdge
    }

    var mode: Mode = .detail
    weak var editor: EditorModel? {
        // Set on every SwiftUI update, so only react to an actual change
        didSet { if editor !== oldValue { attachToWindow() } }
    }
    weak var player: PlayerModel?

    private var draggingTrackID: Track.ID?
    private var draggingFade: FadeHandle?
    /// Set when the press is on both fade handles at once; the drag direction picks one
    private var pendingFadeTrackID: Track.ID?
    private var pressX: CGFloat = 0
    private var isScrubbing = false
    private let keyMonitor = KeyCommandMonitor()
    private let rulerHeight: CGFloat = 20
    private let markerHitWidth: CGFloat = 5
    private let handleRadius: CGFloat = 5.5
    /// Height of the track labels, which fade curves and handles stay below
    private let labelHeight: CGFloat = 26

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { mode == .detail }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachToWindow()
    }

    /// The detail view hands its window to the editor (for undo) and listens for the single-key
    /// shortcuts while it is in a window.
    private func attachToWindow() {
        guard mode == .detail else { return }
        guard let window, let editor else {
            keyMonitor.uninstall()
            return
        }
        editor.window = window
        keyMonitor.install(window: window, editor: editor)
    }

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

    /// Top and bottom of the area the fade curves are drawn in
    private var fadeLane: (top: CGFloat, bottom: CGFloat) {
        (waveRect.minY + labelHeight, waveRect.maxY - 4)
    }

    /// Centres of the selected track's fade handles: at the end of the fade-in and the start of the fade-out
    func fadeHandleCenters(_ editor: EditorModel) -> [(handle: FadeHandle, center: NSPoint)] {
        guard mode == .detail, let i = editor.selectedIndex else { return [] }
        let envelope = editor.envelope(ofTrackAt: i)
        let start = editor.tracks[i].start, end = editor.end(ofTrackAt: i)
        // Too narrow to grab two handles
        guard x(for: end) - x(for: start) >= handleRadius * 4 else { return [] }
        let y = fadeLane.top
        let id = editor.tracks[i].id
        return [
            (FadeHandle(trackID: id, edge: .start), NSPoint(x: x(for: start + envelope.fadeIn.duration), y: y)),
            (FadeHandle(trackID: id, edge: .end), NSPoint(x: x(for: end - envelope.fadeOut.duration), y: y)),
        ]
    }

    /// The fade handles under `point`, nearest first
    private func fadeHandles(at point: NSPoint) -> [(handle: FadeHandle, center: NSPoint)] {
        guard let editor else { return [] }
        return fadeHandleCenters(editor)
            .filter { hypot($0.center.x - point.x, $0.center.y - point.y) <= handleRadius + 3 }
            .sorted { abs($0.center.x - point.x) < abs($1.center.x - point.x) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        (mode == .detail ? NSColor.textBackgroundColor : NSColor.controlBackgroundColor).setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let editor, let peaks = editor.peaks else { return }

        drawTrackRegions(editor)
        drawWaveform(ctx, editor: editor, peaks: peaks)
        drawFades(editor)
        drawMarkers(editor)
        if mode == .detail {
            drawRuler()
            drawFadeHandles(editor)
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

    /// Draws the waveform as it will be exported: scaled by the fades, and greyed out for tracks that are
    /// not exported.
    private func drawWaveform(_ ctx: CGContext, editor: EditorModel, peaks: WaveformPeaks) {
        let rect = waveRect
        let mid = rect.midY
        let half = rect.height / 2 * 0.92
        let width = Int(bounds.width.rounded(.up))
        guard width > 0, peaks.count > 0, !editor.tracks.isEmpty else { return }
        let r = visibleRange
        let secondsPerPixel = r.length / Double(bounds.width)
        let binDuration = peaks.binDuration
        let tracks = editor.tracks
        let envelopes = tracks.indices.map(editor.envelope(ofTrackAt:))
        let enabledPath = CGMutablePath(), disabledPath = CGMutablePath()
        var trackIndex = 0

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
                    // Pixels go left to right, so the track only ever moves forward
                    let t = (t0 + t1) / 2
                    while trackIndex + 1 < tracks.count, tracks[trackIndex + 1].start <= t {
                        trackIndex += 1
                    }
                    let gain = CGFloat(envelopes[trackIndex].gain(at: t - tracks[trackIndex].start))
                    let top = mid - CGFloat(hi) * half * gain
                    let bottom = mid - CGFloat(lo) * half * gain
                    let bar = CGRect(x: CGFloat(px), y: top, width: 1, height: max(1, bottom - top))
                    (tracks[trackIndex].isEnabled ? enabledPath : disabledPath).addRect(bar)
                }
            }
        }
        ctx.addPath(enabledPath)
        NSColor.controlAccentColor.setFill()
        ctx.fillPath()
        ctx.addPath(disabledPath)
        NSColor.tertiaryLabelColor.setFill()
        ctx.fillPath()
    }

    /// Fade curves, with the part of the track a fade takes away shaded
    private func drawFades(_ editor: EditorModel) {
        let lane = mode == .detail ? fadeLane : (waveRect.minY + 2, waveRect.maxY - 2)
        for i in editor.tracks.indices {
            let envelope = editor.envelope(ofTrackAt: i)
            guard !envelope.isFlat else { continue }
            let start = editor.tracks[i].start
            let end = editor.end(ofTrackAt: i)
            if envelope.fadeIn.isEnabled {
                drawFade(envelope.fadeIn, from: start, to: start + envelope.fadeIn.duration, rising: true, lane: lane)
            }
            if envelope.fadeOut.isEnabled {
                drawFade(envelope.fadeOut, from: end - envelope.fadeOut.duration, to: end, rising: false, lane: lane)
            }
        }
    }

    private func drawFade(_ fade: Fade, from t0: Double, to t1: Double, rising: Bool,
                          lane: (top: CGFloat, bottom: CGFloat)) {
        let x0 = x(for: t0), x1 = x(for: t1)
        guard x1 >= 0, x0 <= bounds.width, x1 - x0 >= 1 else { return }
        let steps = max(2, min(Int((x1 - x0) / 3), 200))
        let curve = NSBezierPath()
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let gain = fade.curve.gain(rising ? progress : 1 - progress)
            let point = NSPoint(x: x0 + (x1 - x0) * progress, y: lane.bottom - (lane.bottom - lane.top) * gain)
            step == 0 ? curve.move(to: point) : curve.line(to: point)
        }
        let shade = curve.copy() as! NSBezierPath
        shade.line(to: NSPoint(x: x1, y: lane.top))
        shade.line(to: NSPoint(x: x0, y: lane.top))
        shade.close()
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        shade.fill()
        curve.lineWidth = mode == .detail ? 1.5 : 1
        NSColor.labelColor.withAlphaComponent(0.55).setStroke()
        curve.stroke()
    }

    private func drawFadeHandles(_ editor: EditorModel) {
        for (_, center) in fadeHandleCenters(editor) {
            guard center.x >= -handleRadius, center.x <= bounds.width + handleRadius else { continue }
            let rect = NSRect(x: center.x - handleRadius, y: center.y - handleRadius,
                              width: handleRadius * 2, height: handleRadius * 2)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
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
            let maxWidth = max(0, x(for: editor.end(ofTrackAt: i)) - px - 6)
            let height = size.height + 4
            let box = NSRect(x: max(px, 0) + 3, y: waveRect.minY + 4, width: min(size.width + 14, maxWidth), height: height)
            guard box.width > 16 else { continue }
            let capsule = NSBezierPath(roundedRect: box, xRadius: height / 2, yRadius: height / 2)
            (editor.tracks[i].isEnabled ? color : NSColor.systemGray).withAlphaComponent(0.9).setFill()
            capsule.fill()
            NSGraphicsContext.saveGraphicsState()
            capsule.addClip()
            (label as NSString).draw(at: NSPoint(x: box.minX + 7, y: box.minY + 2), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawRuler() {
        let rulerRect = NSRect(x: 0, y: 0, width: bounds.width, height: rulerHeight)
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
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
                .draw(at: NSPoint(x: px + 3, y: 3), withAttributes: attrs)
        }
    }

    private func drawVisibleWindow(_ editor: EditorModel) {
        let x0 = x(for: editor.visibleStart)
        let x1 = x(for: editor.visibleStart + editor.visibleDuration)
        let rect = NSRect(x: x0, y: 1, width: max(x1 - x0, 4), height: bounds.height - 2)
        let window = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        window.fill()
        window.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        window.stroke()
    }

    private func drawPlayhead() {
        guard let player else { return }
        let px = x(for: player.currentTime).rounded() + 0.5
        guard px >= -6, px <= bounds.width + 6 else { return }
        NSColor.systemRed.setFill()
        NSRect(x: px - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
        guard mode == .detail else { return }
        // Head in the ruler
        let head = NSBezierPath()
        head.move(to: NSPoint(x: px - 6, y: 0))
        head.line(to: NSPoint(x: px + 6, y: 0))
        head.line(to: NSPoint(x: px + 6, y: rulerHeight - 9))
        head.line(to: NSPoint(x: px, y: rulerHeight - 3))
        head.line(to: NSPoint(x: px - 6, y: rulerHeight - 9))
        head.close()
        head.fill()
    }

    // MARK: - Mouse

    override func resetCursorRects() {
        guard mode == .detail, let editor else { return }
        for track in editor.tracks.dropFirst() {
            let px = x(for: track.start)
            addCursorRect(NSRect(x: px - markerHitWidth, y: 0, width: markerHitWidth * 2, height: bounds.height),
                          cursor: .resizeLeftRight)
        }
        for (_, center) in fadeHandleCenters(editor) {
            let r = handleRadius + 3
            addCursorRect(NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2), cursor: .openHand)
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
        let handles = fadeHandles(at: p)
        if let nearest = handles.first {
            // When the fades meet, both handles are in the same place. Dragging left can only shorten the
            // fade-in and dragging right only the fade-out, so the direction decides.
            if handles.count == 2, abs(handles[0].center.x - handles[1].center.x) < handleRadius {
                pendingFadeTrackID = nearest.handle.trackID
            } else {
                draggingFade = nearest.handle
            }
            pressX = p.x
            editor.beginContinuousEdit()
            NSCursor.closedHand.push()
            return
        }
        if let id = markerTrackID(near: p.x) {
            draggingTrackID = id
            editor.selectedTrackID = id
            editor.beginContinuousEdit()
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
        if let id = pendingFadeTrackID, p.x != pressX {
            draggingFade = FadeHandle(trackID: id, edge: p.x < pressX ? .start : .end)
            pendingFadeTrackID = nil
        }

        if mode == .overview {
            editor.centerVisible(on: t)
        } else if let handle = draggingFade, let i = editor.index(of: handle.trackID) {
            let duration = handle.edge == .start ? t - editor.tracks[i].start : editor.end(ofTrackAt: i) - t
            editor.setFadeDuration(handle.edge, duration, ofTrackAt: i)
        } else if let id = draggingTrackID {
            editor.moveSplit(id, to: t)
        } else if isScrubbing {
            player?.seek(to: t)
            editor.selectTrack(containing: t)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if draggingFade != nil || pendingFadeTrackID != nil {
            editor?.endContinuousEdit((draggingFade?.edge ?? .start).actionName)
            NSCursor.pop()
        } else if draggingTrackID != nil {
            editor?.endContinuousEdit("分割点を移動")
        }
        draggingFade = nil
        pendingFadeTrackID = nil
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
        guard let i = editor.trackIndex(containing: t) else { return menu }
        let track = editor.tracks[i]
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "ここまでフェードイン") { editor.setFade(.start, at: t) })
        menu.addItem(ClosureMenuItem(title: "ここからフェードアウト") { editor.setFade(.end, at: t) })
        if track.fadeIn.isEnabled {
            menu.addItem(ClosureMenuItem(title: "フェードインを解除") { editor.removeFade(.start, ofTrackAt: i) })
        }
        if track.fadeOut.isEnabled {
            menu.addItem(ClosureMenuItem(title: "フェードアウトを解除") { editor.removeFade(.end, ofTrackAt: i) })
        }
        menu.addItem(.separator())
        let export = ClosureMenuItem(title: "このトラックを書き出す") { editor.setEnabled(!track.isEnabled, for: track.id) }
        export.state = track.isEnabled ? .on : .off
        menu.addItem(export)
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
