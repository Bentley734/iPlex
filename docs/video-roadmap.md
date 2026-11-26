# iPlex video roadmap

I reviewed Infuse 8.5.1 on macOS. Its sidebar separates Home, Library, and Files. The installed Home view showed Plex-specific Watchlist and Recently Added shelves, plus Unwatched and genre shelves. Firecore also documents per-title version selection, playback shortcuts, subtitle tools, and Trakt sync. [Infuse settings](https://support.firecore.com/hc/en-us/articles/360015608854-Settings-Overview) · [Playback controls](https://support.firecore.com/hc/en-us/articles/215090987-Playback-Controls)

## Phase 1 architecture

Keep SwiftUI and Swift on macOS, iOS/iPadOS, and tvOS, and C# with WebView2 on Windows. Keep AVPlayer and VideoLAN. Keep Plex as the primary source for its own library metadata. Filename matching and external metadata become useful when importing local files or network shares and when a Plex record lacks a useful match.

Use a per-device SQLite database with versioned schema migrations. The first increment stores playback state in SQLite on macOS, iOS/iPadOS, and Windows. Apple TV keeps a bounded recent history in UserDefaults. Windows bundles the official SQLite binaries. Keep poster and backdrop bytes on disk in the existing artwork cache. [Apple TV storage limits](https://developer.apple.com/documentation/foundation/userdefaults/sizelimitexceededmessage) · [SQLite downloads](https://www.sqlite.org/download.html)

| Table | Proposed keys and fields |
| --- | --- |
| `sources` | `id`, `kind`, stable remote identity, display name, credential reference, last scan, scan cursor |
| `titles` | `id`, `kind`, title, sort title, year, synopsis. Seasons and episodes use `parent_id`, season number, and episode number. |
| `media_files` | `id`, `title_id`, `source_id`, remote item ID or relative path, edition, container, resolution, codecs, HDR format, duration, size, modification time. Unique on the source and file identity. |
| `provider_ids` | Unique `provider` and `provider_id` per media type, mapped to `title_id`. Keep matching evidence and support a manual override. |
| `metadata_cache` | `title_id`, provider, locale, payload, last fetched time, expiry, and artwork references |
| `collections` and `collection_items` | Collection ID, name, provenance, title ID, and sort position |
| `watch_state` | Account or profile scope, title ID, optional file version ID, position and duration in milliseconds, watched state, update time, and origin. The first increment uses Plex server, library and item IDs. |
| `sync_queue` | Unique event ID, provider, profile, item, action, event time, retry time, attempt count, and last error. A sync cursor tracks the latest imported provider state. |

Store credentials in Keychain or Windows credential storage. Use relative paths and stable IDs in the database. Keep time-based playback state scoped to the current account and library when sync is introduced. Only merge cuts when the edition and timeline are compatible. An ambiguous metadata match should stay unmatched until the user resolves it.

### Module structure

| Layer | Apple source modules | Windows source modules |
| --- | --- | --- |
| Storage and network | `Plex/`, `Shares/`, `Transport/` | `Plex/`, `Shares/`, `Transport/` |
| Metadata and database | `VideoLibrary/Metadata/`, `VideoLibrary/Persistence/` | `VideoLibrary/Metadata/`, `VideoLibrary/Persistence/` |
| Playback engine | `VideoPlayback/` for AVPlayer and VideoLAN adapters | `VideoPlayback/` for browser and VideoLAN adapters |
| User interface | `VideoUI/` for shelves, details, and player surfaces | `Web/` for shelves, details, and browser player surfaces |

Start with the existing `PlexService.swift` and `Windows/Video.cs` as the Plex network adapters. Keep watch state persistence in `VideoWatchStore` and have the players emit position, readiness, and completion. Move modules into those folders when introducing the next source. For long network files, storage adapters should expose seekable streams with cancellable range reads and bounded buffers.

## Feature audit

| Roadmap feature | iPlex today | Remaining |
| --- | --- | --- |
| 1. Metadata | Plex supplies listings, summaries and artwork. Selected libraries can pre-cache covers. | Parse filenames, match TMDB and optionally TVDB, add localized metadata caching and manual corrections for ambiguous matches. |
| 2. Continue Watching | Per-device progress, resume, watched state and Continue Watching. Up Next locates the next unwatched episode across seasons and auto-advances after a cancelable countdown. | Cross-device or Plex watch-state sync. |
| 3. Grouping and stacking | Plex shows already group into seasons and episodes. The video player offers a version picker for alternate Plex media files. | Edition handling and franchise collections. |
| 4. Trakt | Pending. | OAuth, two-way history/progress/ratings sync, account scoping, retry and conflict handling. |
| 5. Network shares | iPlex streams from Plex directly when supported. | Direct SMB, NFS, WebDAV and SFTP sources, credentials, scanning and seekable byte ranges. |
| 6. Direct Play and HDR | OS-native and VideoLAN playback cover common sources including MP4, MKV and WebM, with Plex fallback. | Verify hardware decoding by platform and codec, AVI coverage, Dolby Vision Profiles 5/7/8, HDR10+, and SDR tone mapping on real displays. Profile 7 base-layer playback and full enhancement-layer rendering need separate checks. |
| 7. Audio and Night Mode | iPlex can locally decode multiple video audio codecs. The existing music EQ is independent of video playback. | Per-route Atmos, TrueHD and DTS:X passthrough testing, and video DRC. |
| 8. Subtitles | VideoLAN and native players can handle some embedded tracks, and the Plex fallback can request burn-in. | Consistent track selection, styled ASS/SSA and PGS verification, OpenSubtitles search and timing offsets. |
| 9. Chapters and skip controls | Players already offer seeking. | Chapter lists, Plex intro/credits markers, Skip Intro and Next Episode controls. Consider fingerprinting after sources without markers are supported. |
| 10. Playback diagnostics | Video shows Direct Play or Plex Transcode. | A HUD sourced from each player adapter for codecs, bitrate, resolution, HDR, buffer health, dropped frames, and hardware decoder status. |

Add a local-file scanner and metadata matching so the catalog can ingest network sources without redesigning title identity. Add Trakt after the watch-state merge rules are in place.
