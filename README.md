# NotchKit

A small panel of tools that lives at the top of the screen: hover over it (or press the shortcut) and it opens.

| | Folder | Built with |
|---|---|---|
| macOS (in the MacBook notch) | [`macos/`](macos/README.md) | Swift, SwiftUI |
| Windows (a notch drawn at the top centre) | [`windows/`](windows/README.md) | C#, WPF, .NET 10, plus a Windows service |

The two are separate native apps with the same widgets and settings. They share no code; a change to one is ported to the other by hand.

## Download

- **Windows:** [NotchKit-Installer.exe](https://github.com/Emidolo/NotchKit/releases/latest/download/NotchKit-Installer.exe). Open it: it downloads NotchKit, installs it and opens it. If Windows says it protected your PC, click **More info → Run anyway**.
- **Mac:** [NotchKit.dmg](https://github.com/Emidolo/NotchKit/releases/latest/download/NotchKit.dmg). Open it and drag NotchKit to Applications. The first time, allow it in System Settings → Privacy & Security → **Open Anyway**.

## Releasing

Push a version tag and [the release workflow](.github/workflows/release.yml) builds both installers on GitHub's machines and publishes them:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

| | Files in the release | Built locally with |
|---|---|---|
| macOS | `NotchKit.dmg` | `cd macos && make dmg` |
| Windows | `NotchKit-Installer.exe` (small downloader), `NotchKit-setup.exe` (full installer: app + service) | `windows\build-installer.ps1`, on Windows |

Keep the version in `macos/Resources/Info.plist` and the `windows/*/*.csproj` files in step with the tag.
