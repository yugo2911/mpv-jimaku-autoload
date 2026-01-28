# Quick Start: Kitsunekko Mirror Support

## 30-Second Setup

1. **Open jimaku.lua** in a text editor
2. **Find line 71** (search for `KITSUNEKKO_MIRROR_PATH`)
3. **Replace:**
   ```lua
   local KITSUNEKKO_MIRROR_PATH = ""
   local KITSUNEKKO_ENABLED = false
   ```
   **With:**
   ```lua
   local KITSUNEKKO_MIRROR_PATH = "D:/kitsunekko-mirror/subtitles"  -- Edit this path
   local KITSUNEKKO_ENABLED = true
   ```

4. **Save** the file
5. **Use normally** - subtitles will load from local mirror when available!

## Two Load Strategies

**Default (Recommended):**
```lua
KITSUNEKKO_PREFER_LOCAL = false  -- Jimaku first, local as backup
```

**Offline/Faster:**
```lua
KITSUNEKKO_PREFER_LOCAL = true   -- Local first, Jimaku as backup
```

## Where Is My Mirror?

Run from command line:
```bash
# Windows
Get-ChildItem "D:\kitsunekko-mirror" -Depth 1

# Linux/Mac
ls -la /path/to/kitsunekko-mirror
```

Look for this structure:
```
├── subtitles/          ← This is your MIRROR_PATH
│   ├── anime_tv/
│   ├── anime_movie/
│   ├── drama_tv/
│   └── ...
```

## Testing It Works

1. In MPV, press `Ctrl+J` (open menu)
2. Go to: Settings → Kitsunekko Mirror
3. Click "Scan Mirror Now"
4. Should show: `✓ Indexed X anime entries`

If you see `0 indexed`, check your path!

## Common Paths

**Windows:**
```lua
KITSUNEKKO_MIRROR_PATH = "D:\\kitsunekko-mirror\\subtitles"
KITSUNEKKO_MIRROR_PATH = "D:/kitsunekko-mirror/subtitles"  -- Also works
```

**Linux/Mac:**
```lua
KITSUNEKKO_MIRROR_PATH = "/mnt/media/kitsunekko-mirror/subtitles"
KITSUNEKKO_MIRROR_PATH = "/home/user/.local/share/kitsunekko/subtitles"
```

## What Happens Now?

When you watch a video:
1. Press `A` to search for subtitles
2. If a match is found in your mirror:
   - **With PREFER_LOCAL=false**: Checks Jimaku first, uses local as backup
   - **With PREFER_LOCAL=true**: Loads immediately from mirror
3. If no match found locally: Falls back to Jimaku API
4. Subtitles auto-load!

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "0 indexed" entries | Path is wrong - check spelling and slashes |
| Subtitles not loading | Check .kitsuinfo.json has `anilist_id` field |
| Mixed path separators | Use all `/` OR all `\\` (not both) |
| File permissions | Ensure read access to mirror directory |
| Too slow | Set `KITSUNEKKO_PREFER_LOCAL=true` for local-first |

## Need More Info?

- **Setup details:** Read `KITSUNEKKO_SETUP.md`
- **Configuration examples:** See `KITSUNEKKO_CONFIG_EXAMPLE.lua`
- **Technical details:** Check `IMPLEMENTATION_SUMMARY.md`
- **Code changes:** Review `CHANGES_REFERENCE.md`

---

**That's it!** Enjoy instant offline subtitle loading! 🎉
