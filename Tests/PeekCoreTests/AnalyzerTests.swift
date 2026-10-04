import XCTest
import AVFAudio
@testable import PeekCore

/// Loudness / true-peak / spectrogram checks on synthetic signals with known answers.
/// Reference values were also cross-checked against ffmpeg's ebur128 filter
/// (integrated and LRA within 0.1 LU on pink noise, 5.1, 44.1 / 48 / 96 kHz).
final class AnalyzerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("peek-analyzer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Writes a float WAV; `sample(channel, frame)` supplies each value.
    private func write(_ name: String, channels: Int, rate: Double = 48_000, seconds: Double,
                       layout: AudioChannelLayoutTag? = nil,
                       sample: (Int, Int) -> Float) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format: AVAudioFormat
        if let layout, let l = AVAudioChannelLayout(layoutTag: layout) {
            format = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: l)
        } else {
            let tag = channels <= 2 ? (channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo)
                : kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
            format = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: AVAudioChannelLayout(layoutTag: tag)!)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels { for i in 0..<frames { buffer.floatChannelData![c][i] = sample(c, i) } }
        try file.write(from: buffer)
        return url
    }

    func testStereoSineReadsItsLevelInLUFS() throws {
        // EBU Tech 3341: a 997 Hz sine at −23 dBFS in both channels measures −23 LUFS.
        let a = Float(pow(10, -23.0 / 20))
        let url = try write("sine.wav", channels: 2, seconds: 10) { _, i in a * sin(2 * .pi * 997 * Float(i) / 48_000) }
        let r = try AudioAnalyzer().analyze(url: url)
        XCTAssertEqual(r.integratedLUFS ?? 0, -23, accuracy: 0.1)
        XCTAssertEqual(r.loudnessRangeLU ?? 99, 0, accuracy: 0.1)
        XCTAssertEqual(r.samplePeakDBFS ?? 0, -23, accuracy: 0.05)
        XCTAssertEqual(r.truePeakDBTP ?? 0, -23, accuracy: 0.1)
    }

    func testTruePeakFindsTheInterSamplePeak() throws {
        // fs/4 sine at 45° phase: every sample sits at 0.9·√½, the waveform peaks at 0.9.
        let url = try write("isp.wav", channels: 2, seconds: 2) { _, i in
            // Exact cycle (+, +, −, −)·0.9√½; computing sin(π/2·i) in Float drifts for large i.
            0.9 * 0.70710678 * (i % 4 < 2 ? 1 : -1)
        }
        let r = try AudioAnalyzer().analyze(url: url)
        XCTAssertEqual(r.samplePeakDBFS ?? 0, 20 * log10(0.9 * 0.70710678), accuracy: 0.05)
        XCTAssertEqual(r.truePeakDBTP ?? -99, 20 * log10(0.9), accuracy: 0.2)
        XCTAssertGreaterThan(r.truePeakDBTP ?? -99, (r.samplePeakDBFS ?? 0) + 2.5, "true peak must exceed the sample peak here")
    }

    func testLFEIsExcludedAndSurroundsWeighted() throws {
        let tone: (Int) -> Float = { i in 0.1 * sin(2 * .pi * 997 * Float(i) / 48_000) }
        // Default 6-channel order: L R C LFE Ls Rs.
        let front = try write("front.wav", channels: 6, seconds: 5) { c, i in c == 0 ? tone(i) : 0 }
        let lfe = try write("lfe.wav", channels: 6, seconds: 5) { c, i in c == 3 ? tone(i) : 0 }
        let surround = try write("ls.wav", channels: 6, seconds: 5) { c, i in c == 4 ? tone(i) : 0 }
        let a = AudioAnalyzer()
        let l = try a.analyze(url: front).integratedLUFS
        XCTAssertNotNil(l)
        XCTAssertNil(try a.analyze(url: lfe).integratedLUFS, "LFE alone carries no programme loudness")
        XCTAssertEqual((try a.analyze(url: surround).integratedLUFS ?? 0) - (l ?? 0), 10 * log10(1.41), accuracy: 0.05)
    }

    func testSilenceHasNoLoudness() throws {
        let url = try write("silence.wav", channels: 2, seconds: 3) { _, _ in 0 }
        let r = try AudioAnalyzer().analyze(url: url)
        XCTAssertNil(r.integratedLUFS)
        XCTAssertNil(r.truePeakDBTP)
        XCTAssertNil(r.samplePeakDBFS)
    }

    func testLoudnessRangeSeesTwoLevels() throws {
        // 10 s at one level, 10 s 12 dB lower: LRA ≈ 12 LU (well inside the −20 LU gate).
        let url = try write("steps.wav", channels: 2, seconds: 20) { _, i in
            let a: Float = i < 480_000 ? 0.25 : 0.25 * pow(10, -12 / 20)
            return a * sin(2 * .pi * 997 * Float(i) / 48_000)
        }
        let lra = try AudioAnalyzer().analyze(url: url).loudnessRangeLU ?? 0
        XCTAssertEqual(lra, 12, accuracy: 0.6)
    }

    func testSpectrogramPutsASineInTheRightRow() throws {
        let url = try write("spec.wav", channels: 1, seconds: 4) { _, i in 0.5 * sin(2 * .pi * 1000 * Float(i) / 48_000) }
        let s = try XCTUnwrap(try AudioAnalyzer().analyze(url: url).spectrogram)
        XCTAssertGreaterThan(s.columns, 10)
        let column = Array(s.values[(s.columns / 2 * s.rows)..<((s.columns / 2 + 1) * s.rows)])
        let loudest = column.indices.max { column[$0] < column[$1] }!
        XCTAssertEqual(s.frequency(row: Double(loudest)), 1000, accuracy: 60)
        // −6 dBFS sine → about (−6 + 100)/100 of full scale.
        XCTAssertEqual(Double(column[loudest]), 255 * 0.94, accuracy: 10)
        XCTAssertLessThan(Double(column[s.rows - 5]), 255 * 0.3, "no energy near Nyquist")
    }

    func testCancellationStopsTheAnalysis() throws {
        let url = try write("cancel.wav", channels: 2, seconds: 5) { _, i in sin(Float(i)) * 0.1 }
        XCTAssertThrowsError(try AudioAnalyzer().analyze(url: url, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}
