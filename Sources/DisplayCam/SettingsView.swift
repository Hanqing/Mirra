import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("摄像头", systemImage: "camera") { CameraSettings() }
            Tab("镜子", systemImage: "rectangle.inset.filled.on.rectangle") { MirrorSettings() }
            Tab("录制", systemImage: "record.circle") { RecordingSettings() }
            Tab("关于", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 520)
        .tint(.brand)
    }
}

private struct CameraSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("摄像头", selection: $model.camera) {
                    Text("后置").tag("facing:back")
                    Text("前置").tag("facing:front")
                    if !model.cameras.isEmpty { Divider() }
                    ForEach(model.cameras) { Text($0.title).tag("id:\($0.id)") }
                }
                LabeledContent("变焦") {
                    HStack {
                        Slider(value: $model.zoom, in: 1...model.maxZoom, step: 0.1)
                        Text(String(format: "%.1f×", model.zoom))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } footer: {
                Text("后置摄像头画质更好。手机横放时，后置镜头对着你。")
            }
            Section {
                Picker("分辨率", selection: $model.size) {
                    ForEach(SizeOption.all, id: \.self) { Text($0.label).tag($0.value) }
                }
                Picker("帧率", selection: $model.cameraFPS) {
                    ForEach(model.fpsOptions, id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("码率", selection: $model.bitrate) {
                    ForEach([4, 8, 12, 16], id: \.self) { Text("\($0) Mbps").tag($0) }
                }
            } header: {
                Text("画质")
            } footer: {
                Text("4:3 分辨率在手机横放时能拍到更多的上下范围，适合小房间拍全身。修改后会自动重新连接。")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MirrorSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("显示在", selection: $model.displayID) {
                    Text("自动（优先外接显示器）").tag(CGDirectDisplayID(0))
                    ForEach(model.screens) { screen in
                        Text(screen.name + (screen.isPrimary ? "（主屏）" : "")).tag(screen.id)
                    }
                }
                Toggle("接着外接显示器时，启动后自动打开镜子", isOn: $model.openMirrorOnLaunch)
            }
            Section("画面") {
                Toggle("镜像（左右翻转）", isOn: $model.mirror)
                Picker("旋转", selection: $model.rotation) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("缩放", selection: $model.fill) {
                    Text("完整显示").tag(false)
                    Text("铺满裁切").tag(true)
                }
                .pickerStyle(.segmented)
            }
            Section {
                LabeledContent("延迟") {
                    HStack {
                        Slider(value: $model.delay, in: 1...MediaPipeline.maxDelay, step: 0.5)
                        Text(String(format: "%.1f 秒", model.delay))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            } header: {
                Text("延迟回放")
            } footer: {
                Text("镜子窗口快捷键：M 镜像 · D 切换视图 · ←/→ 调延迟 · R 旋转 · 空格 录制 · S 保存刚才 · F 全屏/窗口 · Esc 关闭")
            }
        }
        .formStyle(.grouped)
    }
}

private struct RecordingSettings: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store = AppModel.shared.recordings

    var body: some View {
        Form {
            Section {
                Toggle("录制声音（手机麦克风）", isOn: $model.recordAudio)
                if model.recordAudio && model.audioAvailable == false {
                    Label("这台手机暂时无法录音，录像将只有画面。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Toggle("录像和镜子里看到的一致（左右翻转）", isOn: $model.recordMirrored)
                Picker("「保存刚才」的长度", selection: $model.replaySeconds) {
                    ForEach([10, 15, 30, 60], id: \.self) { Text("\($0) 秒").tag($0) }
                }
            } footer: {
                Text("录像直接保存手机传来的视频，不重新编码，几乎不占电脑性能。")
            }
            Section("保存位置") {
                LabeledContent("文件夹") {
                    Text(store.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("在访达中打开") { store.openFolder() }
                    Button("更改…") { chooseFolder() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = store.folder
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { store.folder = url }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            AppIconImage(size: 112)
            Text("DisplayCam").font(.title.bold())
            Text("把旧手机变成你的舞蹈镜子")
                .foregroundStyle(.secondary)
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                Link("官网", destination: URL(string: "https://hanqing.github.io/DisplayCam/")!)
                Link("GitHub", destination: URL(string: "https://github.com/Hanqing/DisplayCam")!)
            }
            .buttonStyle(.glass)
            Text("手机端组件来自开源项目 scrcpy（Apache 2.0）。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}
