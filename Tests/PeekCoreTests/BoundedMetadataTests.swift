import XCTest
@testable import PeekCore

final class BoundedMetadataTests: XCTestCase {
    func testXMLRejectsMalformedOversizeAndEntities() {
        for text in ["<BWFXML><PROJECT>broken</BWFXML>",
                     "<!DOCTYPE BWFXML SYSTEM 'https://example.invalid/test'><BWFXML/>",
                     "<!DOCTYPE BWFXML [<!ENTITY a 'expansion'>]><BWFXML><NOTE>&a;</NOTE></BWFXML>",
                     "<BWFXML>" + String(repeating: "<N>", count: 40) + String(repeating: "</N>", count: 40) + "</BWFXML>"] {
            XCTAssertNil(IXMLChunk.parse(payload: Data(text.utf8)))
        }
        XCTAssertNil(IXMLChunk.parse(payload: Data("<BWFXML/>".utf8), maxBytes: 2))
        XCTAssertNil(IXMLChunk.parse(payload: Data(), maxBytes: -1))
    }
    func testXMLCharacterReferencesCDATAAndTracks() {
        let xml = "<BWFXML><PROJECT>A &amp; B</PROJECT><NOTE><![CDATA[x < y]]></NOTE><TRACK_LIST><TRACK><NAME>Boom</NAME></TRACK></TRACK_LIST></BWFXML>"
        let result = IXMLChunk.parse(payload: Data(xml.utf8))
        XCTAssertEqual(result?.project, "A & B")
        XCTAssertEqual(result?.notes, "x < y")
        XCTAssertEqual(result?.track, "Boom")
    }
    func testMetadataAfterLargeSparseAudioChunk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let audioBytes: UInt32 = 1024 * 1024 * 1024 + 2
        let xml = Data("<BWFXML><PROJECT>After audio</PROJECT></BWFXML>".utf8)
        let padded = xml.count + (xml.count & 1)
        try handle.write(contentsOf: Data("RIFF".utf8) + le(4 + 8 + audioBytes + 8 + UInt32(padded)) + Data("WAVEdata".utf8) + le(audioBytes))
        try handle.seek(toOffset: 20 + UInt64(audioBytes))
        try handle.write(contentsOf: Data("iXML".utf8) + le(UInt32(xml.count)) + xml + Data(repeating: 0, count: xml.count & 1))
        try handle.close()
        let parsed = try XCTUnwrap(RIFFParser().scan(url: url, options: .init(maxChunkBytes: 1024, maxTotalBytes: 2048)))
        XCTAssertFalse(parsed.truncated)
        XCTAssertEqual(parsed.chunks.map(\.id), ["iXML"])
        XCTAssertEqual(IXMLChunk.parse(payload: parsed.chunks[0].payload)?.project, "After audio")
        XCTAssertThrowsError(try RIFFParser().scan(url: url, isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
    }
    func testScanPreservesDeclaredBoundaryAndTruncationRegressions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for data in [Data("RIFF".utf8) + le(12) + Data("WAVEbext".utf8) + le(4) + Data([1,2,3,4]),
                     Data("RIFF".utf8) + le(100) + Data("WAVE".utf8)] {
            try data.write(to: url)
            let result = try XCTUnwrap(RIFFParser().scan(url: url))
            XCTAssertTrue(result.truncated)
            XCTAssertTrue(result.chunks.isEmpty)
        }
    }
    private func le(_ v: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: v >> ($0*8)) }) }
}
