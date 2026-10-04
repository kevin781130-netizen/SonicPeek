import Cocoa
import SwiftUI
import AVFAudio
import ImageIO
import PeekCore

@MainActor public final class PreviewModel: ObservableObject {
    @Published public var metadata: AudioMetadata?
    @Published public var waveform: WaveformGenerator.Buckets?
    @Published public var isPlaying = false
    /// Position and meters change ~40× a second while playing; they live in `playback`
    /// so only the playhead, time and meters redraw, not the whole page.
    public let playback = PlaybackState()
    public var fraction: Double {
        get { playback.fraction }
        set { playback.fraction = newValue }
    }
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    /// Per-channel min/max lanes (at most 24).
    @Published public var lanes: [WaveformGenerator.Buckets] = []
    @Published public var analysis: AudioAnalysis?
    /// 0…1 while the loudness / spectrum pass runs; nil when idle.
    @Published public var analysisProgress: Double?
    /// Files above the automatic budget wait for an explicit "Measure" click.
    @Published public var analysisDeferred = false
    /// Live playback meters in dBFS (peak and average), one per channel.
    public var meterPeak: [Float] {
        get { playback.meterPeak }
        set { playback.meterPeak = newValue }
    }
    public var meterAverage: [Float] {
        get { playback.meterAverage }
        set { playback.meterAverage = newValue }
    }
    @Published public var mode: DisplayMode = .waveform
    /// "File details" / "Recording metadata" disclosure state (kept while the preview is open).
    @Published public var showFileDetails = false
    @Published public var showRecordingMetadata = false
    /// How multichannel audio is being played (direct out or binaural); nil for mono/stereo.
    @Published public var playbackRoute: String?

    public enum DisplayMode: String, CaseIterable, Sendable { case waveform = "Waveform", channels = "Channels", spectrum = "Spectrum" }
}

@MainActor public final class PlaybackState: ObservableObject {
    @Published public var fraction = 0.0
    @Published public var meterPeak: [Float] = []
    @Published public var meterAverage: [Float] = []
}

/// Re-evaluates only its content when the playback state changes.
private struct WithPlayback<Content: View>: View {
    @ObservedObject var playback: PlaybackState
    @ViewBuilder let content: (PlaybackState) -> Content
    var body: some View { content(playback) }
}

/// Shared playback implementation. The Quick Look extension opts into autoplay.
@MainActor open class AudioPreviewController: NSViewController {
    public let model = PreviewModel()
    private var worker: Task<(AudioMetadata, [WaveformGenerator.Buckets]), Error>?
    private var analysisTask: Task<Void, Never>?
    /// Automatic analysis budget: about 30 minutes of 48 kHz stereo.
    public static let automaticAnalysisSamples: Int64 = 48_000 * 1_800 * 2
    private var generation = UUID()
    private var url: URL?
    private var player: AVAudioPlayer?
    /// Files with more than two channels: direct out or binaural (MultichannelPlayer).
    private var multi: MultichannelPlayer?
    private var isMultichannel: Bool { (model.metadata?.channels ?? 0) > 2 }
    private var timer: Timer?
    public var playbackAllowed = true
    /// Only the standalone host supplies a file picker; Quick Look supplies its file.
    public var openFileAction: (() -> Void)?
    public var hasPlaybackTimer: Bool { timer != nil }

    public override func loadView() {
        // Closures hold the controller weakly: no hosting-view/controller cycle.
        view = NSHostingView(rootView: PreviewView(model: model,
            openFile: openFileAction,
            play: { [weak self] in self?.togglePlayback() },
            stop: { [weak self] in self?.stopPlayback() },
            seek: { [weak self] in self?.seek(to: $0) },
            measure: { [weak self] in self?.startAnalysis() }))
        preferredContentSize = NSSize(width: 720, height: 600)
    }

    open func prepare(_ newURL: URL) async throws {
        cancelPreview()
        _ = view // QL may call prepare before loading the view.
        let id = UUID()
        generation = id
        model.metadata = nil; model.waveform = nil; model.errorMessage = nil
        model.lanes = []; model.analysis = nil; model.analysisProgress = nil; model.analysisDeferred = false
        model.isLoading = true
        let task = Task.detached(priority: .userInitiated) {
            // This synchronous decode is explicitly on a detached executor.
            assert(!Thread.isMainThread)
            let assembler = MetadataAssembler()
            var md = try assembler.assemble(newURL, isCancelled: { Task.isCancelled })
            let lanes = try WaveformGenerator().generateChannels(from: newURL, isCancelled: { Task.isCancelled })
            do { md = try await assembler.addArtwork(to: md, url: newURL) }
            catch is CancellationError { throw CancellationError() }
            catch { md.warnings.append("Embedded artwork could not be read.") }
            try Task.checkCancellation()
            return (md, lanes)
        }
        worker = task
        do {
            let result = try await withTaskCancellationHandler {
                let result = try await task.value
                try Task.checkCancellation()
                return result
            } onCancel: { task.cancel() }
            guard generation == id else { throw CancellationError() }
            model.metadata = result.0; model.lanes = result.1
            model.waveform = WaveformGenerator.combine(result.1)
            model.mode = (result.0.channels ?? 1) > 2 ? .channels : .waveform
            model.isLoading = false; worker = nil; url = newURL
            let samples = Int64(((result.0.durationSeconds ?? 0) * (result.0.sampleRateHz ?? 0)).rounded()) * Int64(max(1, result.0.channels ?? 1))
            if samples <= Self.automaticAnalysisSamples { startAnalysis() } else { model.analysisDeferred = true }
        } catch {
            if generation == id {
                worker = nil; model.isLoading = false
                model.errorMessage = error is CancellationError ? "Preview cancelled." : "Could not preview: \(error.localizedDescription)"
            }
            throw error
        }
    }

    /// Loudness, true peak and spectrum: one low-priority pass over the file.
    public func startAnalysis() {
        guard let url, analysisTask == nil, model.analysis == nil else { return }
        let id = generation
        model.analysisDeferred = false
        model.analysisProgress = 0
        let labels = model.metadata?.channelLabels ?? []
        analysisTask = Task { [weak self] in
            let job = Task.detached(priority: .utility) { () -> AudioAnalysis? in
                let map = labels.isEmpty ? nil : ChannelMap(labels: labels, weights: labels.map(ChannelMap.weight))
                return try? AudioAnalyzer().analyze(url: url, channelMap: map, isCancelled: { Task.isCancelled }) { f in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id, self.model.analysisProgress != nil else { return }
                        self.model.analysisProgress = f
                    }
                }
            }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self, self.generation == id else { return }
            self.analysisTask = nil
            self.model.analysisProgress = nil
            if let result { self.model.analysis = result } else if !Task.isCancelled {
                self.model.errorMessage = "Loudness could not be measured for this file."
            }
        }
    }

    public func cancelPreview() {
        generation = UUID()
        worker?.cancel(); worker = nil
        analysisTask?.cancel(); analysisTask = nil; model.analysisProgress = nil
        stopPlayback(); url = nil; model.isLoading = false
    }
    open override func viewWillDisappear() {
        super.viewWillDisappear()
        cancelPreview()
    }
    deinit { worker?.cancel(); analysisTask?.cancel(); timer?.invalidate(); player?.stop(); multi?.stop() }

    /// Seeking stores a position without starting or even creating a player.
    public func seek(to fraction: Double) {
        guard fraction.isFinite else { return }
        model.fraction = min(1, max(0, fraction))
        if let player { player.currentTime = player.duration * model.fraction }
        if let multi, multi.isPlaying { try? multi.play(from: multi.duration * model.fraction) }
    }
    public func togglePlayback() {
        guard playbackAllowed, let url else { return }
        if isMultichannel { toggleMultichannel(url); return }
        if let player, player.isPlaying {
            player.pause(); model.isPlaying = false; clearTimer()
            model.meterPeak = []; model.meterAverage = []; return
        }
        do {
            if player == nil {
                player = try AVAudioPlayer(contentsOf: url)
                player?.isMeteringEnabled = true
            }
            guard let player else { return }
            player.currentTime = player.duration * (model.fraction >= 1 ? 0 : model.fraction)
            guard player.prepareToPlay(), player.play() else {
                throw NSError(domain: "Peek", code: 2, userInfo: [NSLocalizedDescriptionKey: "The audio device could not start playback."])
            }
            model.isPlaying = true
            clearTimer()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            model.errorMessage = "Playback failed: \(error.localizedDescription)"
            stopPlayback()
        }
    }
    private func toggleMultichannel(_ url: URL) {
        if let multi, multi.isPlaying {
            _ = multi.pause(); model.isPlaying = false; clearTimer()
            model.meterPeak = []; model.meterAverage = []; return
        }
        do {
            if multi == nil {
                let m = try MultichannelPlayer(url: url)
                m.onLevels = { [weak self] peak, average in
                    DispatchQueue.main.async {
                        guard let self, self.multi === m, m.isPlaying else { return }
                        self.model.meterPeak = peak; self.model.meterAverage = average
                    }
                }
                m.onFinished = { [weak self] in
                    guard let self, self.multi === m else { return }
                    self.model.isPlaying = false; self.model.fraction = 1; self.clearTimer()
                    self.model.meterPeak = []; self.model.meterAverage = []
                }
                multi = m
                model.playbackRoute = m.route.summary
            }
            guard let multi else { return }
            try multi.play(from: multi.duration * (model.fraction >= 1 ? 0 : model.fraction))
            model.isPlaying = true
            clearTimer()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let multi = self.multi, multi.isPlaying, multi.duration > 0 else { return }
                    self.model.fraction = min(1, multi.currentTime / multi.duration)
                }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            model.errorMessage = "Playback failed: \(error.localizedDescription)"
            stopPlayback()
        }
    }

    private func tick() {
        guard let player, player.isPlaying else {
            model.isPlaying = false; model.fraction = 1; clearTimer()
            model.meterPeak = []; model.meterAverage = []; return
        }
        model.fraction = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
        player.updateMeters()
        let n = min(24, player.numberOfChannels)
        model.meterPeak = (0..<n).map { player.peakPower(forChannel: $0) }
        model.meterAverage = (0..<n).map { player.averagePower(forChannel: $0) }
    }
    public func stopPlayback() {
        player?.stop(); player = nil
        multi?.stop(); multi = nil; model.playbackRoute = nil
        clearTimer(); model.isPlaying = false; model.fraction = 0
        model.meterPeak = []; model.meterAverage = []
    }
    private func clearTimer() { timer?.invalidate(); timer = nil }
}

private struct PreviewView: View {
    @ObservedObject var model: PreviewModel
    let openFile: (() -> Void)?
    let play: () -> Void
    let stop: () -> Void
    let seek: (Double) -> Void
    let measure: () -> Void

    var body: some View {
        Group {
            if let md = model.metadata {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header(md)
                        if let error = model.errorMessage { message(error, symbol: "exclamationmark.circle", color: .red) }
                        audioPlayer(md)
                        facts(md)
                        loudness(md)
                        details(md)
                        ForEach(Array(md.warnings.enumerated()), id: \.offset) { _, warning in
                            message(warning, symbol: "exclamationmark.triangle", color: .orange)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
            } else {
                emptyState
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(_ md: AudioMetadata) -> some View {
        HStack(spacing: 14) {
            ArtworkView(data: md.artworkData)
            VStack(alignment: .leading, spacing: 6) {
                Text(md.fileName).font(.system(size: 22, weight: .semibold))
                    .lineLimit(2).textSelection(.enabled)
                Text([md.containerDescription, ByteCountFormatter.string(fromByteCount: md.fileSizeBytes, countStyle: .file)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                if md.isADM || md.hasDolbyMetadata || md.isRF64 {
                    HStack(spacing: 6) {
                        if md.isADM { Badge(text: "ADM BWF" + (md.admTrackCount.map { " · \($0) tracks" } ?? "")) }
                        if md.hasDolbyMetadata { Badge(text: "Dolby metadata") }
                        if md.isRF64 { Badge(text: "RF64") }
                    }
                }
            }
            Spacer(minLength: 8)
            if let openFile {
                Button(action: openFile) { Image(systemName: "folder").frame(width: 24, height: 24) }
                    .modifier(GlassControl(prominent: false))
                    .help("Open another audio file (⌘O)").accessibilityLabel("Open audio file")
            }
        }
    }

    private func audioPlayer(_ md: AudioMetadata) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 14) {
                HStack {
                    Picker("View", selection: $model.mode) {
                        ForEach(PreviewModel.DisplayMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                                .disabled(mode == .channels && model.lanes.count < 2)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Waveform: all channels · Channels: one lane per speaker · Spectrum: frequency over time")
                    Spacer()
                    WithPlayback(playback: model.playback) { pb in
                        Text("\(time((md.durationSeconds ?? 0) * pb.fraction)) / \(time(md.durationSeconds))")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    display(md)
                    let labels = meterLabels(md)
                    WithPlayback(playback: model.playback) { pb in
                        MeterBank(labels: labels, peak: pb.meterPeak, average: pb.meterAverage)
                    }
                    .frame(height: displayHeight)
                }
                WithPlayback(playback: model.playback) { pb in
                    Slider(value: Binding(get: { pb.fraction }, set: seek), in: 0...1)
                        .controlSize(.small).tint(.blue)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue(time((md.durationSeconds ?? 0) * pb.fraction))
                }
            }
            .padding(20)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
            HStack(spacing: 10) {
                Button(action: play) {
                    Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 78, height: 28)
                }
                .modifier(GlassControl(prominent: true))
                .help(model.isPlaying ? "Pause playback" : "Play audio")
                WithPlayback(playback: model.playback) { pb in
                    Button(action: stop) { Image(systemName: "stop.fill").font(.system(size: 12)).frame(width: 28, height: 28) }
                        .modifier(GlassControl(prominent: false))
                        .disabled(!model.isPlaying && pb.fraction == 0)
                        .help("Stop and return to the beginning").accessibilityLabel("Stop playback")
                }
            }
            if (md.channels ?? 0) > 2 {
                Label(model.playbackRoute ?? "Plays spatially on headphones, or direct to an interface with enough outputs",
                      systemImage: model.playbackRoute?.hasPrefix("Spatial") == true ? "headphones" : "hifispeaker.2")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var displayHeight: CGFloat {
        model.mode == .channels ? max(132, min(22, 264 / CGFloat(max(1, model.lanes.count))) * CGFloat(model.lanes.count)) : 132
    }

    private func meterLabels(_ md: AudioMetadata) -> [String] {
        let labels = md.channelLabels.isEmpty ? ChannelMap.defaultLabels(md.channels ?? 2) : md.channelLabels
        return Array(labels.prefix(24))
    }

    /// Quiet files would draw as a flat line: below −12 dBFS the drawing is scaled
    /// up (at most +30 dB) and the corner says so. Levels and meters are untouched.
    private var viewGain: Float {
        let peak = model.waveform?.values.map(abs).max() ?? 0
        guard peak > 0, peak < 0.25 else { return 1 }
        return min(31.6, 0.9 / peak)
    }

    @ViewBuilder private func zoomNote<V: View>(_ content: V) -> some View {
        content.overlay(alignment: .topTrailing) {
            if viewGain > 1 {
                Text("View +\(Int((20 * log10(viewGain)).rounded())) dB")
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.background.opacity(0.8), in: Capsule())
                    .help("This file is quiet; the drawing is enlarged. Measurements are not affected.")
            }
        }
    }

    @ViewBuilder private func display(_ md: AudioMetadata) -> some View {
        switch model.mode {
        case .waveform:
            let values = model.waveform?.values ?? [], gain = viewGain
            zoomNote(WithPlayback(playback: model.playback) { pb in
                WaveformView(values: values, fraction: pb.fraction, gain: gain)
            }.frame(height: 132).accessibilityLabel("Audio waveform"))
        case .channels:
            let lanes = model.lanes, labels = meterLabels(md), gain = viewGain
            zoomNote(WithPlayback(playback: model.playback) { pb in
                ChannelLanesView(lanes: lanes, labels: labels, fraction: pb.fraction, gain: gain)
            }.frame(height: displayHeight).accessibilityLabel("Waveform per channel"))
        case .spectrum:
            if let spectrogram = model.analysis?.spectrogram {
                WithPlayback(playback: model.playback) { pb in
                    SpectrogramView(spectrogram: spectrogram, fraction: pb.fraction)
                }.frame(height: 132).accessibilityLabel("Spectrogram")
            } else {
                VStack(spacing: 8) {
                    if let p = model.analysisProgress {
                        ProgressView(value: p).frame(width: 160)
                        Text("Analysing… \(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
                    } else if model.analysisDeferred {
                        Button("Analyse this file", action: measure).modifier(GlassControl(prominent: false))
                        Text("Long file — analysis runs only when you ask.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No spectrum for this file.").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity).frame(height: 132)
            }
        }
    }

    private func loudness(_ md: AudioMetadata) -> some View {
        HStack(spacing: 0) {
            if let a = model.analysis {
                fact("Integrated", a.integratedLUFS.map { String(format: "%.1f LUFS", $0) } ?? "Below gate")
                Divider().frame(height: 30)
                level("True peak", a.truePeakDBTP.map { String(format: "%.1f dBTP", $0) } ?? "−∞",
                      warn: (a.truePeakDBTP ?? -99) > -1.0, clip: (a.truePeakDBTP ?? -99) > 0)
                Divider().frame(height: 30)
                fact("Loudness range", a.loudnessRangeLU.map { String(format: "%.1f LU", $0) } ?? "—")
                Divider().frame(height: 30)
                level("Sample peak", a.samplePeakDBFS.map { String(format: "%.1f dBFS", $0) } ?? "−∞",
                      warn: false, clip: (a.samplePeakDBFS ?? -99) >= -0.0001)
            } else if let p = model.analysisProgress {
                HStack(spacing: 10) {
                    ProgressView(value: p).frame(width: 140)
                    Text("Measuring loudness… \(Int(p * 100))%").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            } else if model.analysisDeferred {
                HStack(spacing: 12) {
                    Text("Loudness is measured on request for long files.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Measure loudness", action: measure).modifier(GlassControl(prominent: false))
                }.frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain).accessibilityLabel("Loudness")
    }

    /// A fact whose value turns orange above −1 dBTP and red at or over full scale.
    private func level(_ title: String, _ value: String, warn: Bool, clip: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                if warn || clip { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)) }
                Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            }.foregroundStyle(clip ? Color.red : warn ? Color.orange : Color.primary)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.horizontal, 8)
            .help(clip ? "Reaches full scale" : warn ? "Above −1 dBTP: most delivery specs ask for −1 dBTP or lower" : "")
            .accessibilityElement(children: .combine)
    }

    private func facts(_ md: AudioMetadata) -> some View {
        HStack(spacing: 0) {
            fact("Duration", time(md.durationSeconds))
            Divider().frame(height: 30)
            fact("Sample rate", md.sampleRateHz.map { "\(($0 / 1000).formatted(.number.precision(.fractionLength(0...6)))) kHz" } ?? "—")
            Divider().frame(height: 30)
            fact("Bit depth", md.bitDepth.map { "\($0)-bit" } ?? "—")
            Divider().frame(height: 30)
            fact("Channels", md.channels.map { $0 == 1 ? "Mono" : $0 == 2 ? "Stereo" : "\($0) channels" } ?? "—")
        }
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.horizontal, 8)
            .accessibilityElement(children: .combine)
    }

    private func details(_ md: AudioMetadata) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            DisclosureGroup(isExpanded: $model.showFileDetails) {
                VStack(spacing: 10) {
                    row("Duration", md.durationSeconds.map { String(format: "%.6f seconds", $0) })
                    row("Sample rate", md.sampleRateHz.map { "\($0.formatted(.number.precision(.fractionLength(0...6)))) Hz" })
                    row("Bit depth", md.bitDepth.map { "\($0)-bit" } ?? "Not specified / not applicable")
                    row("Channel layout", md.channelLayoutName ?? "Not specified by file")
                    row("Channels", md.channelLabels.isEmpty ? nil : md.channelLabels.joined(separator: " "))
                    row("True peak per channel", model.analysis.flatMap { a in
                        a.channelTruePeakDBTP.isEmpty ? nil : zip(meterLabels(md), a.channelTruePeakDBTP)
                            .map { "\($0) \($1.map { String(format: "%.1f", $0) } ?? "−∞")" }.joined(separator: "  ") })
                    row("ADM", md.isADM ? "ADM BWF (axml + chna)\(md.admTrackCount.map { ", \($0) tracks" } ?? "")" : nil)
                    row("Codec", md.codec)
                    row("Bit rate", md.bitRate.map { "\((Double($0) / 1000).formatted()) kbps" })
                    row("Container", md.containerDescription)
                    row("File size", "\(md.fileSizeBytes.formatted()) bytes")
                    row("Created", md.creationDate?.formatted(date: .abbreviated, time: .standard))
                    row("Modified", md.modificationDate?.formatted(date: .abbreviated, time: .standard))
                }.padding(.top, 12)
            } label: {
                Label("File details", systemImage: "info.circle").font(.system(size: 13, weight: .medium))
            }
            if md.bwf != nil || [md.iXMLProject, md.iXMLScene, md.iXMLTape, md.iXMLTrack, md.iXMLNotes].contains(where: { $0?.isEmpty == false }) {
                DisclosureGroup(isExpanded: $model.showRecordingMetadata) {
                    VStack(spacing: 10) {
                        if let bwf = md.bwf {
                            row("Description", bwf.description)
                            row("Originator", bwf.originator)
                            row("Reference", bwf.originatorReference)
                            row("Recorded", "\(bwf.originationDate) \(bwf.originationTime)")
                            row("BWF version", String(bwf.version))
                            row("Sample reference", String(bwf.timeReferenceSamples))
                            row("Time reference", md.bwfTimeReferenceSeconds.map { "\($0) s" })
                        }
                        row("Project", md.iXMLProject)
                        row("Scene", md.iXMLScene)
                        row("Tape", md.iXMLTape)
                        row("Track", md.iXMLTrack)
                        row("Notes", md.iXMLNotes)
                    }.padding(.top, 12)
                } label: {
                    Label("Recording metadata", systemImage: "waveform.badge.mic").font(.system(size: 13, weight: .medium))
                }
            }
        }.padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: model.errorMessage == nil ? "waveform" : "waveform.badge.exclamationmark")
                .font(.system(size: 42, weight: .light)).foregroundStyle(.blue).frame(height: 64)
            if model.isLoading {
                ProgressView("Reading audio…")
            } else {
                Text(model.errorMessage == nil ? "Take a closer listen." : "Couldn't open this audio file.")
                    .font(.system(size: 24, weight: .semibold))
                Text(model.errorMessage ?? "See the waveform, check the details, and press play.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                if let openFile {
                    Button("Open Audio File…", action: openFile)
                        .controlSize(.large).modifier(GlassControl(prominent: true))
                    Text("WAV · AIFF · CAF · MP3 · M4A · FLAC")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
                }
            }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 18) {
                Text(label).foregroundStyle(.secondary).frame(width: 128, alignment: .leading)
                Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 12))
        }
    }
    private func message(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).font(.callout).foregroundStyle(color).textSelection(.enabled)
    }
    private func time(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct GlassControl: ViewModifier {
    let prominent: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(.blue) }
            else { content.buttonStyle(.glass).buttonBorderShape(.capsule) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(.blue) }
            else { content.buttonStyle(.bordered).buttonBorderShape(.capsule) }
        }
    }
}

/// Blender-rendered plates bundled as PNGs (@2x). Missing files fall back to plain drawing.
enum PeekArt {
    static func image(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        if let rep = image.representations.first { image.size = NSSize(width: rep.pixelsWide / 2, height: rep.pixelsHigh / 2) }
        return image
    }
    static let artworkLight = image("artwork-light"), artworkDark = image("artwork-dark")
    static let plateLight = image("meter-plate-light"), plateDark = image("meter-plate-dark")
}

private struct ArtworkView: View {
    @Environment(\.colorScheme) private var colorScheme
    let data: Data?
    @State private var artwork: NSImage?
    var body: some View {
        Group {
            if let artwork { Image(nsImage: artwork).resizable().scaledToFill() }
            else if let puck = colorScheme == .dark ? PeekArt.artworkDark : PeekArt.artworkLight {
                Image(nsImage: puck).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "waveform").font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.blue).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.blue.opacity(0.09))
            }
        }
        .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 13))
        .accessibilityHidden(true)
        .task(id: data) {
            artwork = nil
            guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 160,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return }
            artwork = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }
}

/// The bars are drawn once per size/appearance; playback only moves a mask and a 1-pt line.
private struct WaveformView: View {
    let values: [Float]
    let fraction: Double
    var gain: Float = 1
    var body: some View {
        GeometryReader { geo in
            let playhead = max(0, min(geo.size.width - 1, fraction * geo.size.width))
            ZStack(alignment: .topLeading) {
                WaveformBars(values: values, gain: gain, played: false).equatable()
                WaveformBars(values: values, gain: gain, played: true).equatable()
                    .mask(alignment: .leading) { Rectangle().frame(width: playhead) }
                Rectangle().fill(Color.blue).frame(width: 1).offset(x: playhead)
            }
        }
    }
}

private struct WaveformBars: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme
    let values: [Float]
    let gain: Float
    let played: Bool
    static func == (a: Self, b: Self) -> Bool { a.gain == b.gain && a.played == b.played && a.values == b.values }
    var body: some View {
        Canvas { ctx, size in
            let count = values.count / 2
            guard count > 0 else { return }
            if !played {
                ctx.fill(Path(CGRect(x: 0, y: size.height / 2, width: size.width, height: 0.5)), with: .color(.primary.opacity(0.08)))
            }
            let color = Color.blue.opacity(played ? 0.95 : colorScheme == .dark ? 0.65 : 0.42)
            // Aggregate the decoder's min/max buckets into readable 3-point bars.
            let bars = max(1, min(count, Int(size.width / 3)))
            for i in 0..<bars {
                let start = i * count / bars, end = (i + 1) * count / bars
                var lo: Float = 1, hi: Float = -1
                for bucket in start..<end {
                    lo = min(lo, values[2 * bucket]); hi = max(hi, values[2 * bucket + 1])
                }
                lo = max(-1, lo * gain); hi = min(1, hi * gain)
                let x = CGFloat(i) * size.width / CGFloat(bars)
                let rect = CGRect(x: x, y: size.height * (1 - CGFloat(hi)) / 2,
                    width: max(1, size.width / CGFloat(bars) - 1), height: max(1, size.height * CGFloat(hi - lo) / 2))
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }
    }
}

private struct Badge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(0.3)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(.blue)
            .background(.blue.opacity(0.12), in: Capsule())
    }
}

/// One vertical meter per channel: average as the bar, peak as a line with a short hold.
private struct MeterBank: View {
    @Environment(\.colorScheme) private var colorScheme
    let labels: [String]
    let peak: [Float]
    let average: [Float]
    @State private var held: [Float] = []
    @State private var heldAt: [Date] = []

    private static let floor: Float = -60
    private func level(_ db: Float) -> CGFloat { CGFloat(max(0, min(1, (db - Self.floor) / -Self.floor))) }
    private func color(_ db: Float) -> Color { db > -3 ? .red : db > -12 ? .orange : .green }

    var body: some View {
        let count = max(1, labels.count)
        let column: CGFloat = (count > 12 ? 5 : count > 6 ? 7 : 9) + 6
        let spacing: CGFloat = count > 12 ? 2 : 3
        // One Canvas for every bar (redrawn per level update); labels are a separate static row.
        VStack(spacing: 3) {
            Canvas { ctx, size in
                let h = size.height
                for c in 0..<count {
                    let x = CGFloat(c) * (column + spacing)
                    let avg = c < average.count ? average[c] : Self.floor
                    let pk = c < held.count ? held[c] : Self.floor
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: column, height: h), cornerRadius: 1.5),
                             with: .color(.primary.opacity(0.07)))
                    let barH = h * level(avg)
                    if barH > 0 {
                        ctx.fill(Path(roundedRect: CGRect(x: x, y: h - barH, width: column, height: barH), cornerRadius: 1.5),
                                 with: .color(color(avg).opacity(0.85)))
                    }
                    if pk > Self.floor {
                        let top = h - max(2, h * level(pk))
                        ctx.fill(Path(CGRect(x: x, y: top, width: column, height: 2)), with: .color(color(pk)))
                    }
                }
            }
            .frame(width: CGFloat(count) * column + CGFloat(count - 1) * spacing)
            MeterLabels(labels: labels, count: count, column: column, spacing: spacing).equatable()
        }
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 9)
        .background {
            if let plate = colorScheme == .dark ? PeekArt.plateDark : PeekArt.plateLight {
                Image(nsImage: plate).resizable(capInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
            }
        }
        .accessibilityLabel("Playback level meters")
        .onChange(of: peak) { _, new in hold(new) }
    }

    /// Peak hold: keep the highest value for 1.5 s, then follow the signal down.
    private func hold(_ new: [Float]) {
        let now = Date()
        if new.isEmpty { held = []; heldAt = []; return }
        if held.count != new.count { held = new; heldAt = Array(repeating: now, count: new.count); return }
        for c in new.indices {
            if new[c] >= held[c] || now.timeIntervalSince(heldAt[c]) > 1.5 {
                held[c] = new[c]; heldAt[c] = now
            }
        }
    }
}

private struct MeterLabels: View, Equatable {
    let labels: [String]
    let count: Int
    let column: CGFloat
    let spacing: CGFloat
    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<count, id: \.self) { c in
                Text(labels.indices.contains(c) ? labels[c] : "")
                    .font(.system(size: count > 12 ? 6 : 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .frame(width: column)
            }
        }
    }
}

/// One min/max lane per channel with its speaker label. Drawn once; playback moves a mask.
private struct ChannelLanesView: View {
    let lanes: [WaveformGenerator.Buckets]
    let labels: [String]
    let fraction: Double
    var gain: Float = 1
    private let labelWidth: CGFloat = 34
    var body: some View {
        GeometryReader { geo in
            let playhead = labelWidth + max(0, min(geo.size.width - labelWidth - 1, fraction * (geo.size.width - labelWidth)))
            ZStack(alignment: .topLeading) {
                ChannelLaneBars(lanes: lanes, labels: labels, gain: gain, labelWidth: labelWidth, played: false).equatable()
                ChannelLaneBars(lanes: lanes, labels: labels, gain: gain, labelWidth: labelWidth, played: true).equatable()
                    .mask(alignment: .leading) { Rectangle().frame(width: playhead) }
                if !lanes.isEmpty { Rectangle().fill(Color.blue).frame(width: 1).offset(x: playhead) }
            }
        }
    }
}

private struct ChannelLaneBars: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme
    let lanes: [WaveformGenerator.Buckets]
    let labels: [String]
    let gain: Float
    let labelWidth: CGFloat
    let played: Bool
    static func == (a: Self, b: Self) -> Bool {
        a.gain == b.gain && a.played == b.played && a.labels == b.labels && a.labelWidth == b.labelWidth
            && a.lanes.map(\.values) == b.lanes.map(\.values)
    }
    var body: some View {
        Canvas { ctx, size in
            guard !lanes.isEmpty else { return }
            let plot = size.width - labelWidth
            let laneHeight = size.height / CGFloat(lanes.count)
            let color = Color.blue.opacity(played ? 0.95 : colorScheme == .dark ? 0.65 : 0.42)
            for (index, lane) in lanes.enumerated() {
                let top = CGFloat(index) * laneHeight
                let mid = top + laneHeight / 2
                if !played {
                    if index > 0 { ctx.fill(Path(CGRect(x: 0, y: top, width: size.width, height: 0.5)), with: .color(.primary.opacity(0.08))) }
                    let label = labels.indices.contains(index) ? labels[index] : "\(index + 1)"
                    ctx.draw(Text(label).font(.system(size: min(11, max(7, laneHeight * 0.45)), weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary), at: CGPoint(x: 4, y: mid), anchor: .leading)
                }
                let count = lane.values.count / 2
                guard count > 0 else { continue }
                let bars = max(1, min(count, Int(plot / 2)))
                for i in 0..<bars {
                    let start = i * count / bars, end = max(start + 1, (i + 1) * count / bars)
                    var lo: Float = 1, hi: Float = -1
                    for b in start..<min(end, count) { lo = min(lo, lane.values[2 * b]); hi = max(hi, lane.values[2 * b + 1]) }
                    lo = max(-1, lo * gain); hi = min(1, hi * gain)
                    let x = labelWidth + CGFloat(i) * plot / CGFloat(bars)
                    let y0 = mid - CGFloat(max(0, hi)) * laneHeight * 0.45
                    let y1 = mid - CGFloat(min(0, lo)) * laneHeight * 0.45
                    ctx.fill(Path(CGRect(x: x, y: y0, width: max(1, plot / CGFloat(bars) - 0.5), height: max(0.75, y1 - y0))),
                             with: .color(color))
                }
            }
        }
    }
}

/// Log-frequency spectrogram (20 Hz – Nyquist) rendered once into an image.
private struct SpectrogramView: View {
    let spectrogram: Spectrogram
    let fraction: Double
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geo in
            let axis: CGFloat = 34
            let plot = geo.size.width - axis
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                        .frame(width: plot, height: geo.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .offset(x: axis)
                }
                ForEach([100.0, 1_000.0, 10_000.0], id: \.self) { hz in
                    if hz < spectrogram.maxHz {
                        let y = geo.size.height * (1 - log(hz / spectrogram.minHz) / log(spectrogram.maxHz / spectrogram.minHz))
                        Text(hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))")
                            .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                            .position(x: axis / 2 - 2, y: y)
                        Rectangle().fill(Color.white.opacity(0.12)).frame(width: plot, height: 0.5).offset(x: axis, y: y)
                    }
                }
                Rectangle().fill(Color.white).frame(width: 1, height: geo.size.height)
                    .offset(x: axis + max(0, min(plot - 1, fraction * plot)))
            }
        }
        .task(id: spectrogram.values.count) { image = Self.render(spectrogram) }
    }

    /// Dark violet → magenta → orange → pale yellow, low values nearly black.
    static func render(_ s: Spectrogram) -> CGImage? {
        let stops: [(Double, (Double, Double, Double))] = [
            (0.0, (0.02, 0.01, 0.06)), (0.35, (0.25, 0.05, 0.45)), (0.6, (0.75, 0.15, 0.45)),
            (0.8, (0.98, 0.5, 0.2)), (1.0, (1.0, 0.95, 0.7))]
        var lut = [UInt8](repeating: 0, count: 256 * 4)
        for v in 0..<256 {
            let t = Double(v) / 255
            let k = max(0, min(stops.count - 2, (stops.firstIndex { $0.0 >= t } ?? stops.count - 1) - 1))
            let (t0, c0) = stops[k], (t1, c1) = stops[k + 1]
            let f = t1 > t0 ? (t - t0) / (t1 - t0) : 0
            lut[v * 4] = UInt8(255 * (c0.0 + (c1.0 - c0.0) * f))
            lut[v * 4 + 1] = UInt8(255 * (c0.1 + (c1.1 - c0.1) * f))
            lut[v * 4 + 2] = UInt8(255 * (c0.2 + (c1.2 - c0.2) * f))
            lut[v * 4 + 3] = 255
        }
        var pixels = [UInt8](repeating: 0, count: s.columns * s.rows * 4)
        for x in 0..<s.columns {
            for r in 0..<s.rows {
                let v = Int(s.values[x * s.rows + r])
                let o = ((s.rows - 1 - r) * s.columns + x) * 4
                pixels[o] = lut[v * 4]; pixels[o + 1] = lut[v * 4 + 1]; pixels[o + 2] = lut[v * 4 + 2]; pixels[o + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: s.columns, height: s.rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: s.columns * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
