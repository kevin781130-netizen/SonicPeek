# SonicPeek

**Press Space on an audio file in Finder: see it, hear it, measure it.**

SonicPeek is a native macOS Quick Look audio inspector for delivery and QC workflows. It shows loudness, true peak, per-channel waveforms and meters up to 7.1.4, spectrum, and BWF / iXML / ADM-related metadata without opening a DAW.

[繁體中文](README.zh-Hant.md) · Free · MIT

![SonicPeek audio preview](docs/screenshots/dark-714-channels.webp)

## Features

- **Loudness** — ITU-R BS.1770-4 integrated loudness, EBU Tech 3342 loudness range, true peak and sample peak.
- **Three views** — Waveform, per-channel lanes, and log-frequency Spectrum.
- **Live meters** — per-channel peak / average meters with peak hold while playing.
- **Multichannel playback** — direct channel-to-output routing when enough outputs are available, or Apple HRTF binaural rendering for supported speaker beds on headphones.
- **Delivery metadata** — duration, sample rate, bit depth, channel layout, codec, BWF `bext`, common iXML fields, ADM BWF presence (`axml` + `chna`), Dolby `dbmd`, and RF64 recognition.
- **Local-first** — analysis runs on your Mac; the Quick Look extension is sandboxed.

Supported formats include WAV / BWF / RF64, AIFF, AIFF-C, CAF, FLAC, MP3, and AAC / M4A.

## Current status

SonicPeek is an early-development fork and is currently version **0.1.0**. There is no official SonicPeek binary release yet; build from source for development and testing.

## Build from source

Requirements: Apple Silicon Mac, macOS 14+, Xcode command-line tools.

```bash
bash scripts/build.sh
swift test
"build/SonicPeek.app/Contents/MacOS/SonicPeek" --analyze file.wav
```

`scripts/build.sh` builds the Swift package, runs tests, creates the host app and Quick Look extension, and ad-hoc signs the local build. A custom `Resources/AppIcon.icns` is optional; if it is absent, macOS uses the default app icon.

## Project structure

```text
Sources/PeekCore       parsers, loudness/true-peak analysis, waveform, multichannel playback
Sources/PeekUI         shared SwiftUI preview
Sources/PeekApp        standalone host app and developer modes
Sources/PeekExtension  Quick Look preview extension
Tests/PeekCoreTests    analysis, parser, routing, multichannel and preview tests
```

## Roadmap

SonicPeek is intended to grow toward a fast Finder-based audio QC tool. Planned areas include stronger spectrum handling, phase/correlation checks, delivery validation, and additional regression/conformance testing.

## Upstream and license

SonicPeek is based on **UTUVO Peek**, originally developed by UTUVO contributors:
https://github.com/mickyyang-1407/utuvo-peek

The upstream project is MIT licensed. Its original copyright and MIT license notice are preserved in [LICENSE](LICENSE). See [NOTICE.md](NOTICE.md) for attribution.

Some screenshots and UI assets currently remain from the upstream project and will be replaced as SonicPeek branding evolves.
