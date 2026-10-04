import Foundation
import UniformTypeIdentifiers

/// Reproducible UTI probe for the file types UTUVO Peek can preview.
///
/// UTType probe order (all macOS 14+ public UTTypes, verified in
/// `docs/API-FEASIBILITY.md` §2):
///
/// 1. Try `UTType(filenameExtension:)`. Returns nil for unusual
///    extensions — fall back to magic-byte inspection.
/// 2. If we already know the parent UTI is `public.audio`, return
///    `UTType.audio` regardless of the container.
///
/// The probe is deliberately **pure**: it does not call into AVFoundation,
/// does not open the file, and does not touch the network. It is the
/// single source of truth for "what is this file" inside Peek.
public enum UTTypeProbe {

    /// Result of probing a file. Use `displayName` for human-readable
    /// text, `utType.identifier` for the system UTI string.
    public struct Result: Equatable, Sendable {
        public let utType: UTType
        public let displayName: String
        public let isSupported: Bool
    }

    /// Public UTTypes that AVFoundation's `AVAudioFile` can open on
    /// macOS 14+ and that Peek's Quick Look extension claims. The
    /// extension `Info.plist` and this list are two hand-maintained
    /// copies of the same set; keep them in sync when editing.
    public static let supportedIdentifiers: [String] = [
        UTType.wav.identifier,                    // com.microsoft.waveform-audio
        UTType.aiff.identifier,                   // public.aiff-audio
        "public.aifc-audio",                     // AIFF-C
        "public.aac-audio",                      // ADTS AAC
        UTType("com.apple.coreaudio-format")!.identifier, // CAF
        UTType.mp3.identifier,                    // public.mp3
        UTType.mpeg4Audio.identifier,             // public.mpeg-4-audio
        UTType("org.xiph.flac")!.identifier       // FLAC
    ]

    /// Probe a URL. Uses extension first, then a small magic-byte
    /// check. Returns a result the caller can render or pass to
    /// `AVAudioFile` for decoding.
    public static func probe(_ url: URL) -> Result {
        // 1) extension-based
        if let extType = UTType(filenameExtension: url.pathExtension) {
            if supportedIdentifiers.contains(extType.identifier)
                || extType.conforms(to: .audio) {
                return Result(
                    utType: extType,
                    displayName: humanName(for: extType),
                    isSupported: true
                )
            }
            if extType.conforms(to: .audio) {
                // Some audio subtypes (e.g. ALAC in .caf) hit here.
                return Result(
                    utType: .audio,
                    displayName: "Audio (\(extType.identifier))",
                    isSupported: true
                )
            }
            // Identified but not in our supported list.
            return Result(
                utType: extType,
                displayName: humanName(for: extType),
                isSupported: false
            )
        }

        // 2) magic-byte fallback
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Result(utType: .data, displayName: "Unknown", isSupported: false)
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 12)) ?? Data()
        if let magic = MagicByteSniff.detect(head: head) {
            return Result(
                utType: magic.utType,
                displayName: magic.displayName,
                isSupported: true
            )
        }
        return Result(utType: .data, displayName: "Unknown", isSupported: false)
    }

    private static func humanName(for utType: UTType) -> String {
        switch utType.identifier {
        case UTType.wav.identifier: return "WAVE / BWF"
        case UTType.aiff.identifier: return "AIFF"
        case UTType("com.apple.coreaudio-format")?.identifier ?? "": return "CAF"
        case UTType.mp3.identifier: return "MP3"
        case UTType.mpeg4Audio.identifier: return "MPEG-4 Audio"
        case UTType("org.xiph.flac")?.identifier ?? "": return "FLAC"
        default: return utType.localizedDescription ?? utType.identifier
        }
    }
}

/// Lightweight magic-byte detector. We only recognise the formats we
/// actually claim in the extension Info.plist; the extension itself
/// rejects anything else.
enum MagicByteSniff {
    struct Hit { let utType: UTType; let displayName: String }

    static func detect(head: Data) -> Hit? {
        guard head.count >= 4 else { return nil }
        // RIFF....WAVE
        if head.count >= 12
            && head[0] == 0x52, head[1] == 0x49, head[2] == 0x46, head[3] == 0x46
            && head[8] == 0x57, head[9] == 0x41, head[10] == 0x56, head[11] == 0x45 {
            return Hit(utType: .wav, displayName: "WAVE / BWF")
        }
        // FORM....AIFF / AIFC
        if head.count >= 12
            && head[0] == 0x46, head[1] == 0x4F, head[2] == 0x52, head[3] == 0x4D {
            let form = head.subdata(in: 8..<12)
            if form == Data([0x41, 0x49, 0x46, 0x46]) {
                return Hit(utType: UTType.aiff, displayName: "AIFF")
            }
            if form == Data([0x41, 0x49, 0x46, 0x43]) {
                return Hit(utType: UTType.aiff, displayName: "AIFF-C")
            }
        }
        // CAF
        if head.count >= 4
            && head[0] == 0x63, head[1] == 0x61, head[2] == 0x66, head[3] == 0x66 {
            return Hit(utType: UTType("com.apple.coreaudio-format") ?? .audio,
                       displayName: "CAF")
        }
        // fLaC
        if head.count >= 4
            && head[0] == 0x66, head[1] == 0x4C, head[2] == 0x61, head[3] == 0x43 {
            return Hit(utType: UTType("org.xiph.flac") ?? .audio,
                       displayName: "FLAC")
        }
        // ID3 tag → MP3, or MPEG sync word 0xFFEx.
        if head.count >= 3
            && head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 {
            return Hit(utType: .mp3, displayName: "MP3")
        }
        if head.count >= 2
            && head[0] == 0xFF
            && (head[1] & 0xE0) == 0xE0 {
            return Hit(utType: .mp3, displayName: "MP3")
        }
        // MPEG-4 / M4A: "ftyp" at offset 4
        if head.count >= 8
            && head[4] == 0x66, head[5] == 0x74, head[6] == 0x79, head[7] == 0x70 {
            return Hit(utType: .mpeg4Audio, displayName: "MPEG-4 Audio")
        }
        return nil
    }
}
