<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="RePaste">
</p>

<h1 align="center">RePaste</h1>

<p align="center">
  A native macOS clipboard history tool built for keyboard workflows<br>
  Text, code, link, and image capture with full-text search, Pinyin search, and fast paste-back
</p>

<p align="center">
  <a href="#workflow">Workflow</a> ·
  <a href="#build-from-source">Build from source</a>
</p>

<p align="center">
  <a href="README.en.md">English</a>
  <a href="README.md">简体中文</a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License: AGPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/storage-SQLite-2f74c0" alt="SQLite">
</p>

---

<p align="center">
  <img alt="RePaste clipboard history palette" src=".github/assets/app.png" width="860">
</p>

## About

RePaste is a native macOS clipboard history tool that keeps copied content inside a lightweight command palette. It recognizes text, code, links, and images, records the source application, and turns search, selection, and paste-back into a keyboard-driven workflow.

History is stored in a local SQLite database, with image payloads managed as local files. SQLite FTS5 and a Pinyin index search the complete history, including Chinese text found through full spelling or initials.

## Why RePaste

The system clipboard remembers only the latest copy, while many clipboard managers turn into permanent, feature-heavy windows. RePaste behaves more like a focused command palette: summon it when needed, find and paste an item, then return immediately to the previous app.

- **Multiple content types**: classifies plain text, code, links, and images
- **Full-history search**: SQLite FTS5 searches beyond the in-memory window
- **Pinyin search**: supports full spelling and initials with source-text highlighting
- **Keyboard first**: arrow-key selection plus shortcuts for paste, pin, preview, and actions
- **Image preview**: on-demand thumbnails and a Space-bar Quick Look sized to available screen space
- **Source aware**: displays the copy source and pastes back into the app that was active before the palette opened

## Workflow

Press `Option + W` to show or hide the palette. Type to search, move with the arrow keys, and press Return to paste.

- `Return`: paste and close the palette
- `Command + Return`: copy the selected item
- `Command + P`: pin or unpin an item
- `Space`: preview an image
- Action menu: paste while keeping the palette open, reveal images in Finder, delete entries, and more

The global shortcut is configurable. RePaste can also switch to an English input source when the palette opens, making Pinyin queries immediately available.

## Local Storage and Privacy

The clipboard database and image files stay on the Mac; no cloud service is required. Retention can be set from one day to forever, and pinned items are exempt from automatic pruning.

Applications can be excluded from capture. Keychain Access and Passwords are excluded by default so sensitive content does not enter history. Accessibility permission is required to deliver the selected item reliably to the original target app.

## More Features

- Sections for pinned, today, yesterday, past seven days, past thirty days, and earlier
- Code syntax highlighting and link recognition
- Memory-bounded image caches with background downsampling
- Launch at login
- System, light, and dark appearances
- Simplified Chinese and English interfaces

## Build from Source

You need macOS 26, Xcode 26, and Swift 6.

```bash
git clone https://github.com/Aaron48615/Paste.git
cd Paste
open Paste.xcodeproj
```

Select the **Paste** scheme and choose **Product → Run**. Grant Accessibility permission when prompted before the first paste operation.

## Independent RePaste fork

RePaste is Aaron's independently developed fork of [imeelinew/Paste](https://github.com/imeelinew/Paste). The upstream attribution and AGPL-3.0 license are retained.

The product is `RePaste.app` (`com.aaron.RePaste`) with a `repaste-cli` tool. History, images and pinned cards use `~/Library/Application Support/com.aaron.RePaste`; preferences and Accessibility grants are separate from the original app. Before the first RePaste run, optionally copy existing data with `python3 scripts/import-paste-data.py`. The script never overwrites an existing RePaste installation's data.

Updates are disabled until a RePaste-owned feed and key are configured; see [RELEASING.md](RELEASING.md). The Xcode project, schemes and source folders retain their original names to reduce upstream merge friction. Builds produce RePaste. Local ad-hoc signing may still require renewed Accessibility permission after rebuilds; configure a stable signing identity to address that. Assign different global shortcuts if running both apps.

For upstream contributions, start a branch from `upstream/main`, cherry-pick only general feature/fix commits, and open a PR from your fork. Keep RePaste branding, signing, updates and migration changes separate.
