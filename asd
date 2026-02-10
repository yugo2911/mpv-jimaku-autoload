🚀 1. Startup/Initialization Flow
jimaku.lua loads → Mode detection → Config loading → State init → MPV setup
├── Detect environment (MPV vs standalone)
├── Load configuration files & defaults
├── Initialize EPISODE_CACHE, ANILIST_CACHE, JIMAKU_CACHE
├── Setup async task system
├── Initialize menu_state (stack, selections, timeouts)
└── Bind keys: 'A' (search), 'Alt+A' (menu), file-loaded event
⚡ 2. Main Event Loop
MPV Event Loop
├── User Press 'A' → search_anilist(false) [Manual search]
├── User Press 'Alt+A' → show_main_menu() [Open menu]
├── File-Loaded Event → auto_download_if_enabled() [Auto mode]
└── Script Messages → Console commands
🎯 3. Subtitle Detection Flow (Core Logic)
search_anilist() Entry Point
├── Extract title from media-title/filename
├── Parse title: parse_media_title() → {title, episode, season, confidence}
├── Check cache (24h freshness check)
├── IF cache miss → AniList API request
│   ├── GraphQL query with fuzzy matching
│   ├── Fallback searches if no results
│   └── Cache results
├── Smart matching: smart_match_anilist()
│   ├── Priority 1: Explicit season numbers (S2, S3)
│   ├── Priority 2: Special/OVA formats  
│   ├── Priority 3: Cumulative episode calculation
│   └── Return: selected_media, actual_episode, actual_season
├── Update menu_state with match info
└── Download subtitles: search_jimaku_subtitles()
📋 4. Menu Navigation Flow
Menu Stack System
├── push_menu() → Add to stack → bind_menu_keys() → render_menu_osd()
├── Navigation Keys:
│   ├── UP/DOWN → Change selection
│   ├── LEFT/RIGHT → Custom actions
│   ├── ENTER → Execute selected.action
│   ├── 0-9 → Direct selection
│   └── ESC → pop_menu() or close_menu()
└── Menu Hierarchy:
    ├── Main Menu → Browse/Search/Preferences
    ├── Search Menu → Auto/Pick/Manual options
    └── Preferences → Download/Groups/Interface settings
⬇️ 5. Download Flow
download_subtitle_smart()
├── Validate API key and files exist
├── fetch_all_episode_files() → Jimaku API call
├── match_episodes_intelligent()
│   ├── Group preference matching (user priorities)
│   ├── Episode confidence scoring
│   └── Sort by priority → confidence → accuracy
├── Download loop (max JIMAKU_MAX_SUBS):
│   ├── curl download each file
│   ├── IF archive → extract relevant subs
│   └── mp.commandv("sub-add", path)
└── Update loaded_subs_files tracking
🎮 6. File Matching Logic
match_episodes_intelligent()
├── Calculate target_cumulative episode
├── Group Preference System:
│   ├── Extract [GroupName] brackets
│   ├── Match against user preferences
│   └── Calculate priority_score
├── Process each subtitle file:
│   ├── parse_jimaku_filename() → season/episode
│   ├── Filter disabled groups
│   ├── Filter signs-only (if setting enabled)
│   └── Calculate match confidence
└── Matching Cases:
    ├── Case 1: Explicit SxxExx → HIGH confidence
    ├── Case 2: Cumulative episodes → HIGH confidence  
    ├── Case 3: Direct episode match → MEDIUM confidence
    └── Case 4: Japanese numbering (第222話) → HIGH confidence
🛡️ 7. Error Handling
Error Recovery System
├── API Errors → Retry with fallbacks
├── Network Failures → Use local cache
├── Parse Errors → Try alternative patterns
├── File System Errors → Multiple extraction tools
└── User Communication:
    ├── conditional_osd() → Manual actions only
    ├── debug_log() → Detailed logging
    └── mp.osd_message() → Immediate feedback
🔑 Critical Decision Points
1. parse_media_title() - Determines episode/season from filename
2. smart_match_anilist() - Selects correct anime from search results  
3. match_episodes_intelligent() - Picks best subtitle files
4. Group Preference System - User-defined release group priorities
5. Cumulative Episode Calculation - Handles multi-season anime
The system is designed with multiple fallback strategies at every level, ensuring robust subtitle matching even with imperfect filename patterns or API failures.