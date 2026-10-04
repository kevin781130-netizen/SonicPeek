import Cocoa
import UniformTypeIdentifiers
import PeekUI
import PeekCore

@main @MainActor final class PeekHostApp {
    static func main() {
        // Developer check: `SonicPeek --analyze <file>` prints the measurements as JSON.
        if let i = CommandLine.arguments.firstIndex(of: "--analyze") {
            guard CommandLine.arguments.count == i + 2 else { exit(2) }
            do {
                let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
                let a = try AudioAnalyzer().analyze(url: url)
                func j(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "null" }
                print("{\"integrated\": \(j(a.integratedLUFS)), \"lra\": \(j(a.loudnessRangeLU)), \"truePeak\": \(j(a.truePeakDBTP)), " +
                      "\"samplePeak\": \(j(a.samplePeakDBFS)), \"channelTruePeak\": [\(a.channelTruePeakDBTP.map(j).joined(separator: ", "))], " +
                      "\"spectrogram\": [\(a.spectrogram?.columns ?? 0), \(a.spectrogram?.rows ?? 0)]}")
                exit(0)
            } catch { fputs("analyze FAIL: \(error)\n", stderr); exit(2) }
        }
        let app = NSApplication.shared
        let delegate = PeekAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(CommandLine.arguments.contains("--smoke-test") ? .accessory : .regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class PeekAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let preview = AudioPreviewController()
    private var window: NSWindow?
    private var request: Task<Void, Never>?
    private var scopedURL: URL?
    private var openPanel: NSOpenPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.delegate = self
        w.minSize = NSSize(width: 560, height: 480)
        preview.openFileAction = { [weak self] in self?.openFile() }
        w.title = "SonicPeek"; w.contentViewController = preview; window = w
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-preview") {
            guard args.count == i + 3 else { exit(2) }
            preview.playbackAllowed = false
            w.title = "SonicPeek — Sample audio"
            request = Task {
                do {
                    try await PreviewRenderer.render(preview, in: w,
                        file: URL(fileURLWithPath: args[i + 1]),
                        directory: URL(fileURLWithPath: args[i + 2]))
                    preview.cancelPreview()
                    exit(0)
                } catch { fputs("render FAIL: \(error)\n", stderr); exit(2) }
            }
            return
        }
        if let i = args.firstIndex(of: "--perf-sim") {
            // Developer check: silent playback simulation. Drives the playhead and meters at the
            // real playback rates (20 Hz position, ~23 Hz levels) and prints this process's CPU use.
            guard args.count >= i + 3, let seconds = Double(args[i + 2]) else { exit(2) }
            let mode = args.count > i + 3 ? PreviewModel.DisplayMode(rawValue: args[i + 3]) : nil
            preview.playbackAllowed = false
            w.setContentSize(NSSize(width: 780, height: 860)); w.center(); w.orderFrontRegardless()
            request = Task {
                do {
                    try await preview.prepare(URL(fileURLWithPath: args[i + 1]))
                    for _ in 0..<200 where preview.model.analysisProgress != nil { try await Task.sleep(for: .milliseconds(100)) }
                    if let mode { preview.model.mode = mode }
                    let n = max(1, preview.model.lanes.count)
                    let model = preview.model
                    let start = Date()
                    func cpu() -> Double {
                        var u = rusage(); getrusage(RUSAGE_SELF, &u)
                        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
                    }
                    let posTimer = Timer(timeInterval: 0.05, repeats: true) { _ in
                        MainActor.assumeIsolated { model.fraction = (Date().timeIntervalSince(start) / 60).truncatingRemainder(dividingBy: 1) }
                    }
                    let levelTimer = Timer(timeInterval: 2048.0 / 48_000, repeats: true) { _ in
                        MainActor.assumeIsolated {
                            let t = Float(Date().timeIntervalSince(start))
                            model.meterPeak = (0..<n).map { -12 + 10 * sin(t * 3 + Float($0)) }
                            model.meterAverage = (0..<n).map { -20 + 10 * sin(t * 3 + Float($0)) }
                        }
                    }
                    RunLoop.main.add(posTimer, forMode: .common); RunLoop.main.add(levelTimer, forMode: .common)
                    try await Task.sleep(for: .seconds(2))
                    let c0 = cpu(), t0 = Date()
                    try await Task.sleep(for: .seconds(seconds))
                    let pct = 100 * (cpu() - c0) / Date().timeIntervalSince(t0)
                    print(String(format: "perf-sim mode=%@ channels=%d cpu=%.1f%%", preview.model.mode.rawValue, n, pct))
                    exit(0)
                } catch { fputs("perf-sim FAIL: \(error)\n", stderr); exit(2) }
            }
            return
        }
        if let i = args.firstIndex(of: "--smoke-test") {
            guard args.count == i + 2 else { exit(2) }
            preview.playbackAllowed = false
            _ = preview.view
            // Offscreen isolated window: same real NSHostingView, no focus stealing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { fputs("smoke TIMEOUT\n", stderr); exit(3) }
            request = Task {
                do {
                    try await preview.prepare(URL(fileURLWithPath: args[i+1]))
                    preview.view.layoutSubtreeIfNeeded()
                    preview.seek(to: 0.5)
                    guard preview.model.metadata != nil, preview.model.waveform?.isEmpty == false,
                          preview.model.fraction == 0.5, !preview.model.isPlaying,
                          !preview.hasPlaybackTimer else { exit(2) }
                    preview.togglePlayback() // hard-disabled, must remain silent
                    guard !preview.model.isPlaying, !preview.hasPlaybackTimer else { exit(2) }
                    preview.cancelPreview()
                    fputs("smoke PASS: shared view, seek-before-play, no playback/timer, cleanup\n", stderr)
                    exit(0)
                } catch { fputs("smoke FAIL: \(error)\n", stderr); exit(2) }
            }
            return
        }
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit SonicPeek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu
        let open = fileMenu.addItem(withTitle: "Open File…", action: #selector(openFile), keyEquivalent: "o")
        open.target = self
        NSApp.mainMenu = menu
        w.center(); w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openFile() {
        guard let window else { return }
        if let openPanel { openPanel.makeKeyAndOrderFront(nil); return }
        let panel = NSOpenPanel()
        openPanel = panel
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.openPanel = nil
            guard response == .OK, let url = panel.url else { return }
            self?.open(url)
        }
    }
    private func open(_ url: URL) {
        request?.cancel(); preview.cancelPreview()
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        request = Task { do { try await preview.prepare(url) } catch { /* visible in shared model */ } }
    }
    func windowWillClose(_ notification: Notification) {
        request?.cancel(); preview.cancelPreview()
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
