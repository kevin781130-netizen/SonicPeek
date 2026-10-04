import Cocoa
import PeekUI

/// Explicit local visual check. Never plays audio or registers the extension.
@MainActor enum PreviewRenderer {
    static func render(_ preview: AudioPreviewController, in window: NSWindow, file: URL, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.appearance = NSAppearance(named: .aqua)
        try await capture(window, to: directory.appendingPathComponent("peek-empty.png"))
        window.setContentSize(NSSize(width: 780, height: 860))
        window.center()
        try await preview.prepare(file)
        preview.seek(to: 0.32)
        // Wait for the loudness / spectrum pass (bounded).
        for _ in 0..<200 where preview.model.analysis == nil && preview.model.analysisProgress != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        // Playback stays disabled here, so meters get fixed demo values for the layout check only.
        let n = preview.model.lanes.count
        preview.model.meterAverage = (0..<n).map { -30 + Float($0 % 5) * 5 }
        preview.model.meterPeak = (0..<n).map { -24 + Float($0 % 5) * 5 }
        // Shown as playing (Pause button) to match autoplay; nothing is played in this mode.
        preview.model.isPlaying = true
        for (name, appearance) in [("peek-light", NSAppearance.Name.aqua), ("peek-dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            for mode in PreviewModel.DisplayMode.allCases where mode != .channels || n > 1 {
                preview.model.mode = mode
                try await capture(window, to: directory.appendingPathComponent("\(name)-\(mode.rawValue.lowercased()).png"))
            }
        }
        // Full page with both disclosure groups open (dark, current file).
        preview.model.mode = n > 2 ? .channels : .waveform
        preview.model.showFileDetails = true; preview.model.showRecordingMetadata = true
        window.setContentSize(NSSize(width: 780, height: min(1640, (window.screen?.visibleFrame.height ?? 1000) - 40)))
        window.center()
        try await capture(window, to: directory.appendingPathComponent("peek-dark-details-top.png"))
        // The page is taller than the screen: scroll to the end for the metadata rows.
        if let scroll = firstScrollView(in: window.contentView), let doc = scroll.documentView {
            window.contentView?.layoutSubtreeIfNeeded()
            let y = doc.isFlipped ? max(0, doc.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        try await capture(window, to: directory.appendingPathComponent("peek-dark-details.png"))
        preview.model.showFileDetails = false; preview.model.showRecordingMetadata = false
        fputs("render PASS: empty, light and dark × waveform / channels / spectrum; playback disabled\n", stderr)
    }

    private static func firstScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let s = view as? NSScrollView { return s }
        for sub in view.subviews { if let s = firstScrollView(in: sub) { return s } }
        return nil
    }

    private static func capture(_ window: NSWindow, to url: URL) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        // WindowServer capture is required for composited native Liquid Glass.
        try await Task.sleep(for: .milliseconds(700))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "PeekPreview", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Window capture failed. Check Screen Recording permission."])
        }
    }
}
