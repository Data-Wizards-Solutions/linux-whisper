# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Linux Whisper Dictation — a local, privacy-respecting voice-to-text tool for Linux. Press a hotkey (default: Ctrl+Space), speak, and transcribed text is typed at the cursor in any application. Works on both X11 and Wayland (including GNOME). No cloud APIs or internet needed after initial model download.

## Running

```bash
./run.sh                                    # Run directly from terminal
systemctl --user start whisper-dictate      # Via systemd service
systemctl --user status whisper-dictate     # Check status
journalctl --user -u whisper-dictate -f     # View logs
```

First run downloads the Whisper model (~150MB for base.en). No test suite or linter is configured.

## Installation

```bash
./install.sh   # Installs system deps, sets up permissions, creates venv, enables systemd services
```

This handles: system packages (ydotool, portaudio, ffmpeg), `input` group membership, udev rules for `/dev/uinput`, ydotoold service, Python venv with pip deps, and the whisper-dictate systemd user service.

## Architecture

**Single-file application** (`whisper_dictate.py`, ~586 lines) running as a systemd user daemon to keep the Whisper model warm in memory.

### Core Pipeline

1. **Hotkey detection** — `python-evdev` reads keyboard events at the kernel level (bypasses Wayland security model)
2. **Audio capture** — `RealtimeSTT` with VAD (Silero + WebRTC) for automatic silence detection
3. **Transcription** — `faster-whisper` (local OpenAI Whisper), model kept loaded in memory
4. **Text injection** — `ydotool` via `/dev/uinput` (kernel-level, works everywhere), with clipboard fallback

### Key Design Decisions

- **evdev for hotkeys**: Only method that detects key-release on Wayland (needed for push-to-talk). Requires `input` group.
- **ydotool for typing**: Only text injection method that works on GNOME Wayland. Falls back to wl-copy/xclip + paste.
- **Hold-to-record + VAD**: Holding the hotkey keeps recording across multiple VAD-detected phrases — each phrase is transcribed and typed as it completes (1.2s post-speech silence). Releasing the key stops recording.
- **Thread safety**: `threading.Lock` prevents concurrent recording; separate `is_recording`/`is_processing` states with 120s safety timeout.

### Code Structure in whisper_dictate.py

- **Lines 23-32**: ALSA/JACK error suppression (noisy PortAudio warnings)
- **Lines 34-59**: Config loading from `config.json`
- **Lines 61-149**: Input method detection and text typing (ydotool/xdotool/wtype/clipboard)
- **Lines 151-190**: Audio feedback (`play_sound`) and desktop notifications (`notify`)
- **Lines 194-271**: `AudioHealthMonitor` — background daemon checking microphone connectivity
- **Lines 275-371**: `WhisperDictation` — main class managing recording state and transcription
- **Lines 372-540**: Hotkey listener — evdev device discovery, hotkey parsing, main event loop (300ms debounce)
- **Lines 542-585**: `main()` entry point

## Configuration

`config.json` supports: `hotkey` (e.g. `"<ctrl>+space"`), `model` (tiny.en/base.en/small.en/medium.en/large-v3), `language`, `input_method` (auto/ydotool/xdotool/wtype/clipboard), `sound_feedback`.

## Dependencies

Python (in `requirements.txt`): `RealtimeSTT>=0.3.0`, `evdev>=1.6.0`. System: ydotool, portaudio19-dev, ffmpeg, wl-clipboard (Wayland).
