# bisrt – Bilingual Subtitle Generator

> **bisrt** is a lightweight, cross‑platform tool that automatically generates bilingual (Japanese ↔ Chinese) subtitles for video files. It uses **Whisper** for speech‑to‑text, a local **llama‑cpp** translation server for fast on‑device translation, and a small IINA plugin that lets you generate subtitles directly from the player.

> **Author**: AAIF (Agentic AI Foundation)  
> **License**: MIT (see `LICENSE`)

---

## Table of Contents

| Section | Description |
|---------|-------------|
| [Overview](#overview) | What it does |
| [Prerequisites](#prerequisites) | Software & models |
| [Installation](#installation) | CLI + IINA plugin |
| [Command‑line usage](#command-line-usage) | Running `bi‑srt.py` |
| [IINA plugin usage](#iina-plugin-usage) | Generating subtitles in the player |
| [Options & Environment Variables](#options--environment-variables) | Customising behaviour |
| [Troubleshooting](#troubleshooting) | Common issues |
| [License](#license) | Legal |

---

## Overview

The **bisrt** project is split into two independent parts:

1. **IINA Plugins** – Two lightweight JavaScript plugins that run inside the IINA media player:
   * **Load‑Subtitle** (`srtloader`) – Loads an existing `.srt` file into IINA.
   * **Generate‑Subtitle** (`bisrt`) – Calls the core Python script to create bilingual subtitles for the currently playing video.

2. **Desktop Subtitle Generator** – A macOS GUI application (`SubtitlerApp`) that acts as an IDE for batch subtitle generation. It lets you:
   * Import one or more video files or directories.
   * Choose an output folder.
   * Set parallel workers and other options.
   * Start the generation process and monitor progress, logs, and statistics.

Both parts share the same core logic implemented in `core/bi‑srt.py`. The Python script performs speech‑to‑text with Whisper, translates with a local llama‑cpp server, cleans the transcript, and writes the final `.srt` file.

The tool is written in pure Python 3 and requires only a few external binaries (`ffmpeg`, `ffprobe`, `whisper-cli`, `python3`, and the translation server).

---

## Prerequisites

| Component | Minimum version | Install |
|-----------|-----------------|---------|
| **Python** | 3.9+ | `brew install python` (macOS) or `apt install python3` (Linux) |
| **ffmpeg** | 4.2+ | `brew install ffmpeg` |
| **whisper‑cli** | 1.0+ | `pip install whisper-cli` |
| **llama‑cpp** | 0.2+ | `git clone https://github.com/ggerganov/llama.cpp && cd llama.cpp && make` |
| **Translation model** | `HY‑MT1.5‑1.8B‑Q4_K_M.gguf` | Download from the repo or your own source |
| **Whisper model** | `ggml-large-v3-turbo.bin` | Download from the Whisper repo or your own source |
| **IINA** (macOS only) | 1.9+ | [Download](https://iina.io/) |

> **Tip** – The script will automatically start the translation server if it isn’t already running.

---

## Installation

### 1. Clone the repo

```bash
git clone https://github.com/AAIF/bisrt.git
cd bisrt
```

### 2. Install the IINA plugin (optional)

```bash
# From the repo root
./install.sh
```

The script copies the core script and the two IINA plugins into your `~/Library/Application Support/com.colliderli.iina/plugins` directory.

> **Note** – If you want to use the CLI only, you can skip this step.

### 3. Set up environment variables

```bash
# Add to ~/.zshrc or ~/.bash_profile
export WHISPER_MODEL="$HOME/whisper-models/ggml-large-v3-turbo.bin"
export MT_MODEL="$HOME/llm-models/HY-MT1.5-1.8B-Q4_K_M.gguf"
export MT_PORT=8181          # port for the translation server
export MT_PARALLEL=4         # number of parallel translation workers
export MT_BATCH=12           # batch size for translation
export WHISPER_THREADS=8     # threads for whisper
export MAX_LINE=40           # max lines per SRT block
export DEFAULT_LANG=ja       # default language if detection fails
export LID_MIN_P=0.85        # language detection confidence threshold
export REPEAT_MAX=4          # max repeated characters before collapsing
export DROP_NOISE=1          # drop pure noise lines
export MT_KEEP=0             # keep translation output (1 = keep)
```

> **Tip** – Adjust `MT_PARALLEL` and `MT_BATCH` to match your CPU/GPU resources.

---

## Command‑line usage

```bash
python3 core/bi-srt.py [options] <video-or-directory> ...
```

### Options

| Flag | Description |
|------|-------------|
| `--progress <file>` | Write progress JSON to `<file>` (used by the IINA plugin). |
| `--out <dir>` | Output directory for generated SRT files. If omitted, the SRT is written next to the video. |
| `--fast` | Use a faster pipeline that skips some cleaning steps. Good for quick tests. |
| `--workers N` | Number of parallel workers for the main loop (default 1). |
| `--help` | Show help. |

### Examples

```bash
# Generate subtitles for a single file
python3 core/bi-srt.py /path/to/video.mp4

# Batch process a folder
python3 core/bi-srt.py /path/to/videos/

# Use a custom output directory
python3 core/bi-srt.py --out ~/subtitles /path/to/video.mp4

# Run in fast mode
python3 core/bi-srt.py --fast /path/to/video.mp4
```

> **Output** – For each video, a `<basename>.srt` file is created. If the file already exists and is non‑empty, the script skips that video.

---

## IINA plugin usage

1. **Open IINA** and load a video.  
2. In the **menu bar → Subtitle → 字幕模式** choose:
   * **关闭字幕** – No subtitles.
   * **中日双语** – Generate bilingual subtitles (default).
   * **仅中文** – Generate Chinese‑only subtitles.
3. Click **生成双语字幕（当前视频）** (or press `⌘⇧G`).  
   * The plugin will run `bi‑srt.py` in the background.  
   * Progress is shown in the menu title and a JSON file (default `~/bisrt-progress.json`).
4. Once finished, the plugin automatically loads the generated `.srt` file as a subtitle track.

> **Force regenerate** – If you want to re‑run the script even if an SRT already exists, choose **强制重新生成字幕**.

---

## Options & Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `WHISPER_MODEL` | Path to Whisper model | `~/whisper-models/ggml-large-v3-turbo.bin` |
| `MT_MODEL` | Path to translation model | `~/llm-models/HY-MT1.5-1.8B-Q4_K_M.gguf` |
| `MT_PORT` | Port for translation server | `8181` |
| `MT_PARALLEL` | Parallel translation workers | `4` |
| `MT_BATCH` | Batch size for translation | `12` |
| `WHISPER_THREADS` | Threads for Whisper | `8` |
| `MAX_LINE` | Max lines per SRT block | `40` |
| `DEFAULT_LANG` | Default language if detection fails | `ja` |
| `LID_MIN_P` | Language detection confidence threshold | `0.85` |
| `REPEAT_MAX` | Max repeated characters before collapsing | `4` |
| `DROP_NOISE` | Drop pure noise lines | `1` |
| `MT_KEEP` | Keep translation output files (`1` = keep) | `0` |

> **Tip** – The script automatically starts the translation server on the first run. If you want to run the server manually, use `./core/bi-srt.py --server` (not documented in the README but available in the code).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `whisper-cli` not found | Missing Whisper CLI | `pip install whisper-cli` |
| `ffmpeg`/`ffprobe` not found | FFmpeg missing | `brew install ffmpeg` |
| Translation server fails | Wrong `MT_MODEL` path or port conflict | Verify `MT_MODEL` exists; kill any process on `MT_PORT` |
| No subtitles generated | Video has no audio or is silent | Check with `ffprobe -i video.mp4` |
| Script hangs | Large video, insufficient RAM | Use `--fast` or split the video |
| IINA plugin not loading | Plugin folder wrong | Run `./install.sh` again or check `~/Library/Application Support/com.colliderli.iina/plugins` |

---

## License

MIT – see the `LICENSE` file in the repository.

---

### Quick Reference

```bash
# Batch process all videos in a folder
python3 core/bi-srt.py /path/to/videos/

# Generate subtitles for a single file, output to custom dir
python3 core/bi-srt.py --out ~/subtitles /path/to/video.mp4

# Run the IINA plugin (after installing)
# 1. Open IINA → Subtitle → 字幕模式 → 中日双语
# 2. Press ⌘⇧G or click “生成双语字幕（当前视频）”
```

Happy subtitling!
