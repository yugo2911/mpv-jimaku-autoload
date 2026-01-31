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
