import Foundation

struct ADBDevice: Equatable {
    let serial: String
    let state: String  // "device" / "unauthorized" / "offline" ...
    let model: String?
}

enum ADBError: LocalizedError {
    case notFound
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "找不到 adb，请安装 Android platform-tools（brew install --cask android-platform-tools）"
        case .commandFailed(let msg):
            return msg
        }
    }
}

/// Thin wrapper around the adb command-line tool.
final class ADB: @unchecked Sendable {  // immutable after init
    let path: String

    init(path: String) {
        self.path = path
    }

    /// Apps launched from Finder get a minimal PATH, so check the usual install locations explicitly.
    static func locate() -> String? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = env[key] { candidates.append(sdk + "/platform-tools/adb") }
        }
        candidates += [
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        if let path = env["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/adb" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func makeProcess(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        return p
    }

    /// Runs an adb command synchronously and returns its combined output.
    @discardableResult
    func run(_ args: [String], timeout: TimeInterval = 20) throws -> String {
        let p = makeProcess(args)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let output = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            let msg = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ADBError.commandFailed(msg.isEmpty ? "adb \(args.joined(separator: " ")) 失败" : msg)
        }
        return output
    }

    /// Starts the adb daemon up front, with output discarded, so later calls don't pay for it.
    func startServer() {
        let p = makeProcess(["start-server"])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// Removes port forwards left behind if a previous run was killed. Our sessions forward
    /// `tcp:0` (a random port); scrcpy's own CLI uses 27183-27199, so those are left alone.
    func removeStaleForwards() {
        guard let list = try? run(["forward", "--list"], timeout: 5) else { return }
        for line in list.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[2].hasPrefix("localabstract:scrcpy_"),
                  let port = Int(parts[1].replacingOccurrences(of: "tcp:", with: "")),
                  !(27183...27199).contains(port)
            else { continue }
            _ = try? run(["-s", String(parts[0]), "forward", "--remove", String(parts[1])], timeout: 5)
        }
    }

    func devices() throws -> [ADBDevice] {
        let output = try run(["devices", "-l"])
        return output.split(separator: "\n").compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("List of devices"), !s.hasPrefix("*") else { return nil }
            let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) }
            return ADBDevice(serial: parts[0], state: parts[1], model: model)
        }
    }
}
