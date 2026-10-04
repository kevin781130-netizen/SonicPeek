import Foundation

/// Decoded Broadcast Wave Extension (`bext`) chunk.
///
/// The `bext` chunk is a fixed-prefix (602 bytes) followed by optional
/// variable-length fields. We decode the prefix strictly and decode the
/// variable fields defensively. EBU Tech 3285 specifies the layout;
/// the version we decode is v0 (the most common).
public struct BWFChunk: Equatable, Sendable {

    /// BWF time reference, two fields:
    /// * `samples` — total sample count since midnight (UInt64 LE).
    /// * `seconds` — derived from `samples / sampleRate`. Caller
    ///   supplies the sample rate.
    public let description: String
    public let originator: String
    public let originatorReference: String
    public let originationDate: String       // "YYYY-MM-DD"
    public let originationTime: String       // "HH:MM:SS"
    public let timeReferenceSamples: UInt64
    public let version: UInt16

    public var timeReferenceSeconds: Double? = nil   // populated when caller provides sample rate

    public init(
        description: String,
        originator: String,
        originatorReference: String,
        originationDate: String,
        originationTime: String,
        timeReferenceSamples: UInt64,
        version: UInt16
    ) {
        self.description = description
        self.originator = originator
        self.originatorReference = originatorReference
        self.originationDate = originationDate
        self.originationTime = originationTime
        self.timeReferenceSamples = timeReferenceSamples
        self.version = version
    }

    /// Parse a `bext` chunk payload. Payload must be ≥ 602 bytes
    /// (the v0 fixed-size prefix). Truncated / undersized input yields
    /// nil.
    public static func parse(payload: Data) -> BWFChunk? {
        guard payload.count >= 602 else { return nil }

        func fixedString(_ range: Range<Int>) -> String {
            let slice = payload.subdata(in: range)
            // Strip trailing NULs.
            var end = slice.count
            while end > 0 && slice[end - 1] == 0 { end -= 1 }
            let trimmed = slice.prefix(end)
            // Modern recorders write UTF-8 (e.g. "joé"); older tools wrote
            // Latin-1. ASCII-only data decodes identically either way, so the
            // fallback chain never changes plain-ASCII results.
            return String(data: trimmed, encoding: .utf8)
                ?? String(data: trimmed, encoding: .isoLatin1) ?? ""
        }

        let description = fixedString(0..<256)
        let originator = fixedString(256..<288)
        let originatorReference = fixedString(288..<320)
        let originationDate = fixedString(320..<330)  // "YYYY-MM-DD\0"
        let originationTime = fixedString(330..<338)  // "HH:MM:SS\0"

        // Time reference (8 bytes LE) at offset 338.
        let timeLo = readUInt32LE(payload, at: 338)
        let timeHi = readUInt32LE(payload, at: 342)
        guard let lo = timeLo, let hi = timeHi else { return nil }
        let timeRef = UInt64(lo) | (UInt64(hi) << 32)

        // Version at offset 346 (2 bytes LE).
        let versionLo = payload[346]
        let versionHi = payload[347]
        let version = UInt16(versionLo) | (UInt16(versionHi) << 8)

        return BWFChunk(
            description: description,
            originator: originator,
            originatorReference: originatorReference,
            originationDate: originationDate,
            originationTime: originationTime,
            timeReferenceSamples: timeRef,
            version: version
        )
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { raw -> UInt32 in
            let p = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UInt32(p[0])
                | (UInt32(p[1]) << 8)
                | (UInt32(p[2]) << 16)
                | (UInt32(p[3]) << 24)
        }
    }
}
