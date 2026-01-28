# Kitsunekko Mirror Integration Setup

The jimaku.lua script now supports loading subtitles from a local Kitsunekko mirror repository.

## Configuration

Edit `jimaku.lua` and set these values:

```lua
-- Kitsunekko mirror configuration
local KITSUNEKKO_MIRROR_PATH = ""  -- Set to local mirror path
local KITSUNEKKO_ENABLED = false   -- Enable local kitsunekko mirror support
local KITSUNEKKO_PREFER_LOCAL = false  -- Prefer local subtitles over Jimaku
```

### Example Paths

**Windows:**
```lua
KITSUNEKKO_MIRROR_PATH = "D:\\kitsunekko-mirror\\subtitles"
KITSUNEKKO_MIRROR_PATH = "D:/kitsunekko-mirror/kitsunekko-mirror/subtitles"
```

**Linux/macOS:**
```lua
KITSUNEKKO_MIRROR_PATH = "/mnt/media/kitsunekko-mirror/subtitles"
KITSUNEKKO_MIRROR_PATH = "/home/user/kitsunekko-mirror/kitsunekko-mirror/subtitles"
```

## How It Works

### Directory Structure Expected
```
subtitles/
├── anime_tv/
│   ├── Title 1/
│   │   ├── .kitsuinfo.json      (contains anilist_id)
│   │   ├── subtitle.srt
│   │   └── subtitle.ass
│   └── Title 2/
├── anime_movie/
├── drama_tv/
├── drama_movie/
└── unsorted/
```

### .kitsuinfo.json Format
```json
{
  "anilist_id": 12345,
  "name": "Anime Title",
  "entry_type": "anime_tv",
  "english_name": "English Title",
  "japanese_name": "アニメタイトル"
}
```

## Features

1. **Automatic Indexing**: When enabled, the mirror is indexed by AniList ID
2. **Smart Matching**: Uses the same episode matching logic as Jimaku
3. **Two Modes**:
   - **Fallback** (default): Uses Kitsunekko only if Jimaku has no results
   - **Prefer Local**: Tries Kitsunekko first before Jimaku
4. **Menu Control**: Configure from Settings → Kitsunekko Mirror

## Menu Options

- **Enable Mirror**: Toggle Kitsunekko support
- **Load Strategy**: Choose between "Prefer Local" or "Fallback to Jimaku"
- **Mirror Path**: Shows currently configured path
- **Scan Mirror Now**: Manually index the mirror directory
- **Cache Status**: See how many entries are indexed

## Usage

1. Set `KITSUNEKKO_ENABLED = true` in jimaku.lua
2. Set `KITSUNEKKO_MIRROR_PATH` to your mirror location
3. Reload the script or open Menu → Settings → Kitsunekko Mirror → Scan Mirror Now
4. Play a video and press 'A' to search for subtitles
5. If subtitles are found locally, they will be loaded based on your preference

## Performance Notes

- First scan indexes all directories (one-time cost)
- Subsequent scans check for new directories only
- Local file loading is instant (no network required)
- Subtitle matching uses the same intelligent matching as Jimaku
