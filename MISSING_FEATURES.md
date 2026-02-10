# Missing Features Comparison: Original vs Refactored

## Summary
**Original:** 4,158 lines with full feature set  
**Refactored:** 1,235 lines with core functionality only

---

## ✅ What's Included in Refactored Version

### Core Functionality (Working)
1. ✅ **Auto-download on file load**
2. ✅ **Manual search keybind (A key)**
3. ✅ **AniList API integration** - Search anime by title
4. ✅ **Jimaku API integration** - Search & download subtitles
5. ✅ **Intelligent filename parsing** - Extract title, episode, season, group
6. ✅ **Smart title matching** - Score-based matching algorithm
7. ✅ **Fallback searches** - Progressive title shortening
8. ✅ **Caching system** - AniList and Jimaku caches with TTL
9. ✅ **Configuration management** - Load from jimaku.conf
10. ✅ **Comprehensive logging** - Debug log file

---

## ❌ What's Missing in Refactored Version

### 1. 🎨 **Menu System (500+ lines)**
**Original Features:**
- Interactive OSD menu with keyboard navigation
- Main menu (Alt+A)
- Search & Download menu
- Subtitle browser with pagination
- AniList results picker
- Settings/Preferences menu
- Cache management menu

**Impact:** High - Major usability loss
**Lines:** ~500 lines
**Priority:** ⭐⭐⭐⭐⭐

**Example Usage:**
```
Press Alt+A → Menu appears
→ 1. Auto-Search & Match
→ 2. Pick from Results
→ 3. Manual AniList Search
→ 4. Browse Jimaku Subs
→ 5. Preferences
```

---

### 2. 🎯 **Preferred Release Groups (200+ lines)**
**Original Features:**
- User-defined priority list of fansub groups
- Default groups: Haruhana, Nekomoe kissaten, LoliHouse, etc.
- Enable/disable groups
- Add groups via console
- Smart priority scoring (bracket tag vs filename)
- Filter out disabled groups
- Save/load preferences to cache

**Impact:** Medium-High - Affects subtitle quality
**Lines:** ~200 lines
**Priority:** ⭐⭐⭐⭐

**Example:**
```lua
JIMAKU_PREFERRED_GROUPS = {
    {name = "Haruhana", enabled = true},    -- Priority 1
    {name = "LoliHouse", enabled = true},   -- Priority 2
    {name = "WEBRip", enabled = false}      -- Disabled
}
```

---

### 3. 📊 **Multi-Season Episode Calculation (300+ lines)**
**Original Features:**
- Cumulative episode counting across seasons
- Season chain walking via AniList relations
- Handle Netflix-style absolute numbering
- Convert between AniList episodes and Jimaku episodes
- Support for "Part 2", "Season 2" detection
- SEQUEL relationship graph traversal

**Impact:** High - Breaks multi-season anime
**Lines:** ~300 lines
**Priority:** ⭐⭐⭐⭐⭐

**Example:**
```
Frieren Part 2 Episode 5
→ Season 1 has 28 episodes
→ Cumulative episode = 28 + 5 = 33
→ Download Jimaku episode 33
```

---

### 4. 📦 **Archive Extraction (400+ lines)**
**Original Features:**
- Auto-extract .zip, .rar, .7z, .tar.gz archives
- Multi-method extraction (7z, unrar, unzip, tar)
- Smart filtering of extracted subtitles
- Prevent loading wrong episodes from archives
- Episode number matching validation
- Title matching verification

**Impact:** Medium - Some subtitles are only in archives
**Lines:** ~400 lines
**Priority:** ⭐⭐⭐

**Example:**
```
Downloads: [SubGroup] Anime 01-12.zip
→ Extracts to: subtitle-cache/extracted_anime_timestamp/
→ Finds: 01.ass, 02.ass, ... 12.ass
→ Loads only: 05.ass (matches current episode)
```

---

### 5. 🗂️ **Local Subtitle Cache (300+ lines)**
**Original Features:**
- Index all cached subtitles
- Search cache when Jimaku API fails
- Fuzzy title matching
- Episode number matching
- Recursive directory walking
- Cache index persistence
- Manual refresh command

**Impact:** Medium - Fallback when API down
**Lines:** ~300 lines  
**Priority:** ⭐⭐⭐

**Example:**
```
Jimaku API: No entry found
→ Searching local cache...
→ Found: /subtitle-cache/anime/episode_05.ass
→ Loading cached subtitle
```

---

### 6. 🔍 **Advanced Subtitle Browser (200+ lines)**
**Original Features:**
- Paginated file list (8 items per page)
- Keyboard navigation (arrows, vim keys)
- Episode number display
- File size display
- Filter by text (/ or f key)
- Sort by season/episode
- Preview mode
- Bulk operations

**Impact:** Medium-Low - Nice to have
**Lines:** ~200 lines
**Priority:** ⭐⭐

---

### 7. ⚙️ **Settings/Preferences Menu (400+ lines)**
**Original Features:**
- UI Settings (font size, timeout, items per page)
- Feature Toggles (auto-download, hide signs, initial OSD)
- API Toggles (AniList, Jimaku)
- Cache Management (clear, refresh)
- Config file editor
- Save settings to jimaku.conf
- Real-time config reload

**Impact:** Medium - Quality of life
**Lines:** ~400 lines
**Priority:** ⭐⭐⭐

**Menu Structure:**
```
Preferences
  → UI Settings
     - Font Size: 16
     - Menu Timeout: 30s
     - Items Per Page: 8
  → Feature Toggles
     - Auto Download: ON
     - Hide Signs Only: OFF
  → Manage & Cleanup
     - Clear Cache
     - Refresh Index
```

---

### 8. 🎬 **Intelligent Episode Matching (500+ lines)**
**Original Features:**
- Multi-strategy matching algorithm
- Confidence levels (high/medium/low)
- AniList metadata cross-verification
- Title variation matching (romaji/english/synonyms)
- Format detection (TV/OVA/Special)
- Year matching
- Episode range validation
- Fractional episodes (13.5)
- Japanese episode markers (第5話)
- Full-width digit normalization

**Impact:** High - Better match accuracy
**Lines:** ~500 lines
**Priority:** ⭐⭐⭐⭐

---

### 9. 📝 **Console Commands (100+ lines)**
**Original Features:**
```
script-message jimaku-search <title>
script-message jimaku-set-groups <group1,group2>
script-message jimaku-browser-filter <text>
script-message jimaku-refresh-index
```

**Impact:** Low - Advanced users only
**Lines:** ~100 lines
**Priority:** ⭐

---

### 10. 🔄 **Async Request System (150+ lines)**
**Original Features:**
- Promise-based async operations
- Request cancellation
- Task queue with priorities
- Non-blocking API calls
- Timeout handling

**Impact:** Low - Script still works synchronously
**Lines:** ~150 lines
**Priority:** ⭐⭐

---

### 11. 🎨 **Signs-Only Filtering**
**Original Features:**
- Detect "Signs Only" subtitles
- Filter by file size (<5KB)
- Filter by filename keywords
- Toggle via config

**Impact:** Low - Niche feature
**Lines:** ~50 lines
**Priority:** ⭐

---

### 12. 📋 **Loaded Subtitles Tracking**
**Original Features:**
- Track which subtitles are currently loaded
- Display in menu
- Count loaded subs
- Show subtitle filenames

**Impact:** Low - Informational only
**Lines:** ~50 lines
**Priority:** ⭐

---

### 13. 🌐 **Network Configuration**
**Original Features:**
- Proxy support toggle
- Network error handling
- Deny reason headers

**Impact:** Very Low
**Lines:** ~20 lines
**Priority:** ⭐

---

## 📊 Priority Matrix

| Feature | Priority | Impact | Lines | Difficulty |
|---------|----------|--------|-------|------------|
| Multi-Season Calculation | ⭐⭐⭐⭐⭐ | High | 300 | Hard |
| Menu System | ⭐⭐⭐⭐⭐ | High | 500 | Medium |
| Preferred Groups | ⭐⭐⭐⭐ | Med-High | 200 | Easy |
| Intelligent Matching | ⭐⭐⭐⭐ | High | 500 | Hard |
| Archive Extraction | ⭐⭐⭐ | Medium | 400 | Medium |
| Settings Menu | ⭐⭐⭐ | Medium | 400 | Medium |
| Local Cache Search | ⭐⭐⭐ | Medium | 300 | Easy |
| Subtitle Browser | ⭐⭐ | Med-Low | 200 | Easy |
| Async System | ⭐⭐ | Low | 150 | Medium |
| Console Commands | ⭐ | Low | 100 | Easy |

---

## 🎯 Recommended Implementation Order

### Phase 1: Critical Features (Restore Full Functionality)
1. **Multi-Season Episode Calculation** - Without this, anime like Frieren Part 2 fail
2. **Menu System** - User experience is severely degraded without it
3. **Intelligent Episode Matching** - Current matching is too simplistic

### Phase 2: High-Value Features
4. **Preferred Release Groups** - Users want control over subtitle quality
5. **Archive Extraction** - Many subtitles are distributed as archives
6. **Settings Menu** - Users need to configure behavior

### Phase 3: Nice-to-Have Features
7. **Local Cache Search** - Useful fallback
8. **Subtitle Browser** - Better UX for selection
9. **Async System** - Performance improvement

### Phase 4: Polish
10. **Console Commands** - Power user features
11. **Signs Filtering** - Niche use case
12. **Tracking Features** - Informational only

---

## 🔧 How to Restore Features

Each feature can be added as a separate module following the refactored pattern:

```lua
-- Example: Adding Menu System
local MenuManager = {
    stack = {},
    active = false,
    timeout_timer = nil
}

function MenuManager:init(config)
    self.config = config
end

function MenuManager:show(title, items)
    -- Menu logic here
end

-- In controller:
self.menu = MenuManager
self.menu:init(self.config)
```

---

## 📈 Feature Completeness

**Current:** ~30% (Core functionality only)  
**With Phase 1:** ~60% (Usable for most scenarios)  
**With Phase 2:** ~85% (Feature-complete for typical users)  
**With Phase 3:** ~95% (Full feature parity)  
**With Phase 4:** 100% (Complete original functionality)

---

## 🎪 The Biggest Loss: Menu System

The menu system is probably the most noticeable missing feature. Without it:

❌ Can't browse subtitles interactively  
❌ Can't pick from multiple AniList results  
❌ Can't change settings on the fly  
❌ Can't see what's loaded  
❌ Can't manually filter or search  

The original had this beautiful workflow:
```
1. Press Alt+A
2. Menu appears with current match info
3. Navigate with arrows or vim keys
4. Browse 100+ subtitle files
5. Filter with /
6. Select and download
7. Configure preferences
8. All without leaving video
```

Now it's just: "Press A, hope it works, check logs if it doesn't"

---

## 💡 Suggested Next Steps

1. **Add the menu system first** - Biggest UX impact
2. **Then multi-season support** - Biggest functional gap
3. **Then preferred groups** - Most requested feature
4. **Consider archive support** - Moderate complexity, good value

Would you like me to implement any of these missing features?
