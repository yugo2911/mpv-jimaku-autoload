## **Jimaku Subtitle Auto‑Loader for MPV**
A Lua script for MPV that automatically detects the correct anime title, season, and episode from your video filename, queries the Jimaku.cc API, scores available subtitle files, and loads the best match automatically.

---

##  **Installation**

### **1. Download the script**
Download **`jimaku.lua`** and place it inside your MPV:

```
mpv/scripts/
```

MPV will load it automatically on startup.

---

## **API Key Setup**

Get your API key from:

**https://jimaku.cc/account**

You can provide the key in **two ways**:

### **Option A — Recommended (external file)**
Create a file named:

```
jimaku-api-key.txt
```

Place it in your MPV **config directory**, which is **one level above** the `scripts` folder.

Example structure:

```
mpv/
 ├─ scripts/
 │   └─ jimaku.lua
 └─ jimaku-api-key.txt
```

Put **only your API key** inside the file.

The script will automatically read it.

---

### **Option B — Inline key (inside the script)**
Edit this line in `jimaku.lua`:

```lua
local JIMAKU_API_KEY = ""
```

Paste your key between the quotes.

If this value is left empty, the script will fall back to reading `jimaku-api-key.txt`.

---

## **Usage**
Just open any anime episode in MPV.

The script will:

- parse the filename  
- detect title / season / episode  
- query Jimaku.cc  
- score all matching entries  
- download the best subtitle file  
- load it automatically  

(not yet really implemented) You can also trigger a manual search with:

```
Ctrl + j
```

---

##  **Logging**
Debug logs are written to:

```
mpv/jimaku-debug.log
```

Useful for troubleshooting or improving the matching logic.

---

#  **MPV Directory Structure**

Below is a clear directory tree showing where everything belongs. If there is no script folder just create it mpv should detect it

```
mpv/
├─ mpv.conf
├─ input.conf
├─ scripts/
│   ├─ jimaku.lua
│   └─ (other scripts)
├─ script-opts/
│   └─ (optional config files)
├─ fonts/
├─ shaders/
├─ watch_later/
└─ jimaku-api-key.txt   ← API key file (one level above scripts/)
```

##  **Scoring System & Customization**

### **How Scoring Works**
The script assigns points to subtitle files based on several criteria:

- **Perfect Match** (+1000): Season and episode match exactly
- **Offset Match** (+850): Episode matches with known offset (e.g., S01E14 for your S01E02)
- **Implied Season Match** (+800): Episode matches when season is inherited from entry
- **Season Match** (+200): Entry matches your video's season
- **Pattern Bonuses**: Additional points for preferred sources

### **Customizing Preferred Patterns**
Edit the `JIMAKU_PREFERRED_PATTERNS` table in `jimaku.lua` to boost specific subtitle sources:

```lua
local JIMAKU_PREFERRED_PATTERNS = {
    {"netflix", 200},   -- Strong preference for Netflix subs
    {"amazon", 200},    -- Strong preference for Amazon subs
    {"webrip", 200},    -- Web releases
    {"sdh", 150},       -- Subtitles for Deaf/Hard-of-hearing
    -- Add your own patterns:
    -- {"bluray", 75},
    -- {"official", 100},
}
```

Each entry is either:
- A **string** (pattern): defaults to +50 points
- A **table** `{pattern, score}`: custom point value

**Pattern matching is case-insensitive** and searches the subtitle filename.

### **Viewing Scores in Debug Log**
Enable detailed scoring by checking:

```
mpv/jimaku-debug.log
```

Example log output:

```
--- SCORING 12 FILES ---
File: [SubsPlease] Show - 02 (1080p) [ABC123].ass | S:1 E:2 | Score: 1200
  -> Perfect Match (+1000), Pattern 'webrip' (+200)
File: [Erai-raws] Show - 02 [1080p].ass | S:1 E:2 | Score: 1000
  -> Perfect Match (+1000)
File: Show S01E14 [Netflix].ass | S:1 E:14 | Score: 1050
  -> Offset Match 12 (+850), Pattern 'netflix' (+200)
```


### **Adjusting Maximum Subtitles**
By default, up to **5 subtitles** are loaded. To change this:

```lua
local JIMAKU_MAX_SUBS = 5  -- Change to your preferred number
```

