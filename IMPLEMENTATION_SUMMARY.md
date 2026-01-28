# Kitsunekko Mirror Integration - Implementation Summary

## What Was Added

Local subtitle support for the jimaku.lua script, allowing it to load subtitles from a local Kitsunekko mirror repository instead of (or in addition to) fetching from the Jimaku API.

## Key Features

### 1. **Configuration Variables** (lines 70-80)
```lua
KITSUNEKKO_MIRROR_PATH  -- Path to mirror root (e.g., "D:/kitsunekko-mirror/subtitles")
KITSUNEKKO_ENABLED      -- Enable/disable local support
KITSUNEKKO_PREFER_LOCAL -- Choose load strategy (local-first vs fallback)
```

### 2. **Core Functions** (lines 2058-2180)
- `path_exists(path)` - Cross-platform path existence check
- `list_directory(path)` - List directory contents
- `parse_kitsuinfo(path)` - Parse .kitsuinfo.json for metadata
- `scan_kitsunekko_mirror()` - Index mirror by AniList ID
- `get_kitsunekko_files(anilist_id)` - Retrieve files for an anime
- `load_kitsunekko_subtitles()` - Load local files with episode matching

### 3. **Smart Integration**
- Uses existing episode matching logic (same as Jimaku)
- Supports fallback mode: Jimaku first, local as backup
- Supports prefer-local mode: Local first, Jimaku if needed
- Automatic directory scanning and caching

### 4. **Menu System** (lines 929-967)
New submenu: Settings → Kitsunekko Mirror
- Toggle enable/disable
- Choose load strategy
- View/configure mirror path
- Scan mirror manually
- View cache status

## File Structure Expected

```
D:/kitsunekko-mirror/subtitles/
├── anime_tv/
│   ├── Title Name/
│   │   ├── .kitsuinfo.json
│   │   ├── subtitle.srt
│   │   └── subtitle.ass
├── anime_movie/
├── drama_tv/
├── drama_movie/
└── unsorted/
```

## .kitsuinfo.json Format
```json
{
  "anilist_id": 12345,
  "name": "Anime Title",
  "entry_type": "anime_tv",
  "english_name": "English Title",
  "japanese_name": "日本語タイトル",
  "last_modified": "2024-06-06T02:06:16Z"
}
```

## Quick Setup

1. **Edit jimaku.lua** (around line 71):
```lua
KITSUNEKKO_MIRROR_PATH = "D:/kitsunekko-mirror/subtitles"  -- Your path
KITSUNEKKO_ENABLED = true
KITSUNEKKO_PREFER_LOCAL = false  -- or true if preferred
```

2. **Load in MPV** - Script auto-detects and initializes

3. **Optional: Manual Scan** - Menu → Settings → Kitsunekko Mirror → Scan Now

4. **Use as Normal** - Press 'A' to search for subtitles
   - Loads from Kitsunekko if available (per your preference)
   - Falls back to Jimaku if needed

## Loading Modes

### Mode 1: Fallback (Default)
- Tries Jimaku API first
- Falls back to local mirror if Jimaku returns nothing
- Best for: Freshest + most complete coverage

### Mode 2: Prefer Local
- Tries local mirror first  
- Falls back to Jimaku if not found locally
- Best for: Offline speed + avoiding API quota

## Performance

- **First Run**: Scans mirror directory structure (one-time)
  - Creates index of all anime entries by AniList ID
  - Time depends on mirror size (~minutes for full mirror)
  
- **Subsequent Runs**: Instant lookup via cached index
  - No rescanning unless manually triggered
  - Local file loading is immediate (no network)

## Compatibility

- Works with existing Jimaku subtitle matching logic
- Respects all Jimaku settings (episode detection, group preferences, etc.)
- Maintains all existing functionality when disabled

## Error Handling

- Gracefully handles missing mirror path
- Silently skips if mirror unavailable
- Falls back to Jimaku if local load fails
- Logs all operations for debugging

## Files Added/Modified

**Modified:**
- `jimaku.lua` - Added configuration, functions, and menu items

**Created:**
- `KITSUNEKKO_SETUP.md` - Detailed setup guide
- `KITSUNEKKO_CONFIG_EXAMPLE.lua` - Configuration examples
- This file - Implementation summary

---

**Note:** The implementation supports both Jimaku API and local mirror seamlessly, with flexible configuration for different use cases (offline access, bandwidth saving, quality preference, etc.).
