# NotchKit

A native macOS app that lives in the MacBook notch. Hover over the notch (or press ⌃⌥N) and it opens into a small panel of tools.

## Widgets

- **Music** — controls Spotify or Apple Music: artwork, title, previous / play-pause / next, and the player's volume.
- **Converter** — drop files on the notch and pick a format.
  - Images: PNG, JPG, HEIC, WebP, TIFF, GIF, BMP, with a quality slider and an optional maximum size.
  - PDF: PDF → one PNG/JPG per page at a chosen DPI; images → one PDF; merge PDFs.
  - Video: MP4, MOV, MKV, WebM, GIF, and video → audio.
  - Audio: MP3, M4A, WAV, FLAC, OGG.
  - Output goes next to the original (or a folder you choose) and never replaces an existing file.
- **YouTube** — copy a YouTube link anywhere and the notch offers "Video" or "Audio". Downloads queue up, show progress, and can be cancelled. Video is merged to MP4 at the quality you pick; audio is MP3 or M4A with thumbnail and metadata.
- **Wallpaper** — controls [MacWall](https://github.com/Emidolo/MacWall): current wallpaper, previous / next, pause, volume, and a strip of your library. MacWall stays a separate app.
- **Keep Awake** — keeps the Mac awake until turned off, for a set time, or automatically: while chosen apps or processes run, while this app is converting or downloading, on AC power, with an external display, or while Claude Code is working. Stops on low battery. Optional closed-lid mode.

While the notch is closed, small indicators beside it show conversion and download progress, a keep-awake countdown, Claude Code's status, and a pause mark when you paused the wallpaper.

## Build and run

Requires macOS 14+ and Swift 5.9+ — Xcode or just the Command Line Tools (`xcode-select --install`).

```bash
make run     # build build/NotchKit.app and open it
make app     # build only
make install # build, copy to /Applications and open that copy
make test    # unit tests
```

In Xcode: **File → Open…**, pick `Package.swift`, run the `NotchKit` scheme.

The bundle is ad-hoc signed, so nothing needs configuring. macOS may ask again for permissions after a rebuild, because the signature changed.

### Releasing

```bash
make dmg     # build/NotchKit-<version>.dmg: universal (arm64 + x86_64), with an Applications shortcut
```

Without a certificate the DMG is ad-hoc signed. It works, but Gatekeeper rejects it on other Macs: whoever downloads it has to allow it under System Settings → Privacy & Security → **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/NotchKit.app`.

For a DMG that opens without warnings you need a Developer ID Application certificate (Apple Developer Program) in your keychain, and a notarization profile stored once with `xcrun notarytool store-credentials`:

```bash
make dmg SIGN="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=your-profile
```

That signs the app with the hardened runtime (`Resources/NotchKit.entitlements`), signs the DMG, submits it for notarization and staples the ticket.

Run `make install` before turning on **Launch at login**: macOS registers the copy that is running, and it should be the one in `/Applications`.

`NOTCHKIT_NETWORK_TESTS=1 make test` also runs the tests that download a short clip from YouTube.

## Tools it uses

| Tool | Needed for | Install |
|---|---|---|
| `ffmpeg` | video and audio conversion; merging YouTube downloads | `brew install ffmpeg` |
| `cwebp` | WebP output | `brew install webp` |
| `yt-dlp` | YouTube downloads | `brew install yt-dlp` |

NotchKit looks in `/opt/homebrew/bin` and `/usr/local/bin`. When a tool is missing, the widget that needs it shows an **Install** button that runs the `brew install` for you. yt-dlp breaks whenever YouTube changes something; **Update yt-dlp** is in the YouTube widget's "…" menu.

## Permissions

| Prompt | When | Why |
|---|---|---|
| "NotchKit wants to control Spotify / Music" | first time the Music widget talks to a player | playback control goes through AppleScript |
| Administrator password | only if you install the closed-lid helper | see below |

Nothing else: no Accessibility, no Screen Recording, no Full Disk Access.

## Closed-lid mode

macOS only stays awake with the lid closed when it is on power with an external display attached. To stay awake with the lid closed and nothing attached, NotchKit can run `pmset -a disablesleep 1`, which needs root.

**Settings → Keep Awake → Install Helper** asks for your password once and adds `/etc/sudoers.d/notchkit`, a single rule that lets your user run `pmset -a disablesleep 0` and `pmset -a disablesleep 1` without a password, and nothing else. **Remove Helper** deletes it.

A closed MacBook cannot cool itself well. Sleep is disabled only while closed-lid mode is on *and* something is keeping the Mac awake, and it is restored when keep-awake ends, on battery below the floor (never lower than 10%), when the Mac reports thermal pressure, when NotchKit quits, and at the next launch after a crash. Do not put it in a bag like this.

## Claude Code

NotchKit can show "Claude is working… / Claude finished / Claude needs input" beside the notch, play a sound, and keep the Mac awake until a few minutes after Claude finishes.

Install the hooks from **Settings → Keep Awake → Install Hooks**, or by hand:

```bash
python3 Scripts/claude-hooks.py install   # adds hooks to ~/.claude/settings.json
python3 Scripts/claude-hooks.py remove
```

The script leaves your other hooks alone and keeps the previous file as `settings.json.notchkit-backup`. Each hook opens a `notchkit://claude?event=…` URL, and only when NotchKit is running. New Claude Code sessions pick the hooks up.

## MacWall

The Wallpaper widget needs MacWall with its `macwall://` URL scheme (in MacWall's `main` since commit `fd9dffd`). NotchKit reads MacWall's library and saved state from disk, sends commands through the URL scheme, and listens for MacWall's `dev.macwall.MacWall.stateChanged` notification, so wallpapers keep playing if NotchKit quits.

## Settings

Menu bar icon → **Settings…**, or the gear in the open notch.

- **General** — hover delay, panel height, hide over fullscreen apps, the keyboard shortcut (click it and press a new one), launch at login, default folders, clipboard detection.
- **Widgets** — switch widgets on and off and drag to reorder the tabs.
- **Keep Awake** — the automatic rules, Claude Code, battery floor, closed-lid mode, recent sessions.

On a Mac without a notch, the panel opens from the menu bar icon or the shortcut and drops down under the menu bar.

## How it is put together

```
Sources/NotchKit/
  App.swift            app delegate, menu bar icon
  Notch/               the panel over the notch: geometry, window, hover/drop handling, view
  Widgets/
    Widget.swift       the Widget type and WidgetStore.registry, the central list
    Music/ Converter/ YouTube/ Wallpaper/ KeepAwake/     one folder per widget: view + view model
  Shared/              running external tools, the global shortcut
  Settings/            the Settings window
Scripts/claude-hooks.py
Tests/NotchKitTests/
```

To add a widget: make a folder with its view and view model, declare `static let myWidget = Widget(id:title:icon:) { AnyView(MyView()) }` in an extension of `Widget`, and add it to `WidgetStore.registry`. Pass `indicator:` to show something beside the closed notch.

It is built to sit idle: everything is driven by notifications except two timers, the clipboard check (one integer compare a second, off when clipboard detection is off) and the process list (every 10 seconds, only while a process rule is on).

## Known limits

- Animated GIFs convert as a still image. GIFs made from video are 12 fps and at most 480px wide.
- `.ogg` output contains Opus, because Homebrew's ffmpeg has no Vorbis encoder.
- YouTube video above 1080p is VP9 or AV1, which QuickTime may not play.
- One Claude status for all sessions: the latest event wins.
- Process rules match executable names, so a tool running inside another runtime shows up under the runtime's name.
- Missing tools are installed through Homebrew only.

## License

MIT. See [LICENSE](LICENSE).
