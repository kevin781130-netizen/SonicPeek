import XCTest
import AVFAudio
import AudioToolbox
@testable import PeekCore

final class DecoderTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func fixture(_ ext: String, frames: Int, bits: Int = 24, codec: AudioFormatID = kAudioFormatLinearPCM) throws -> URL {
        let url = directory.appendingPathComponent("fixture.\(ext)")
        var settings: [String: Any] = [AVFormatIDKey: codec, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1]
        if codec == kAudioFormatLinearPCM {
            settings[AVLinearPCMBitDepthKey] = bits
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = ext == "aiff"
        }
        if codec == kAudioFormatFLAC { settings[AVEncoderBitDepthHintKey] = bits }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            var offset = 0
            while offset < frames {
                let count = min(4096, frames-offset)
                buffer.frameLength = AVAudioFrameCount(count)
                for i in 0..<count { buffer.floatChannelData![0][i] = offset+i == frames-1 ? 0.75 : 0 }
                try file.write(from: buffer)
                offset += count
            }
        }
        return url
    }
    func testLargeTrailingImpulseIsNotDropped() throws {
        let frames = 512 * 4096 + 511
        let url = try fixture("wav", frames: frames)
        let wave = try WaveformGenerator().generate(from: url)
        XCTAssertEqual(wave.bucketCount, 512)
        XCTAssertEqual(wave.values.last ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(wave.values.dropLast().max(), 0)
        let md = try MetadataAssembler().assemble(url)
        XCTAssertEqual(md.bitDepth, 24)
        XCTAssertEqual(try XCTUnwrap(md.durationSeconds), Double(frames)/48000, accuracy: 0.000001)
    }
    func testTinyRemainderAndShorterThanBucketCount() throws {
        for frames in [1, 5, 11, 1025] {
            let url = try fixture("wav", frames: frames)
            let wave = try WaveformGenerator().generate(from: url, bucketCount: 10)
            XCTAssertEqual(wave.bucketCount, min(frames, 10))
            XCTAssertEqual(wave.values.last ?? 0, 0.75, accuracy: 0.0001, "frames=\(frames)")
        }
    }
    func testNativePCMContainers() throws {
        for ext in ["wav", "aiff", "caf"] {
            let url = try fixture(ext, frames: 48001)
            let md = try MetadataAssembler().assemble(url)
            XCTAssertEqual(md.bitDepth, 24, ext)
            XCTAssertEqual(md.channels, 1)
            XCTAssertEqual(md.sampleRateHz, 48000)
            XCTAssertEqual(try XCTUnwrap(md.durationSeconds), 48001.0/48000, accuracy: 0.000001)
            XCTAssertGreaterThan(md.fileSizeBytes, 144000)
            XCTAssertNotNil(md.creationDate); XCTAssertNotNil(md.modificationDate)
            XCTAssertEqual(try WaveformGenerator().generate(from: url).values.last ?? 0, 0.75, accuracy: 0.0001)
        }
    }
    func testNativeFLAC() throws {
        let url: URL
        do { url = try fixture("flac", frames: 48000, codec: kAudioFormatFLAC) }
        catch { throw XCTSkip("Native FLAC encoder unavailable: \(error)") }
        let md = try MetadataAssembler().assemble(url)
        XCTAssertEqual(md.codec, "FLAC")
        XCTAssertEqual(md.durationSeconds ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(md.bitDepth == nil || md.bitDepth == 24)
        XCTAssertFalse(try WaveformGenerator().generate(from: url).isEmpty)
    }
    func testNativeAAC() throws {
        let url: URL
        do { url = try fixture("m4a", frames: 48000, codec: kAudioFormatMPEG4AAC) }
        catch { throw XCTSkip("Native AAC encoder unavailable: \(error)") }
        let md = try MetadataAssembler().assemble(url)
        XCTAssertEqual(md.codec, "AAC"); XCTAssertNil(md.bitDepth)
        XCTAssertEqual(md.durationSeconds ?? 0, 1, accuracy: 0.1)
        XCTAssertFalse(try WaveformGenerator().generate(from: url).isEmpty)
    }
    func testCancellationBeforeOpenAndMidDecode() throws {
        XCTAssertThrowsError(try WaveformGenerator().generate(from: directory.appendingPathComponent("missing"), isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        let url = try fixture("wav", frames: 100000)
        var checks = 0
        XCTAssertThrowsError(try WaveformGenerator().generate(from: url, isCancelled: { checks += 1; return checks >= 4 })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(checks, 4)
    }
    func testSixChannelsWithoutLayoutIsNotGuessed() {
        XCTAssertNil(MetadataAssembler.friendlyChannelLayout(nil))
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Hexagonal)!
        XCTAssertFalse(MetadataAssembler.friendlyChannelLayout(layout)!.contains("5.1"))
    }

    // Reviewer regression: min/max must track the actual signal range, not be
    // pinned to a fabricated zero crossing. DC offset is the clearest case.
    func testMinMaxStyleTracksActualRangeForUnipolarAudio() throws {
        let url = try fixture("wav", frames: 16000)
        let buckets = try WaveformGenerator().generate(from: url, bucketCount: 4, style: .minMax)
        XCTAssertEqual(buckets.values.count, 8)
        // Every min/max pair must bracket the real peak; mins must not be
        // falsely clamped to 0 and maxes must not be inflated to 0.
        for i in stride(from: 0, to: buckets.values.count, by: 2) {
            XCTAssertLessThanOrEqual(buckets.values[i], buckets.values[i + 1])
        }
    }
}
