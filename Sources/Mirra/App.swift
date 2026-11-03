import AppKit
import SwiftUI

@main
struct MirraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model: AppModel
    @ObservedObject private var updates = UpdateController.shared

    init() {
        SettingsMigration.run()  // before AppModel reads its settings
        _model = ObservedObject(wrappedValue: AppModel.shared)
    }

    var body: some Scene {
        Window("Mirra", id: "main") {
            RootView()
                .environmentObject(model)
        }
        .defaultSize(width: 1120, height: 740)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
            CommandMenu("镜子") {
                Button(model.mirrorWindowOpen ? "关闭镜子窗口" : "打开镜子窗口") { model.toggleMirrorWindow() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Toggle("镜像", isOn: $model.mirror)
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Picker("视图", selection: $model.viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                Button("实时") { model.viewMode = .live }.keyboardShortcut("1")
                Button("延迟回放") { model.viewMode = .delayed }.keyboardShortcut("2")
                Button("分屏") { model.viewMode = .split }.keyboardShortcut("3")
                Divider()
                Button(model.isRecording ? "停止录制" : "开始录制") { model.toggleRecording() }
                    .keyboardShortcut("r")
                    .disabled(!model.isStreaming)
                Button("保存刚才 \(model.replaySeconds) 秒") { model.saveReplay() }
                    .keyboardShortcut("s")
                    .disabled(!model.isStreaming)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updates)
        }

        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "figure.dance")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppModel.shared.start()
        SelfTest.runIfRequested(AppModel.shared)

        // Quit cleanly on `kill` too, so the phone-side server is stopped.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigterm = source
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false  // keep running from the menu bar
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.deviceName.isEmpty ? model.status.text : "\(model.deviceName) · \(model.status.text)")
        Divider()
        Button(model.mirrorWindowOpen ? "关闭镜子窗口" : "打开镜子窗口") { model.toggleMirrorWindow() }
        Toggle("镜像（左右翻转）", isOn: $model.mirror)
        Picker("视图", selection: $model.viewMode) {
            ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Button(model.isRecording ? "停止录制（\(formatDuration(model.recordingElapsed))）" : "开始录制") {
            model.toggleRecording()
        }
        .disabled(!model.isStreaming)
        Button("保存刚才 \(model.replaySeconds) 秒") { model.saveReplay() }
            .disabled(!model.isStreaming)
        Divider()
        Button("打开 Mirra…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("设置…") }
        Button("检查更新…") { UpdateController.shared.checkForUpdates() }
            .disabled(!UpdateController.shared.canCheckForUpdates)
        Button("退出 Mirra") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Carries settings over from the app's previous name (DisplayCam).
enum SettingsMigration {
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromDisplayCam"),
              let old = UserDefaults(suiteName: "com.hanqing.DisplayCam") else { return }
        let keys = ["camera", "size", "cameraFPS", "bitrate", "zoom", "recordAudio", "mirror", "rotation", "fill",
                    "viewMode", "delay", "replaySeconds", "recordMirrored", "openMirrorOnLaunch", "displayID",
                    "recordingsFolder"]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "migratedFromDisplayCam")
    }
}
