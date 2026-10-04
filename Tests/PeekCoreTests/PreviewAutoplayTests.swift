import XCTest
import AVFAudio
import PeekExtension

final class PreviewAutoplayTests: XCTestCase {
    /// Only generated silence is played; no user files or audio settings are touched.
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 5))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        try file.write(from: buffer)
        return url
    }

    @MainActor func testPreparedPreviewWaitsForAppearanceAndRespectsPause() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = PeekPreviewViewController()
        defer { preview.cancelPreview() }
        try await preview.preparePreviewOfFile(at: url)
        XCTAssertFalse(preview.model.isPlaying)
        XCTAssertFalse(preview.hasPlaybackTimer)
        preview.viewDidAppear()
        XCTAssertTrue(preview.model.isPlaying, preview.model.errorMessage ?? "Autoplay did not start")
        XCTAssertTrue(preview.hasPlaybackTimer)
        preview.togglePlayback()
        preview.viewDidAppear()
        XCTAssertFalse(preview.model.isPlaying, "Appearance must not undo the user's pause")
        XCTAssertFalse(preview.hasPlaybackTimer)
    }

    @MainActor func testVisiblePreviewStartsWhenReadyAndStopsOnClose() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = PeekPreviewViewController()
        defer { preview.cancelPreview() }
        _ = preview.view
        preview.viewDidAppear()
        try await preview.preparePreviewOfFile(at: url)
        XCTAssertTrue(preview.model.isPlaying, preview.model.errorMessage ?? "Autoplay did not start")
        preview.viewWillDisappear()
        XCTAssertFalse(preview.model.isPlaying)
        XCTAssertFalse(preview.hasPlaybackTimer)
        XCTAssertEqual(preview.model.fraction, 0)
        preview.togglePlayback()
        XCTAssertFalse(preview.model.isPlaying, "Closing must release the previous file")
    }

    @MainActor func testClosingWhileLoadingCannotStartLatePlayback() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = PeekPreviewViewController()
        defer { preview.cancelPreview() }
        _ = preview.view
        preview.viewDidAppear()
        let loading = Task { try await preview.preparePreviewOfFile(at: url) }
        // Let prepare reach its first suspension, then close before it completes.
        await Task.yield()
        preview.viewWillDisappear()
        _ = try? await loading.value
        XCTAssertFalse(preview.model.isPlaying)
        XCTAssertFalse(preview.hasPlaybackTimer)
    }
}
