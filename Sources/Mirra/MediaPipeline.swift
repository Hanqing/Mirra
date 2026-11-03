import AVFoundation
import QuartzCore

/// Routes the phone's media to everything that consumes it:
/// - live display layers (the mirror), fed as soon as frames arrive
/// - delayed display layers, fed the same frames `delay` seconds later
/// - recorders (a running recording, or "save the last N seconds")
///
/// Recent frames stay compressed in memory (~1 MB/s), which is what makes delayed playback
/// and saving the last minute cheap.
final class MediaPipeline {
    struct Stats {
        var fps: Double
        var bufferedSeconds: Double
        var delayedReady: Bool
    }

    struct LayerPair {
        let live: AVSampleBufferDisplayLayer
        let delayed: AVSampleBufferDisplayLayer
    }

    enum RecordingError: LocalizedError {
        case noVideo
        case busy

        var errorDescription: String? {
            switch self {
            case .noVideo: return "还没有画面，等手机连上再试"
            case .busy: return "已经在录制"
            }
        }
    }

    static let maxDelay: Double = 15
    static let maxReplay: Double = 60

    /// Called on the main thread about twice a second.
    var onStats: ((Stats) -> Void)?

    private final class Sink {
        let layer = AVSampleBufferDisplayLayer()
        var needsKey = true

        init() {
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        }
    }

    private let queue = DispatchQueue(label: "Mirra.media", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    // Everything below is only touched on `queue`.
    private var liveSinks: [Sink] = []
    private var delayedSinks: [Sink] = []
    private var history: [VideoPacket] = []
    private var audioHistory: [AudioPacket] = []
    private var latestAudioFormat: CMAudioFormatDescription?
    private var videoClock = StreamClock()
    private var audioClock = StreamClock()
    private var cursor = 0  // next history index for the delayed layers
    private var delayedSynced = false
    private var delay: Double = 3
    private var delayedEnabled = false
    private var keepSeconds: Double = maxDelay + 3
    private var recorder: Recorder?
    private var frameCount = 0
    private var statsSince = CACurrentMediaTime()

    init() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// A new live + delayed layer pair for one view (mirror window, preview…).
    func makeLayers() -> LayerPair {
        let live = Sink(), delayed = Sink()
        queue.async {
            self.liveSinks.append(live)
            self.delayedSinks.append(delayed)
        }
        return LayerPair(live: live.layer, delayed: delayed.layer)
    }

    func push(_ packet: VideoPacket) {
        queue.async { self.handle(packet) }
    }

    func pushAudio(_ packet: AudioPacket) {
        queue.async { self.handleAudio(packet) }
    }

    func configure(delayedEnabled: Bool, delay: Double, replaySeconds: Double) {
        queue.async {
            if self.delayedEnabled != delayedEnabled || self.delay != delay {
                self.delayedSynced = false
            }
            self.delayedEnabled = delayedEnabled
            self.delay = delay
            self.keepSeconds = max(Self.maxDelay, replaySeconds) + 3
        }
    }

    /// Drops all frames, e.g. when a new connection starts.
    func reset(clearImage: Bool) {
        queue.async {
            self.history.removeAll()
            self.audioHistory.removeAll()
            self.latestAudioFormat = nil
            self.videoClock.reset()
            self.audioClock.reset()
            self.cursor = 0
            self.delayedSynced = false
            for sink in self.liveSinks + self.delayedSinks {
                sink.needsKey = true
                sink.layer.sampleBufferRenderer.flush(removingDisplayedImage: clearImage, completionHandler: nil)
            }
        }
    }

    // MARK: Recording

    /// Starts recording, including the frames since the latest keyframe so it starts instantly.
    func startRecording(to url: URL, transform: CGAffineTransform, includeAudio: Bool,
                        completion: @escaping (Error?) -> Void) {
        queue.async {
            let result: Error? = {
                guard self.recorder == nil else { return RecordingError.busy }
                guard let start = self.history.lastIndex(where: { $0.isKey }),
                      let videoOffset = self.videoClock.offset
                else { return RecordingError.noVideo }
                do {
                    let audioFormat = includeAudio ? self.latestAudioFormat : nil
                    let recorder = try Recorder(
                        url: url, videoFormat: self.history[start].format, audioFormat: audioFormat,
                        transform: transform, videoOffset: videoOffset,
                        audioOffset: self.audioClock.offset ?? videoOffset, realtime: true)
                    let preroll = Array(self.history[start...])
                    let audio = audioFormat == nil ? [] : self.audioHistory.filter { $0.arrival >= preroll[0].arrival - 0.2 }
                    recorder.append(video: preroll, audio: audio)
                    self.recorder = recorder
                    return nil
                } catch {
                    return error
                }
            }()
            DispatchQueue.main.async { completion(result) }
        }
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            guard let recorder = self.recorder else { return }
            self.recorder = nil
            recorder.finish { result in DispatchQueue.main.async { completion(result) } }
        }
    }

    /// Writes the last `seconds` of video (and audio) to a new file, without interrupting anything.
    func saveReplay(seconds: Double, to url: URL, transform: CGAffineTransform, includeAudio: Bool,
                    completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            let target = CACurrentMediaTime() - seconds
            guard let start = self.history.lastIndex(where: { $0.isKey && $0.arrival <= target })
                    ?? self.history.firstIndex(where: { $0.isKey }),
                  let videoOffset = self.videoClock.offset
            else {
                DispatchQueue.main.async { completion(.failure(RecordingError.noVideo)) }
                return
            }
            let frames = Array(self.history[start...])
            let audioFormat = includeAudio ? self.latestAudioFormat : nil
            let audio = audioFormat == nil ? [] : self.audioHistory.filter { $0.arrival >= frames[0].arrival - 0.2 }
            let audioOffset = self.audioClock.offset ?? videoOffset

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let recorder = try Recorder(
                        url: url, videoFormat: frames[0].format, audioFormat: audioFormat,
                        transform: transform, videoOffset: videoOffset, audioOffset: audioOffset,
                        realtime: false)
                    recorder.append(video: frames, audio: audio)
                    recorder.finish { result in DispatchQueue.main.async { completion(result) } }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }
    }

    // MARK: Feeding

    private func handle(_ packet: VideoPacket) {
        videoClock.observe(pts: packet.pts, arrival: packet.arrival)
        for sink in liveSinks { enqueue(packet, into: sink) }
        recorder?.append(video: [packet])
        history.append(packet)
        trimHistory()
        frameCount += 1
    }

    private func handleAudio(_ packet: AudioPacket) {
        audioClock.observe(pts: packet.pts, arrival: packet.arrival)
        latestAudioFormat = packet.format
        recorder?.append(audio: [packet])
        audioHistory.append(packet)
        let keepFrom = packet.arrival - keepSeconds
        if let drop = audioHistory.firstIndex(where: { $0.arrival >= keepFrom }), drop > 0 {
            audioHistory.removeFirst(drop)
        }
    }

    private func enqueue(_ packet: VideoPacket, into sink: Sink, doNotDisplay: Bool = false) {
        let renderer = sink.layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            sink.needsKey = true
        }
        if sink.needsKey && !packet.isKey { return }
        sink.needsKey = false
        if let sample = packet.makeSampleBuffer(doNotDisplay: doNotDisplay) {
            renderer.enqueue(sample)
        }
    }

    private func trimHistory() {
        guard let newest = history.last else { return }
        let keepFrom = newest.arrival - keepSeconds
        var drop = 0
        while drop < history.count - 1 && history[drop].arrival < keepFrom { drop += 1 }
        guard drop > 0 else { return }
        history.removeFirst(drop)
        cursor -= drop
        if cursor < 0 {
            cursor = 0
            delayedSynced = false
        }
    }

    private func tick() {
        if delayedEnabled { feedDelayed() }
        reportStatsIfDue()
    }

    private func feedDelayed() {
        guard !history.isEmpty, !delayedSinks.isEmpty else { return }
        let target = CACurrentMediaTime() - delay
        if delayedSinks.contains(where: {
            $0.layer.sampleBufferRenderer.status == .failed || $0.layer.sampleBufferRenderer.requiresFlushToResumeDecoding
        }) {
            delayedSynced = false
        }
        if !delayedSynced {
            // Decoding must start at a keyframe at or before the target moment.
            guard let start = history.lastIndex(where: { $0.isKey && $0.arrival <= target }) else { return }
            for sink in delayedSinks {
                sink.layer.sampleBufferRenderer.flush()
                sink.needsKey = true
            }
            cursor = start
            delayedSynced = true
        }
        while cursor < history.count && history[cursor].arrival <= target {
            // When catching up, decode intermediate frames without showing them.
            let superseded = cursor + 1 < history.count && history[cursor + 1].arrival <= target
            for sink in delayedSinks { enqueue(history[cursor], into: sink, doNotDisplay: superseded) }
            cursor += 1
        }
    }

    private func reportStatsIfDue() {
        let now = CACurrentMediaTime()
        let elapsed = now - statsSince
        guard elapsed >= 0.5 else { return }
        let buffered = history.isEmpty ? 0 : now - history[0].arrival
        let stats = Stats(fps: Double(frameCount) / elapsed, bufferedSeconds: buffered, delayedReady: delayedSynced)
        frameCount = 0
        statsSince = now
        if ProcessInfo.processInfo.environment["MIRRA_DEBUG"] != nil {
            for sink in liveSinks + delayedSinks where sink.layer.sampleBufferRenderer.status == .failed {
                NSLog("[render] failed: %@", String(describing: sink.layer.sampleBufferRenderer.error))
            }
        }
        DispatchQueue.main.async { self.onStats?(stats) }
    }
}
