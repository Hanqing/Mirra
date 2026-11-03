import AudioToolbox
import CoreMedia
import Foundation
import QuartzCore

/// One raw AAC frame (no ADTS header) from the phone microphone.
struct AudioPacket {
    let data: Data
    let format: CMAudioFormatDescription
    let pts: Int64  // microseconds, phone clock
    let arrival: CFTimeInterval

    func makeSampleBuffer(presentationTime: CMTime) -> CMSampleBuffer? {
        let length = data.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }

        var description = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(length))
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, presentationTimeStamp: presentationTime,
            packetDescriptions: &description, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}

/// Builds `AudioPacket`s from scrcpy's AAC stream; the config packet carries the AudioSpecificConfig.
final class AACAssembler {
    private var format: CMAudioFormatDescription?

    func process(_ payload: Data, isConfig: Bool, pts: Int64) -> AudioPacket? {
        if isConfig {
            format = Self.makeFormat(audioSpecificConfig: payload)
            return nil
        }
        guard let format, !payload.isEmpty else { return nil }
        return AudioPacket(data: payload, format: format, pts: pts, arrival: CACurrentMediaTime())
    }

    static func makeFormat(audioSpecificConfig asc: Data) -> CMAudioFormatDescription? {
        guard asc.count >= 2 else { return nil }
        let b0 = asc[asc.startIndex], b1 = asc[asc.startIndex + 1]
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let rateIndex = Int((b0 & 0x07) << 1 | b1 >> 7)
        let channels = UInt32((b1 >> 3) & 0x0F)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rateIndex < rates.count ? rates[rateIndex] : 48000,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: max(channels, 1), mBitsPerChannel: 0, mReserved: 0)
        var format: CMAudioFormatDescription?
        let status = asc.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: asc.count, magicCookie: raw.baseAddress, extensions: nil,
                formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }
}

/// Maps a stream's phone timestamps onto the Mac clock (CACurrentMediaTime).
/// Audio and video use different clocks on the phone, so each stream keeps its own offset,
/// estimated as the smallest (arrival − pts) seen, i.e. the least-delayed packet.
struct StreamClock {
    private(set) var offset: Double?

    mutating func observe(pts: Int64, arrival: CFTimeInterval) {
        let candidate = arrival - Double(pts) / 1_000_000
        if offset == nil || candidate < offset! { offset = candidate }
    }

    mutating func reset() { offset = nil }
}
