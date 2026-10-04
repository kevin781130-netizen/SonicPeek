import XCTest
import AVFAudio
import Accelerate
@testable import PeekCore

/// Routing checks with AVAudioEngine offline rendering: no audio device, no sound.
final class MultichannelPlayerTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("peek-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// 12-channel WAV (no layout in the file, like many exports) with a tone on one channel.
    private func twelve(toneOn channel: Int) throws -> URL {
        let url = dir.appendingPathComponent("tone\(channel).wav")
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 12)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 12, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = 48_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<12 { for i in 0..<frames {
            buffer.floatChannelData![c][i] = c == channel ? 0.3 * sin(2 * .pi * 1000 * Float(i) / 48_000) : 0
        } }
        try file.write(from: buffer)
        return url
    }

    /// Renders 0.5 s offline and returns the RMS of each output channel.
    private func render(_ url: URL, outputChannels: Int) throws -> (MultichannelPlayer.Route, [Float]) {
        let tag = outputChannels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(outputChannels)
        let out = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: AVAudioChannelLayout(layoutTag: tag)!)
        let player = try MultichannelPlayer(url: url, manualOutput: out)
        try player.play(from: 0.1)
        let buffer = AVAudioPCMBuffer(pcmFormat: player.engine.manualRenderingFormat, frameCapacity: 24_000)!
        var rms = [Float](repeating: 0, count: outputChannels)
        var rendered = 0
        while rendered < 24_000 {
            let status = try player.engine.renderOffline(4096, to: buffer)
            XCTAssertEqual(status, .success)
            for c in 0..<outputChannels {
                var r: Float = 0
                vDSP_rmsqv(buffer.floatChannelData![c], 1, &r, vDSP_Length(buffer.frameLength))
                rms[c] = max(rms[c], r)
            }
            rendered += Int(buffer.frameLength)
        }
        player.stop()
        return (player.route, rms)
    }

    func testHeadphonesGetABinauralBedThatKeepsLeftAndRight() throws {
        let (route, left) = try render(try twelve(toneOn: 8), outputChannels: 2)    // Ltf / Vhl
        XCTAssertEqual(route, .binaural(layout: "7.1.4"))
        XCTAssertGreaterThan(left[0], 0.01, "the height channel must be heard")
        XCTAssertGreaterThan(left[0], left[1] * 1.3, "top-front-left lands on the left ear")
        let (_, right) = try render(try twelve(toneOn: 11), outputChannels: 2)      // Rtr
        XCTAssertGreaterThan(right[1], right[0] * 1.3, "top-rear-right lands on the right ear")
    }

    func testWideInterfaceGetsEachChannelUnchanged() throws {
        let (route, rms) = try render(try twelve(toneOn: 9), outputChannels: 16)
        XCTAssertEqual(route, .discrete(fileChannels: 12, deviceChannels: 16))
        XCTAssertEqual(rms[9], 0.3 / sqrt(2), accuracy: 0.02, "channel 10 goes out on output 10 at unity")
        for c in 0..<16 where c != 9 { XCTAssertLessThan(rms[c], 0.001, "output \(c + 1) must stay silent") }
    }

    func testLayoutsForCommonBeds() {
        XCTAssertEqual(MultichannelPlayer.bedLayout(for: 12, fileLayout: nil)?.1, "7.1.4")
        XCTAssertEqual(MultichannelPlayer.bedLayout(for: 6, fileLayout: nil)?.1, "5.1")
        XCTAssertNil(MultichannelPlayer.bedLayout(for: 7, fileLayout: nil))
    }
}
