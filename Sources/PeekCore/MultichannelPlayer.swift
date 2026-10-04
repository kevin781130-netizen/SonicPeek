import Foundation
import AVFAudio
import Accelerate

/// Plays files with more than two channels.
///
/// * Output device has at least as many channels as the file → each channel goes
///   out unchanged, in file order (channel 1 → output 1 …).
/// * Otherwise (headphones, stereo speakers) → binaural render of the speaker bed
///   with Apple's HRTF (`AVAudioEnvironmentNode`, ambience-bed mode).
public final class MultichannelPlayer {
    public enum Route: Equatable, Sendable {
        case discrete(fileChannels: Int, deviceChannels: Int)
        case binaural(layout: String)

        public var summary: String {
            switch self {
            case let .discrete(f, d): return "Direct out · \(f) of \(d) outputs"
            case let .binaural(layout): return "Spatial (headphones) · \(layout) · Apple HRTF"
            }
        }
    }

    public let engine = AVAudioEngine()
    public private(set) var route: Route
    public let duration: Double
    /// Latest per-channel peak and RMS in dBFS, updated from the render tap.
    public var onLevels: (([Float], [Float]) -> Void)?

    private let file: AVAudioFile
    private let player = AVAudioPlayerNode()
    private let environment = AVAudioEnvironmentNode()
    private let bedFormat: AVAudioFormat
    private var startFrame: AVAudioFramePosition = 0
    private var scheduledToken = 0
    public private(set) var isPlaying = false
    public var onFinished: (() -> Void)?

    /// Speaker layout for a channel count in the conventional WAV / Atmos order
    /// (5.1 L R C LFE Ls Rs · 7.1 L R C LFE Lrs Rrs Lss Rss · 7.1.2 · 7.1.4).
    public static func bedLayout(for channels: Int, fileLayout: AVAudioChannelLayout?) -> (AVAudioChannelLayout, String)? {
        if let fileLayout, fileLayout.channelCount == channels,
           fileLayout.layoutTag != kAudioChannelLayoutTag_Unknown,
           fileLayout.layoutTag & 0xFFFF0000 != kAudioChannelLayoutTag_DiscreteInOrder {
            return (fileLayout, "\(channels)-channel layout from file")
        }
        let tag: AudioChannelLayoutTag, name: String
        switch channels {
        case 3: (tag, name) = (kAudioChannelLayoutTag_MPEG_3_0_A, "3.0")
        case 4: (tag, name) = (kAudioChannelLayoutTag_Quadraphonic, "Quad")
        case 6: (tag, name) = (kAudioChannelLayoutTag_MPEG_5_1_A, "5.1")
        case 8: (tag, name) = (kAudioChannelLayoutTag_WAVE_7_1, "7.1")
        case 10: (tag, name) = (kAudioChannelLayoutTag_Atmos_7_1_2, "7.1.2")
        case 12: (tag, name) = (kAudioChannelLayoutTag_Atmos_7_1_4, "7.1.4")
        default: return nil
        }
        guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return nil }
        return (layout, name)
    }

    /// `outputChannels` overrides the device width (tests use manual rendering).
    public init(url: URL, manualOutput: AVAudioFormat? = nil) throws {
        file = try AVAudioFile(forReading: url)
        let channels = Int(file.processingFormat.channelCount)
        let rate = file.processingFormat.sampleRate
        duration = rate > 0 ? Double(file.length) / rate : 0
        if let manualOutput {
            try engine.enableManualRenderingMode(.offline, format: manualOutput, maximumFrameCount: 4096)
        }
        let device = Int(engine.outputNode.outputFormat(forBus: 0).channelCount)
        engine.attach(player)

        if device >= channels {
            // Discrete: label the stream "in order" so the mixer maps 1:1 instead of up/down-mixing.
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels))!
            bedFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
            let outLayout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(device))!
            let outFormat = AVAudioFormat(standardFormatWithSampleRate: engine.outputNode.outputFormat(forBus: 0).sampleRate,
                                          channelLayout: outLayout)
            engine.connect(player, to: engine.mainMixerNode, format: bedFormat)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outFormat)
            route = .discrete(fileChannels: channels, deviceChannels: device)
        } else {
            guard let (layout, name) = Self.bedLayout(for: channels, fileLayout: file.processingFormat.channelLayout) else {
                throw NSError(domain: "Peek", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    "No speaker layout for \(channels) channels; connect an interface with \(channels) outputs to play it."])
            }
            bedFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
            engine.attach(environment)
            environment.renderingAlgorithm = .HRTFHQ
            environment.outputType = .headphones
            environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
            player.sourceMode = .ambienceBed
            player.renderingAlgorithm = .HRTFHQ
            engine.connect(player, to: environment, format: bedFormat)
            engine.connect(environment, to: engine.mainMixerNode, format: nil)
            route = .binaural(layout: name)
        }
        installMeterTap(channels: channels)
        engine.prepare()
    }

    deinit {
        player.removeTap(onBus: 0)
        engine.stop()
    }

    private func installMeterTap(channels: Int) {
        player.installTap(onBus: 0, bufferSize: 2048, format: bedFormat) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let n = vDSP_Length(buffer.frameLength)
            var peaks = [Float](), rms = [Float]()
            for c in 0..<min(channels, Int(buffer.format.channelCount)) {
                var p: Float = 0, r: Float = 0
                vDSP_maxmgv(data[c], 1, &p, n)
                vDSP_rmsqv(data[c], 1, &r, n)
                peaks.append(p > 0 ? 20 * log10(p) : -160)
                rms.append(r > 0 ? 20 * log10(r) : -160)
            }
            self.onLevels?(peaks, rms)
        }
    }

    public var currentTime: Double {
        guard let nodeTime = player.lastRenderTime, let t = player.playerTime(forNodeTime: nodeTime) else {
            return Double(startFrame) / file.processingFormat.sampleRate
        }
        return Double(startFrame + t.sampleTime) / t.sampleRate
    }

    /// Schedules from `seconds` and plays.
    public func play(from seconds: Double) throws {
        let rate = file.processingFormat.sampleRate
        startFrame = max(0, min(file.length - 1, AVAudioFramePosition(seconds * rate)))
        player.stop()
        scheduledToken += 1
        let token = scheduledToken
        let frames = AVAudioFrameCount(file.length - startFrame)
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.scheduledToken == token, self.isPlaying else { return }
                self.isPlaying = false
                self.onFinished?()
            }
        }
        if !engine.isRunning { try engine.start() }
        player.play()
        isPlaying = true
    }

    public func pause() -> Double {
        let now = currentTime
        isPlaying = false
        scheduledToken += 1
        player.stop()
        startFrame = AVAudioFramePosition(now * file.processingFormat.sampleRate)
        return now
    }

    public func stop() {
        isPlaying = false
        scheduledToken += 1
        player.stop()
        engine.stop()
    }
}
