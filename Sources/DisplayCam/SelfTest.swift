import AppKit

/// Development self-test, enabled with DISPLAYCAM_SELFTEST=<output dir>.
/// Exercises recording and saves snapshots of the app's own windows.
@MainActor
enum SelfTest {
    static func runIfRequested(_ model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["DISPLAYCAM_SELFTEST"] else { return }
        func at(_ t: Double, _ block: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated(block) }
        }
        at(0.6) { snapshot(dir, "00-guide") }
        at(3) { snapshot(dir, "01-start") }
        at(9) { snapshot(dir, "02-streaming"); model.saveReplay() }
        at(10) { model.startRecording() }
        at(13) { snapshot(dir, "03-recording") }
        at(16) { model.stopRecording() }
        at(17) { model.viewMode = .split }
        at(19) { snapshot(dir, "04-split"); model.viewMode = .live; model.page = .recordings }
        at(21) { snapshot(dir, "05-recordings"); model.page = .mirror
}
        at(23) { model.mirrorWindow.toggleFullscreen(); model.mirrorWindow.open() }
        at(25) { snapshot(dir, "06-mirror-window"); model.mirrorWindow.close(); model.mirrorWindow.toggleFullscreen() }
    }

    static func snapshot(_ dir: String, _ name: String) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(sym, to: Capture.self)
        for window in NSApp.windows where window.isVisible && window.frame.width > 300 {
            // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1
            guard let image = capture(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() else {
                NSLog("[selftest] capture failed for %@", window.title)
                continue
            }
            let rep = NSBitmapImageRep(cgImage: image)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(window.windowNumber).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            NSLog("[selftest] saved %@", url.path)
        }
    }
}
