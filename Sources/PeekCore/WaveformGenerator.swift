import Foundation
import AVFAudio
import Accelerate

/// Bounded streaming peak-bucket waveform generator.
///
/// Reads an `AVAudioFile` in fixed-size windows and reduces the stream
/// to per-bucket min/max pairs (or absolute peaks). Memory use is
/// bounded: one 4096-frame `AVAudioPCMBuffer` is allocated once and
/// reused for the whole file, regardless of duration.
public struct WaveformGenerator {

    public enum Style: Sendable {
        /// One Float per bucket: the absolute peak.
        case peak
        /// Two Floats per bucket (min, max) for symmetric drawing.
        case minMax
    }

    public struct Buckets: Equatable, Sendable {
        public let bucketCount: Int
        public let framesPerBucket: Int64
        /// For `.peak`: length == bucketCount. For `.minMax`:
        /// length == bucketCount * 2.
        public let values: [Float]

        public init(bucketCount: Int, framesPerBucket: Int64, values: [Float]) {
            self.bucketCount = bucketCount
            self.framesPerBucket = framesPerBucket
            self.values = values
        }

        public var isEmpty: Bool { values.isEmpty }
    }

    public init() {}

    public func generate(
        from url: URL,
        bucketCount: Int = 512,
        style: Style = .peak,
        isCancelled: () -> Bool = { false }
    ) throws -> Buckets {
        if isCancelled() { throw CancellationError() }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let totalFrames = file.length
        guard totalFrames > 0, bucketCount > 0 else {
            return Buckets(bucketCount: 0, framesPerBucket: 0, values: [])
        }

        // Distribute all frames across exactly min(requested, frames)
        // buckets; earlier buckets get one extra frame when dividing
        // is uneven, so no trailing frames are dropped and no bucket
        // is empty. Clamp output allocation independently of duration.
        let effectiveBuckets = min(bucketCount, Int(min(totalFrames, 16384)))
        let framesPerBucket = totalFrames / Int64(effectiveBuckets)
        let remainder = totalFrames % Int64(effectiveBuckets)

        let format = file.processingFormat
        let readWindow: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readWindow) else {
            return Buckets(bucketCount: 0, framesPerBucket: framesPerBucket, values: [])
        }

        let valuesPerBucket = style == .minMax ? 2 : 1
        var output: [Float] = []
        output.reserveCapacity(effectiveBuckets * valuesPerBucket)

        var framesDone: Int64 = 0
        var framesInBucket: Int64 = 0
        // Seed with sentinels, not 0: a bucket of unipolar or DC-offset audio
        // must not report a fabricated zero crossing.
        var bucketMin: Float = .greatestFiniteMagnitude
        var bucketMax: Float = -.greatestFiniteMagnitude
        var bucketsEmitted = 0

            func emit() {
                // A bucket that saw no frames (sentinels intact) emits silence
                // rather than ±inf.
                if bucketMin > bucketMax {
                    bucketMin = 0
                    bucketMax = 0
                }
                switch style {
            case .peak:
                output.append(max(abs(bucketMin), abs(bucketMax)))
            case .minMax:
                output.append(bucketMin)
                output.append(bucketMax)
            }
            bucketsEmitted += 1
            bucketMin = .greatestFiniteMagnitude
            bucketMax = -.greatestFiniteMagnitude
            framesInBucket = 0
        }

        // Capacity of the bucket currently being accumulated: uniform
        // framesPerBucket except the final bucket, which absorbs the
        // floored remainder.
        func bucketCapacity(_ index: Int) -> Int64 {
            framesPerBucket + (Int64(index) < remainder ? 1 : 0)
        }

        while framesDone < totalFrames, bucketsEmitted < effectiveBuckets {
            if isCancelled() { throw CancellationError() }
            let want = AVAudioFrameCount(min(Int64(readWindow), totalFrames - framesDone))
            if want == 0 { break }
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: want)
            let got = Int(buffer.frameLength)
            guard got > 0, let channelData = buffer.floatChannelData else {
                throw NSError(domain: "Peek", code: 3, userInfo: [NSLocalizedDescriptionKey: "Audio ended before the declared frame count or supplied no PCM samples."])
            }
            let channelCount = Int(buffer.format.channelCount)

            // Split the window at bucket boundaries: a window may span
            // several buckets (short buckets) or a bucket may span
            // several windows (long buckets).
            var offset = 0
            while offset < got, bucketsEmitted < effectiveBuckets {
                let roomInBucket = bucketCapacity(bucketsEmitted) - framesInBucket
                let take = min(Int64(got - offset), roomInBucket)
                let (lo, hi) = minMaxOf(channelData: channelData,
                                        channels: channelCount,
                                        frames: Int(take),
                                        offset: offset)
                bucketMin = min(bucketMin, lo)
                bucketMax = max(bucketMax, hi)
                framesInBucket += take
                framesDone += take
                offset += Int(take)
                if framesInBucket >= bucketCapacity(bucketsEmitted) {
                    emit()
                }
            }
        }
        if framesInBucket > 0, bucketsEmitted < effectiveBuckets {
            emit()
        }
        if isCancelled() { throw CancellationError() }

        return Buckets(bucketCount: bucketsEmitted, framesPerBucket: framesPerBucket, values: output)
    }

    /// One min/max waveform per channel (up to `maxChannels`), read in a single pass.
    /// Used for the per-channel lanes; `combine` rebuilds the mixed view from it.
    public func generateChannels(
        from url: URL,
        bucketCount: Int = 512,
        maxChannels: Int = 24,
        isCancelled: () -> Bool = { false }
    ) throws -> [Buckets] {
        if isCancelled() { throw CancellationError() }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let totalFrames = file.length
        let channels = min(maxChannels, Int(file.processingFormat.channelCount))
        guard totalFrames > 0, bucketCount > 0, channels > 0 else { return [] }
        let buckets = min(bucketCount, Int(min(totalFrames, 16384)))
        let perBucket = totalFrames / Int64(buckets)
        let remainder = totalFrames % Int64(buckets)
        func capacity(_ index: Int) -> Int64 { perBucket + (Int64(index) < remainder ? 1 : 0) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { return [] }

        var out = Array(repeating: [Float](), count: channels)
        for c in 0..<channels { out[c].reserveCapacity(buckets * 2) }
        var lo = [Float](repeating: .greatestFiniteMagnitude, count: channels)
        var hi = [Float](repeating: -.greatestFiniteMagnitude, count: channels)
        var emitted = 0, inBucket: Int64 = 0, done: Int64 = 0
        func emit() {
            for c in 0..<channels {
                if lo[c] > hi[c] { lo[c] = 0; hi[c] = 0 }
                out[c].append(lo[c]); out[c].append(hi[c])
                lo[c] = .greatestFiniteMagnitude; hi[c] = -.greatestFiniteMagnitude
            }
            emitted += 1; inBucket = 0
        }
        while done < totalFrames, emitted < buckets {
            if isCancelled() { throw CancellationError() }
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, totalFrames - done)))
            let got = Int(buffer.frameLength)
            guard got > 0, let data = buffer.floatChannelData else {
                throw NSError(domain: "Peek", code: 3, userInfo: [NSLocalizedDescriptionKey: "Audio ended before the declared frame count or supplied no PCM samples."])
            }
            var offset = 0
            while offset < got, emitted < buckets {
                let take = Int(min(Int64(got - offset), capacity(emitted) - inBucket))
                for c in 0..<channels {
                    var mn: Float = 0, mx: Float = 0
                    vDSP_minv(data[c] + offset, 1, &mn, vDSP_Length(take))
                    vDSP_maxv(data[c] + offset, 1, &mx, vDSP_Length(take))
                    lo[c] = min(lo[c], mn); hi[c] = max(hi[c], mx)
                }
                inBucket += Int64(take); done += Int64(take); offset += take
                if inBucket >= capacity(emitted) { emit() }
            }
        }
        if inBucket > 0, emitted < buckets { emit() }
        if isCancelled() { throw CancellationError() }
        return out.map { Buckets(bucketCount: emitted, framesPerBucket: perBucket, values: $0) }
    }

    /// The all-channel min/max waveform, rebuilt from per-channel lanes.
    public static func combine(_ lanes: [Buckets]) -> Buckets {
        guard let first = lanes.first else { return Buckets(bucketCount: 0, framesPerBucket: 0, values: []) }
        var values = first.values
        for lane in lanes.dropFirst() where lane.values.count == values.count {
            for i in stride(from: 0, to: values.count, by: 2) {
                values[i] = min(values[i], lane.values[i])
                values[i + 1] = max(values[i + 1], lane.values[i + 1])
            }
        }
        return Buckets(bucketCount: first.bucketCount, framesPerBucket: first.framesPerBucket, values: values)
    }

    // MARK: - buffer reduction

    private func minMaxOf(channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
                          channels: Int,
                          frames: Int,
                          offset: Int) -> (Float, Float) {
        var mn: Float = .greatestFiniteMagnitude
        var mx: Float = -.greatestFiniteMagnitude
        for ch in 0..<channels {
            let p = channelData[ch] + offset
            for i in 0..<frames {
                let v = p[i]
                if v < mn { mn = v }
                if v > mx { mx = v }
            }
        }
        return (mn, mx)
    }
}
