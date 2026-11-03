import SwiftUI

enum SidebarItem: Hashable {
    case mirror, recordings
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $model.page, recordings: model.recordings)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            switch model.page {
            case .mirror: MirrorPage()
            case .recordings: RecordingsPage(store: model.recordings)
            }
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(toast: toast).padding(.top, 14)
            }
        }
        .frame(minWidth: 880, minHeight: 580)
        .tint(.brand)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Binding var selection: SidebarItem
    @ObservedObject var recordings: RecordingsStore

    var body: some View {
        List(selection: $selection) {
            Label("镜子", systemImage: "figure.dance")
                .tag(SidebarItem.mirror)
            Label("录像", systemImage: "film.stack")
                .badge(recordings.items.count)
                .tag(SidebarItem.recordings)
        }
        .safeAreaInset(edge: .bottom) {
            DeviceCard().padding(12)
        }
    }
}

struct DeviceCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "smartphone")
                    .font(.title2)
                    .foregroundStyle(model.isStreaming ? AnyShapeStyle(.brandGradient) : AnyShapeStyle(.secondary))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.deviceName.isEmpty ? "Android 手机" : model.deviceName)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        StatusDot(color: model.status.color, pulsing: model.status == .connecting)
                        Text(model.status.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            if let battery = model.battery {
                HStack(spacing: 12) {
                    Label("\(battery.level)%", systemImage: batterySymbol(battery))
                        .foregroundStyle(battery.level <= 15 ? Color.orange : Color.secondary)
                    Label(String(format: "%.0f°C", battery.temperature), systemImage: "thermometer.medium")
                        .foregroundStyle(battery.temperature >= 42 ? Color.red : Color.secondary)
                }
                .font(.caption.monospacedDigit())
                .labelStyle(.titleAndIcon)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func batterySymbol(_ b: BatteryInfo) -> String {
        if b.charging { return "battery.100percent.bolt" }
        switch b.level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - Mirror page

struct MirrorPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            MirrorPreview(model: model)
                .opacity(model.isStreaming ? 1 : 0)
            if !model.isStreaming {
                ConnectGuide()
            }
        }
        .padding(16)
        .overlay(alignment: .topLeading) {
            if model.isStreaming {
                HStack(spacing: 8) {
                    GlassPill {
                        StatusDot(color: .green)
                        Text("\(Int(model.videoSize.width))×\(Int(model.videoSize.height)) · \(Int(model.measuredFPS.rounded())) fps")
                            .monospacedDigit()
                        if model.audioAvailable == true {
                            Image(systemName: "mic.fill").foregroundStyle(.secondary)
                        }
                    }
                    if model.isRecording {
                        GlassPill(tint: .red.opacity(0.75)) {
                            StatusDot(color: .white, pulsing: true)
                            Text("REC  " + formatDuration(model.recordingElapsed)).monospacedDigit()
                        }
                        .foregroundStyle(.white)
                    }
                }
                .padding(32)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if model.isStreaming {
                ControlBar().padding(.bottom, 34)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.isStreaming)
        .animation(.snappy, value: model.isRecording)
        .navigationTitle("镜子")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("显示在", selection: $model.displayID) {
                        Text("自动（优先外接显示器）").tag(CGDirectDisplayID(0))
                        ForEach(model.screens) { screen in
                            Text(screen.name + (screen.isPrimary ? "（主屏）" : "")).tag(screen.id)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("显示器", systemImage: "display")
                }
                .help("选择镜子显示在哪台显示器上")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button {
                    model.toggleMirrorWindow()
                } label: {
                    Label(model.mirrorWindowOpen ? "关闭镜子" : "打开镜子",
                          systemImage: model.mirrorWindowOpen ? "rectangle.slash" : "rectangle.inset.filled.on.rectangle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .help("在「\(model.targetScreenName)」上全屏显示镜子（⇧⌘M）")
            }
        }
    }
}

/// The floating Liquid Glass controls at the bottom of the preview.
struct ControlBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    iconButton(model.mirror ? "arrow.left.and.right.righttriangle.left.righttriangle.right.fill"
                                            : "arrow.left.and.right.righttriangle.left.righttriangle.right",
                               help: "镜像（M）", active: model.mirror) { model.mirror.toggle() }
                    iconButton("rotate.right", help: "旋转 90°（R）") { model.rotation = (model.rotation + 90) % 360 }
                    iconButton(model.fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: model.fill ? "完整显示" : "铺满裁切") { model.fill.toggle() }
                }
                .padding(6)
                .glassEffect(.regular, in: .capsule)

                HStack(spacing: 10) {
                    Picker("视图", selection: $model.viewMode) {
                        ForEach(ViewMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if model.viewMode != .live {
                        HStack(spacing: 2) {
                            iconButton("minus", help: "缩短延迟（←）") { model.delay = max(1, model.delay - 0.5) }
                            Text(String(format: "%.1f 秒", model.delay))
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .frame(width: 54)
                            iconButton("plus", help: "加长延迟（→）") {
                                model.delay = min(MediaPipeline.maxDelay, model.delay + 0.5)
                            }
                        }
                        .transition(.blurReplace)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .animation(.snappy, value: model.viewMode)

                HStack(spacing: 8) {
                    Button {
                        model.toggleRecording()
                    } label: {
                        Label(model.isRecording ? formatDuration(model.recordingElapsed) : "录制",
                              systemImage: model.isRecording ? "stop.fill" : "record.circle")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .frame(minWidth: 70)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(model.isRecording ? .red : .brand)
                    .help(model.isRecording ? "停止录制（空格）" : "开始录制（空格）")

                    Button {
                        model.saveReplay()
                    } label: {
                        Label("保存刚才 \(model.replaySeconds) 秒", systemImage: "gobackward")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .disabled(model.isSavingReplay)
                    .help("把最近 \(model.replaySeconds) 秒存成视频（S）")
                }
                .controlSize(.large)
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? AnyShapeStyle(Color.brand) : AnyShapeStyle(.primary))
                .frame(width: 34, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Shown instead of the preview until the phone is streaming.
struct ConnectGuide: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            AppIconImage(size: 96)
                .shadow(color: .brand.opacity(0.25), radius: 18, y: 10)
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            HStack(alignment: .top, spacing: 14) {
                step("01", "打开 USB 调试", "手机「设置 › 开发者选项」里打开", highlighted: model.status == .noDevice)
                step("02", "用数据线连接 Mac", "手机横放，后置摄像头对着你", highlighted: false)
                step("03", "在手机上点「允许」", "勾选「始终允许这台电脑」", highlighted: model.status == .unauthorized)
            }
            .frame(maxWidth: 760)
            footer
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.background.secondary)
        }
    }

    private var title: String {
        switch model.status {
        case .connecting: return "正在连接手机…"
        case .unauthorized: return "还差一步"
        case .error: return "连接出了点问题"
        case .noADB: return "需要安装 adb"
        default: return "把旧手机变成你的镜子"
        }
    }

    private var subtitle: String {
        switch model.status {
        case .connecting: return "正在启动摄像头，通常只要一两秒。"
        case .unauthorized: return "手机上弹出了「允许 USB 调试吗？」，点「允许」就能开始。"
        case .error(let message): return message
        case .noADB: return "DisplayCam 通过 adb 和手机通信。在终端运行下面的命令安装，然后重新打开 App。"
        default: return "用 USB 线连上一台 Android 手机，摄像头的画面会实时显示在你的显示器上。"
        }
    }

    @ViewBuilder private var footer: some View {
        switch model.status {
        case .connecting:
            ProgressView().controlSize(.small)
        case .error:
            Button("重新连接") { model.retryNow() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        case .noADB:
            HStack {
                Text("brew install --cask android-platform-tools")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button("拷贝", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install --cask android-platform-tools", forType: .string)
                }
                .buttonStyle(.glass)
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
        default:
            EmptyView()
        }
    }

    private func step(_ number: String, _ title: String, _ detail: String, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(number)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(highlighted ? AnyShapeStyle(.brandGradient) : AnyShapeStyle(.tertiary))
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(highlighted ? .regular.tint(.brand.opacity(0.18)) : .regular, in: .rect(cornerRadius: 16))
    }
}

// MARK: - Recordings page

struct RecordingsPage: View {
    @ObservedObject var store: RecordingsStore
    @StateObject private var pendingDelete = LocalState<Recording?>(nil)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 18)], spacing: 22) {
                ForEach(store.items) { item in
                    RecordingCard(item: item, store: store)
                        .contextMenu {
                            Button("播放", systemImage: "play") { store.open(item) }
                            Button("在访达中显示", systemImage: "folder") { store.reveal(item) }
                            Divider()
                            Button("移到废纸篓", systemImage: "trash", role: .destructive) { pendingDelete.value = item }
                        }
                }
            }
            .padding(24)
        }
        .overlay {
            if store.items.isEmpty {
                ContentUnavailableView {
                    Label("还没有录像", systemImage: "film")
                } description: {
                    Text("在「镜子」页点「录制」，或者跳完一段后点「保存刚才」，把最近的动作存下来。")
                }
            }
        }
        .navigationTitle("录像")
        .navigationSubtitle(store.items.isEmpty ? "" : "\(store.items.count) 个视频")
        .toolbar {
            ToolbarItem {
                Button("在访达中打开", systemImage: "folder") { store.openFolder() }
                    .help(store.folder.path)
            }
        }
        .onAppear { store.reload() }
        .confirmationDialog("把这个录像移到废纸篓？", isPresented: Binding(
            get: { pendingDelete.value != nil }, set: { if !$0 { pendingDelete.value = nil } }
        ), presenting: pendingDelete.value) { item in
            Button("移到废纸篓", role: .destructive) { store.moveToTrash(item) }
        } message: { item in
            Text(item.title)
        }
    }
}

struct RecordingCard: View {
    let item: Recording
    @ObservedObject var store: RecordingsStore
    @StateObject private var hover = LocalState(false)
    private var hovering: Bool { hover.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image = store.thumbnails[item.url] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.tertiary)
                }
                Image(systemName: "play.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .opacity(hovering ? 1 : 0)
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topLeading) {
                Text(item.kind == .replay ? "回放" : "练习")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(item.kind == .replay ? AnyShapeStyle(.brandGradient) : AnyShapeStyle(Color.black.opacity(0.45)),
                                in: .capsule)
                    .padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
                if let duration = store.durations[item.url] {
                    Text(formatDuration(duration))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: .capsule)
                        .padding(10)
                }
            }
            .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 16 : 8, y: hovering ? 8 : 4)
            .scaleEffect(hovering ? 1.015 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.date.formatted(.relative(presentation: .named)))
                    .font(.headline)
                Text("\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(.rect)
        .onHover { h in withAnimation(.snappy(duration: 0.2)) { hover.value = h } }
        .onTapGesture(count: 2) { store.open(item) }
    }
}
