import AVFoundation

/// Writes the phone's H.264 video and AAC audio into an MP4 as-is (no re-encoding).
/// Rotation and mirroring are stored as the track transform, so they cost nothing.
final class Recorder {
    enum RecorderError: LocalizedError {
        case noFrames
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .noFrames: return "没有录到画面"
            case .writer(let msg): return "保存录像失败：\(msg)"
            }
        }
    }

    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let realtime: Bool
    private let videoOffset: Double
    private let audioOffset: Double
    private let queue = DispatchQueue(label: "DisplayCam.recorder", qos: .userInitiated)

    // Only touched on `queue`.
    private var startTime: CMTime?
    private var lastVideoTime = CMTime.negativeInfinity
    private var lastAudioTime = CMTime.negativeInfinity

    /// - Parameters:
    ///   - videoOffset/audioOffset: phone-clock → Mac-clock offsets, frozen for this file so
    ///     timestamps stay monotonic and audio stays in sync with video.
    init(url: URL, videoFormat: CMVideoFormatDescription, audioFormat: CMAudioFormatDescription?,
         transform: CGAffineTransform, videoOffset: Double, audioOffset: Double, realtime: Bool) throws {
        self.url = url
        self.realtime = realtime
        self.videoOffset = videoOffset
        self.audioOffset = audioOffset
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = realtime
        videoInput.transform = transform
        writer.add(videoInput)

        if let audioFormat {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = realtime
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else {
            throw RecorderError.writer(writer.error?.localizedDescription ?? "无法创建文件")
        }
    }

    func append(video packets: [VideoPacket]) {
        append(video: packets, audio: [])
    }

    func append(audio packets: [AudioPacket]) {
        append(video: [], audio: packets)
    }

    /// Appends both streams. Live recordings write in time order and drop rather than block;
    /// saved replays feed whichever input the writer is ready for, which is how it wants to interleave.
    func append(video: [VideoPacket], audio: [AudioPacket]) {
        queue.async {
            var v = 0, a = 0
            if self.realtime {
                while v < video.count || a < audio.count {
                    let takeVideo = a >= audio.count
                        || (v < video.count && self.time(of: video[v]) <= self.time(of: audio[a]))
                    if takeVideo { self.write(video[v]); v += 1 } else { self.write(audio[a]); a += 1 }
                }
                return
            }
            if self.audioInput == nil { a = audio.count }
            var idleSince: Date?
            while (v < video.count || a < audio.count) && self.writer.status == .writing {
                var progressed = false
                // The first sample must be video: it starts the session.
                if v < video.count && (self.videoInput.isReadyForMoreMediaData || self.startTime == nil) {
                    self.write(video[v]); v += 1; progressed = true
                }
                if self.startTime != nil, a < audio.count, self.audioInput?.isReadyForMoreMediaData == true {
                    self.write(audio[a]); a += 1; progressed = true
                }
                if progressed {
                    idleSince = nil
                } else {
                    if idleSince == nil { idleSince = Date() }
                    if Date().timeIntervalSince(idleSince!) > 3 {
                        NSLog("[recorder] gave up waiting for the writer (video %d/%d, audio %d/%d)",
                              v, video.count, a, audio.count)
                        return
                    }
                    usleep(1000)
                }
            }
        }
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            guard self.startTime != nil else {
                self.writer.cancelWriting()
                try? FileManager.default.removeItem(at: self.url)
                completion(.failure(RecorderError.noFrames))
                return
            }
            self.videoInput.markAsFinished()
            self.audioInput?.markAsFinished()
            // Give the last frame a normal duration.
            self.writer.endSession(atSourceTime: self.lastVideoTime + CMTime(value: 1, timescale: 30))
            self.writer.finishWriting {
                if self.writer.status == .completed {
                    completion(.success(self.url))
                } else {
                    completion(.failure(RecorderError.writer(self.writer.error?.localizedDescription ?? "未知错误")))
                }
            }
        }
    }

    // MARK: Private (on `queue`)

    private func time(of packet: VideoPacket) -> CMTime {
        CMTime(seconds: Double(packet.pts) / 1_000_000 + videoOffset, preferredTimescale: 1_000_000)
    }

    private func time(of packet: AudioPacket) -> CMTime {
        CMTime(seconds: Double(packet.pts) / 1_000_000 + audioOffset, preferredTimescale: 1_000_000)
    }

    private func write(_ packet: VideoPacket) {
        guard writer.status == .writing else { return }
        let t = time(of: packet)
        if startTime == nil {
            guard packet.isKey else { return }  // a file must start on a keyframe
            writer.startSession(atSourceTime: t)
            startTime = t
        }
        guard t > lastVideoTime, let sample = packet.makeSampleBuffer(presentationTime: t) else { return }
        if videoInput.isReadyForMoreMediaData || !realtime {
            videoInput.append(sample)
            lastVideoTime = t
        }
    }

    private func write(_ packet: AudioPacket) {
        guard writer.status == .writing, let input = audioInput, let start = startTime else { return }
        let t = time(of: packet)
        guard t >= start, t > lastAudioTime, let sample = packet.makeSampleBuffer(presentationTime: t) else { return }
        if input.isReadyForMoreMediaData || !realtime {
            input.append(sample)
            lastAudioTime = t
        }
    }
}
