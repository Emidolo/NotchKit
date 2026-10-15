# NotchKit

A small panel of tools that lives at the top of the screen: hover over it (or press the shortcut) and it opens.

| | Folder | Built with |
|---|---|---|
| macOS (in the MacBook notch) | [`macos/`](macos/README.md) | Swift, SwiftUI |
| Windows (a notch drawn at the top centre) | [`windows/`](windows/README.md) | C#, WPF, .NET 10, plus a Windows service |

The two are separate native apps with the same widgets and settings. They share no code; a change to one is ported to the other by hand.
