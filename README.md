### 1. Install Dependencies

* **MPV Player:** Version **0.34.0** or newer.
* **cURL:** Required for API requests (pre-installed on most modern systems).
* **Archive Tools (Optional):** Required for `.zip`, `.rar`, or `.7z` support.
> 🚧 **Note:** Archive extraction is currently **Work-in-Progress**. For best results, use individual `.ass` or `.srt` files.


* **Windows:** Install [7-Zip](https://www.7-zip.org/) and ensure is added to your **System PATH**.
* **Linux:** `sudo apt install unzip unrar p7zip-full`
* **macOS:** `brew install p7zip`

---

### 2. Download Script

Place `jimaku.lua` in your mpv scripts folder:

* **Windows:** `%APPDATA%\mpv\scripts\`
* **Linux/macOS:** `~/.config/mpv/scripts/`

3. **Use:**
   - `A`: Auto-search subtitles
   - `Ctrl+j`/`Alt+a`: Open menu
   - Subtitles auto-download when opening files (enabled by default)

<details>
<summary>📂 <b>File Structure & Permissions</b></summary>

The script requires **write access** to your mpv config directory. It will automatically create the following on first run:

```text
mpv/
├── scripts/
│   └── jimaku.lua
├── script-opts/
│   └── jimaku.conf
├── subtitle-cache/       # Downloaded .ass/.srt files
│   └── extracted_archives/
├── cache/                # API response caching
│   ├── anilist-cache.json
│   └── jimaku-cache.json
└── autoload-subs.log     # Debugging and error logs

```
</details>

<details>
<summary><b>Config Options</b></summary>

```ini
# jimaku.conf — place in: ~/.config/mpv/script-opts/jimaku.conf
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
- Cache system for faster searches
- Interactive menu system


- Note confidence feedback currently does not make much sense u can ignore it...
- some things like cache deleting currently is wip
- gui is still wip aswell
