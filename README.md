[README.md](https://github.com/user-attachments/files/27294477/README.md)
# CursorDrop

Drag files or paste screenshots into a floating widget — they're instantly uploaded to your remote SSH server and the path appears in your Claude Code terminal. Zero friction.

## The Problem

Using Claude Code over SSH in Cursor or VS Code, getting a local file onto the remote server is painful: drag to file tree, wait for sync, find the path, paste it. Every. Single. Time.

## The Solution

CursorDrop is a tiny floating pill that sits on top of your editor. Drop a file on it or Ctrl+V a screenshot — the remote path appears in your terminal instantly. The actual upload happens in the background.

## How Fast?

- **Drag a file** → path appears instantly, upload runs in background
- **Ctrl+V a copied file** → instant (native Win32 clipboard, no PowerShell)
- **Ctrl+V a screenshot** → ~50ms (native GDI+ encoding, no PowerShell)

The path is pasted into your terminal before any network call happens. By the time you finish typing your prompt and hit Enter, the file is already there.

## Install

1. Install [AutoHotkey v2](https://www.autohotkey.com/)
2. Download `CursorDrop.ahk`
3. Double-click to run

That's it.

## Requirements

- Windows 10/11
- AutoHotkey v2
- SSH key auth configured — `scp yourhost:/path` must work without a password prompt
- Cursor or VS Code connected to a remote server via Remote-SSH

## Usage

**Drag and drop** — drag any file from Explorer onto the pill.

**Clipboard paste** — copy a file (right-click → Copy) or take a screenshot (Win+Shift+S), click the pill, press Ctrl+V.

**Watch folder** — drop files into `%USERPROFILE%\CursorDrop\` from any app. They're automatically uploaded and the local copy is deleted. Works great with [LocalSend](https://localsend.org/) for sending files from your phone.

**Right-click menu:**
- Pin/unpin to editor window
- Switch dark/light theme
- Resize presets
- Open watch folder
- Clean all remote files (with confirmation)
- Show log

## Features

- Pins to your Cursor/VS Code window — follows it across monitors as you move or resize
- Drag the pill while pinned to set a custom offset
- Dark and light mode (auto-detects Windows theme, or toggle manually)
- Resizable — drag edges or pick a preset
- Remembers size, position, pin offset, and theme across restarts
- Remote files go into `.cursor-drop-files/` under your workspace root
- Cleanup counts files and asks for confirmation before deleting
- Full log file for debugging

## How It Works

1. You drop or paste a file
2. CursorDrop builds the remote path locally (zero network, instant)
3. The path is pasted into your terminal immediately
4. In the background: `ssh mkdir -p && touch` creates a placeholder, then `scp` uploads the real file

Screenshots are saved via native GDI+ DllCalls — no PowerShell process spawn.

## Supported Editors

- Cursor
- VS Code
- VS Code Insiders

Automatically detects the active editor, reads the SSH alias from the window title, and resolves the remote workspace path from the editor's storage (including Cursor's hex-encoded format).

## Configuration

Edit the config block at the top of `CursorDrop.ahk`:

| Setting | Default | Description |
|---------|---------|-------------|
| `remoteSubdir` | `.cursor-drop-files` | Folder created under your remote workspace root |
| `sshTimeout` | `30` | SSH/SCP timeout in seconds |
| `watchDir` | `%USERPROFILE%\CursorDrop` | Local folder watched for new files |

## LocalSend Integration

To send files from your phone directly into Claude Code:

1. Install [LocalSend](https://localsend.org/) on your PC and phone
2. In LocalSend settings on PC, set the save directory to `%USERPROFILE%\CursorDrop`
3. Enable Quick Save
4. Send a file from your phone — the path appears in Claude Code automatically

## License

MIT
