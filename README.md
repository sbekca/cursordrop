[README (2).md](https://github.com/user-attachments/files/27297154/README.2.md)
# CursorDrop

Drag files or paste screenshots into a floating widget — they're instantly uploaded to your remote SSH server and the path appears in your Claude Code terminal. Zero friction.

## The Problem

Using Claude Code over SSH in Cursor or VS Code, getting a local file onto the remote server is painful: drag to file tree, wait for sync, find the path, paste it. Every. Single. Time.

## The Solution

CursorDrop is a tiny floating pill that sits on top of your editor. Drop a file on it or paste a screenshot — the remote path appears in your terminal instantly. The actual upload happens in the background.

## How Fast?

- **Drag a file** → path appears instantly, upload runs in background
- **Paste a copied file** → instant
- **Paste a screenshot** → ~50ms on Windows (native GDI+), ~100ms on macOS (native NSBitmapImageRep)

The path is pasted into your terminal before any network call happens. By the time you finish typing your prompt and hit Enter, the file is already there.

## Install

### Windows

1. Install [AutoHotkey v2](https://www.autohotkey.com/)
2. Download `CursorDrop.ahk`
3. Double-click to run

### macOS

1. Download and unzip `CursorDrop-macOS.zip`
2. Run `bash install.sh`
3. Grant Accessibility access when prompted

Requires Xcode command line tools (the install script will prompt if missing). No other dependencies.

## Requirements

- SSH key auth configured — `scp yourhost:/path` must work without a password prompt
- Cursor or VS Code connected to a remote server via Remote-SSH
- Windows 10/11 or macOS 13+
- [FFmpeg](https://ffmpeg.org/) (optional — only needed for video frame extraction)

## Usage

**Drag and drop** — drag any file from Explorer/Finder onto the pill.

**Clipboard paste** — copy a file or take a screenshot, then:
- **Windows:** click the pill, press Ctrl+V
- **macOS:** press Ctrl+Cmd+V from anywhere, or click the ⬆ menubar icon

**Watch folder** — drop files into `~/CursorDrop/` from any app. They're automatically uploaded and the local copy is deleted. Works great with [LocalSend](https://localsend.org/) for sending files from your phone.

**Right-click menu:**
- Pin/unpin to editor window
- Switch dark/light theme
- Resize presets
- Video frame rate presets
- Open watch folder
- Clean all remote files (with confirmation)
- Show log

## Video Support

Drop a video file onto CursorDrop and it extracts frames using FFmpeg, uploads them as a folder, and pastes the folder path. Claude can read the frames to understand what happened on screen — great for screen recordings of bugs.

**Supported formats:** mp4, mov, webm, avi, mkv, wmv

**Frame rate presets (right-click → Video frame rate):**
- 0.5 fps — 1 frame every 2 seconds, for long recordings
- 1 fps — default, good for most screen recordings
- 2 fps — more detail, for faster interactions
- 4 fps — animations and quick UI transitions

Videos longer than 30 seconds are clipped. Hard cap of 60 frames.

**Install FFmpeg:**
- Windows: `winget install ffmpeg`
- macOS: `brew install ffmpeg`

CursorDrop will prompt you if FFmpeg is missing when you drop a video.

**Remote structure:**
```
.cursor-drop-files/
├── 20260501-screenshot.png
└── 20260501-bug-recording-frames/
    ├── frame_001.jpg
    ├── frame_002.jpg
    └── ...
```

## Watch Folder & LocalSend

CursorDrop watches `~/CursorDrop/` for new files. Anything dropped in that folder is automatically uploaded, the path is pasted into your terminal, and the local copy is deleted.

To send files from your phone directly into Claude Code:

1. Install [LocalSend](https://localsend.org/) on your PC/Mac and phone
2. In LocalSend settings, set the save directory to `~/CursorDrop`
3. Enable Quick Save
4. Send a file from your phone — the path appears in Claude Code automatically

## Features

- Pins to your Cursor/VS Code window — follows it across monitors as you move or resize
- Drag the pill while pinned to set a custom offset
- Dark and light mode (auto-detects system theme, or toggle manually)
- Resizable — drag edges or pick a preset
- Remembers size, position, pin offset, theme, and video FPS across restarts
- Remote files go into `.cursor-drop-files/` under your workspace root
- Cleanup counts files and asks for confirmation before deleting
- Full log file for debugging

## How It Works

1. You drop or paste a file
2. CursorDrop builds the remote path locally (zero network, instant)
3. The path is pasted into your terminal immediately
4. In the background: `ssh mkdir -p && touch` creates a placeholder, then `scp` uploads the real file

For videos: frames are extracted locally with FFmpeg, then uploaded as a folder in a single `scp` call.

## Supported Editors

- Cursor
- VS Code
- VS Code Insiders

Automatically detects the active editor, reads the SSH alias from the window title, and resolves the remote workspace path from the editor's storage (including Cursor's hex-encoded format).

## Configuration

### Windows
Edit the config block at the top of `CursorDrop.ahk`:

### macOS
Settings are saved automatically to `~/.config/cursordrop/settings.json`. Configure via the right-click menu.

| Setting | Default | Description |
|---------|---------|-------------|
| `remoteSubdir` | `.cursor-drop-files` | Folder created under your remote workspace root |
| `sshTimeout` | `30` | SSH/SCP timeout in seconds |
| `watchDir` | `~/CursorDrop` | Local folder watched for new files |
| `videoFPS` | `1` | Frames per second for video extraction |
| `videoMaxSec` | `30` | Max video duration to process |

## License

MIT
