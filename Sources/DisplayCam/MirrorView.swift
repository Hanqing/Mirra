import AVFoundation
import AppKit
import Combine
import SwiftUI

/// A Liquid Glass capsule with a line of text, for overlays on top of video.
final class GlassLabel: NSGlassEffectView {
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    var showsDot = false { didSet { dot.isHidden = !showsDot; needsLayout = true } }

    init(tint: NSColor? = nil) {
        super.init(frame: .zero)
        tintColor = tint
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        let container = NSView()
        container.addSubview(dot)
        container.addSubview(label)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.white.cgColor
        dot.layer?.cornerRadius = 4
        dot.isHidden = true
        contentView = container
    }

    required init?(coder: NSCoder) { fatalError() }

    var text: String {
        get { label.stringValue }
        set {
            guard label.stringValue != newValue else { return }
            label.stringValue = newValue
            needsLayout = true
            superview?.needsLayout = true
        }
    }

    var fittingSize2: CGSize {
        let s = label.intrinsicContentSize
        return CGSize(width: s.width + 28 + (showsDot ? 14 : 0), height: s.height + 12)
    }

    override func layout() {
        super.layout()
        cornerRadius = bounds.height / 2
        let s = label.intrinsicContentSize
        let x: CGFloat = showsDot ? 28 : 14
        dot.frame = CGRect(x: 14, y: (bounds.height - 8) / 2, width: 8, height: 8)
        label.frame = CGRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
    }
}

/// Hosts one display layer with mirror / rotation / fill applied.
final class VideoPaneView: NSView {
    let displayLayer: AVSampleBufferDisplayLayer
    let badge = GlassLabel()
    /// In the main window preview the top-left corner holds the status pill.
    var badgeOnRight = false

    private var mirrored = true
    private var rotation = 0
    private var fill = false

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(displayLayer)
        badge.isHidden = true
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(mirrored: Bool, rotation: Int, fill: Bool) {
        guard mirrored != self.mirrored || rotation != self.rotation || fill != self.fill else { return }
        self.mirrored = mirrored
        self.rotation = rotation
        self.fill = fill
        needsLayout = true
    }

    func setBadge(_ text: String?) {
        badge.isHidden = text == nil
        if let text { badge.text = text }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let sideways = rotation % 180 != 0
        displayLayer.bounds = CGRect(
            x: 0, y: 0, width: sideways ? b.height : b.width, height: sideways ? b.width : b.height)
        displayLayer.position = CGPoint(x: b.midX, y: b.midY)
        // Rotate clockwise first, then flip horizontally on screen.
        var transform = CATransform3DMakeRotation(-CGFloat(rotation) * .pi / 180, 0, 0, 1)
        if mirrored {
            transform = CATransform3DConcat(transform, CATransform3DMakeScale(-1, 1, 1))
        }
        displayLayer.transform = transform
        displayLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        CATransaction.commit()

        let size = badge.fittingSize2
        let x = badgeOnRight ? b.width - size.width - 16 : 16
        badge.frame = CGRect(x: x, y: b.height - size.height - 16, width: size.width, height: size.height)
    }
}

/// Live and/or delayed panes, laid out for the current view mode.
/// Used full-screen in the mirror window and as the preview in the main window.
final class MirrorCompositionView: NSView {
    enum Style { case mirror, preview }

    private unowned let model: AppModel
    private let style: Style
    private let livePane: VideoPaneView
    private let delayedPane: VideoPaneView
    private let statusLabel = NSTextField(labelWithString: "")
    private let recBadge = GlassLabel(tint: NSColor.systemRed.withAlphaComponent(0.75))
    private var mode: ViewMode = .live
    private var observer: AnyCancellable?
    private var cursorTimer: Timer?

    init(model: AppModel, layers: MediaPipeline.LayerPair, style: Style) {
        self.model = model
        self.style = style
        livePane = VideoPaneView(displayLayer: layers.live)
        delayedPane = VideoPaneView(displayLayer: layers.delayed)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        if style == .preview {
            livePane.badgeOnRight = true
            delayedPane.badgeOnRight = true
            layer?.cornerRadius = 22
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
        }
        addSubview(livePane)
        addSubview(delayedPane)

        statusLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 3
        statusLabel.isHidden = style == .preview
        addSubview(statusLabel)

        recBadge.showsDot = true
        recBadge.isHidden = true
        addSubview(recBadge)

        observer = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        for pane in [livePane, delayedPane] {
            pane.configure(mirrored: model.mirror, rotation: model.rotation, fill: model.fill)
        }
        if mode != model.viewMode {
            mode = model.viewMode
            needsLayout = true
        }

        let streaming = model.status == .streaming
        livePane.setBadge(mode == .split && streaming ? "实时" : nil)
        var delayedText = String(format: "延迟 %.1f 秒", model.delay)
        if !model.delayedReady {
            delayedText += String(format: " · 缓冲中 %.0f/%.0f", min(model.bufferedSeconds, model.delay), model.delay)
        }
        delayedPane.setBadge(mode != .live && streaming ? delayedText : nil)

        // The preview shows recording state in SwiftUI; the mirror window shows it here.
        recBadge.isHidden = style == .preview || !model.isRecording
        if model.isRecording { recBadge.text = "REC  " + formatDuration(model.recordingElapsed) }

        if style == .mirror {
            let message = streaming ? "" : model.status.text
            if statusLabel.stringValue != message {
                statusLabel.stringValue = message
                needsLayout = true
            }
            statusLabel.isHidden = streaming
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        switch mode {
        case .live:
            livePane.frame = b
            livePane.isHidden = false
            delayedPane.isHidden = true
        case .delayed:
            delayedPane.frame = b
            delayedPane.isHidden = false
            livePane.isHidden = true
        case .split:
            let half = floor(b.width / 2)
            livePane.frame = CGRect(x: 0, y: 0, width: half - 1, height: b.height)
            delayedPane.frame = CGRect(x: half + 1, y: 0, width: b.width - half - 1, height: b.height)
            livePane.isHidden = false
            delayedPane.isHidden = false
        }
        statusLabel.sizeToFit()
        statusLabel.frame.origin = CGPoint(
            x: (b.width - statusLabel.frame.width) / 2, y: (b.height - statusLabel.frame.height) / 2)
        let rec = recBadge.fittingSize2
        recBadge.frame = CGRect(x: b.width - rec.width - 16, y: b.height - rec.height - 16,
                                width: rec.width, height: rec.height)
    }

    // MARK: Keyboard & mouse (mirror window)

    override var acceptsFirstResponder: Bool { style == .mirror }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Esc
            model.mirrorWindow.close(); return
        case 123:  // ←
            model.delay = max(1, model.delay - 0.5); return
        case 124:  // →
            model.delay = min(MediaPipeline.maxDelay, model.delay + 0.5); return
        case 49:  // Space
            model.toggleRecording(); return
        default:
            break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "m": model.mirror.toggle()
        case "f": model.mirrorWindow.toggleFullscreen()
        case "d": model.cycleViewMode()
        case "r": model.rotation = (model.rotation + 90) % 360
        case "s": model.saveReplay()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if style == .mirror && event.clickCount == 2 { model.mirrorWindow.toggleFullscreen() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard style == .mirror else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded(.down))
    return String(format: "%02d:%02d", s / 60, s % 60)
}

/// The main window's live preview.
struct MirrorPreview: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let view = model.previewView
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class MirrorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The mirror: borderless and covering a whole display, or a normal window (toggle with F).
@MainActor
final class MirrorWindowController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var window: MirrorWindow?
    private lazy var content = MirrorCompositionView(
        model: model, layers: model.pipeline.makeLayers(), style: .mirror)
    private var fullscreen = true

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func open() {
        let w = window ?? makeWindow()
        window = w
        place()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(content)
        model.mirrorWindowOpen = true
    }

    func close() {
        window?.orderOut(nil)
        model.mirrorWindowOpen = false
    }

    func toggleFullscreen() {
        fullscreen.toggle()
        place()
    }

    func place() {
        guard let w = window, let screen = model.targetScreen() else { return }
        if fullscreen {
            w.styleMask = [.borderless]
            w.level = .statusBar  // above the menu bar of that display
            w.hasShadow = false
            w.setFrame(screen.frame, display: true)
        } else {
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.level = .normal
            w.hasShadow = true
            let area = screen.visibleFrame
            let size = CGSize(width: min(1280, area.width * 0.8), height: min(800, area.height * 0.8))
            w.setFrame(
                CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                       width: size.width, height: size.height),
                display: true)
        }
        w.makeFirstResponder(content)
    }

    private func makeWindow() -> MirrorWindow {
        let w = MirrorWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.borderless], backing: .buffered, defer: false)
        w.title = "DisplayCam 镜子"
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.acceptsMouseMovedEvents = true
        w.contentView = content
        w.delegate = self
        return w
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { model.mirrorWindowOpen = false }
    }
}
