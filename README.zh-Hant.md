# SonicPeek

**在 Finder 選音檔、按空白鍵：看得到、聽得到、量得到。**

SonicPeek 是 macOS 原生 Quick Look 音訊檢查工具，定位在交付前與 QC 工作流程。不用先打開 DAW，就能查看響度、True Peak、最多 7.1.4 的逐聲道波形與表頭、Spectrum，以及 BWF／iXML／ADM 相關資訊。

[English](README.md) · 免費 · MIT 開源

![SonicPeek 音訊預覽](docs/screenshots/dark-714-channels.webp)

## 功能

- **響度分析**：ITU-R BS.1770-4 Integrated Loudness、EBU Tech 3342 LRA、True Peak、Sample Peak。
- **三種顯示**：Waveform、逐聲道 Channels、對數頻率 Spectrum。
- **即時表頭**：播放時逐聲道 Peak／Average 與 Peak Hold。
- **多聲道播放**：輸出介面聲道足夠時一對一直出；支援的 speaker bed 可用 Apple HRTF 轉成耳機雙耳播放。
- **交付 Metadata**：長度、取樣率、位元深度、聲道配置、codec、BWF `bext`、常用 iXML、ADM BWF (`axml` + `chna`)、Dolby `dbmd`、RF64。
- **本機處理**：分析在 Mac 本機完成，Quick Look extension 使用 sandbox。

支援格式包含 WAV／BWF／RF64、AIFF、AIFF-C、CAF、FLAC、MP3、AAC／M4A。

## 目前狀態

SonicPeek 是持續開發中的 fork，目前版本為 **0.1.0**。目前尚未提供正式 SonicPeek binary release，開發測試請先從原始碼建置。

## 從原始碼建置

需求：Apple Silicon Mac、macOS 14 以上、Xcode command-line tools。

```bash
bash scripts/build.sh
swift test
"build/SonicPeek.app/Contents/MacOS/SonicPeek" --analyze file.wav
```

`scripts/build.sh` 會建置 Swift package、執行測試、產生主 App 與 Quick Look extension，並進行本機 ad-hoc signing。`Resources/AppIcon.icns` 現在是選配；尚未放入 SonicPeek 正式 icon 時，macOS 會使用預設圖示。

## 專案結構

```text
Sources/PeekCore       parser、響度 / true-peak 分析、waveform、多聲道播放
Sources/PeekUI         共用 SwiftUI 預覽介面
Sources/PeekApp        主程式與開發模式
Sources/PeekExtension  Quick Look preview extension
Tests/PeekCoreTests    分析、parser、routing、多聲道與 preview 測試
```

## 開發方向

SonicPeek 的方向是把 Finder 裡的音訊 QC 做到更完整。接下來可加入 Spectrum 改進、Phase / Correlation、交付規格檢查，以及更完整的 regression / conformance tests。

## 上游與授權

SonicPeek 基於 **UTUVO Peek** 繼續開發，原始專案由 UTUVO contributors 開發：
https://github.com/mickyyang-1407/utuvo-peek

上游採 MIT License。原始 copyright 與 MIT 授權聲明保留於 [LICENSE](LICENSE)，詳細 attribution 見 [NOTICE.md](NOTICE.md)。

目前部分截圖與 UI 素材仍沿用上游專案，之後會逐步替換成 SonicPeek 品牌素材。
