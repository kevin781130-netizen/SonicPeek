import XCTest
import AVFAudio
@testable import PeekCore

/// Per-channel waveforms, channel labels, and ADM / RF64 detection.
final class MultichannelTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("peek-mc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func writeWAV(_ name: String, channels: Int, frames: Int, sample: (Int, Int) -> Float) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let tag = channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: AVAudioChannelLayout(layoutTag: tag)!)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels { for i in 0..<frames { buffer.floatChannelData![c][i] = sample(c, i) } }
        try file.write(from: buffer)
        return url
    }

    func testEachChannelGetsItsOwnLane() throws {
        // Channel c carries a constant 0.1·(c+1); lanes must not bleed into each other.
        let url = try writeWAV("six.wav", channels: 6, frames: 48_000) { c, _ in 0.1 * Float(c + 1) }
        let lanes = try WaveformGenerator().generateChannels(from: url, bucketCount: 64)
        XCTAssertEqual(lanes.count, 6)
        for (c, lane) in lanes.enumerated() {
            XCTAssertEqual(lane.bucketCount, 64)
            XCTAssertEqual(lane.values.max() ?? 0, 0.1 * Float(c + 1), accuracy: 0.001)
            XCTAssertEqual(lane.values.min() ?? 0, 0.1 * Float(c + 1), accuracy: 0.001)
        }
        let mix = WaveformGenerator.combine(lanes)
        XCTAssertEqual(mix.values.max() ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(mix.values.min() ?? 0, 0.1, accuracy: 0.001)
    }

    func testCombinedLanesMatchTheMixedWaveform() throws {
        let url = try writeWAV("st.wav", channels: 2, frames: 96_000) { c, i in (c == 0 ? 0.5 : -0.25) * sin(Float(i) * 0.01) }
        let mixed = try WaveformGenerator().generate(from: url, bucketCount: 200, style: .minMax)
        let rebuilt = WaveformGenerator.combine(try WaveformGenerator().generateChannels(from: url, bucketCount: 200))
        XCTAssertEqual(mixed, rebuilt)
    }

    func testLayoutNamesFromLabels() {
        XCTAssertEqual(ChannelMap.formatName(ChannelMap.defaultLabels(12)), "7.1.4")
        XCTAssertEqual(ChannelMap.formatName(ChannelMap.defaultLabels(10)), "7.1.2")
        XCTAssertEqual(ChannelMap.formatName(ChannelMap.defaultLabels(6)), "5.1")
        XCTAssertEqual(ChannelMap.formatName(["L", "R", "Ls", "Rs"]), "4.0")
        XCTAssertEqual(ChannelMap.formatName(["L", "R"]), "Stereo")
        XCTAssertNil(ChannelMap.formatName(ChannelMap.defaultLabels(16)))
    }

    /// A file that names its 7.1.4 speakers (as ffmpeg writes them) shows "7.1.4 (…)", not label numbers.
    func testDescribedLayoutGetsAReadableName() throws {
        let tags: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
            kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect,
            kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_LeftTopFront,
            kAudioChannelLabel_RightTopFront, kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_RightTopRear]
        let size = MemoryLayout<AudioChannelLayout>.size + (tags.count - 1) * MemoryLayout<AudioChannelDescription>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        memset(raw, 0, size)
        let acl = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        acl.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        acl.pointee.mNumberChannelDescriptions = UInt32(tags.count)
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let d = raw.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
        for (i, t) in tags.enumerated() { d[i].mChannelLabel = t }
        let layout = AVAudioChannelLayout(layout: acl)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        XCTAssertEqual(ChannelMap.fileLabels(format), ChannelMap.defaultLabels(12))
        func write(_ name: String, _ layout: AVAudioChannelLayout) throws -> AudioMetadata {
            let f = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
            let url = dir.appendingPathComponent(name)
            let file = try AVAudioFile(forWriting: url, settings: f.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480)!
            buffer.frameLength = 480
            try file.write(from: buffer)
            return try MetadataAssembler().assemble(url)
        }
        // CAF keeps the described layout.
        XCTAssertEqual(try write("described-714.caf", layout).channelLayoutName, "7.1.4 (L R C LFE Lss Rss Lrs Rrs Ltf Rtf Ltr Rtr)")
        // A named tag is expanded by Core Audio instead of being printed as hex.
        let atmos = try write("tag-714.caf", AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Atmos_7_1_4)!)
        XCTAssertEqual(atmos.channelLayoutName, "7.1.4 (L R C LFE Ls Rs Lrs Rrs Ltf Rtf Ltr Rtr)")
        XCTAssertEqual(atmos.channelLabels, ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs", "Ltf", "Rtf", "Ltr", "Rtr"])
        // AVAudioFile's WAV writer drops the layout (DiscreteInOrder): say so, don't pretend.
        XCTAssertEqual(try write("discrete-714.wav", layout).channelLayoutName, "Discrete, no speaker labels · shown in 7.1.4 order")
    }

    func testDefaultLabelsAndWeights() {
        XCTAssertEqual(ChannelMap.defaultLabels(6), ["L", "R", "C", "LFE", "Ls", "Rs"])
        XCTAssertEqual(ChannelMap.defaultLabels(12).last, "Rtr")
        XCTAssertEqual(ChannelMap.weight("LFE"), 0)
        XCTAssertEqual(ChannelMap.weight("Lss"), 1.41)
        XCTAssertEqual(ChannelMap.weight("Ltf"), 1.0)
    }

    /// Appends chunks after the audio and patches the RIFF size.
    private func appendChunks(_ url: URL, _ chunks: [(String, Data)]) throws {
        var d = try Data(contentsOf: url)
        for (id, payload) in chunks {
            d.append(id.data(using: .ascii)!)
            var n = UInt32(payload.count).littleEndian
            d.append(Data(bytes: &n, count: 4)); d.append(payload)
            if payload.count % 2 == 1 { d.append(0) }
        }
        var riff = UInt32(d.count - 8).littleEndian
        d.replaceSubrange(4..<8, with: Data(bytes: &riff, count: 4))
        try d.write(to: url)
    }

    func testADMMasterIsRecognised() throws {
        let url = try writeWAV("adm.wav", channels: 2, frames: 4800) { _, _ in 0 }
        // Well-formed BS.2076 chna: 2 tracks, 2 UIDs × 40 bytes (Core Audio rejects inconsistent ones).
        var chna = Data([2, 0, 2, 0])
        for track in 1...2 {
            var uid = Data([UInt8(track), 0]) + Data("ATU_0000000\(track)".utf8) + Data("AT_00010001_01".utf8) + Data("AP_00010001".utf8)
            uid.append(Data(count: 40 - uid.count))
            chna.append(uid)
        }
        try appendChunks(url, [("chna", chna), ("axml", Data("<ebuCoreMain/>".utf8)), ("dbmd", Data(count: 16))])
        let md = try MetadataAssembler().assemble(url)
        XCTAssertTrue(md.isADM)
        XCTAssertEqual(md.admTrackCount, 2)
        XCTAssertTrue(md.hasDolbyMetadata)
        XCTAssertFalse(md.isRF64)
    }

    /// A 7.1.4 ADM master without speaker labels in its WAVE header says where the layout lives.
    func testADMBedLayoutIsAttributedToADM() throws {
        let url = try writeWAV("adm-714.wav", channels: 12, frames: 4800) { _, _ in 0 }
        var chna = Data([12, 0, 12, 0])
        for track in 1...12 {
            var uid = Data([UInt8(track), 0]) + Data(String(format: "ATU_%08d", track).utf8)
                + Data(String(format: "AT_%08X_01", 0x00010000 + track).utf8) + Data(String(format: "AP_%08X", 0x00010000 + track).utf8)
            uid.append(Data(count: 40 - uid.count))
            chna.append(uid)
        }
        try appendChunks(url, [("chna", chna), ("axml", Data("<ebuCoreMain/>".utf8))])
        let md = try MetadataAssembler().assemble(url)
        XCTAssertTrue(md.isADM)
        XCTAssertEqual(md.channelLayoutName, "Defined by ADM (chna) · shown in 7.1.4 order")
        XCTAssertEqual(md.channelLabels, ChannelMap.defaultLabels(12))
    }

    func testPlainWAVIsNotADM() throws {
        let url = try writeWAV("plain.wav", channels: 2, frames: 4800) { _, _ in 0 }
        try appendChunks(url, [("axml", Data("<x/>".utf8))])   // axml alone is not an ADM master
        let md = try MetadataAssembler().assemble(url)
        XCTAssertFalse(md.isADM)
        XCTAssertNil(md.admTrackCount)
        XCTAssertEqual(md.channelLabels, ["L", "R"])
    }

    func testRF64UsesTheDs64Sizes() throws {
        // RF64 header, ds64 with real sizes, fmt, a small data chunk declared 0xFFFFFFFF, then iXML.
        func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
        func le64(_ v: UInt64) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 8) }
        let audio = Data(count: 64)
        let ixml = Data("<BWFXML><PROJECT>RF</PROJECT></BWFXML>".utf8)
        var body = Data("WAVE".utf8)
        let riffSize = UInt64(4 + (8 + 28) + (8 + 16) + (8 + audio.count) + (8 + ixml.count))
        body += Data("ds64".utf8) + le32(28) + le64(riffSize) + le64(UInt64(audio.count)) + le64(16) + le32(0)
        body += Data("fmt ".utf8) + le32(16) + Data([1, 0, 1, 0]) + le32(48_000) + le32(96_000) + Data([2, 0, 16, 0])
        body += Data("data".utf8) + le32(0xFFFF_FFFF) + audio
        body += Data("iXML".utf8) + le32(UInt32(ixml.count)) + ixml
        let file = Data("RF64".utf8) + le32(0xFFFF_FFFF) + body
        let c = try XCTUnwrap(RIFFParser().parse(data: file))
        XCTAssertTrue(c.isRF64)
        XCTAssertFalse(c.truncated)
        XCTAssertEqual(c.chunkIDs, ["ds64", "fmt ", "data", "iXML"])
        XCTAssertEqual(c.chunks.first { $0.id == "iXML" }?.payload, ixml)
    }
}
