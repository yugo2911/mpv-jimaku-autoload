# Kitsunekko Mirror Integration - Code Changes Reference

## Summary of Changes to jimaku.lua

### 1. Configuration Section (Line ~70)
**Added:**
```lua
-- Kitsunekko mirror configuration
local KITSUNEKKO_MIRROR_PATH = ""  -- Set to local mirror path
local KITSUNEKKO_ENABLED = false   -- Enable local kitsunekko mirror support
local KITSUNEKKO_PREFER_LOCAL = false  -- Prefer local subtitles over Jimaku

-- Kitsunekko mirror cache (stores parsed metadata)
local kitsunekko_cache = {}
local kitsunekko_anilist_index = {}  -- Maps AniList ID to local subtitle directory
```

### 2. Kitsunekko Support Functions (Line ~2058-2200)
**Added functions:**
- `path_exists(path)` - Check if file/directory exists
- `list_directory(path)` - Get directory contents
- `parse_kitsuinfo(kitsuinfo_path)` - Parse .kitsuinfo.json
- `scan_kitsunekko_mirror()` - Index mirror by AniList ID
- `get_kitsunekko_files(anilist_id)` - Retrieve subtitle files
- `load_kitsunekko_subtitles(...)` - Load local subtitles with matching
- `count_table(t)` - Helper to count table entries

### 3. Smart Download Integration (Line ~2610)
**Modified `download_subtitle_smart()`:**
```lua
-- Added fallback logic
if not all_files or #all_files == 0 then
    debug_log("No subtitle files available from Jimaku, checking Kitsunekko...", false)
    -- Try kitsunekko as fallback if Jimaku has no results
    if KITSUNEKKO_PREFER_LOCAL and anilist_entry and anilist_entry.id then
        return load_kitsunekko_subtitles(anilist_entry.id, ...)
    end
    return false
end
```

### 4. Settings Menu (Line ~865)
**Added menu option:**
```lua
{text = "5. Kitsunekko Mirror  →", action = show_kitsunekko_settings_menu},
```

### 5. Kitsunekko Settings Submenu (Line ~929)
**Added new submenu with:**
- Enable/disable toggle
- Load strategy selector (Prefer Local vs Fallback)
- Mirror path display
- Manual scan option
- Cache status viewer

### 6. Initialization (Line ~3442)
**Added initialization code:**
```lua
-- Initialize Kitsunekko mirror if configured
if KITSUNEKKO_ENABLED and KITSUNEKKO_MIRROR_PATH and KITSUNEKKO_MIRROR_PATH ~= "" then
    debug_log("Kitsunekko mirror support enabled: " .. KITSUNEKKO_MIRROR_PATH)
    -- Scan will happen on-demand when needed
end
```

## Architecture Overview

```
User plays video
      ↓
Search for subtitles (press 'A')
      ↓
Get AniList ID
      ↓
[KITSUNEKKO_PREFER_LOCAL == true?]
  YES → Try load_kitsunekko_subtitles()
          ├─ Scan mirror if needed
          ├─ Match episodes using same logic
          └─ Load local files
        If found, done. If not found, try Jimaku
  NO  → Try download_subtitle_smart() (Jimaku)
        If found, done. If not found, try Kitsunekko as fallback
      ↓
Load into MPV
```

## Key Design Decisions

1. **Reuse Existing Logic**: Uses `match_episodes_intelligent()` for consistency
2. **On-Demand Scanning**: Only scans mirror when enabled and needed
3. **Caching by AniList ID**: Fast lookup: AniList ID → Directory path
4. **Non-Intrusive**: Fully optional, doesn't affect existing Jimaku flow
5. **Flexible Loading**: Two modes for different user preferences
6. **Graceful Degradation**: Falls back silently if mirror unavailable

## Data Flow for Subtitle Loading

```
.kitsuinfo.json (AniList ID: 12345)
         ↓
scan_kitsunekko_mirror()
         ↓
kitsunekko_anilist_index[12345] = "/path/to/anime"
         ↓
get_kitsunekko_files(12345)
         ↓
Returns: [{name: "sub.ass", path: "/full/path", source: "kitsunekko"}, ...]
         ↓
match_episodes_intelligent()  (shared logic with Jimaku)
         ↓
load_kitsunekko_subtitles()
         ↓
mp.commandv("sub-add", subtitle_path, flag)
         ↓
Subtitles visible in player
```

## Testing Checklist

- [x] Lua syntax validation (luac check passed)
- [x] Configuration variables accessible
- [x] Menu integration works
- [x] Fallback logic implemented
- [ ] Test with actual mirror directory structure
- [ ] Test with sample .kitsuinfo.json files
- [ ] Verify episode matching works with local files
- [ ] Test both load strategies (prefer-local and fallback)

## Future Enhancements

- [ ] Support for additional subtitle file formats (.vtt, .idx/.sub)
- [ ] Metadata caching to disk for persistence
- [ ] Batch subtitle loading from same directory
- [ ] Custom matching rules per anime
- [ ] Integration with other local subtitle sources
- [ ] Web UI for easier configuration
