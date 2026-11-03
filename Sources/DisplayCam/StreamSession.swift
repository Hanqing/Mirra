import Darwin
import Foundation

enum SessionError: LocalizedError {
    case closed
    case io(Int32)
    case timeout
    case server(String)

    var errorDescription: String? {
        switch self {
        case .closed: return "连接已断开"
        case .io(let code): return "读取失败：\(String(cString: strerror(code)))"
        case .timeout: return "连接手机超时"
        case .server(let msg): return msg
        }
    }
}

/// Blocking TCP socket to the adb-forwarded port.
final class SocketConnection {
    private var fd: Int32 = -1
    private let lock = NSLock()

    func connect(port: UInt16) throws {
        close()
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw SessionError.io(errno) }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            Darwin.close(s)
            throw SessionError.io(err)
        }
        lock.lock(); fd = s; lock.unlock()
    }

    func setReadTimeout(seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func read(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var received = 0
        try data.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            while received < count {
                let r = recv(fd, base + received, count - received, 0)
                if r > 0 {
                    received += r
                } else if r == 0 {
                    throw SessionError.closed
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw SessionError.timeout
                } else {
                    throw SessionError.io(errno)
                }
            }
        }
        return data
    }

    /// Unblocks a pending read from another thread.
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

/// One streaming session: pushes and starts scrcpy-server on the phone, then reads
/// the video stream on a dedicated thread and feeds the pipeline.
final class StreamSession {
    enum Event {
        case connected(deviceName: String)
        case videoSize(width: Int, height: Int)
        case audioAvailable(Bool)
        case ended(error: String?)
    }

    let config: StreamConfig
    let serial: String
    private let adb: ADB
    private let pipeline: MediaPipeline
    private let onEvent: (StreamSession, Event) -> Void
    private let connection = SocketConnection()
    private let audioConnection = SocketConnection()
    private let scid = String(format: "%08x", UInt32.random(in: 1..<0x7fff_ffff))
    private let lock = NSLock()
    private var stopped = false
    private var serverProcess: Process?
    private var serverLog: [String] = []

    init(adb: ADB, serial: String, config: StreamConfig, pipeline: MediaPipeline,
         onEvent: @escaping (StreamSession, Event) -> Void) {
        self.adb = adb
        self.serial = serial
        self.config = config
        self.pipeline = pipeline
        self.onEvent = onEvent
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "DisplayCam.stream"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        connection.shutdown()
        audioConnection.shutdown()
        serverProcess?.terminate()
    }

    private func emit(_ event: Event) {
        onEvent(self, event)
    }

    private func run() {
        var forwardedPort: String?
        var failure: String?
        do {
            try ScrcpyServer.push(adb: adb, serial: serial)
            let port = try adb.run(["-s", serial, "forward", "tcp:0", "localabstract:scrcpy_\(scid)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let portNumber = UInt16(port) else { throw SessionError.server("adb 端口转发失败：\(port)") }
            forwardedPort = port
            try launchServer()
            try connectWithRetry(port: portNumber)
            if config.audio {
                // The server accepts the audio socket right after the video one.
                try audioConnection.connect(port: portNumber)
                startAudioThread()
            }
            try readStream()
        } catch {
            if !isStopped {
                let summary = serverErrorSummary()
                failure = summary ?? error.localizedDescription
            }
        }

        connection.close()
        audioConnection.shutdown()
        if let p = serverProcess, p.isRunning { p.terminate() }
        if let port = forwardedPort {
            _ = try? adb.run(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 5)
        }
        emit(.ended(error: isStopped ? nil : (failure ?? "连接已断开")))
    }

    private func launchServer() throws {
        let p = adb.makeProcess(ScrcpyServer.shellArgs(serial: serial, options: config.serverOptions(scid: scid)))
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.appendLog(String(decoding: data, as: UTF8.self))
        }
        try p.run()
        serverProcess = p
    }

    private func appendLog(_ text: String) {
        let lines = text.split(separator: "\n").map(String.init)
        for line in lines { NSLog("[phone] %@", line) }
        lock.lock()
        serverLog.append(contentsOf: lines)
        if serverLog.count > 200 { serverLog.removeFirst(serverLog.count - 200) }
        lock.unlock()
    }

    /// The most useful error lines from the phone, if any.
    private func serverErrorSummary() -> String? {
        lock.lock(); defer { lock.unlock() }
        let errors = serverLog.filter { $0.contains("ERROR") || $0.contains("Exception") }
        guard !errors.isEmpty else { return nil }
        return "手机端错误：" + errors.prefix(3).joined(separator: "\n")
    }

    /// With a forward tunnel, connect() succeeds even before the server listens; the server's
    /// dummy byte is what proves the connection is real.
    private func connectWithRetry(port: UInt16) throws {
        let deadline = Date().addingTimeInterval(10)
        while true {
            if isStopped { throw SessionError.closed }
            if let p = serverProcess, !p.isRunning {
                Thread.sleep(forTimeInterval: 0.2)  // let the last log lines arrive
                throw SessionError.server(serverErrorSummary() ?? "手机端服务意外退出")
            }
            do {
                try connection.connect(port: port)
                connection.setReadTimeout(seconds: 2)
                _ = try connection.read(1)
                return
            } catch {
                connection.close()
                if Date() > deadline { throw SessionError.timeout }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    private func readStream() throws {
        // Camera frames arrive continuously, so a long silence means something is stuck.
        connection.setReadTimeout(seconds: 5)

        let meta = try connection.read(64)
        let name = String(decoding: meta.prefix { $0 != 0 }, as: UTF8.self)

        let codec = try connection.read(4).u32(at: 0)
        if codec == 0 || codec == 1 {
            Thread.sleep(forTimeInterval: 0.2)
            throw SessionError.server(serverErrorSummary() ?? "手机端无法启动摄像头")
        }
        guard codec == 0x6832_3634 else { throw SessionError.server("不支持的视频编码") }
        emit(.connected(deviceName: name))

        let assembler = H264Assembler()
        while !isStopped {
            let header = try connection.read(12)
            if header[header.startIndex] & 0x80 != 0 {
                // Session packet: a new capture session with its frame size.
                emit(.videoSize(width: Int(header.u32(at: 4)), height: Int(header.u32(at: 8))))
                continue
            }
            let ptsAndFlags = header.u64(at: 0)
            let size = Int(header.u32(at: 8))
            guard size > 0, size < 32 << 20 else { throw SessionError.server("视频数据异常") }
            let payload = try connection.read(size)
            let isKey = ptsAndFlags & (1 << 61) != 0
            let pts = Int64(ptsAndFlags & ((1 << 61) - 1))
            if let packet = assembler.process(payload, isKey: isKey, pts: pts) {
                pipeline.push(packet)
            }
        }
    }
}

extension StreamSession {
    fileprivate func startAudioThread() {
        let thread = Thread { [self] in
            do {
                try readAudio()
            } catch {
                if !isStopped { NSLog("[audio] stream ended: %@", error.localizedDescription) }
            }
            audioConnection.close()
        }
        thread.name = "DisplayCam.audio"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func readAudio() throws {
        // No read timeout: the stream only starts once video is flowing.
        let codec = try audioConnection.read(4).u32(at: 0)
        guard codec == 0x0061_6163 else {
            // 0 = the phone could not capture audio (video keeps going), 1 = error.
            emit(.audioAvailable(false))
            return
        }
        emit(.audioAvailable(true))
        let assembler = AACAssembler()
        while !isStopped {
            let header = try audioConnection.read(12)
            let ptsAndFlags = header.u64(at: 0)
            let size = Int(header.u32(at: 8))
            guard size > 0, size < 1 << 20 else { throw SessionError.server("音频数据异常") }
            let payload = try audioConnection.read(size)
            let isConfig = ptsAndFlags & (1 << 62) != 0
            let pts = Int64(ptsAndFlags & ((1 << 61) - 1))
            if let packet = assembler.process(payload, isConfig: isConfig, pts: pts) {
                pipeline.pushAudio(packet)
            }
        }
    }
}

extension Data {
    func u32(at offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(self[startIndex + offset + i]) }
        return v
    }

    func u64(at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(self[startIndex + offset + i]) }
        return v
    }
}
