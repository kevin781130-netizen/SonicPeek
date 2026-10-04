import Foundation
import AVFAudio
import AudioToolbox

/// Speaker labels and ITU-R BS.1770 loudness weights for each channel of a file.
public struct ChannelMap: Equatable, Sendable {
    public let labels: [String]
    /// BS.1770-4 channel weights: 1.0 for front/centre/height, 1.41 for side and
    /// rear surrounds, 0 for LFE (not part of programme loudness).
    public let weights: [Double]

    public init(labels: [String], weights: [Double]) {
        self.labels = labels
        self.weights = weights
    }

    /// Labels from the file's own channel layout when it names them; otherwise
    /// the conventional WAV / SMPTE order for the channel count.
    public static func resolve(_ format: AVAudioFormat) -> ChannelMap {
        let count = Int(format.channelCount)
        if let layout = format.channelLayout, let labels = labelsFromLayout(layout, count: count) {
            return ChannelMap(labels: labels, weights: labels.map(weight))
        }
        let labels = defaultLabels(count)
        return ChannelMap(labels: labels, weights: labels.map(weight))
    }

    /// Conventional orders: WAVEFORMATEXTENSIBLE / SMPTE for 5.1 and 7.1, and the
    /// Dolby Atmos 7.1.4 bed order (L R C LFE Lss Rss Lrs Rrs Ltf Rtf Ltr Rtr).
    public static func defaultLabels(_ count: Int) -> [String] {
        switch count {
        case 1: return ["M"]
        case 2: return ["L", "R"]
        case 3: return ["L", "R", "C"]
        case 4: return ["L", "R", "Ls", "Rs"]
        case 6: return ["L", "R", "C", "LFE", "Ls", "Rs"]
        case 8: return ["L", "R", "C", "LFE", "Lrs", "Rrs", "Lss", "Rss"]
        case 10: return ["L", "R", "C", "LFE", "Lss", "Rss", "Lrs", "Rrs", "Ltm", "Rtm"]
        case 12: return ["L", "R", "C", "LFE", "Lss", "Rss", "Lrs", "Rrs", "Ltf", "Rtf", "Ltr", "Rtr"]
        default: return (1...max(1, count)).map { "\($0)" }
        }
    }

    /// Labels only when the file's own layout names every channel (no convention guess).
    public static func fileLabels(_ format: AVAudioFormat) -> [String]? {
        format.channelLayout.flatMap { labelsFromLayout($0, count: Int(format.channelCount)) }
    }

    /// "Stereo", "5.1", "7.1.4" … counted from the labels; nil if a label is unknown.
    public static func formatName(_ labels: [String]) -> String? {
        guard !labels.isEmpty, !labels.contains(where: { Int($0) != nil || $0 == "?" }) else { return nil }
        if labels == ["M"] { return "Mono" }
        if labels == ["L", "R"] { return "Stereo" }
        let lfe = labels.filter { $0.hasPrefix("LFE") }.count
        let height = labels.filter { ["Ltf", "Rtf", "Ltr", "Rtr", "Ltm", "Rtm"].contains($0) }.count
        let bed = labels.count - lfe - height
        return "\(bed).\(lfe)" + (height > 0 ? ".\(height)" : "")
    }

    public static func weight(_ label: String) -> Double {
        switch label {
        case "LFE", "LFE2": return 0
        case "Ls", "Rs", "Lss", "Rss", "Lrs", "Rrs", "Cs": return 1.41
        default: return 1.0
        }
    }

    private static func labelsFromLayout(_ layout: AVAudioChannelLayout, count: Int) -> [String]? {
        let raw = layout.layout.pointee
        switch raw.mChannelLayoutTag {
        case kAudioChannelLayoutTag_Mono: return count == 1 ? ["M"] : nil
        case kAudioChannelLayoutTag_Stereo, kAudioChannelLayoutTag_StereoHeadphones: return count == 2 ? ["L", "R"] : nil
        case kAudioChannelLayoutTag_UseChannelDescriptions:
            return describedLabels(UnsafeRawPointer(layout.layout), count: count)
        case kAudioChannelLayoutTag_UseChannelBitmap:
            var bitmap = raw.mChannelBitmap.rawValue
            return expanded(kAudioFormatProperty_ChannelLayoutForBitmap, &bitmap, count: count)
        default:
            // Named layouts (5.1, 7.1, Atmos 7.1.4 …): Core Audio expands the tag into per-channel labels.
            var tag = raw.mChannelLayoutTag
            return expanded(kAudioFormatProperty_ChannelLayoutForTag, &tag, count: count)
        }
    }

    private static func expanded(_ property: AudioFormatPropertyID, _ specifier: inout UInt32, count: Int) -> [String]? {
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(property, 4, &specifier, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioChannelLayout>.size), size <= 64 * 1024 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { buffer.deallocate() }
        guard AudioFormatGetProperty(property, 4, &specifier, &size, buffer) == noErr else { return nil }
        let acl = buffer.assumingMemoryBound(to: AudioChannelLayout.self).pointee
        guard acl.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions
                || Int(acl.mNumberChannelDescriptions) == count else { return nil }
        return describedLabels(UnsafeRawPointer(buffer), count: count)
    }

    /// Reads from the original variable-length allocation, not a copied struct (its tuple holds one description).
    private static func describedLabels(_ layout: UnsafeRawPointer, count: Int) -> [String]? {
        let n = Int(layout.assumingMemoryBound(to: AudioChannelLayout.self).pointee.mNumberChannelDescriptions)
        guard n == count, n > 0, n <= 64 else { return nil }
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let descriptions = layout.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
        let labels = (0..<n).map { name(descriptions[$0].mChannelLabel) }
        return labels.contains("?") ? nil : labels
    }

    private static func name(_ label: AudioChannelLabel) -> String {
        switch label {
        case kAudioChannelLabel_Left: return "L"
        case kAudioChannelLabel_Right: return "R"
        case kAudioChannelLabel_Center: return "C"
        case kAudioChannelLabel_LFEScreen: return "LFE"
        case kAudioChannelLabel_LFE2: return "LFE2"
        case kAudioChannelLabel_LeftSurround: return "Ls"
        case kAudioChannelLabel_RightSurround: return "Rs"
        case kAudioChannelLabel_LeftSurroundDirect: return "Lss"
        case kAudioChannelLabel_RightSurroundDirect: return "Rss"
        case kAudioChannelLabel_RearSurroundLeft: return "Lrs"
        case kAudioChannelLabel_RearSurroundRight: return "Rrs"
        case kAudioChannelLabel_CenterSurround: return "Cs"
        case kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_LeftTopFront: return "Ltf"
        case kAudioChannelLabel_VerticalHeightRight, kAudioChannelLabel_RightTopFront: return "Rtf"
        case kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_LeftTopRear: return "Ltr"
        case kAudioChannelLabel_TopBackRight, kAudioChannelLabel_RightTopRear: return "Rtr"
        case kAudioChannelLabel_LeftTopMiddle: return "Ltm"
        case kAudioChannelLabel_RightTopMiddle: return "Rtm"
        case kAudioChannelLabel_Mono: return "M"
        default: return "?"
        }
    }
}
