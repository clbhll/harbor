# Harbor

A macOS menu bar utility that shows every local server listening on your machine — ports, process names, and one-click open — designed to feel quiet and deliberate.

<img src="Resources/HarborIcon.png" width="128" alt="Harbor icon" />

## Why

Inspired by the eternal developer wish: glance at the menu bar, see what’s running on which port, open it, move on.

## Features

- **Menu bar home** — lives in the status area; shows a live count of listening ports
- **Live discovery** — polls `lsof` every few seconds for TCP `LISTEN` sockets
- **Readable names** — resolves app display names, and smart labels for `node` / `python` scripts
- **One click to open** — click a row to open `http://localhost:<port>`
- **Context actions** — copy URL, copy port, reveal executable, terminate process
- **Hide system noise** — optional filter for `/System` and common daemon processes
- **Search** — filter by name, port, or pid

## Requirements

- macOS 14 Sonoma or later
- Xcode 15+

## Build & run

```bash
open Harbor.xcodeproj
```

Then press **⌘R**. Harbor appears in the menu bar (no Dock icon — it’s a UIElement agent app).

Or from the command line on a Mac:

```bash
xcodebuild -project Harbor.xcodeproj -scheme Harbor -configuration Debug
```

## Design notes

Visual direction is **ink + seafoam**: deep green-black atmosphere, serif brand mark, rounded utility type for ports and metadata. The first surface is one composition — brand, status line, search, then the list. Motion is reserved for refresh, hover, and empty-state breathing.

## Project layout

```
Harbor.xcodeproj
Harbor/
├── HarborApp.swift          # MenuBarExtra entry
├── Models/
├── Services/PortScanner.swift
├── Views/
├── Theme/
└── Utilities/
```

## Privacy

Harbor runs entirely on-device. It reads local process/socket metadata via `lsof` and `libproc`. Sandbox is off so process paths and command lines can be resolved. No network calls, no analytics.

## License

MIT
