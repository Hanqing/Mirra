import AppKit
import SwiftUI

@main
struct DisplayCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("DisplayCam", id: "main") {
            RootView()
                .environmentObject(model)
        }
        .defaultSize(width: 1120, height: 740)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
        Button("打开 DisplayCam…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("设置…") }
        Button("退出 DisplayCam") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
