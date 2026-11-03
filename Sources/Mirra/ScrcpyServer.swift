import Foundation

/// The phone-side half: scrcpy-server (from the scrcpy project, Apache 2.0), run via app_process.
/// The client protocol is version-specific, so this must match the bundled server exactly.
enum ScrcpyServer {
    static let version = "5.0.1"
    static let remotePath = "/data/local/tmp/mirra-server.jar"

    /// Bundled copy inside the .app, or the repo copy when running with `swift run`.
    static var localPath: String? {
        if let url = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) {
            return url.path
        }
        let repoCopy = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/scrcpy-server").path
        return FileManager.default.fileExists(atPath: repoCopy) ? repoCopy : nil
    }

    static func shellArgs(serial: String, options: [String]) -> [String] {
        ["-s", serial, "shell", "CLASSPATH=\(remotePath)", "app_process", "/", "com.genymobile.scrcpy.Server", version] + options
    }

    static func push(adb: ADB, serial: String) throws {
        guard let local = localPath else { throw ADBError.commandFailed("缺少 scrcpy-server 文件") }
        try adb.run(["-s", serial, "push", local, remotePath])
    }

    static func listCameras(adb: ADB, serial: String) throws -> [CameraInfo] {
        try push(adb: adb, serial: serial)
        let output = try adb.run(shellArgs(serial: serial, options: ["list_cameras=true", "log_level=info"]))
        return CameraInfo.parse(output)
    }

    static func battery(adb: ADB, serial: String) -> BatteryInfo? {
        guard let output = try? adb.run(["-s", serial, "shell", "dumpsys", "battery"], timeout: 5) else { return nil }
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let level = values["level"].flatMap(Int.init) else { return nil }
        let temp = (values["temperature"].flatMap(Double.init) ?? 0) / 10
        let status = values["status"].flatMap(Int.init) ?? 0  // 2 = charging, 5 = full
        return BatteryInfo(level: level, temperature: temp, charging: status == 2 || status == 5)
    }
}

struct BatteryInfo: Equatable {
    let level: Int
    let temperature: Double
    let charging: Bool
}

struct CameraInfo: Identifiable, Hashable {
    let id: String
    let facing: String
    let width: Int
    let height: Int
    let fps: [Int]
    let maxZoom: Double

    var title: String {
        let name: String
        switch facing {
        case "back": name = "后置"
        case "front": name = "前置"
        default: name = "外接"
        }
        return "\(name) · 摄像头 \(id)（\(width)×\(height)）"
    }

    /// Parses lines like:
    /// `--camera-id=0    (back, 3712x2784, fps={10, 15, 20, 30}, zoom-range=[1, 10])`
    static func parse(_ output: String) -> [CameraInfo] {
        let pattern = #"--camera-id=(\S+)\s+\((\w+), (\d+)x(\d+), fps=\{([^}]*)\}(?:, zoom-range=\[([^\]]*)\])?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = output as NSString
        return regex.matches(in: output, range: NSRange(location: 0, length: ns.length)).map { m in
            func group(_ i: Int) -> String {
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            let fps = group(5).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let zoom = group(6).split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return CameraInfo(
                id: group(1), facing: group(2),
                width: Int(group(3)) ?? 0, height: Int(group(4)) ?? 0,
                fps: fps, maxZoom: zoom.last ?? 1
            )
        }
    }
}

/// Settings that require restarting the phone-side server when changed.
struct StreamConfig: Equatable {
    var camera: String  // "facing:back", "facing:front" or "id:<n>"
    var size: String  // e.g. "1920x1080"
    var fps: Int
    var bitrateMbps: Int
    var zoom: Double
    var audio: Bool  // stream the phone microphone (AAC) for recordings

    func serverOptions(scid: String) -> [String] {
        var options = [
            "scid=\(scid)",
            "log_level=info",
            "tunnel_forward=true",
            "control=false",
            "cleanup=false",
            "video_source=camera",
            "video_codec=h264",
            "video_bit_rate=\(bitrateMbps * 1_000_000)",
            // A keyframe every second lets delayed playback (re)start quickly.
            "video_codec_options=i-frame-interval=1",
            "camera_size=\(size)",
            "camera_fps=\(fps)",
        ]
        if camera.hasPrefix("id:") {
            options.append("camera_id=\(camera.dropFirst(3))")
        } else {
            options.append("camera_facing=\(camera.replacingOccurrences(of: "facing:", with: ""))")
        }
        if audio {
            // Plain "mic" records louder than "mic-camcorder" on the devices tested.
            options += ["audio=true", "audio_codec=aac", "audio_source=mic", "audio_bit_rate=128000"]
        } else {
            options.append("audio=false")
        }
        if zoom > 1.01 {
            options.append(String(format: "camera_zoom=%.2f", zoom))
        }
        return options
    }
}
