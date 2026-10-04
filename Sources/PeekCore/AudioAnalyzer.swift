import Foundation
import AVFAudio
import Accelerate

/// Result of a full read of the file: loudness (ITU-R BS.1770-4 / EBU R128),
/// true peak, sample peak and a compact log-frequency spectrogram.
public struct AudioAnalysis: Equatable, Sendable {
    /// Gated programme loudness; nil when everything is below the −70 LUFS gate.
    public var integratedLUFS: Double?
    /// EBU Tech 3342 loudness range; nil for material shorter than one 3 s window.
    public var loudnessRangeLU: Double?
    /// Maximum over channels, dBTP (4× oversampled below 96 kHz, 2× below 192 kHz).
    public var truePeakDBTP: Double?
    public var samplePeakDBFS: Double?
    public var channelTruePeakDBTP: [Double?]
    public var spectrogram: Spectrogram?

    public init(integratedLUFS: Double? = nil, loudnessRangeLU: Double? = nil, truePeakDBTP: Double? = nil,
                samplePeakDBFS: Double? = nil, channelTruePeakDBTP: [Double?] = [], spectrogram: Spectrogram? = nil) {
        self.integratedLUFS = integratedLUFS
        self.loudnessRangeLU = loudnessRangeLU
        self.truePeakDBTP = truePeakDBTP
        self.samplePeakDBFS = samplePeakDBFS
        self.channelTruePeakDBTP = channelTruePeakDBTP
        self.spectrogram = spectrogram
    }
}

/// Column-major magnitudes: `values[column * rows + row]`, row 0 = lowest frequency.
/// 0 = −100 dBFS or quieter, 255 = 0 dBFS (a full-scale sine).
public struct Spectrogram: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let minHz: Double
    public let maxHz: Double
    public let values: [UInt8]

    /// Frequency at the centre of a row (log spaced).
    public func frequency(row: Double) -> Double {
        minHz * pow(maxHz / minHz, row / Double(max(1, rows - 1)))
    }
}

public struct AudioAnalyzer {
    public init() {}

    public func analyze(url: URL, channelMap: ChannelMap? = nil, spectrogramColumns: Int = 480,
                        isCancelled: () -> Bool = { false },
                        progress: (Double) -> Void = { _ in }) throws -> AudioAnalysis {
        if isCancelled() { throw CancellationError() }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let rate = format.sampleRate
        let total = file.length
        guard total > 0, channels > 0, rate > 0 else { return AudioAnalysis() }
        let map = channelMap ?? ChannelMap.resolve(file.fileFormat)
        let weights = map.weights.count == channels ? map.weights : ChannelMap.defaultLabels(channels).map(ChannelMap.weight)

        var loudness = LoudnessMeter(rate: rate, weights: weights)
        var peaks = TruePeakMeter(rate: rate, channels: channels)
        var spectrum = SpectrogramBuilder(totalFrames: total, rate: rate, columns: spectrogramColumns)

        let window: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window) else { return AudioAnalysis() }
        var done: Int64 = 0
        var lastReport = -1.0
        while done < total {
            if isCancelled() { throw CancellationError() }
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(window), total - done)))
            let got = Int(buffer.frameLength)
            guard got > 0, let data = buffer.floatChannelData else { break }
            let pointers = (0..<channels).map { UnsafePointer(data[$0]) }
            loudness.process(pointers, frames: got)
            peaks.process(pointers, frames: got)
            spectrum.process(pointers, frames: got)
            done += Int64(got)
            let f = Double(done) / Double(total)
            if f - lastReport >= 0.02 { progress(f); lastReport = f }
        }
        if isCancelled() { throw CancellationError() }
        let tp = peaks.truePeak.map { $0 > 0 ? 20 * log10($0) : nil }
        let maxTP = peaks.truePeak.max() ?? 0
        let maxSP = peaks.samplePeak
        return AudioAnalysis(integratedLUFS: loudness.integrated(), loudnessRangeLU: loudness.range(),
                             truePeakDBTP: maxTP > 0 ? 20 * log10(Double(maxTP)) : nil,
                             samplePeakDBFS: maxSP > 0 ? 20 * log10(Double(maxSP)) : nil,
                             channelTruePeakDBTP: tp.map { $0.map(Double.init) },
                             spectrogram: spectrum.finish())
    }
}

// MARK: - Loudness (BS.1770-4)

struct LoudnessMeter {
    private var filters: [KWeighting]
    private let weights: [Double]
    private let segmentFrames: Int          // 100 ms
    private var segmentSums: [Double]
    private var segmentFill = 0
    /// Weighted mean-square energy of each completed 100 ms segment.
    private(set) var segments: [Double] = []

    init(rate: Double, weights: [Double]) {
        self.weights = weights
        filters = weights.map { _ in KWeighting(rate: rate) }
        segmentFrames = max(1, Int((rate / 10).rounded()))
        segmentSums = Array(repeating: 0, count: weights.count)
    }

    mutating func process(_ channels: [UnsafePointer<Float>], frames: Int) {
        var offset = 0
        while offset < frames {
            let take = min(frames - offset, segmentFrames - segmentFill)
            for c in channels.indices where weights[c] > 0 {
                segmentSums[c] += filters[c].sumOfSquares(channels[c] + offset, count: take)
            }
            segmentFill += take
            offset += take
            if segmentFill == segmentFrames {
                var z = 0.0
                for c in weights.indices { z += weights[c] * segmentSums[c] / Double(segmentFrames) }
                segments.append(z)
                segmentSums = Array(repeating: 0, count: weights.count)
                segmentFill = 0
            }
        }
    }

    private static func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }

    /// Mean energy of `span` consecutive segments starting every `hop` segments.
    private func blocks(span: Int, hop: Int) -> [Double] {
        guard segments.count >= span else { return [] }
        var out: [Double] = []
        var i = 0
        while i + span <= segments.count {
            var s = 0.0
            for k in i..<(i + span) { s += segments[k] }
            out.append(s / Double(span))
            i += hop
        }
        return out
    }

    /// 400 ms blocks with 75 % overlap, absolute gate −70 LUFS, relative gate −10 LU.
    func integrated() -> Double? {
        let gated = blocks(span: 4, hop: 1).filter { $0 > 0 && Self.lufs($0) > -70 }
        guard !gated.isEmpty else { return nil }
        let relative = Self.lufs(gated.reduce(0, +) / Double(gated.count)) - 10
        let kept = gated.filter { Self.lufs($0) > relative }
        guard !kept.isEmpty else { return nil }
        return Self.lufs(kept.reduce(0, +) / Double(kept.count))
    }

    /// EBU Tech 3342: 3 s short-term values, gated at −70 LUFS and −20 LU
    /// relative; the range between the 10th and 95th percentiles.
    func range() -> Double? {
        let gated = blocks(span: 30, hop: 1).filter { $0 > 0 && Self.lufs($0) > -70 }
        guard !gated.isEmpty else { return nil }
        let relative = Self.lufs(gated.reduce(0, +) / Double(gated.count)) - 20
        let values = gated.map(Self.lufs).filter { $0 > relative }.sorted()
        guard values.count > 1 else { return values.isEmpty ? nil : 0 }
        func percentile(_ p: Double) -> Double {
            values[min(values.count - 1, max(0, Int((p * Double(values.count - 1)).rounded())))]
        }
        return percentile(0.95) - percentile(0.10)
    }
}

/// Two-stage K-weighting pre-filter, coefficients derived for any sample rate
/// (same derivation as libebur128).
struct KWeighting {
    private var s1 = (0.0, 0.0), s2 = (0.0, 0.0)
    private let b1: (Double, Double, Double), a1: (Double, Double)
    private let b2: (Double, Double, Double), a2: (Double, Double)

    init(rate: Double) {
        var f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196
        var K = tan(Double.pi * f0 / rate)
        let Vh = pow(10, G / 20), Vb = pow(Vh, 0.4996667741545416)
        var a0 = 1 + K / Q + K * K
        b1 = ((Vh + Vb * K / Q + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0)
        a1 = (2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0)
        f0 = 38.13547087602444; Q = 0.5003270373238773; G = 0
        K = tan(Double.pi * f0 / rate)
        a0 = 1 + K / Q + K * K
        b2 = (1, -2, 1)
        a2 = (2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0)
        _ = G
    }

    /// Filters `count` samples (transposed direct form II) and returns Σy².
    mutating func sumOfSquares(_ x: UnsafePointer<Float>, count: Int) -> Double {
        var sum = 0.0
        var (z1, z2) = s1, (w1, w2) = s2
        for i in 0..<count {
            let input = Double(x[i])
            let y = b1.0 * input + z1
            z1 = b1.1 * input - a1.0 * y + z2
            z2 = b1.2 * input - a1.1 * y
            let out = b2.0 * y + w1
            w1 = b2.1 * y - a2.0 * out + w2
            w2 = b2.2 * y - a2.1 * out
            sum += out * out
        }
        s1 = (z1, z2); s2 = (w1, w2)
        return sum
    }
}

// MARK: - True peak (BS.1770-4 Annex 2)

struct TruePeakMeter {
    private let factor: Int
    private let taps: Int = 12
    /// Polyphase branches, each reversed so vDSP_conv performs convolution.
    private let phases: [[Float]]
    private var history: [[Float]]
    private(set) var truePeak: [Float]
    private(set) var samplePeak: Float = 0
    private var scratch: [Float] = []
    private var output: [Float] = []

    init(rate: Double, channels: Int) {
        factor = rate < 96_000 * 0.99 ? 4 : rate < 192_000 * 0.99 ? 2 : 1
        let n = taps * factor
        // Windowed-sinc interpolation filter (Blackman), cutoff at the original Nyquist.
        var h = [Float](repeating: 0, count: n)
        let centre = Double(n - 1) / 2
        for i in 0..<n {
            let t = (Double(i) - centre) / Double(factor)
            let sinc = t == 0 ? 1 : sin(Double.pi * t) / (Double.pi * t)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * Double.pi * Double(i) / Double(n - 1))
            h[i] = Float(sinc * w)
        }
        var branches: [[Float]] = []
        for p in 0..<factor {
            var branch = stride(from: p, to: n, by: factor).map { h[$0] }
            let gain = branch.reduce(0, +)
            if gain != 0 { branch = branch.map { $0 / gain } }
            branches.append(branch.reversed())
        }
        phases = branches
        history = Array(repeating: [Float](repeating: 0, count: taps - 1), count: channels)
        truePeak = Array(repeating: 0, count: channels)
    }

    mutating func process(_ channels: [UnsafePointer<Float>], frames: Int) {
        guard frames > 0 else { return }
        if scratch.count < frames + taps - 1 { scratch = [Float](repeating: 0, count: frames + taps - 1) }
        if output.count < frames { output = [Float](repeating: 0, count: frames) }
        for c in channels.indices {
            var peak: Float = 0
            vDSP_maxmgv(channels[c], 1, &peak, vDSP_Length(frames))
            samplePeak = max(samplePeak, peak)
            truePeak[c] = max(truePeak[c], peak)
            guard factor > 1 else { continue }
            scratch.withUnsafeMutableBufferPointer { s in
                history[c].withUnsafeBufferPointer { s.baseAddress!.update(from: $0.baseAddress!, count: taps - 1) }
                (s.baseAddress! + taps - 1).update(from: channels[c], count: frames)
                for branch in phases {
                    branch.withUnsafeBufferPointer { f in
                        output.withUnsafeMutableBufferPointer { o in
                            vDSP_conv(s.baseAddress!, 1, f.baseAddress!, 1, o.baseAddress!, 1,
                                      vDSP_Length(frames), vDSP_Length(taps))
                            var m: Float = 0
                            vDSP_maxmgv(o.baseAddress!, 1, &m, vDSP_Length(frames))
                            truePeak[c] = max(truePeak[c], m)
                        }
                    }
                }
                let keep = taps - 1
                let tail = Array(UnsafeBufferPointer(start: s.baseAddress! + frames, count: keep))
                history[c] = tail
            }
        }
    }
}

// MARK: - Spectrogram

struct SpectrogramBuilder {
    static let fftSize = 2048
    private let log2n = vDSP_Length(11)
    private let columns: Int
    private let rows = 160
    private let starts: [Int64]
    private let rate: Double
    private let minHz = 20.0
    private let maxHz: Double
    private var setup: FFTSetup?
    private var window = [Float](repeating: 0, count: SpectrogramBuilder.fftSize)
    private var collect: [Float] = []
    private var collecting = -1
    private var nextColumn = 0
    private var position: Int64 = 0
    private var values: [UInt8] = []

    init(totalFrames: Int64, rate: Double, columns requested: Int) {
        self.rate = rate
        maxHz = min(24_000, rate / 2)
        let usable = max(0, totalFrames - Int64(Self.fftSize))
        let count = usable > 0 ? max(1, min(requested, Int(usable / Int64(Self.fftSize / 4)))) : 0
        columns = count
        starts = (0..<count).map { count > 1 ? usable * Int64($0) / Int64(count - 1) : 0 }
        setup = columns > 0 ? vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) : nil
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        values.reserveCapacity(columns * rows)
    }

    mutating func process(_ channels: [UnsafePointer<Float>], frames: Int) {
        guard columns > 0 else { return }
        var i = 0
        while i < frames {
            if collecting < 0 {
                guard nextColumn < columns else { return }
                let start = starts[nextColumn]
                if position + Int64(frames - i) <= start { position += Int64(frames - i); return }
                if position < start { let skip = Int(start - position); i += skip; position += Int64(skip) }
                collecting = nextColumn
                collect.removeAll(keepingCapacity: true)
            }
            let take = min(frames - i, Self.fftSize - collect.count)
            for k in 0..<take {
                var s: Float = 0
                for c in channels.indices { s += channels[c][i + k] }
                collect.append(s / Float(channels.count))
            }
            i += take
            position += Int64(take)
            if collect.count == Self.fftSize {
                emitColumn()
                collecting = -1
                nextColumn += 1
            }
        }
    }

    private mutating func emitColumn() {
        guard let setup else { return }
        let n = Self.fftSize, half = n / 2
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(collect, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        // A sine of amplitude A peaks at A·Σw/2 in the DFT, and zrip scales by 2,
        // so a full-scale sine reads Σw.
        let fullScale = window.reduce(0, +)
        let binHz = rate / Double(n)
        for row in 0..<rows {
            let lo = minHz * pow(maxHz / minHz, (Double(row) - 0.5) / Double(rows - 1))
            let hi = minHz * pow(maxHz / minHz, (Double(row) + 0.5) / Double(rows - 1))
            let a = max(1, Int(lo / binHz)), b = min(half - 1, max(a, Int(hi / binHz)))
            var m: Float = 0
            for bin in a...b { m = max(m, mags[bin]) }
            let db = 20 * log10(max(1e-9, Double(m / fullScale)))
            values.append(UInt8(max(0, min(255, (db + 100) / 100 * 255))))
        }
    }

    mutating func finish() -> Spectrogram? {
        if let setup { vDSP_destroy_fftsetup(setup) }
        setup = nil
        let done = values.count / rows
        guard done > 0 else { return nil }
        return Spectrogram(columns: done, rows: rows, minHz: minHz, maxHz: maxHz, values: Array(values.prefix(done * rows)))
    }
}
