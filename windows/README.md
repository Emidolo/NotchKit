# NotchKit for Windows

The Windows port of [NotchKit](../macos/README.md). Windows has no notch, so NotchKit draws one: a small black tab at the top centre of the main screen. Hover over it (or press Ctrl+Alt+N, or click the tray icon) and it opens into the panel.

It comes in two parts:

| | What | Runs as |
|---|---|---|
| `NotchKit.exe` | the notch, the widgets, Settings, the tray icon | you, at login |
| `NotchKitService.exe` | keeps the PC awake and changes the lid action | a Windows service (LocalSystem) |

A service runs in session 0, away from the desktop, so it can't draw anything, read the clipboard, take the shortcut or type keys; that all stays in the app. The app tells the service what it needs over a named pipe. When the app quits or crashes, the pipe closes and the service lets the PC sleep and puts the lid action back.

Without the service the app still keeps the PC awake by itself; only closed-lid mode and the clean-up after a crash need the service.

## Widgets

- **Music** — whatever Windows shows in its media flyout (Spotify, a browser tab, Media Player…): artwork, title, previous / play-pause / next. No volume slider.
- **Converter** — drop files on the notch and pick a format.
  - Images: PNG, JPG, WebP, TIFF, GIF, BMP, with a quality slider and an optional maximum size. Reads HEIC when the HEIF extension from the Microsoft Store is installed.
  - PDF → one PNG/JPG per page at a chosen DPI; images → one PDF. Merging PDFs is not supported on Windows.
  - Video and audio: same formats as on the Mac.
- **YouTube** — copy a YouTube link anywhere and the notch offers "Video" or "Audio".
- **Keep Awake** — until turned off, for a set time, or automatically: while chosen apps or processes run, while this app converts or downloads, on AC power, with a second display, or while Claude Code is working. Stops on low battery. Optional closed-lid mode (needs the service).
- **Ask** — one question to OpenAI, streamed answer. The key is kept in Windows Credential Manager.
- **Typer** — switch it on, copy text, click where it should go, and three seconds later it is typed there key by key. Esc stops it. It can't type into apps running as administrator.

The Wallpaper widget is macOS only (MacWall is a Mac app).

## Install

Needs Windows 10 2004 or later, and the [.NET 10 SDK](https://dotnet.microsoft.com/download) to build. From an elevated PowerShell in this folder:

```powershell
.\install.ps1
```

That builds both, copies them to `C:\Program Files\NotchKit` and registers and starts the service (`NotchKitService`, automatic start). Then start `NotchKit.exe` from that folder (not as administrator) and turn on **Launch at login** in its Settings. `.\install.ps1 -Uninstall` removes everything.

For development, without installing:

```powershell
dotnet run --project NotchKit                     # the app
dotnet run --project NotchKitService              # the service logic, as a console program (run elevated for the lid)
dotnet run --project Tests                        # the pure logic, on any OS
```

The app also compiles on macOS and Linux (`dotnet build NotchKit`), it just doesn't run there.

For checking layouts without a mouse: `NotchKit.exe --open [widget id]` starts expanded, `--settings [general|widgets|keepAwake]` opens Settings.

## Tools it uses

| Tool | Needed for | Installed with |
|---|---|---|
| `ffmpeg` | video and audio conversion, WebP output, merging YouTube downloads | `winget install Gyan.FFmpeg` |
| `yt-dlp` | YouTube downloads | `winget install yt-dlp.yt-dlp` |

When one is missing, the widget that needs it shows an **Install** button that runs that winget command. NotchKit looks on PATH and in winget's links folder.

## Claude Code

Settings → Keep Awake → **Install Hooks** adds hooks to `%USERPROFILE%\.claude\settings.json` that run `NotchKit.exe --claude <event>`. They reach NotchKit only when it is running; otherwise they do nothing.

## Where things are kept

- Settings: `%APPDATA%\NotchKit\settings.json`
- OpenAI key: Credential Manager → Web Credentials → NotchKit
- The lid action saved by the service: `%ProgramData%\NotchKit\lid-saved.json` (only while closed-lid mode is in force)

## Not verified on Windows yet

This was written and compiled on a Mac; the logic tests pass there, but nothing has run on Windows. Worth checking first: the transparent window with the Fluent dark theme, the hover target at the top edge, focus in the Ask field, the media session, the service's power requests (`powercfg /requests` should list "NotchKit Keep Awake"), and the lid action.
