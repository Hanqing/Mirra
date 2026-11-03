import CoreMedia
import Foundation
import QuartzCore

/// One encoded frame, already converted to the length-prefixed (AVCC) layout CoreMedia expects.
struct VideoPacket {
    let avcc: Data
    let format: CMVideoFormatDescription
    let isKey: Bool
    let pts: Int64  // microseconds, from the phone
    let arrival: CFTimeInterval  // CACurrentMediaTime() when received

    /// A fresh sample buffer each time, so renderers and recorders never share mutable attachments.
    /// Pass `presentationTime` when writing to a file; otherwise the frame is marked for immediate display.
    func makeSampleBuffer(doNotDisplay: Bool = false, presentationTime: CMTime? = nil) -> CMSampleBuffer? {
        let length = avcc.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return nil }

        let copied = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime ?? CMTime(value: pts, timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var size = length
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            func set(_ key: CFString) {
                CFDictionarySetValue(
                    dict, Unmanaged.passUnretained(key).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            // Show frames as soon as they are decoded: lowest latency, no clock to manage.
            if presentationTime == nil { set(kCMSampleAttachmentKey_DisplayImmediately) }
            if doNotDisplay { set(kCMSampleAttachmentKey_DoNotDisplay) }
            if !isKey { set(kCMSampleAttachmentKey_NotSync) }
        }
        return sample
    }
}

/// Turns scrcpy's Annex-B H.264 packets into `VideoPacket`s, tracking SPS/PPS as they change.
final class H264Assembler {
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?

    func process(_ payload: Data, isKey: Bool, pts: Int64) -> VideoPacket? {
        let bytes = [UInt8](payload)
        var frameNALs: [ArraySlice<UInt8>] = []
        var paramsChanged = false

        for range in Self.nalRanges(bytes) {
            let nal = bytes[range]
            guard let header = nal.first else { continue }
            switch header & 0x1F {
            case 7:
                let d = Data(nal)
                if d != sps { sps = d; paramsChanged = true }
            case 8:
                let d = Data(nal)
                if d != pps { pps = d; paramsChanged = true }
            case 9:
                continue  // access unit delimiter
            default:
                frameNALs.append(nal)
            }
        }

        if paramsChanged || format == nil, let sps, let pps {
            format = Self.makeFormat(sps: sps, pps: pps)
        }
        guard !frameNALs.isEmpty, let format else { return nil }

        var avcc = Data(capacity: bytes.count + frameNALs.count * 4)
        var key = isKey
        for nal in frameNALs {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: nal)
            if nal.first! & 0x1F == 5 { key = true }
        }
        return VideoPacket(avcc: avcc, format: format, isKey: key, pts: pts, arrival: CACurrentMediaTime())
    }

    /// Ranges of NAL unit bodies between 3- or 4-byte start codes.
    static func nalRanges(_ b: [UInt8]) -> [Range<Int>] {
        var starts: [(code: Int, body: Int)] = []
        let n = b.count
        var i = 0
        while i + 2 < n {
            if b[i] == 0 && b[i + 1] == 0 {
                if b[i + 2] == 1 {
                    starts.append((i, i + 3)); i += 3; continue
                }
                if i + 3 < n && b[i + 2] == 0 && b[i + 3] == 1 {
                    starts.append((i, i + 4)); i += 4; continue
                }
            }
            i += 1
        }
        if starts.isEmpty { return n > 0 ? [0..<n] : [] }
        var ranges: [Range<Int>] = []
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].code : n
            if end > s.body { ranges.append(s.body..<end) }
        }
        return ranges
    }

    static func makeFormat(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p -> OSStatus in
                let pointers: [UnsafePointer<UInt8>] = [
                    s.bindMemory(to: UInt8.self).baseAddress!,
                    p.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }
}
