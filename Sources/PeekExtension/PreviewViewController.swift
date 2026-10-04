import Cocoa
import Quartz
import PeekUI

/// Quick Look's principal class. Both entry paths use the same controller/view.
public final class PeekPreviewViewController: AudioPreviewController, QLPreviewingController {
    private var previewIsVisible = false
    private var autoplayPending = false

    public func preparePreviewOfFile(at url: URL) async throws {
        autoplayPending = false
        try await prepare(url)
        autoplayPending = true
        autoplayIfReady()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        previewIsVisible = true
        autoplayIfReady()
    }

    public override func viewWillDisappear() {
        previewIsVisible = false
        autoplayPending = false
        super.viewWillDisappear() // Cancels loading and stops playback immediately.
    }

    private func autoplayIfReady() {
        guard previewIsVisible, autoplayPending else { return }
        // Consume once per file, so a subsequent appearance cannot undo Pause.
        autoplayPending = false
        togglePlayback()
    }
}
