import Foundation
import AVFAudio
import AVFoundation
import AudioToolbox

/// Synchronous file inspection is called only on the detached preview worker.
public struct MetadataAssembler {
    public init() {}
    public func assemble(_ url: URL, isCancelled: () -> Bool = { false }) throws -> AudioMetadata {
        if isCancelled() { throw CancellationError() }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let probe = UTTypeProbe.probe(url)
        let file = try AVAudioFile(forReading: url)
        let original = file.fileFormat
        let rate = file.processingFormat.sampleRate
        var md = AudioMetadata(fileName: url.lastPathComponent,
            fileSizeBytes: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
            containerUTType: probe.utType.identifier, containerDescription: probe.displayName,
            codec: Self.codecHint(original),
            durationSeconds: rate > 0 ? Double(file.length) / rate : nil,
            sampleRateHz: rate, bitDepth: Self.bitDepth(original),
            channels: Int(original.channelCount), channelLayoutName: Self.friendlyChannelLayout(original.channelLayout),
            creationDate: attrs[.creationDate] as? Date, modificationDate: attrs[.modificationDate] as? Date)
        md.channelLabels = ChannelMap.resolve(original).labels
        // Raw label numbers / bitmaps mean nothing to a reader: name the layout the file declares.
        if let raw = md.channelLayoutName, ["Channel labels", "Speaker bitmap", "Layout tag"].contains(where: raw.hasPrefix) {
            if let labels = ChannelMap.fileLabels(original), let name = ChannelMap.formatName(labels) {
                md.channelLayoutName = "\(name) (\(labels.joined(separator: " ")))"
            } else {
                let discrete = (original.channelLayout?.layoutTag ?? 0) & 0xFFFF0000 == kAudioChannelLayoutTag_DiscreteInOrder
                let what = discrete ? "Discrete, no speaker labels" : "Speaker labels not recognised"
                md.channelLayoutName = ChannelMap.formatName(md.channelLabels).map { "\(what) · shown in \($0) order" } ?? what
            }
        }
        if isCancelled() { throw CancellationError() }
        if let container = try RIFFParser().scan(url: url, isCancelled: isCancelled), container.formType == "WAVE" {
            if container.truncated { md.warnings.append("RIFF metadata is truncated or exceeds safety limits.") }
            md.isRF64 = container.isRF64
            md.isADM = container.chunkIDs.contains("axml") && container.chunkIDs.contains("chna")
            // ADM masters describe their speakers in axml / chna, not in the WAVE header.
            if md.isADM, let name = md.channelLayoutName,
               name.hasPrefix("Speaker labels not recognised") || name.hasPrefix("Discrete") {
                md.channelLayoutName = ChannelMap.formatName(md.channelLabels)
                    .map { "Defined by ADM (chna) · shown in \($0) order" } ?? "Defined by ADM (chna)"
            }
            md.hasDolbyMetadata = container.chunkIDs.contains("dbmd")
            for chunk in container.chunks {
                if isCancelled() { throw CancellationError() }
                switch chunk.id {
                case "bext":
                    // bext numeric fields are defined little endian; do not misread RIFX.
                    if let b = BWFChunk.parse(payload: chunk.payload) {
                        md.bwf = b
                        md.bwfTimeReferenceSamples = b.timeReferenceSamples
                        md.bwfTimeReferenceSeconds = rate > 0 ? Double(b.timeReferenceSamples) / rate : nil
                    } else { md.warnings.append("Invalid bext metadata.") }
                case "chna":
                    // BS.2076 chna: numTracks (u16 LE) then numUIDs (u16 LE).
                    if chunk.payload.count >= 4 {
                        let b = [UInt8](chunk.payload.prefix(2))
                        md.admTrackCount = Int(b[0]) | Int(b[1]) << 8
                    }
                case "iXML":
                    if let x = IXMLChunk.parse(payload: chunk.payload) {
                        md.iXMLProject = x.project; md.iXMLScene = x.scene
                        md.iXMLTape = x.tape; md.iXMLTrack = x.track; md.iXMLNotes = x.notes
                    } else { md.warnings.append("Invalid or oversized iXML metadata.") }
                default: break
                }
            }
        }
        return md
    }

    /// No commonFormat inference: 24-bit PCM may be presented as Int32.
    static func bitDepth(_ format: AVAudioFormat) -> Int? {
        let a = format.streamDescription.pointee
        guard [kAudioFormatLinearPCM, kAudioFormatFLAC, kAudioFormatAppleLossless].contains(a.mFormatID),
              a.mBitsPerChannel > 0 else { return nil }
        return Int(a.mBitsPerChannel)
    }
    static func codecHint(_ format: AVAudioFormat) -> String {
        switch format.streamDescription.pointee.mFormatID {
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatULaw: return "μ-law"
        case kAudioFormatALaw: return "A-law"
        default: return "Unknown codec"
        }
    }
    static func friendlyChannelLayout(_ layout: AVAudioChannelLayout?) -> String? {
        guard let layout else { return nil }
        let tag = layout.layoutTag
        switch tag {
        case kAudioChannelLayoutTag_Mono: return "Mono"
        case kAudioChannelLayoutTag_Stereo: return "Stereo (L R)"
        case kAudioChannelLayoutTag_MPEG_5_1_A: return "5.1 (L R C LFE Ls Rs)"
        case kAudioChannelLayoutTag_UseChannelBitmap:
            return "Speaker bitmap 0x\(String(layout.layout.pointee.mChannelBitmap.rawValue, radix: 16))"
        case kAudioChannelLayoutTag_UseChannelDescriptions:
            let count = Int(layout.layout.pointee.mNumberChannelDescriptions)
            guard count > 0, count <= 256 else { return nil }
            // Read from the original variable-length allocation, NOT a copied
            // AudioChannelLayout struct whose tuple contains only one description.
            let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
            let descriptions = UnsafeRawPointer(layout.layout).advanced(by: offset)
                .assumingMemoryBound(to: AudioChannelDescription.self)
            let labels = (0..<count).map { "\(descriptions[$0].mChannelLabel)" }
            return "Channel labels: " + labels.joined(separator: ", ")
        default:
            return "Layout tag 0x\(String(tag, radix: 16))"
        }
    }

    /// AVFoundation handles embedded artwork. Retain at most 4 MiB, and
    /// ImageIO in the UI downsamples before display. No URLs are followed.
    public func addArtwork(to metadata: AudioMetadata, url: URL) async throws -> AudioMetadata {
        var md = metadata
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let items = try await asset.load(.commonMetadata)
            for item in items.prefix(256) where item.commonKey == .commonKeyArtwork {
                try Task.checkCancellation()
                if let data = try await item.load(.dataValue), data.count <= 4 * 1024 * 1024 {
                    md.artworkData = data
                    break
                }
            }
            try Task.checkCancellation()
            return md
        } onCancel: { asset.cancelLoading() }
    }
}
