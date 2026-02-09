**Installation:**
1. **Place script:** `jimaku.lua` → `~/.config/mpv/scripts/`
2. **Add API key:** Create `~/.config/mpv/script-opts/jimaku.conf` with:
   ```
   jimaku_api_key=YOUR_API_KEY_HERE
   ```

3. **Configure max subtitles:** In the same config file, set maximum subtitles to load:
   ```
   JIMAKU_MAX_SUBS=10
   ```
   - **Range:** Any number from 1-50, or "all" for unlimited
   - **Default:** 10 (if not specified)
   - **Examples:** `JIMAKU_MAX_SUBS=5` or `JIMAKU_MAX_SUBS=all`
**Get API key:** [jimaku.cc](https://jimaku.cc)

* **Windows:** `%APPDATA%\mpv\scripts\`
* **Linux/macOS:** `~/.config/mpv/scripts/`

Alt + A to open up the menu, [theme is ModernZ](https://github.com/Samillion/ModernZ)
<img width="1024" height="576" alt="image" src="https://github.com/user-attachments/assets/4b411f18-5432-432a-9b29-f611f3da23dc" />

```
1. FILE LOADS in mpv
   │
2. AUTO-SEARCH triggers (if enabled)
   │
3. PARSE filename → Extract {title, season, episode}
   │
4. QUERY AniList API → Get anime ID
   │
5. QUERY Jimaku API → Get subtitle entry ID
   │
6. FETCH all subtitle files for that entry
   │
7. MATCH episodes intelligently
   │   - Season detection
   │   - Cumulative episode calculation
   │   - Preferred group filtering
   │
8. DOWNLOAD top matches
   │   - Archive files → extract & scan
   │   - Regular files → load directly
   │
9. LOAD into mpv as subtitles
   │
10. MENU ACCESS (Alt+A)
    │
    └── Browse, search, manage subtitles
```
It works~ for gettings subs from jimaku, some GUI options are WIP
