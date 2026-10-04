import Foundation

/// RIFF/RIFX walker. Chunk lengths exclude the odd-byte padding.
/// File scans seek over audio/unknown payloads and only retain bext/iXML/chna.
/// Budgets apply to retained metadata, never to the audio file size.
public struct RIFFParser {
    public struct Chunk: Equatable, Sendable {
        public let id: String
        public let payload: Data
        public let offset: UInt64
    }
    public struct Container: Equatable, Sendable {
        public let formType: String
        public let chunks: [Chunk]
        public let truncated: Bool
        /// Every chunk id seen, in order, including ones whose payload was skipped
        /// (e.g. `axml` / `dbmd` presence marks an ADM / Dolby Atmos master).
        public var chunkIDs: [String] = []
        public var isRF64 = false
        public init(formType: String, chunks: [Chunk], truncated: Bool, chunkIDs: [String] = [], isRF64: Bool = false) {
            self.formType = formType; self.chunks = chunks; self.truncated = truncated
            self.chunkIDs = chunkIDs; self.isRF64 = isRF64
        }
    }
    public struct Options {
        public var maxChunkBytes: Int
        public var maxTotalBytes: Int
        public static let `default` = Options(maxChunkBytes: 1024 * 1024, maxTotalBytes: 4 * 1024 * 1024)
        public init(maxChunkBytes: Int, maxTotalBytes: Int) {
            self.maxChunkBytes = maxChunkBytes
            self.maxTotalBytes = maxTotalBytes
        }
    }
    public init() {}

    public func scan(url: URL, options: Options = .default,
                     isCancelled: () -> Bool = { false }) throws -> Container? {
        if isCancelled() { throw CancellationError() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        return try walk(size: size, options: options, metadataOnly: true, isCancelled: isCancelled) { offset, count in
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        }
    }

    /// In-memory compatibility API; retains all small chunks for regression tests.
    public func parse(data: Data, options: Options = .default) -> Container? {
        try? walk(size: UInt64(data.count), options: options, metadataOnly: false, isCancelled: { false }) { offset, count in
            let start = Int(offset)
            return data.subdata(in: start..<min(data.count, start + count))
        }
    }

    private func walk(size: UInt64, options: Options, metadataOnly: Bool,
                      isCancelled: () -> Bool,
                      read: (UInt64, Int) throws -> Data) throws -> Container? {
        guard size >= 12, options.maxChunkBytes >= 0, options.maxTotalBytes >= 4 else { return nil }
        let header = try read(0, 12)
        guard header.count == 12 else { return nil }
        let magic = String(decoding: header.prefix(4), as: UTF8.self)
        guard magic == "RIFF" || magic == "RIFX" || magic == "RF64" else { return nil }
        let little = magic != "RIFX"
        func u32(_ bytes: Data, _ start: Int) -> UInt64 {
            let b = Array(bytes[start..<start+4])
            return (0..<4).reduce(UInt64(0)) { $0 | UInt64(b[$1]) << (8 * (little ? $1 : 3 - $1)) }
        }
        func ascii(_ bytes: Data) -> Bool { bytes.allSatisfy { $0 >= 32 && $0 < 127 } }
        func u64(_ bytes: Data, _ start: Int) -> UInt64 {
            let b = Array(bytes[start..<start+8])
            return (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[$1]) << (8 * $1) }
        }
        var declared = u32(header, 4)
        guard ascii(header.subdata(in: 8..<12)) else { return nil }
        // RF64 (EBU Tech 3306): 32-bit sizes are 0xFFFFFFFF and the real 64-bit
        // RIFF and data sizes live in the mandatory first `ds64` chunk.
        var ds64Data: UInt64?
        if magic == "RF64" {
            guard size >= 36 else { return nil }
            let ds = try read(12, 24)
            guard ds.count == 24, String(decoding: ds.prefix(4), as: UTF8.self) == "ds64" else { return nil }
            declared = u64(ds, 8)
            ds64Data = u64(ds, 16)
        }
        guard declared >= 4 else { return nil }
        let end = min(size, declared + 8)
        var truncated = declared + 8 > size
        var cursor: UInt64 = 12
        var budget = options.maxTotalBytes
        var chunks: [Chunk] = []
        var ids: [String] = []
        var count = 0
        while cursor < end {
            if isCancelled() { throw CancellationError() }
            guard count < 65_536, end - cursor >= 8 else { truncated = true; break }
            count += 1
            let h = try read(cursor, 8)
            guard h.count == 8, ascii(h.prefix(4)) else { truncated = true; break }
            let id = String(decoding: h.prefix(4), as: UTF8.self)
            var length = u32(h, 4)
            if length == 0xFFFF_FFFF, id == "data", let big = ds64Data { length = big }
            if ids.count < 256 { ids.append(id) }
            let payloadStart = cursor + 8
            guard length <= end - payloadStart else { truncated = true; break }
            let capture = !metadataOnly || id == "bext" || id == "iXML" || id == "chna"
            if capture {
                if length <= UInt64(min(options.maxChunkBytes, budget)) {
                    let payload = try read(payloadStart, Int(length))
                    guard payload.count == Int(length) else { truncated = true; break }
                    chunks.append(Chunk(id: id, payload: payload, offset: cursor))
                    budget -= payload.count
                } else {
                    // Skip oversize metadata intact; never feed a truncated XML prefix to a parser.
                    truncated = true
                }
            }
            cursor = payloadStart + length + (length & 1)
            if cursor > end { truncated = true }
        }
        return Container(formType: String(decoding: header[8..<12], as: UTF8.self), chunks: chunks, truncated: truncated,
                         chunkIDs: ids, isRF64: magic == "RF64")
    }
}
