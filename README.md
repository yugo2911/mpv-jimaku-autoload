# Jimaku Subtitles for MPV

Auto-download and load subtitles from [Jimaku.cc](https://Jimaku.cc)

## Quick Setup

1. **Install:**
   ```bash
   # Place in mpv scripts directory:
   mpv/scripts/jimaku.lua
   ```

2. **Configure:**
   ```
   mpv/script-opts/jimaku.conf
   ```
   Add your Jimaku API key:
   ```ini
   jimaku_api_key = "your_key_here"
   ```

3. **Use:**
   - `A`: Auto-search subtitles
   - `Ctrl+j`/`Alt+a`: Open menu
   - Subtitles auto-download when opening files (enabled by default)

<details>
<summary><b>File Structure</b></summary>

```
User's System (example paths)
│
├── mpv/
│   ├── scripts/
│   │   └── jimaku.lua                    ← Place script here
│   │
│   ├── script-opts/
│   │   └── jimaku.conf                   ← Place config here
│   │
│   └── [Auto-created directories on first run]:
│       ├── subtitle-cache/              ← Downloaded subtitles
│       │   ├── extracted_archives/      ← Temporary archive extraction
│       │   └── [subtitle files].ass
│       │
│       ├── cache/
│       │   ├── anilist-cache.json       ← AniList API cache
│       │   └── jimaku-cache.json        ← Jimaku API cache
│       │
│       └── data/
│           └── torrents.txt             ← Test file for parser
│
├── Windows alternative locations:
│     ├── %APPDATA%\mpv\scripts\jimaku.lua
│     └── %APPDATA%\mpv\script-opts\jimaku.conf
│
├── Linux/macOS alternative locations:
│     ├~/.config/mpv/scripts/jimaku.lua
└───  └~/.config/mpv/script-opts/jimaku.conf
```
</details>

<details>
<summary><b>Configuration Options</b></summary>

```ini
# jimaku.conf example
jimaku_api_key = "your_jimaku_api_key_here"  ← REQUIRED
SUBTITLE_CACHE_DIR = "./subtitle-cache"
JIMAKU_MAX_SUBS = 10
JIMAKU_AUTO_DOWNLOAD = true
LOG_ONLY_ERRORS = false
JIMAKU_HIDE_SIGNS = false
JIMAKU_ITEMS_PER_PAGE = 8
JIMAKU_MENU_TIMEOUT = 30
JIMAKU_FONT_SIZE = 16
INITIAL_OSD_MESSAGES = true
```
</details>

<details>
<summary><b>How It Works</b></summary>

```
jimaku.lua
├── INITIALIZATION
│   ├── Detect mode (standalone vs mpv)
│   ├── Load configuration from jimaku.conf
│   ├── Set up global variables and paths
│   └── Load API key (only from jimaku.conf now)
│
├── MENU SYSTEM (mpv mode only)
│   ├── Main menu (Ctrl+j or Alt+a)
│   │   ├── Download Subtitles
│   │   │   ├── Auto-search & download
│   │   │   ├── Browse all available
│   │   │   └── Download more (+5)
│   │   ├── Search & Match
│   │   │   ├── Re-run auto search
│   │   │   ├── Pick from results
│   │   │   └── Manual search
│   │   ├── Preferences
│   │   │   ├── Download settings
│   │   │   ├── Release groups
│   │   │   └── Interface
│   │   ├── Manage & Cleanup
│   │   │   ├── Clear loaded subs
│   │   │   ├── View cache stats
│   │   │   └── Clear caches
│   │   └── About & Help
│   │       └── View log file
│   │
│   ├── Key bindings
│   │   ├── A: Auto-search subtitles
│   │   ├── Ctrl+j / Alt+a: Open main menu
│   │   └── Arrow keys/ESC: Menu navigation
│   │
│   └── OSD rendering with ASS styling
│
├── FILENAME PARSER
│   ├── Parse media titles/filenames
│   ├── Extract: title, season, episode, group
│   ├── Clean Japanese/CJK text
│   ├── Remove version tags and quality markers
│   └── Detect specials/movies
│
├── ANILIST INTEGRATION
│   ├── Query AniList GraphQL API
│   ├── Smart matching algorithm
│   │   ├── Title similarity checking
│   │   ├── Season detection
│   │   ├── Cumulative episode calculation
│   │   └── Confidence scoring
│   ├── Cache results (24 hours)
│   └── Store matches in menu state
│
├── JIMAKU INTEGRATION
│   ├── Search Jimaku by AniList ID
│   ├── Fetch all subtitle files
│   ├── Intelligent episode matching
│   │   ├── Cross-verification with AniList
│   │   ├── Multiple pattern matching
│   │   ├── Preferred groups filtering
│   │   └── Confidence sorting
│   ├── Download subtitles
│   ├── Handle archive files (zip/rar/7z)
│   └── Load subtitles into mpv
│
├── CACHE SYSTEM
│   ├── AniList cache (24h TTL)
│   ├── Jimaku cache (1h TTL)
│   ├── Episode file cache (5m TTL)
│   └── Subtitle cache directory (persistent)
│
├── LOGGING & DEBUG
│   ├── Log to autoload-subs.log
│   ├── Separate parser debug log
│   └── Terminal output
│
└── STANDALONE MODE
    └── Test parser with: lua jimaku.lua --parser torrents.txt
```
</details>

## Features
- Smart title matching with AniList
- Auto-download subtitles from Jimaku.cc
- Browse/filter subtitle files
- ~~Archive extraction support (zip/rar/7z)~~ Archives are WIP 🚧
- Cache system for faster searches
- Interactive menu system
