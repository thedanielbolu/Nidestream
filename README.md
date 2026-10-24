# Nidestream

A native macOS download manager modelled on [Internet Download Manager](https://www.internetdownloadmanager.com/):
multi-connection downloads, pause/resume, browser integration, a video grabber, queues and a scheduler.
Built with Swift, SwiftUI and AppKit. No third-party dependencies.

## Features

| IDM feature | Nidestream |
| --- | --- |
| Download acceleration (dynamic file segmentation) | Up to 32 connections per file, each on its own TCP connection. When a connection finishes early it takes over half of the largest range still in progress. |
| Resume broken downloads | Progress is saved every few seconds. Resumes after pauses, network errors, quitting or crashes, and uses `If-Range` to detect files that changed on the server. |
| Error recovery | Per-connection retries with backoff. Detects servers that limit connections (403/429/503) and backs off to what they allow. Falls back to a single stream when ranges aren't supported. |
| Browser integration | Extension for Chrome, Edge, Brave, Arc, Vivaldi, Opera and Firefox: takes over downloads of chosen file types (with cookies, referrer and user agent), adds "Download with Nidestream", "Download selected links" and "Download all links" menus. |
| Video grabber | The extension detects video/audio files and HLS (`.m3u8`) streams as pages play them, shows them in its popup and puts a "Download video" button over large videos. HLS streams (including AES-128 encrypted ones) are downloaded segment by segment, with quality selection, and remuxed to MP4 with FFmpeg if it's installed. |
| Queue and scheduler | "Download Later" puts files in the main queue. Start/stop the queue at set times on chosen days, limit how many files download at once, then quit, sleep or shut down when it's done. |
| Speed limiter | Global limit (toolbar, menu bar, ⌥⌘L) plus optional per-file limits. |
| Categories | Compressed, Documents, Music, Programs, Video and General, each with editable extensions and its own save folder. |
| Clipboard monitoring | Copy a link to a downloadable file and Nidestream offers to download it. |
| Batch download | `https://site/img*.jpg` with `*` from 1 to 100 (zero-padded) or a to z. |
| Site grabber | Crawl a site to a chosen depth and pick which of the files found to download. |
| Authentication, proxies | Basic/Digest/NTLM logins (passwords in the Keychain), per-download or per-site. HTTP and SOCKS proxies, or the system setting. |
| Drag and drop, import/export | Drop links on the window. Import links from a text file, export selected links. |
| Command line | `Nidestream --download <url> [--out <folder>] [--connections <n>] [--limit <KB/s>]`, and `open "nidestream://add?url=…"` (add `&silent=1` to skip the dialog). |
| Virus check after download | Finished files get the macOS quarantine flag and "Where from" metadata, like Safari downloads, so Gatekeeper and XProtect check them when opened. |

Mac-specific extras: a menu bar item with live speeds, Dock badge and Dock menu, notifications,
keeping the Mac awake while downloading, and SHA-256 checksums for finished files.

## Build and run

Needs macOS 14 or later and Swift 5.10+ (the Command Line Tools are enough, Xcode is optional).

```bash
scripts/build-app.sh
```

```bash
open build/Nidestream.app
```

`scripts/build-app.sh --install` also copies the app to `/Applications`. The app is ad-hoc signed,
which is fine for your own Mac. To distribute it, sign it with a Developer ID and notarize it.

## Install the browser extension

1. Open Nidestream, then **Settings → Browser → Show Extension Folder**. The folder is
   `~/Library/Application Support/Nidestream/BrowserExtension`.
2. **Chrome, Edge, Brave, Arc, Vivaldi, Opera:** open the Extensions page (`chrome://extensions`),
   turn on **Developer mode**, click **Load unpacked** and choose that folder.
3. **Firefox:** open `about:debugging` → **This Firefox** → **Load Temporary Add-on…** and choose
   `manifest.json` in that folder. Temporary add-ons are removed when Firefox quits. For a permanent
   install, sign the extension at addons.mozilla.org.

The extension talks to the app over `http://127.0.0.1:51515`. The app only listens on the loopback
address and rejects requests from web pages (by `Origin`), DNS-rebinding attempts (by `Host`) and
cross-site form posts (JSON only).

**Safari** extensions have to be packaged in an Xcode project, so there's no Safari extension yet.
In Safari, use the clipboard monitor, drag links into Nidestream, or this bookmarklet:

```
javascript:location.href='nidestream://add?url='+encodeURIComponent(location.href)
```

With Xcode installed, `xcrun safari-web-extension-converter BrowserExtension` can produce a Safari
version of the same extension.

## Tests

```bash
scripts/test.sh
```

This runs the unit tests, then starts `scripts/test-server.py`, a local server that serves files with
byte ranges and a per-connection speed cap, and runs integration tests against it: pause/resume,
resuming with more connections, detecting a changed file, the speed limiter, and HTTP errors.
`scripts/test.sh --unit` runs only the unit tests.

## Project layout

```
Sources/NidestreamCore/         Download engine (no UI)
  SegmentedDownloader.swift    Multi-connection HTTP engine, dynamic segmentation, paced speed limiting
  SegmentPlanner.swift         How files are split between connections
  HLS.swift                    HLS playlist parser and stream downloader (AES-128)
  Prober.swift                 Size, name, type and range support of a link
  HTTPHeaderParsing.swift      Content-Disposition, Content-Range, file names
  Links.swift                  Link extraction, site crawler, batch patterns
  HTTPServerParsing.swift      Tiny HTTP parser for the browser bridge
Sources/Nidestream/             The app
  App/                         App entry, download manager, settings, actions, command line
  Services/                    Browser bridge, clipboard monitor, scheduler, notifications, Keychain
  Views/                       Main window, details panel, dialogs, settings, menu bar
BrowserExtension/            Chromium/Firefox extension (Manifest V3)
scripts/                     Build, test, icon and test-server scripts
```

## Limitations

- **No FTP.** macOS no longer supports FTP in URLSession.
- **No DASH (`.mpd`) and no DRM-protected streams.** Widevine/FairPlay-protected video (Netflix,
  Disney+ and the like) can't be downloaded, by design. Live HLS streams aren't supported either.
- **No site-specific extraction.** Sites such as YouTube that hide their media behind custom players
  aren't handled. The grabber only sees files and HLS playlists the browser actually loads.
- **The speed limit can overshoot briefly at the start** by about the size of the OS socket buffers,
  then holds steady.
- **Without FFmpeg**, HLS streams are saved as `.ts`, and streams with separate audio come out as two
  files. VLC and IINA play them. `brew install ffmpeg` gives you a single `.mp4`.
- **With only the Command Line Tools**, the build uses the macOS 26.5 SDK: the macOS 27 SDK needs a
  SwiftUI macro plugin that only ships with Xcode. `scripts/env.sh` handles this automatically.
