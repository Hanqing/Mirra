import AppKit
import Combine
import IOKit.pwr_mgt
import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case live, delayed, split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "实时"
        case .delayed: return "延迟"
        case .split: return "分屏"
        }
    }

    var symbol: String {
        switch self {
        case .live: return "person.fill"
        case .delayed: return "clock.arrow.circlepath"
        case .split: return "rectangle.split.2x1"
        }
    }
}

struct SizeOption: Hashable {
    let value: String
    let label: String

    static let all: [SizeOption] = [
        SizeOption(value: "1280x720", label: "1280 × 720（16:9）"),
        SizeOption(value: "1920x1080", label: "1920 × 1080（16:9）"),
        SizeOption(value: "1440x1080", label: "1440 × 1080（4:3）"),
        SizeOption(value: "1920x1440", label: "1920 × 1440（4:3）"),
        SizeOption(value: "2560x1440", label: "2560 × 1440（16:9）"),
    ]
}

struct ScreenInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let isPrimary: Bool
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let symbol: String
    var fileURL: URL?
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Status: Equatable {
        case noADB, noDevice, unauthorized, connecting, streaming
        case error(String)

        var text: String {
            switch self {
            case .noADB: return "找不到 adb"
            case .noDevice: return "等待手机连接"
            case .unauthorized: return "请在手机上允许 USB 调试"
            case .connecting: return "正在连接…"
            case .streaming: return "已连接"
            case .error(let msg): return msg
            }
        }

        var color: Color {
            switch self {
            case .streaming: return .green
            case .connecting, .unauthorized: return .orange
            case .noDevice: return .secondary
            case .noADB, .error: return .red
            }
        }
    }

    // MARK: Live state

    @Published private(set) var status: Status = .noDevice { didSet { updateSleepAssertion() } }
    @Published private(set) var deviceName = ""
    @Published private(set) var cameras: [CameraInfo] = []
    @Published private(set) var videoSize = CGSize.zero
    @Published private(set) var measuredFPS: Double = 0
    @Published private(set) var bufferedSeconds: Double = 0
    @Published private(set) var delayedReady = false
    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var screens: [ScreenInfo] = []
    @Published private(set) var audioAvailable: Bool?
    @Published private(set) var isRecording = false
    @Published private(set) var recordingElapsed: Double = 0
    @Published private(set) var isSavingReplay = false
    @Published var toast: Toast?
    @Published var page: SidebarItem = .mirror
    @Published var mirrorWindowOpen = false { didSet { updateSleepAssertion() } }

    // MARK: Settings (persisted)

    private static let defaults = UserDefaults.standard

    @Published var camera = defaults.string(forKey: "camera") ?? "facing:back" {
        didSet { Self.defaults.set(camera, forKey: "camera"); streamConfigChanged() }
    }
    @Published var size = defaults.string(forKey: "size") ?? "1920x1440" {
        didSet { Self.defaults.set(size, forKey: "size"); streamConfigChanged() }
    }
    @Published var cameraFPS = defaults.object(forKey: "cameraFPS") as? Int ?? 30 {
        didSet { Self.defaults.set(cameraFPS, forKey: "cameraFPS"); streamConfigChanged() }
    }
    @Published var bitrate = defaults.object(forKey: "bitrate") as? Int ?? 8 {
        didSet { Self.defaults.set(bitrate, forKey: "bitrate"); streamConfigChanged() }
    }
    @Published var zoom = defaults.object(forKey: "zoom") as? Double ?? 1 {
        didSet { Self.defaults.set(zoom, forKey: "zoom"); streamConfigChanged() }
    }
    @Published var recordAudio = defaults.object(forKey: "recordAudio") as? Bool ?? true {
        didSet { Self.defaults.set(recordAudio, forKey: "recordAudio"); streamConfigChanged() }
    }
    @Published var mirror = defaults.object(forKey: "mirror") as? Bool ?? true {
        didSet { Self.defaults.set(mirror, forKey: "mirror") }
    }
    @Published var rotation = defaults.object(forKey: "rotation") as? Int ?? 0 {
        didSet { Self.defaults.set(rotation, forKey: "rotation") }
    }
    @Published var fill = defaults.object(forKey: "fill") as? Bool ?? false {
        didSet { Self.defaults.set(fill, forKey: "fill") }
    }
    @Published var viewMode = ViewMode(rawValue: defaults.string(forKey: "viewMode") ?? "") ?? .live {
        didSet { Self.defaults.set(viewMode.rawValue, forKey: "viewMode"); applyPipelineSettings() }
    }
    @Published var delay = defaults.object(forKey: "delay") as? Double ?? 3 {
        didSet { Self.defaults.set(delay, forKey: "delay"); applyPipelineSettings() }
    }
    @Published var replaySeconds = defaults.object(forKey: "replaySeconds") as? Int ?? 15 {
        didSet { Self.defaults.set(replaySeconds, forKey: "replaySeconds"); applyPipelineSettings() }
    }
    @Published var recordMirrored = defaults.object(forKey: "recordMirrored") as? Bool ?? true {
        didSet { Self.defaults.set(recordMirrored, forKey: "recordMirrored") }
    }
    @Published var openMirrorOnLaunch = defaults.object(forKey: "openMirrorOnLaunch") as? Bool ?? true {
        didSet { Self.defaults.set(openMirrorOnLaunch, forKey: "openMirrorOnLaunch") }
    }
    /// 0 = automatic (prefer an external display).
    @Published var displayID = CGDirectDisplayID(defaults.object(forKey: "displayID") as? Int ?? 0) {
        didSet {
            Self.defaults.set(Int(displayID), forKey: "displayID")
            if mirrorWindowOpen { mirrorWindow.place() }
        }
    }

    // MARK: Internals

    let pipeline = MediaPipeline()
    let recordings = RecordingsStore()
    lazy var mirrorWindow = MirrorWindowController(model: self)
    lazy var previewView = MirrorCompositionView(model: self, layers: pipeline.makeLayers(), style: .preview)

    private var adb: ADB?
    private let work = DispatchQueue(label: "DisplayCam.adb")
    private var session: StreamSession?
    private var stoppingSession: StreamSession?
    private var pollTimer: Timer?
    private var batteryTimer: Timer?
    private var recordingTimer: Timer?
    private var recordingStart: Date?
    private var polling = false
    private var retryAt = Date.distantPast
    private var failures = 0
    private var camerasSerial: String?
    private var restartWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var sleepAssertion: IOPMAssertionID = 0

    var currentConfig: StreamConfig {
        StreamConfig(camera: camera, size: size, fps: cameraFPS, bitrateMbps: bitrate, zoom: zoom, audio: recordAudio)
    }

    var selectedCamera: CameraInfo? {
        if camera.hasPrefix("id:") {
            return cameras.first { "id:\($0.id)" == camera }
        }
        let facing = camera.replacingOccurrences(of: "facing:", with: "")
        return cameras.first { $0.facing == facing }
    }

    var fpsOptions: [Int] {
        let list = selectedCamera?.fps ?? [15, 30]
        return list.contains(cameraFPS) ? list : (list + [cameraFPS]).sorted()
    }

    var maxZoom: Double { max(selectedCamera?.maxZoom ?? 4, 1.1) }

    var isStreaming: Bool { status == .streaming }

    // MARK: Lifecycle

    func start() {
        refreshScreens()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        pipeline.onStats = { [weak self] stats in
            MainActor.assumeIsolated {
                guard let self else { return }
                if abs(self.measuredFPS - stats.fps) > 0.5 { self.measuredFPS = stats.fps }
                if abs(self.bufferedSeconds - stats.bufferedSeconds) > 0.2 || stats.bufferedSeconds < self.bufferedSeconds {
                    self.bufferedSeconds = stats.bufferedSeconds
                }
                if self.delayedReady != stats.delayedReady { self.delayedReady = stats.delayedReady }
                if ProcessInfo.processInfo.environment["DISPLAYCAM_DEBUG"] != nil {
                    NSLog("[stats] fps=%.1f buffered=%.1fs delayedReady=%d", stats.fps, stats.bufferedSeconds, stats.delayedReady ? 1 : 0)
                }
            }
        }
        applyPipelineSettings()
        recordings.reload()

        guard let path = ADB.locate() else {
            status = .noADB
            return
        }
        let adb = ADB(path: path)
        self.adb = adb
        work.async {
            adb.startServer()
            adb.removeStaleForwards()
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBattery() }
        }
        poll()

        if openMirrorOnLaunch, let screen = targetScreen(), screen != NSScreen.screens.first {
            mirrorWindow.open()
        }
    }

    func shutdown() {
        if isRecording { stopRecording() }
        session?.stop()
        session = nil
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
    }

    func retryNow() {
        retryAt = .distantPast
        failures = 0
        if session != nil {
            restartSession()
        } else {
            poll()
        }
    }

    func cycleViewMode() {
        let all = ViewMode.allCases
        viewMode = all[(all.firstIndex(of: viewMode)! + 1) % all.count]
    }

    // MARK: Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard isStreaming, !isRecording else { return }
        let url = recordings.newFileURL(kind: .practice)
        isRecording = true
        recordingStart = Date()
        recordingElapsed = 0
        pipeline.startRecording(to: url, transform: recordingTransform(), includeAudio: recordAudio) { [weak self] error in
            guard let self else { return }
            if let error {
                self.isRecording = false
                self.showToast(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
                return
            }
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let start = self.recordingStart else { return }
                    let elapsed = Date().timeIntervalSince(start).rounded(.down)
                    if elapsed != self.recordingElapsed { self.recordingElapsed = elapsed }
                }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        pipeline.stopRecording { [weak self] result in
            self?.finishedSaving(result, message: "录像已保存")
        }
    }

    /// Saves the last `replaySeconds` seconds, e.g. right after nailing a move.
    func saveReplay() {
        guard isStreaming, !isSavingReplay else { return }
        isSavingReplay = true
        let url = recordings.newFileURL(kind: .replay)
        pipeline.saveReplay(seconds: Double(replaySeconds), to: url, transform: recordingTransform(),
                            includeAudio: recordAudio) { [weak self] result in
            guard let self else { return }
            self.isSavingReplay = false
            self.finishedSaving(result, message: "已保存刚才 \(self.replaySeconds) 秒")
        }
    }

    private func finishedSaving(_ result: Result<URL, Error>, message: String) {
        switch result {
        case .success(let url):
            recordings.reload()
            showToast(message, symbol: "checkmark.circle.fill", fileURL: url)
        case .failure(let error):
            showToast(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }

    /// Track transform for recordings: the same rotation as the mirror, and optionally its flip.
    private func recordingTransform() -> CGAffineTransform {
        let w = videoSize.width, h = videoSize.height
        var t: CGAffineTransform
        switch rotation {
        case 90: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 180: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: t = .identity
        }
        if mirror && recordMirrored {
            let displayedWidth = rotation % 180 == 0 ? w : h
            t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: displayedWidth, ty: 0))
        }
        return t
    }

    func showToast(_ message: String, symbol: String, fileURL: URL? = nil) {
        toastWork?.cancel()
        withAnimation(.snappy) { toast = Toast(message: message, symbol: symbol, fileURL: fileURL) }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { withAnimation(.snappy) { self?.toast = nil } }
        }
        toastWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    // MARK: Device & session

    private func poll() {
        guard let adb, session == nil, stoppingSession == nil, !polling, Date() >= retryAt else { return }
        polling = true
        work.async {
            let result = Result { try adb.devices() }
            DispatchQueue.main.async {
                self.polling = false
                self.handleDevices(result)
            }
        }
    }

    private func handleDevices(_ result: Result<[ADBDevice], Error>) {
        guard session == nil else { return }
        switch result {
        case .failure(let error):
            status = .error(error.localizedDescription)
        case .success(let devices):
            if let device = devices.first(where: { $0.state == "device" }) {
                startSession(serial: device.serial)
            } else if devices.contains(where: { $0.state == "unauthorized" }) {
                status = .unauthorized
            } else {
                if status != .noDevice { status = .noDevice }
                deviceName = ""
                battery = nil
            }
        }
    }

    private func startSession(serial: String) {
        guard let adb else { return }
        status = .connecting
        audioAvailable = nil
        pipeline.reset(clearImage: false)

        if camerasSerial != serial {
            camerasSerial = serial
            work.async {
                let list = (try? ScrcpyServer.listCameras(adb: adb, serial: serial)) ?? []
                DispatchQueue.main.async { self.cameras = list }
            }
        }

        let session = StreamSession(adb: adb, serial: serial, config: currentConfig, pipeline: pipeline) {
            [weak self] session, event in
            DispatchQueue.main.async { self?.handle(event, from: session) }
        }
        self.session = session
        session.start()
        refreshBattery()
    }

    private func handle(_ event: StreamSession.Event, from source: StreamSession) {
        if case .ended = event, source === stoppingSession {
            stoppingSession = nil
            poll()
            return
        }
        guard source === session else { return }
        NSLog("[session] %@", String(describing: event))

        switch event {
        case .connected(let name):
            deviceName = name
            status = .streaming
            failures = 0
        case .videoSize(let w, let h):
            videoSize = CGSize(width: w, height: h)
        case .audioAvailable(let available):
            audioAvailable = available
        case .ended(let error):
            if isRecording { stopRecording() }
            session = nil
            videoSize = .zero
            measuredFPS = 0
            audioAvailable = nil
            pipeline.reset(clearImage: true)
            if let error {
                status = .error(error)
                failures += 1
                retryAt = Date().addingTimeInterval(min(Double(failures) * 2, 10))
            } else {
                status = .noDevice
            }
        }
    }

    private func streamConfigChanged() {
        restartWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let session = self.session, session.config != self.currentConfig else { return }
                self.restartSession()
            }
        }
        restartWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    /// Stops the current session and starts a new one once the old one has released the camera.
    private func restartSession() {
        guard let old = session else { return }
        if isRecording { stopRecording() }
        session = nil
        stoppingSession = old
        status = .connecting
        retryAt = .distantPast
        old.stop()
    }

    private func refreshBattery() {
        guard let adb, let serial = session?.serial else { return }
        work.async {
            let info = ScrcpyServer.battery(adb: adb, serial: serial)
            DispatchQueue.main.async { self.battery = info }
        }
    }

    private func applyPipelineSettings() {
        pipeline.configure(delayedEnabled: viewMode != .live, delay: delay, replaySeconds: Double(replaySeconds))
    }

    // MARK: Screens & mirror window

    func targetScreen() -> NSScreen? {
        let all = NSScreen.screens
        if displayID != 0, let chosen = all.first(where: { $0.displayID == displayID }) {
            return chosen
        }
        return all.count > 1 ? all.last : all.first
    }

    var targetScreenName: String {
        targetScreen()?.localizedName ?? "显示器"
    }

    func toggleMirrorWindow() {
        if mirrorWindowOpen {
            mirrorWindow.close()
        } else {
            mirrorWindow.open()
        }
    }

    private func refreshScreens() {
        let all = NSScreen.screens
        screens = all.enumerated().map { index, screen in
            ScreenInfo(id: screen.displayID, name: screen.localizedName, isPrimary: index == 0)
        }
    }

    private func screensChanged() {
        refreshScreens()
        if mirrorWindowOpen { mirrorWindow.place() }
    }

    /// Keeps the Mac display awake while the mirror is showing (no keyboard/mouse input while dancing).
    private func updateSleepAssertion() {
        let wanted = mirrorWindowOpen && status == .streaming
        if wanted && sleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "DisplayCam 镜子显示中" as CFString,
                &sleepAssertion)
        } else if !wanted && sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }
}
