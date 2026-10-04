import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import PeekCore

final class ParserTests: XCTestCase {
    func testRejectsShortAndNonRIFFData() {
        XCTAssertNil(RIFFParser().parse(data: Data()))
        XCTAssertNil(RIFFParser().parse(data: Data(repeating: 0, count: 12)))
    }

    func testOddChunkPadding() throws {
        var bytes = Data("RIFF".utf8)
        for part in [le(24), Data("WAVE".utf8), Data("JUNK".utf8), le(1), Data([42, 0]), Data("data".utf8), le(2), Data([1, 2])] {
            bytes.append(part)
        }
        let result = try XCTUnwrap(RIFFParser().parse(data: bytes))
        XCTAssertEqual(result.formType, "WAVE")
        XCTAssertEqual(result.chunks.map(\.id), ["JUNK", "data"])
        XCTAssertEqual(result.chunks.first?.payload, Data([42]))
        XCTAssertFalse(result.truncated)
    }

    func testDoesNotReadPastDeclaredContainer() throws {
        let bytes = Data("RIFF".utf8) + le(12) + Data("WAVE".utf8)
            + Data("bext".utf8) + le(4) + Data([1, 2, 3, 4])
        let result = try XCTUnwrap(RIFFParser().parse(data: bytes))
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.chunks.isEmpty)
    }

    func testTruncatedContainerIsMarked() throws {
        let bytes = Data("RIFF".utf8) + le(100) + Data("WAVE".utf8)
        XCTAssertTrue(try XCTUnwrap(RIFFParser().parse(data: bytes)).truncated)
    }

    func testBWFTimeReferenceKeepsHighWord() throws {
        var payload = Data(repeating: 0, count: 602)
        payload.replaceSubrange(338..<342, with: le(48_000))
        payload.replaceSubrange(342..<346, with: le(1))
        payload[346] = 2
        let bwf = try XCTUnwrap(BWFChunk.parse(payload: payload))
        XCTAssertEqual(bwf.timeReferenceSamples, (UInt64(1) << 32) + 48_000)
        XCTAssertEqual(bwf.version, 2)
        XCTAssertNil(BWFChunk.parse(payload: payload.prefix(601)))
    }

    func testWAVTypeProbe() {
        let result = UTTypeProbe.probe(URL(fileURLWithPath: "/nonexistent/test.wav"))
        XCTAssertEqual(result.utType.identifier, "com.microsoft.waveform-audio")
        XCTAssertTrue(result.isSupported)
    }

    // MARK: - Additional RIFF coverage

    func testRIFFParsesMinimalWAVE() throws {
        // RIFF size = bytes from WAVE..end-of-chunks (4+8+16=28).
        var bytes = Data("RIFF".utf8)
        bytes.append(le(28))
        bytes.append(Data("WAVE".utf8))
        bytes.append(Data("fmt ".utf8))
        bytes.append(le(16))
        bytes.append(Data(repeating: 0, count: 16))
        let container = try XCTUnwrap(RIFFParser().parse(data: bytes))
        XCTAssertEqual(container.formType, "WAVE")
        XCTAssertEqual(container.chunks.map(\.id), ["fmt "])
        XCTAssertEqual(container.chunks.first?.payload.count, 16)
        XCTAssertFalse(container.truncated)
    }

    func testRIFFRejectsBadMagic() {
        var bytes = Data([0,0,0,0])
        bytes.append(le(8))
        bytes.append(Data("WAVE".utf8))
        XCTAssertNil(RIFFParser().parse(data: bytes))
    }

    func testRIFFBoundsHugeChunk() throws {
        var bytes = Data("RIFF".utf8)
        bytes.append(le(200))
        bytes.append(Data("WAVE".utf8))
        bytes.append(Data("JUNK".utf8))
        bytes.append(le(100 * 1024 * 1024))   // 100 MiB claim
        bytes.append(contentsOf: [0x00, 0x01, 0x02, 0x03])
        let opts = RIFFParser.Options(maxChunkBytes: 1024, maxTotalBytes: 1024 * 1024)
        let container = try XCTUnwrap(RIFFParser().parse(data: bytes, options: opts))
        XCTAssertTrue(container.truncated)
    }

    // MARK: - iXML

    func testIXMLChunkParsesBasicFields() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <BWFXML>
          <PROJECT>Demo</PROJECT>
          <SCENE>01</SCENE>
          <TAPE>A001</TAPE>
          <TRACK>1</TRACK>
          <NOTE>tracked on 2026-09-17</NOTE>
        </BWFXML>
        """
        let chunk = IXMLChunk.parse(payload: Data(xml.utf8))
        XCTAssertEqual(chunk?.project, "Demo")
        XCTAssertEqual(chunk?.scene, "01")
        XCTAssertEqual(chunk?.tape, "A001")
        XCTAssertEqual(chunk?.track, "1")
        XCTAssertEqual(chunk?.notes, "tracked on 2026-09-17")
    }

    func testIXMLChunkReturnsNilOnGarbage() {
        XCTAssertNil(IXMLChunk.parse(payload: Data([0xFF, 0xFE, 0x00, 0x01])))
    }

    func testIXMLChunkMissingFieldsAreNil() {
        let chunk = IXMLChunk.parse(payload: Data("<BWFXML></BWFXML>".utf8))
        XCTAssertNotNil(chunk)
        XCTAssertNil(chunk?.project)
        XCTAssertNil(chunk?.scene)
    }

    // MARK: - Magic byte sniffer

    func testMagicByteSniffDetectsWAVE() {
        var head = Data("RIFF".utf8)
        head.append(contentsOf: [0x24, 0x00, 0x00, 0x00])
        head.append(Data("WAVE".utf8))
        XCTAssertEqual(MagicByteSniff.detect(head: head)?.utType, UTType.wav)
    }

    func testMagicByteSniffDetectsID3() {
        let head = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
        XCTAssertEqual(MagicByteSniff.detect(head: head)?.utType, UTType.mp3)
    }

    func testMagicByteSniffDetectsCAF() {
        XCTAssertEqual(MagicByteSniff.detect(head: Data("caff".utf8))?.utType,
                       UTType("com.apple.coreaudio-format"))
    }

    func testMagicByteSniffDetectsFLAC() {
        XCTAssertEqual(MagicByteSniff.detect(head: Data("fLaC".utf8))?.utType,
                       UTType("org.xiph.flac"))
    }

    func testMagicByteSniffDetectsAIFF() {
        var head = Data("FORM".utf8)
        head.append(contentsOf: [0, 0, 0, 0])
        head.append(Data("AIFF".utf8))
        XCTAssertEqual(MagicByteSniff.detect(head: head)?.utType, UTType.aiff)
    }

    func testMagicByteSniffDetectsMP4() {
        var head = Data([0,0,0,0])
        head.append(Data("ftyp".utf8))
        head.append(Data("M4A ".utf8))
        XCTAssertEqual(MagicByteSniff.detect(head: head)?.utType, UTType.mpeg4Audio)
    }

    func testMagicByteSniffReturnsNilForUnknown() {
        XCTAssertNil(MagicByteSniff.detect(head: Data([0x00, 0x01, 0x02, 0x03])))
    }

    private func le(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    // Reviewer regression: non-ASCII bext description (UTF-8 "joé") must not be
    // silently dropped to "" by an ASCII-only decoder.
    func testBWFDescriptionPreservesNonAsciiUTF8() {
        var desc = Data("joé — session take".utf8)
        while desc.count < 256 { desc.append(0) }
        var payload = desc
        let rest = Data(repeating: 0, count: 602 - 256)
        payload.append(rest)
        let parsed = BWFChunk.parse(payload: payload)
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed?.description.hasPrefix("joé") == true, "got \(parsed?.description ?? "nil")")
    }

    func testBWFDescriptionPreservesLatin1Fallback() {
        // Latin-1 é (0xE9) is invalid UTF-8; must fall back, not drop.
        var desc = Data([0x6A, 0x6F, 0xE9])  // "joé" in Latin-1
        while desc.count < 256 { desc.append(0) }
        var payload = desc
        payload.append(Data(repeating: 0, count: 602 - 256))
        let parsed = BWFChunk.parse(payload: payload)
        XCTAssertEqual(parsed?.description, "joé")
    }
}
