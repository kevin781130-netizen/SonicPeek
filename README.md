# UTUVO Peek

**Press Space on an audio file in Finder: see it, hear it, measure it.**
A native macOS Quick Look extension for people who deliver audio — loudness, true peak,
per-channel waveforms and meters up to 7.1.4, and the BWF / iXML / ADM details of the file.

[Download for Mac (Apple Silicon, macOS 14+)](https://github.com/mickyyang-1407/utuvo-peek/releases/latest) ·
[繁體中文](README.zh-Hant.md) · Free · MIT

[![Watch the 2-minute tutorial](docs/screenshots/tutorial-poster.webp)](https://mickyyang-1407.github.io/utuvo-peek/)

▶ [Watch the tutorial](https://mickyyang-1407.github.io/utuvo-peek/) (2:12, Traditional Chinese narration, 5 MB) · full quality in the [release assets](https://github.com/mickyyang-1407/utuvo-peek/releases/latest)

![Peek previewing a 7.1.4 ADM master](docs/screenshots/dark-714-channels.webp)

## What it shows

- **Loudness** — ITU-R BS.1770-4 integrated loudness, EBU Tech 3342 loudness range, oversampled (4× below 96 kHz)
  true peak (per channel) and sample peak. True peak above −1 dBTP turns amber, full scale red.
  Cross-checked against ffmpeg `ebur128`: within 0.1 LU on pink noise, 5.1 and 44.1 / 48 / 96 kHz test files.
- **Three views** — Waveform (all channels), Channels (one labelled lane per speaker: 5.1, 7.1, 7.1.2, 7.1.4 …)
  and Spectrum (log-frequency spectrogram, 20 Hz – Nyquist). Quiet files are drawn enlarged and say so.
- **Live meters** — per-channel peak / average bars with a 1.5 s peak hold while playing.
- **Playback** — starts when the preview opens and stops when it closes. Multichannel files play
  one-to-one on an interface with enough outputs, or binaurally (Apple HRTF) on headphones.
- **Delivery details** — duration, sample rate, bit depth, channel layout, codec; BWF `bext`
  (description, originator, time reference); iXML project / scene / tape / notes; ADM BWF
  (`axml` + `chna`, track count), Dolby `dbmd` and RF64 are recognised.

Formats: WAV / BWF / RF64, AIFF, AIFF-C, CAF, FLAC, MP3, AAC / M4A.

| Stereo mix | Spectrum | Details |
|---|---|---|
| ![Stereo](docs/screenshots/dark-stereo-waveform.webp) | ![Spectrum](docs/screenshots/dark-714-spectrum.webp) | ![Details](docs/screenshots/dark-714-details.webp) |

Screenshots use generated demo audio; the meter values in them are a fixed illustration.

## Install

1. Download the DMG from [Releases](https://github.com/mickyyang-1407/utuvo-peek/releases/latest)
   and drag **UTUVO Peek** to Applications. The app is signed with a Developer ID and notarized by Apple.
2. Open UTUVO Peek once, then quit it. This registers the Quick Look extension.
3. Select an audio file in Finder and press Space.

If Finder still shows the system preview, open System Settings › General › Login Items & Extensions ›
Quick Look and make sure UTUVO Peek is enabled.

## Privacy and resources

- Everything is computed on your Mac. No network access, no analytics.
- The Quick Look extension runs in the system sandbox and reads only the file Finder hands it.
- Loudness runs automatically up to about 30 minutes of stereo-equivalent audio; longer files
  are measured when you click **Measure loudness**.
- While playing, the preview uses about 12 % of one core for a 12-channel file (M-series Mac);
  nothing runs once the preview closes.

## Limitations

- ADM is recognised, not rendered: objects in `axml` are not parsed; channels play as a bed.
- More than 24 channels: only the first 24 are drawn.
- Headphone playback covers 3.0, quad, 5.1, 7.1, 7.1.2 and 7.1.4; other channel counts need an interface
  with enough outputs.
- BWF `bext` v1/v2 extensions and iXML beyond the common tags are ignored.
- No Finder thumbnail extension.

## Build from source

Swift, SwiftUI and AppKit only; no package dependencies.

```bash
bash scripts/build.sh            # swift build + swift test + app bundle (ad-hoc signed) in build/
swift test                       # unit tests only
"build/UTUVO Peek.app/Contents/MacOS/PeekHost" --analyze file.wav   # loudness as JSON
```

`docs/` is the GitHub Pages site (tutorial video and screenshots). `scripts/package-release.sh` makes the signed, notarized DMG (needs your own Developer ID identity
and a `notarytool` Keychain profile). `scripts/blender/` re-renders the small UI plates with Blender.

```
Sources/PeekCore       parsers (RIFF/RF64, bext, iXML), analyzer, waveform, multichannel player
Sources/PeekUI         the shared preview (SwiftUI)
Sources/PeekApp        standalone host app and developer modes
Sources/PeekExtension  the Quick Look extension (QLPreviewingController)
```

## License

MIT — see [LICENSE](LICENSE). Made by [UTUVO](https://utuvo.app).
