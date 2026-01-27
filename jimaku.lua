-- Detect if running standalone (command line) or in mpv
local STANDALONE_MODE = not pcall(function() return mp.get_property("filename") end)

local utils
if not STANDALONE_MODE then
    utils = require 'mp.utils'
end

-- CONFIGURATION
local CONFIG_DIR
local LOG_FILE
local PARSER_LOG_FILE
local TEST_FILE
local SUBTITLE_CACHE_DIR
local JIMAKU_API_KEY_FILE
local ANILIST_API_URL = "https://graphql.anilist.co"
local JIMAKU_API_URL = "https://jimaku.cc/api"

if STANDALONE_MODE then
    CONFIG_DIR = "."
    LOG_FILE = "./anilist-debug.log"
    PARSER_LOG_FILE = "./parser-debug.log"
    TEST_FILE = "./torrents.txt"
    SUBTITLE_CACHE_DIR = "./subtitle-cache"
    JIMAKU_API_KEY_FILE = "./jimaku-api-key.txt"
else
    CONFIG_DIR = mp.command_native({"expand-path", "~~/"})
    LOG_FILE = CONFIG_DIR .. "/anilist-debug.log"
    PARSER_LOG_FILE = CONFIG_DIR .. "/parser-debug.log"
    TEST_FILE = CONFIG_DIR .. "/torrents.txt"
    SUBTITLE_CACHE_DIR = CONFIG_DIR .. "/subtitle-cache"
    JIMAKU_API_KEY_FILE = CONFIG_DIR .. "/jimaku-api-key.txt"
end

-- Parser configuration
local LOG_ONLY_ERRORS = false

-- Jimaku configuration
local JIMAKU_MAX_SUBS = 5 -- Maximum number of subtitles to download and load (set to "all" to download all available)
local JIMAKU_AUTO_DOWNLOAD = true -- Automatically download subtitles when file starts playing (set to false to require manual key press)

-- Jimaku API key (will be loaded from file)
local JIMAKU_API_KEY = ""

-- Episode file cache
local episode_cache = {}

-- Unified logging function
local function debug_log(message, is_error)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local prefix = is_error and "[ERROR] " or "[INFO] "
    local log_msg = string.format("%s %s%s\n", timestamp, prefix, message)
    
    local target_log = STANDALONE_MODE and PARSER_LOG_FILE or LOG_FILE
    local f = io.open(target_log, "a")
    if f then
        f:write(log_msg)
        f:close()
    end
    
    -- Print to terminal if not suppressed
    local should_log = not LOG_ONLY_ERRORS or is_error
    if should_log then
        print(log_msg:gsub("\n", ""))
    end
end

-- Load Jimaku API key from file
local function load_jimaku_api_key()
    local f = io.open(JIMAKU_API_KEY_FILE, "r")
    if f then
        local key = f:read("*l")
        f:close()
        if key and key:match("%S") then
            JIMAKU_API_KEY = key:match("^%s*(.-)%s*$")  -- Trim whitespace
            debug_log("Jimaku API key loaded from: " .. JIMAKU_API_KEY_FILE)
            return true
        end
    end
    debug_log("Jimaku API key not found. Create " .. JIMAKU_API_KEY_FILE .. " with your API key.", true)
    return false
end

-- Create subtitle cache directory if it doesn't exist
local function ensure_subtitle_cache()
    if STANDALONE_MODE then
        os.execute("mkdir -p " .. SUBTITLE_CACHE_DIR)
    else
        -- Use mpv's subprocess to avoid CMD window flash on Windows
        local is_windows = package.config:sub(1,1) == '\\'
        local args = is_windows and {"cmd", "/C", "mkdir", SUBTITLE_CACHE_DIR} or {"mkdir", "-p", SUBTITLE_CACHE_DIR}
        
        mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = args
        })
    end
end

-------------------------------------------------------------------------------
-- CUMULATIVE EPISODE CALCULATION (FIXED)
-- FIX #9: Better fallback handling with confidence tracking
-------------------------------------------------------------------------------

-- Calculate cumulative episode number with confidence tracking
local function calculate_jimaku_episode_safe(season_num, episode_num, seasons_data)
    if not season_num or season_num == 1 then
        return episode_num, "certain"
    end
    
    -- Calculate cumulative episodes from previous seasons
    local cumulative = 0
    local confidence = "certain"
    
    for season_idx = 1, season_num - 1 do
        if seasons_data and seasons_data[season_idx] then
            cumulative = cumulative + seasons_data[season_idx].eps
            debug_log(string.format("  S%d has %d episodes (from AniList)", 
                season_idx, seasons_data[season_idx].eps))
        else
            -- Fallback: assume standard 13-episode season
            cumulative = cumulative + 13
            confidence = "uncertain"
            debug_log(string.format("  S%d episode count UNKNOWN - assuming 13 (UNCERTAIN)", 
                season_idx), true)
        end
    end
    
    local jimaku_ep = cumulative + episode_num
    
    if confidence == "uncertain" then
        debug_log(string.format("WARNING: Cumulative calculation used fallback assumptions. Result may be incorrect!"), true)
        debug_log(string.format("  Calculated: S%dE%d -> Jimaku Episode %d (UNCERTAIN)", 
            season_num, episode_num, jimaku_ep), true)
    end
    
    return jimaku_ep, confidence
end

-- Wrapper for backwards compatibility (without confidence tracking)
local function calculate_jimaku_episode(season_num, episode_num, seasons_data)
    local result, _ = calculate_jimaku_episode_safe(season_num, episode_num, seasons_data)
    return result
end

-- Reverse: Convert Jimaku cumulative episode to AniList season episode
local function convert_jimaku_to_anilist_episode(jimaku_ep, target_season, seasons_data)
    if not target_season or target_season == 1 then
        return jimaku_ep
    end
    
    -- Calculate cumulative offset from previous seasons
    local cumulative = 0
    for season_idx = 1, target_season - 1 do
        if seasons_data and seasons_data[season_idx] then
            cumulative = cumulative + seasons_data[season_idx].eps
        else
            cumulative = cumulative + 13  -- Fallback
        end
    end
    
    return jimaku_ep - cumulative
end

-- Normalize full-width digits to ASCII
local function normalize_digits(s)
    if not s then return s end
    
    -- Replace common full-width digits
    s = s:gsub("０", "0"):gsub("１", "1"):gsub("２", "2"):gsub("３", "3"):gsub("４", "4")
    s = s:gsub("５", "5"):gsub("６", "6"):gsub("７", "7"):gsub("８", "8"):gsub("９", "9")
    
    return s
end

-------------------------------------------------------------------------------
-- JIMAKU SUBTITLE FILENAME PARSER
-- FIX #1: Improved pattern ordering and boundary checking
-------------------------------------------------------------------------------

-- Parse Jimaku subtitle filename to extract episode number(s)
local function parse_jimaku_filename(filename)
    if not filename then return nil, nil end
    
    -- Normalize full-width digits
    filename = normalize_digits(filename)
    
    -- Pattern cascade (ordered by specificity - MOST specific first)
    local patterns = {
        -- SxxExx patterns (MOST SPECIFIC - check first with boundaries)
        {"[^%w]S(%d+)E(%d+)[^%w]", "season_episode"},  -- Requires non-word boundaries
        {"^S(%d+)E(%d+)[^%w]", "season_episode"},       -- At start of string
        {"[^%w]S(%d+)E(%d+)$", "season_episode"},       -- At end of string
        {"^S(%d+)E(%d+)$", "season_episode"},           -- Entire string
        {"[Ss](%d+)[%s%._%-]+[Ee](%d+)", "season_episode"}, -- With separator
        {"Season%s*(%d+)%s*[%-%–—]%s*(%d+)", "season_episode"},
        
        -- Fractional episodes (13.5) - with context checking
        {"[^%d%.v](%d+%.5)[^%dv]", "fractional"},      -- Only .5 decimals, not version numbers
        {"%-%s*(%d+%.5)%s", "fractional"},              -- Preceded by dash
        {"%s(%d+%.5)%s", "fractional"},                 -- Surrounded by spaces
        {"%-%s*(%d+%.5)$", "fractional"},               -- At end after dash
        {"%s(%d+%.5)$", "fractional"},                  -- At end after space
        
        -- EPxx / Exx (with boundaries to prevent false matches)
        {"[^%a]EP(%d+)[^%d]", "episode"},               -- EP prefix, not preceded by letter
        {"[^%a][Ee]p%s*(%d+)[^%d]", "episode"},
        {"^EP(%d+)", "episode"},                         -- At start
        {"^[Ee]p%s*(%d+)", "episode"},
        
        -- Episode keyword (explicit)
        {"Episode%s*(%d+)", "episode"},
        
        -- Japanese patterns
        {"[#＃](%d+)", "episode"},
        {"第(%d+)[話回]", "episode"},
        {"（(%d+)）", "episode"},
        
        -- Common contextual patterns (ordered by specificity)
        {"_(%d+)%.[AaSs]", "episode"},                  -- _01.ass (very specific)
        {"%s(%d+)%s+BD%.", "episode"},                   -- " 01 BD."
        {"%s(%d+)%s+[Ww]eb[%s%.]", "episode"},          -- " 01 Web "
        {"%-%s*(%d+)%s*[%[(]", "episode"},              -- "- 01 ["
        {"%s(%d+)%s*%[", "episode"},                     -- " 01 ["
        
        -- Track patterns (low priority - uncommon)
        {"track(%d+)", "episode"},
        
        -- Underscore patterns
        {"_(%d%d%d)%.[AaSs]", "episode"},
        {"_(%d%d)%.[AaSs]", "episode"},
        
        -- Generic dash/space patterns (LOWEST priority)
        {"%-%s*(%d+)%.", "episode"},                    -- "- 01."
        {"%s(%d+)%.", "episode"},                        -- " 01."
        
        -- Last resort: pure number (must be start of filename only)
        {"^(%d+)%.", "episode"},
        
        -- Loose E pattern (VERY LOW priority - can cause false positives)
        {"[Ee](%d+)", "episode"},                        -- Last resort only
    }
    
    -- Try each pattern in order
    for _, pattern_data in ipairs(patterns) do
        local pattern = pattern_data[1]
        local ptype = pattern_data[2]
        
        if ptype == "season_episode" then
            local s, e = filename:match(pattern)
            if s and e then
                local season_num = tonumber(s)
                local episode_num = tonumber(e)
                -- Validation: reasonable season/episode ranges
                if season_num and episode_num and 
                   season_num >= 1 and season_num <= 20 and
                   episode_num >= 0 and episode_num <= 999 then
                    return season_num, episode_num
                end
            end
        elseif ptype == "fractional" then
            local e = filename:match(pattern)
            if e then
                -- Additional validation: not a version number
                local before = filename:match("([^%s]-)%s*" .. e:gsub("%.", "%%."))
                if not before or not before:lower():match("v%d*$") then
                    return nil, e  -- Return as string for fractional
                end
            end
        else  -- Regular episode
            local e = filename:match(pattern)
            if e then
                local num = tonumber(e)
                -- Sanity check: episode numbers should be reasonable
                if num and num >= 0 and num <= 999 then
                    return nil, num
                end
            end
        end
    end
    
    return nil, nil
end

-------------------------------------------------------------------------------
-- MAIN FILENAME PARSER (WITH CRITICAL HOTFIXES)
-- FIX #3: Improved title extraction with validation
-- HOTFIX: Japanese text, version tags, Part detection
-------------------------------------------------------------------------------

-- NEW: Strip Japanese/CJK characters and clean complex titles
local function clean_japanese_text(title)
    if not title then return title end
    
    -- Remove content in Japanese brackets 「」『』
    title = title:gsub("「[^」]*」", "")
    title = title:gsub("『[^』]*』", "")
    
    -- Remove common Japanese unicode ranges (simplified CJK removal)
    title = title:gsub("[\227-\233][\128-\191]+", "")
    
    -- Clean up resulting spaces
    title = title:gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    
    return title
end

-- NEW: Strip version tags (v2, v3, etc.)
local function strip_version_tag(str)
    if not str then return str end
    
    -- Remove version tags like "v2", "v3" etc
    str = str:gsub("%s*v%d+%s*", " ")
    str = str:gsub("%-v%d+", "")
    
    -- Clean up spaces
    str = str:gsub("%s+", " ")
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    
    return str
end

-- NEW: Clean parenthetical content intelligently
local function clean_parenthetical(title)
    if not title then return title end
    
    -- Remove parenthetical year/date info: (2025), (2024)
    title = title:gsub("%s*%(20%d%d%)%s*", " ")
    
    -- Remove empty parentheses
    title = title:gsub("%s*%(%s*%)%s*", " ")
    
    -- Clean up spaces
    title = title:gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    
    return title
end

-- Helper function: Extract title safely with validation (IMPROVED)
local function extract_title_safe(content, episode_marker)
    if not content then return nil end
    
    local title = nil
    
    -- Method 1: Extract before episode marker (most reliable)
    if episode_marker then
        -- Try to find title before the episode marker
        local patterns = {
            "^(.-)%s*[%-%–—]%s*" .. episode_marker,  -- "Title - E01"
            "^(.-)%s+" .. episode_marker,             -- "Title E01"
            "^(.-)%s*%_%s*" .. episode_marker,       -- "Title_E01"
        }
        
        for _, pattern in ipairs(patterns) do
            local t = content:match(pattern)
            if t and t:len() >= 2 then
                title = t
                break
            end
        end
    end
    
    -- Method 2: Remove common trailing patterns
    if not title then
        title = content
        -- Remove quality tags
        title = title:gsub("%s*%[?%d%d%d%d?p%]?.*$", "")
        title = title:gsub("%s*%d%d%d%dx%d%d%d%d.*$", "")
        -- Remove codec tags
        title = title:gsub("%s*[xh]26[45].*$", "")
        title = title:gsub("%s*HEVC.*$", "")
    end
    
    -- HOTFIX: Strip version tags
    title = strip_version_tag(title)
    
    -- HOTFIX: Clean Japanese text
    title = clean_japanese_text(title)
    
    -- HOTFIX: Clean parenthetical content
    title = clean_parenthetical(title)
    
    -- Clean up
    title = title:gsub("[%._]", " ")        -- Dots and underscores to spaces
    title = title:gsub("%s+", " ")          -- Multiple spaces to single
    title = title:gsub("^%s+", ""):gsub("%s+$", "")  -- Trim
    
    -- HOTFIX: Remove "Part" suffix that might be left over
    title = title:gsub("%s+Part$", "")
    
    -- Validation: title must be reasonable
    if not title or title:len() < 2 or title:len() > 200 then
        return nil
    end
    
    -- Must contain at least one letter (not just numbers)
    if not title:match("%a") then
        return nil
    end
    
    -- Don't allow titles that are just numbers and spaces
    if title:match("^[%d%s]+$") then
        return nil
    end
    
    return title
end

-- Better group name extraction with validation
local function extract_group_name(content)
    if not content then return nil end
    
    -- Pattern 1: [GroupName] at start (most reliable)
    local group = content:match("^%[([%w%._%-%s]+)%]")
    if group and group:len() >= 2 and group:len() <= 50 then
        -- Validate: group names typically have certain characteristics
        -- - Often all caps or mixed case
        -- - Often contain dots, dashes, or are short
        -- - Usually not more than 3 words
        local word_count = select(2, group:gsub("%S+", ""))
        if word_count <= 3 then
            return group
        end
    end
    
    return nil
end

-- Roman numeral converter (for season detection like "Title II")
local function roman_to_int(s)
    if not s then return nil end
    local romans = {I = 1, V = 5, X = 10, L = 50, C = 100}
    local res, prev = 0, 0
    s = s:upper()
    for i = #s, 1, -1 do
        local curr = romans[s:sub(i, i)]
        if curr then
            res = res + (curr < prev and -curr or curr)
            prev = curr
        else
            return nil  -- Invalid roman numeral
        end
    end
    return res > 0 and res or nil
end

-- Main parsing function with all fixes applied
local function parse_filename(filename)
    if not filename then return nil end
    
    -- Log for debugging
    debug_log("-------------------------------------------")
    debug_log("PARSING: " .. filename)
    
    -- Normalize digits
    filename = normalize_digits(filename)
    
    -- Initialize result with FIX #8: confidence tracking
    local result = {
        title = nil,
        episode = nil,
        season = nil,
        quality = nil,
        group = nil,
        is_special = false,
        is_movie = false,  -- NEW: Track if it's a movie
        confidence = "low"  -- Track parsing confidence
    }
    
    -- Strip file extension and path
    local clean_name = filename:gsub("%.%w%w%w?%w?$", "")  -- Remove extension
    clean_name = clean_name:match("([^/\\]+)$") or clean_name  -- Remove path
    
    -- FIX #4: Extract release group first with validation
    result.group = extract_group_name(clean_name)
    if result.group then
        -- Remove group tag from content
        clean_name = clean_name:gsub("^%[[%w%._%-%s]+%]%s*", "")
    end
    
    local content = clean_name
    
    -- FIX #1: PATTERN MATCHING (Ordered by specificity)
    
    -- Pattern A: SxxExx (HIGHEST confidence)
    local s, e = content:match("[^%w]S(%d+)[%s%._%-]*E(%d+%.?%d*)[^%w]")
    if not s then
        s, e = content:match("^S(%d+)[%s%._%-]*E(%d+%.?%d*)") -- At start
    end
    if not s then
        s, e = content:match("S(%d+)[%s%._%-]*E(%d+%.?%d*)$") -- At end
    end
    if not s then
        s, e = content:match("S(%d+)[%s%._%-]*E(%d+%.?%d*)") -- Anywhere
    end
    
    if s and e then
        result.season = tonumber(s)
        result.episode = e
        result.confidence = "high"
        -- Extract title before SxxExx
        result.title = content:match("^(.-)%s*[Ss]%d+[%s%._%-]*[Ee]%d+") or 
                       content:match("^(.-)%s*%-+%s*[Ss]%d+")
    end
    
    -- Pattern B: Explicit "Episode" keyword (HIGH confidence)
    if not result.episode then
        local t, ep = content:match("^(.-)%s*[Ee]pisode%s*(%d+%.?%d*)")
        if t and ep then
            result.title = t
            result.episode = ep
            result.confidence = "high"
        end
    end
    
    -- Pattern C: EPxx or Exx with good boundaries (MEDIUM-HIGH confidence)
    if not result.episode then
        local t, ep = content:match("^(.-)%s*[%-%–—]%s*EP?%s*(%d+%.?%d*)[^%d]")
        if not t then
            t, ep = content:match("^(.-)%s*[%-%–—]%s*EP?%s*(%d+%.?%d*)$")
        end
        if t and ep then
            result.title = t
            result.episode = ep
            result.confidence = "medium-high"
        end
    end
    
    -- Pattern D: Dash with number (MEDIUM confidence) - IMPROVED for version tags
    if not result.episode then
        -- Try to match episode WITH version tag (e.g., "01v2")
        local t, ep, version = content:match("^(.-)%s*[%-%–—]%s*(%d+)(v%d+)")
        if t and ep then
            result.title = t
            result.episode = ep
            result.confidence = "medium-high"
            debug_log(string.format("Detected episode %s with version tag '%s'", ep, version))
        else
            -- Standard dash pattern without version
            local t2, ep2 = content:match("^(.-)%s*[%-%–—]%s*(%d+%.?%d*)%s*[%[%(%s]")
            if not t2 then
                t2, ep2 = content:match("^(.-)%s*[%-%–—]%s*(%d+%.?%d*)$")
            end
            if t2 and ep2 then
                local ep_num = tonumber(ep2)
                -- FIX #2: Validate: probably not a year or other number
                if ep_num and ep_num >= 0 and ep_num <= 999 then
                    result.title = t2
                    result.episode = ep2
                    result.confidence = "medium"
                end
            end
        end
    end
    
    -- Pattern E: Space with number at end (LOW-MEDIUM confidence)
    if not result.episode then
        local t, ep = content:match("^(.-)%s+(%d+%.?%d*)%s*%[")
        if not t then
            t, ep = content:match("^(.-)%s+(%d+%.?%d*)$")
        end
        if t and ep then
            local ep_num = tonumber(ep)
            -- More validation needed for this pattern
            if ep_num and ep_num >= 1 and ep_num <= 999 and 
               not t:match("%d$") then  -- Title shouldn't end in number
                result.title = t
                result.episode = ep
                result.confidence = "low-medium"
            end
        end
    end
    
    -- FIX #3: If we still don't have a title, try safe extraction
    if not result.title then
        result.title = extract_title_safe(content, result.episode)
    end
    
    -- Clean up title if we got one
    if result.title then
        result.title = result.title:gsub("[%._]", " ")
        result.title = result.title:gsub("%s+", " ")
        result.title = result.title:gsub("^%s+", ""):gsub("%s+$", "")
        
        -- Remove common trailing junk
        result.title = result.title:gsub("%s*[%-%_%.]+$", "")
        
        -- HOTFIX: Additional cleaning passes
        result.title = strip_version_tag(result.title)
        result.title = clean_japanese_text(result.title)
        result.title = clean_parenthetical(result.title)
        
        -- Clean up again after all transformations
        result.title = result.title:gsub("%s+", " ")
        result.title = result.title:gsub("^%s+", ""):gsub("%s+$", "")
    end
    
    -- SEASON DETECTION (if not already found)
    
    -- HOTFIX: Remove "Part X" before season detection
    local part_num = nil
    if result.title then
        part_num = result.title:match("%s+Part%s+(%d+)$")
        if part_num then
            result.title = result.title:gsub("%s+Part%s+%d+$", "")
            debug_log(string.format("Removed 'Part %s' from title (not a season marker)", part_num))
        end
    end
    
    -- Method 1: Roman numerals (e.g., "Overlord II" -> Season 2)
    if not result.season and result.title then
        local roman = result.title:match("%s([IVXLCivxlc]+)$")
        if roman then
            local season_num = roman_to_int(roman)
            if season_num and season_num >= 1 and season_num <= 10 then
                result.season = season_num
                result.title = result.title:gsub("%s" .. roman .. "$", "")
                debug_log(string.format("Detected Season %d from Roman numeral '%s'", season_num, roman))
            end
        end
    end
    
    -- Method 2: "S2" suffix (e.g., "Oshi no Ko S3")
    if not result.season and result.title then
        local s_num = result.title:match("%s[Ss](%d+)$")
        if s_num then
            result.season = tonumber(s_num)
            result.title = result.title:gsub("%s[Ss]%d+$", "")
            debug_log(string.format("Detected Season %d from 'S' suffix", result.season))
        end
    end
    
    -- Method 3: Season keywords
    if not result.season and result.title then
        local season_patterns = {
            "[Ss]eason%s*(%d+)",
            "(%d+)[nrdt][dht]%s+[Ss]eason",
        }
        for _, pattern in ipairs(season_patterns) do
            local s_num = result.title:match(pattern)
            if s_num then
                result.season = tonumber(s_num)
                -- Remove season marker from title
                result.title = result.title:gsub("%s*%(?%d*[nrdt][dht]%s+[Ss]eason%)?", "")
                result.title = result.title:gsub("%s*%(?[Ss]eason%s+%d+%)?", "")
                debug_log(string.format("Detected Season %d from keyword", result.season))
                break
            end
        end
    end
    
    -- Method 4: Trailing number (conservative - only for small numbers)
    -- HOTFIX: Only run if "Part X" was NOT found
    if not result.season and result.title and not part_num then
        local trailing = result.title:match("%s(%d+)$")
        if trailing then
            local num = tonumber(trailing)
            -- Very conservative: only 2-6, and avoid numeric titles
            if num and num >= 2 and num <= 6 and 
               not result.title:match("^%d") and  -- Title doesn't start with number
               not result.title:match("%d/%d") then  -- Not a fraction like "22/7"
                result.season = num
                result.title = result.title:gsub("%s%d+$", "")
                debug_log(string.format("Detected Season %d from trailing number (low confidence)", num))
            end
        end
    end
    
    -- FIX #6: SPECIAL EPISODE DETECTION (Enhanced)
    local combined = (result.episode or "") .. " " .. content:lower()
    if combined:match("ova") or combined:match("oad") or 
       combined:match("special") or combined:match("sp[^a-z]") or
       result.episode == "0" or
       combined:match("recap") then
        result.is_special = true
    end
    
    -- HOTFIX: MOVIE DETECTION (enhanced)
    local movie_keywords = {"movie", "gekijouban", "the movie", "film"}
    local title_lower = (result.title or ""):lower()
    for _, keyword in ipairs(movie_keywords) do
        if title_lower:match(keyword) then
            result.is_movie = true
            result.is_special = true
            debug_log("Detected as MOVIE")
            break
        end
    end
    
    -- QUALITY DETECTION (basic)
    local quality_pattern = content:match("(%d%d%d%d?p)")
    if quality_pattern then
        result.quality = quality_pattern
    end
    
    -- FIX #8: FINAL VALIDATION
    if not result.title or result.title:len() < 2 then
        debug_log("ERROR: Failed to extract valid title", true)
        result.title = content  -- Fallback to full content
        result.confidence = "failed"
    end
    
    if not result.episode then
        if result.is_movie then
            result.episode = "1"  -- Movies are episode 1
            debug_log("Movie detected - setting episode to 1")
        else
            result.episode = "1"  -- Default
            result.confidence = "failed"
        end
    end
    
    -- Validate episode number
    local ep_num = tonumber(result.episode)
    if ep_num and (ep_num < 0 or ep_num > 999) then
        debug_log(string.format("WARNING: Episode number %d outside reasonable range", ep_num), true)
    end
    
    -- Validate season number
    if result.season and (result.season < 1 or result.season > 20) then
        debug_log(string.format("WARNING: Season number %d outside reasonable range", result.season), true)
    end
    
    debug_log(string.format("RESULT: Title='%s' | S=%s | E=%s | Confidence=%s | Special=%s | Movie=%s",
        result.title,
        result.season or "nil",
        result.episode,
        result.confidence,
        result.is_special and "yes" or "no",
        result.is_movie and "yes" or "no"))
    
    return result
end

-------------------------------------------------------------------------------
-- PARSER TEST MODE
-------------------------------------------------------------------------------

local function test_parser(input_file)
    local test_file = input_file or TEST_FILE
    
    debug_log("=== PARSER TEST MODE STARTED ===")
    debug_log("Reading from: " .. test_file)
    
    local file = io.open(test_file, "r")
    if not file then
        debug_log("Could not find " .. test_file, true)
        debug_log("Please create the file with torrent filenames (one per line)", true)
        return
    end
    
    local lines = {}
    for line in file:lines() do
        if line:match("%S") then
            table.insert(lines, line)
        end
    end
    file:close()
    
    debug_log(string.format("Processing %d entries", #lines))
    debug_log("")
    
    local results = {}
    local failures = 0
    
    for _, filename in ipairs(lines) do
        local res = parse_filename(filename)
        if res then
            table.insert(results, res)
        else
            failures = failures + 1
        end
    end
    
    debug_log("")
    debug_log("=== PARSER TEST SUMMARY ===")
    debug_log(string.format("Total: %d | Success: %d | Failures: %d", #lines, #results, failures), failures > 0)
    debug_log("Results written to: " .. PARSER_LOG_FILE)
    
    return results, failures
end

-------------------------------------------------------------------------------
-- STANDALONE MODE EXECUTION
-------------------------------------------------------------------------------

if STANDALONE_MODE then
    -- Parse command line arguments
    local input_file = nil
    local show_help = false
    
    for i = 1, #arg do
        if arg[i] == "--parser" and arg[i + 1] then
            input_file = arg[i + 1]
        elseif arg[i] == "--help" or arg[i] == "-h" then
            show_help = true
        end
    end
    
    if show_help then
        print("AniList Parser - Standalone Mode")
        print("")
        print("Usage:")
        print("  lua anilist.lua --parser <filename>")
        print("")
        print("Examples:")
        print("  lua anilist.lua --parser torrents.txt")
        print("  lua anilist.lua --parser /path/to/files.txt")
        print("")
        print("Output:")
        print("  Results are written to parser-debug.log")
        os.exit(0)
    end
    
    -- Clear log file
    local f = io.open(PARSER_LOG_FILE, "w")
    if f then f:close() end
    
    -- Run parser test
    test_parser(input_file)
    os.exit(0)
end

-------------------------------------------------------------------------------
-- MPV MODE - JIMAKU INTEGRATION
-------------------------------------------------------------------------------

-- Search Jimaku for subtitle entry by AniList ID
local function search_jimaku_subtitles(anilist_id)
    if not JIMAKU_API_KEY or JIMAKU_API_KEY == "" then
        debug_log("Jimaku API key not configured - skipping subtitle search", false)
        return nil
    end
    
    debug_log(string.format("Searching Jimaku for AniList ID: %d", anilist_id))
    
    -- Search for entry by AniList ID
    local search_url = string.format("%s/entries/search?anilist_id=%d&anime=true", 
        JIMAKU_API_URL, anilist_id)
    
    local args = {
        "curl", "-s", "-X", "GET",
        "-H", "Authorization: " .. JIMAKU_API_KEY,
        search_url
    }
    
    local result = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = args
    })
    
    if result.status ~= 0 or not result.stdout then
        debug_log("Jimaku search request failed", true)
        return nil
    end
    
    local ok, entries = pcall(utils.parse_json, result.stdout)
    if not ok or not entries or #entries == 0 then
        debug_log("No Jimaku entries found for AniList ID: " .. anilist_id, false)
        return nil
    end
    
    debug_log(string.format("Found Jimaku entry: %s (ID: %d)", entries[1].name, entries[1].id))
    return entries[1]
end

-- Fetch ALL subtitle files for an entry (no episode filter)
local function fetch_all_episode_files(entry_id)
    -- Check cache first
    if episode_cache[entry_id] then
        local cache_age = os.time() - episode_cache[entry_id].timestamp
        if cache_age < 300 then  -- Cache valid for 5 minutes
            debug_log(string.format("Using cached file list for entry %d (%d files)", entry_id, #episode_cache[entry_id].files))
            return episode_cache[entry_id].files
        end
    end
    
    local files_url = string.format("%s/entries/%d/files", JIMAKU_API_URL, entry_id)
    
    debug_log("Fetching ALL subtitle files from: " .. files_url)
    
    local args = {
        "curl", "-s", "-X", "GET",
        "-H", "Authorization: " .. JIMAKU_API_KEY,
        files_url
    }
    
    local result = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = args
    })
    
    if result.status ~= 0 or not result.stdout then
        debug_log("Failed to fetch file list", true)
        return nil
    end
    
    local ok, files = pcall(utils.parse_json, result.stdout)
    if not ok or not files then
        debug_log("Failed to parse file list JSON", true)
        return nil
    end
    
    debug_log(string.format("Retrieved %d total subtitle files", #files))
    
    -- Cache the result
    episode_cache[entry_id] = {
        files = files,
        timestamp = os.time()
    }
    
    return files
end

-- Intelligent episode matching using metadata (fuzzy/lenient approach)
local function match_episodes_intelligent(files, target_episode, target_season, seasons_data, anime_title)
    if not files or #files == 0 then
        return {}
    end
    
    debug_log(string.format("Matching files for S%d E%d from %d total files...", 
        target_season or 1, target_episode, #files))
    
    local matches = {}
    local all_parsed = {}
    
    -- Calculate what cumulative episode we're looking for
    local target_cumulative = calculate_jimaku_episode(target_season, target_episode, seasons_data)
    debug_log(string.format("Target: S%d E%d = Cumulative Episode %d", 
        target_season or 1, target_episode, target_cumulative))
    
    -- Parse all filenames and build episode map
    for _, file in ipairs(files) do
        local jimaku_season, jimaku_episode = parse_jimaku_filename(file.name)
        
        if jimaku_episode then
            local anilist_episode = nil
            local match_type = ""
            local is_match = false
            
            -- Convert to number if it's a string
            local ep_num = tonumber(jimaku_episode) or 0
            
            -- CASE 1: Jimaku file has explicit season marker (S02E14, S03E48)
            if jimaku_season then
                -- Try multiple interpretations of season-marked files
                
                -- Interpretation 1A: Standard season numbering (S2E03 = Season 2, Episode 3)
                if jimaku_season == target_season and ep_num == target_episode then
                    is_match = true
                    anilist_episode = target_episode
                    match_type = "direct_season_match"
                end
                
                -- Interpretation 1B: Netflix-style absolute numbering in season format
                -- (S02E14 actually means "Episode 14 overall", not "Season 2, Episode 14")
                if not is_match and ep_num == target_cumulative then
                    is_match = true
                    anilist_episode = target_episode
                    match_type = "netflix_absolute_in_season_format"
                end
                
                -- Interpretation 1C: Season marker but episode is cumulative from that season's start
                -- (S02E03 means 3rd episode of Season 2, where S2 started at overall episode 14)
                if not is_match and jimaku_season == target_season then
                    -- Calculate what cumulative episode this would be
                    local file_cumulative = calculate_jimaku_episode(jimaku_season, ep_num, seasons_data)
                    if file_cumulative == target_cumulative then
                        is_match = true
                        anilist_episode = target_episode
                        match_type = "season_relative_cumulative"
                    end
                end
            
            -- CASE 2: Jimaku file has NO season marker - could be cumulative OR within-season
            else
                -- Interpretation 2A: It's a cumulative episode number (E14 = overall episode 14)
                if ep_num == target_cumulative then
                    is_match = true
                    anilist_episode = target_episode
                    match_type = "cumulative_match"
                end
                
                -- Interpretation 2B: It's the within-season episode (E03 = 3rd episode of current season)
                if not is_match and ep_num == target_episode then
                    is_match = true
                    anilist_episode = target_episode
                    match_type = "direct_episode_match"
                end
                
                -- Interpretation 2C: Reverse cumulative conversion
                -- (File says E14, but maybe it means something else in context)
                if not is_match then
                    local converted_ep = convert_jimaku_to_anilist_episode(ep_num, target_season, seasons_data)
                    if converted_ep == target_episode then
                        is_match = true
                        anilist_episode = target_episode
                        match_type = "reverse_cumulative_conversion"
                    end
                end
            end
            
            -- Store parsed info for debugging
            table.insert(all_parsed, {
                filename = file.name,
                jimaku_season = jimaku_season,
                jimaku_episode = ep_num,
                anilist_episode = anilist_episode,
                match_type = match_type,
                is_match = is_match,
                file = file
            })
            
            -- Add to matches if we found a match
            if is_match then
                table.insert(matches, file)
                debug_log(string.format("  ✓ MATCH [%s]: %s", 
                    match_type, file.name:sub(1, 80)))
            end
        end
    end
    
    -- If no matches found, show what we parsed for debugging
    if #matches == 0 then
        debug_log(string.format("No matches found for S%d E%d (cumulative: %d). Parsed episodes:", 
            target_season or 1, target_episode, target_cumulative))
        for i = 1, math.min(10, #all_parsed) do
            local p = all_parsed[i]
            local jimaku_display = p.jimaku_season and string.format("S%dE%d", p.jimaku_season, p.jimaku_episode) 
                                   or string.format("E%d", p.jimaku_episode)
            
            debug_log(string.format("  [%d] %s... → Jimaku: %s, Tried: %s", 
                i, 
                p.filename:sub(1, 40),
                jimaku_display,
                p.match_type ~= "" and p.match_type or "no_patterns_matched"))
        end
        if #all_parsed > 10 then
            debug_log(string.format("  ... and %d more files", #all_parsed - 10))
        end
    else
        debug_log(string.format("Found %d matching file(s)", #matches))
    end
    
    return matches
end

-- Smart subtitle download with intelligent matching
local function download_subtitle_smart(entry_id, target_episode, target_season, seasons_data, anime_title)
    -- Fetch all files for this entry
    local all_files = fetch_all_episode_files(entry_id)
    
    if not all_files or #all_files == 0 then
        debug_log("No subtitle files available for this entry", false)
        return false
    end
    
    -- Match files intelligently
    local matched_files = match_episodes_intelligent(all_files, target_episode, target_season, seasons_data, anime_title)
    
    if #matched_files == 0 then
        debug_log(string.format("No subtitle files matched S%d E%d", target_season or 1, target_episode), false)
        return false
    end
    
    debug_log(string.format("Found %d matching subtitle file(s) for S%d E%d:", 
        #matched_files, target_season or 1, target_episode))
    
    -- Log all matched files
    for i, file in ipairs(matched_files) do
        local size_kb = math.floor(file.size / 1024)
        debug_log(string.format("  [%d] %s (%d KB)", i, file.name, size_kb))
    end
    
    -- Determine how many to download
    local max_downloads = #matched_files
    if JIMAKU_MAX_SUBS ~= "all" and type(JIMAKU_MAX_SUBS) == "number" then
        max_downloads = math.min(JIMAKU_MAX_SUBS, #matched_files)
    end
    
    debug_log(string.format("Downloading %d of %d matched subtitle(s)...", max_downloads, #matched_files))
    
    local success_count = 0
    
    -- Download and load subtitles
    for i = 1, max_downloads do
        local subtitle_file = matched_files[i]
        local subtitle_path = SUBTITLE_CACHE_DIR .. "/" .. subtitle_file.name
        
        debug_log(string.format("Downloading [%d/%d]: %s (%d bytes)", 
            i, max_downloads, subtitle_file.name, subtitle_file.size))
        
        -- Download the file
        local download_args = {
            "curl", "-s", "-L", "-o", subtitle_path,
            "-H", "Authorization: " .. JIMAKU_API_KEY,
            subtitle_file.url
        }
        
        local download_result = mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = download_args
        })
        
        if download_result.status == 0 then
            -- Load subtitle into mpv
            mp.commandv("sub-add", subtitle_path)
            debug_log(string.format("Successfully loaded subtitle [%d/%d]: %s", 
                i, max_downloads, subtitle_file.name))
            success_count = success_count + 1
        else
            debug_log(string.format("Failed to download subtitle [%d/%d]: %s", 
                i, max_downloads, subtitle_file.name), true)
        end
    end
    
    if success_count > 0 then
        mp.osd_message(string.format("✓ Loaded %d subtitle(s)", success_count), 4)
        return true
    else
        debug_log("Failed to download any subtitles", true)
        return false
    end
end

-------------------------------------------------------------------------------
-- MPV MODE - ANILIST INTEGRATION
-------------------------------------------------------------------------------

local function make_anilist_request(query, variables)
    debug_log("AniList Request for: " .. (variables.search or "unknown"))
    
    local request_body = utils.format_json({query = query, variables = variables})
    local args = { 
        "curl", "-s", "-X", "POST", 
        "-H", "Content-Type: application/json", 
        "-H", "Accept: application/json", 
        "--data", request_body, 
        ANILIST_API_URL 
    }
    
    local result = mp.command_native({
        name = "subprocess", 
        capture_stdout = true, 
        playback_only = false, 
        args = args
    })
    
    if result.status ~= 0 or not result.stdout then 
        debug_log("Curl request failed or returned no output", true)
        return nil 
    end
    
    local ok, data = pcall(utils.parse_json, result.stdout)
    if not ok then
        debug_log("Failed to parse JSON response", true)
        return nil
    end
    
    if data.errors then
        debug_log("AniList API Error: " .. utils.format_json(data.errors), true)
        return nil
    end
    
    return data.data
end

-------------------------------------------------------------------------------
-- SMART MATCH ALGORITHM (FIXED)
-- FIX #10: Improved priority system with conflict resolution
-------------------------------------------------------------------------------

local function smart_match_anilist(results, parsed, episode_num, season_num)
    local selected = results[1]  -- Default to best search match
    local actual_episode = episode_num
    local actual_season = season_num or 1
    local match_method = "default"
    local match_confidence = "low"
    local seasons = {}
    
    -- FIX #10: Weight different signals
    local has_explicit_season = (season_num and season_num >= 2)
    local has_special_indicator = parsed.is_special
    
    -- Priority scoring system:
    -- Explicit season marker in filename = 10 points (highest trust)
    -- Special keyword in filename = 5 points
    -- Episode number exceeds S1 count = 3 points (suggests later season)
    
    local explicit_season_weight = has_explicit_season and 10 or 0
    local special_weight = has_special_indicator and 5 or 0
    
    debug_log(string.format("Smart Match Weights: Explicit Season=%d, Special=%d", 
        explicit_season_weight, special_weight))
    
    -- PRIORITY 1: Explicit Season Number (HIGHEST weight)
    -- If user has S2/S3 in filename, this should override special detection
    if has_explicit_season then
        for i, media in ipairs(results) do
            local full_text = (media.title.romaji or "") .. " " .. (media.title.english or "")
            for _, syn in ipairs(media.synonyms or {}) do
                full_text = full_text .. " " .. syn
            end
            
            local is_match = false
            local search_pattern = nil
            
            if season_num == 2 then
                search_pattern = "season 2"
                is_match = full_text:lower():match("season%s*2") or full_text:lower():match("2nd%s+season")
            elseif season_num == 3 then
                search_pattern = "season 3"
                is_match = full_text:lower():match("season%s*3") or full_text:lower():match("3rd%s+season")
            elseif season_num >= 4 then
                search_pattern = "season " .. season_num
                is_match = full_text:lower():match("season%s*" .. season_num)
            end
            
            if is_match then
                selected = media
                actual_episode = episode_num
                actual_season = season_num
                match_method = "explicit_season"
                match_confidence = "high"
                debug_log(string.format("MATCH: Explicit Season %d via '%s' (HIGH CONFIDENCE)", 
                    season_num, search_pattern))
                
                -- Store this season's data
                seasons[season_num] = {media = media, eps = media.episodes or 13, name = media.title.romaji}
                
                return selected, actual_episode, actual_season, seasons, match_method, match_confidence
            end
        end
        
        -- If we have explicit season but didn't find match, log warning
        debug_log(string.format("WARNING: S%d specified but no matching season entry found in results", 
            season_num), true)
    end
    
    -- PRIORITY 2: Special/OVA Format (MEDIUM-HIGH weight)
    -- Only if no explicit season number, OR if explicit season also has special keyword
    if has_special_indicator and not has_explicit_season then
        for i, media in ipairs(results) do
            if media.format == "SPECIAL" or media.format == "OVA" or media.format == "ONA" then
                selected = media
                actual_episode = episode_num
                actual_season = 1  -- Specials usually don't have seasons
                match_method = "special_format"
                match_confidence = "medium-high"
                debug_log(string.format("MATCH: Special/OVA format '%s' (MEDIUM-HIGH CONFIDENCE)", 
                    media.format))
                return selected, actual_episode, actual_season, seasons, match_method, match_confidence
            end
        end
    end
    
    -- PRIORITY 3: Cumulative Episode Calculation (MEDIUM weight)
    -- If episode number exceeds first result's count, try to find correct season
    if not has_explicit_season and episode_num > (selected.episodes or 0) then
        debug_log("Episode number exceeds S1 count - attempting cumulative calculation")
        
        -- Build season list
        for i, media in ipairs(results) do
            if media.format == "TV" and media.episodes then
                local full_text = (media.title.romaji or "") .. " " .. (media.title.english or "")
                for _, syn in ipairs(media.synonyms or {}) do
                    full_text = full_text .. " " .. syn
                end
                
                -- Season 1 (no season marker)
                if not seasons[1] and not full_text:lower():match("season") and 
                   not full_text:lower():match("%dnd") and 
                   not full_text:lower():match("%drd") and 
                   not full_text:lower():match("%dth") then
                    seasons[1] = {media = media, eps = media.episodes, name = media.title.romaji}
                end
                
                -- Season 2
                if not seasons[2] and (full_text:lower():match("2nd%s+season") or 
                   full_text:lower():match("season%s*2")) then
                    seasons[2] = {media = media, eps = media.episodes, name = media.title.romaji}
                end
                
                -- Season 3
                if not seasons[3] and (full_text:lower():match("3rd%s+season") or 
                   full_text:lower():match("season%s*3")) then
                    seasons[3] = {media = media, eps = media.episodes, name = media.title.romaji}
                end
            end
        end
        
        -- Calculate which season this episode belongs to
        local cumulative = 0
        local found_match = false
        
        for season_idx = 1, 3 do
            if seasons[season_idx] then
                local season_eps = seasons[season_idx].eps
                debug_log(string.format("  Season %d: %s (%d eps, range: %d-%d)", 
                    season_idx, seasons[season_idx].name, season_eps, 
                    cumulative + 1, cumulative + season_eps))
                
                if episode_num <= cumulative + season_eps then
                    selected = seasons[season_idx].media
                    actual_episode = episode_num - cumulative
                    actual_season = season_idx
                    match_method = "cumulative"
                    match_confidence = "medium"
                    found_match = true
                    debug_log(string.format("MATCH: Cumulative - Ep %d -> S%dE%d of '%s' (MEDIUM CONFIDENCE)", 
                        episode_num, season_idx, actual_episode, selected.title.romaji))
                    break
                end
                cumulative = cumulative + season_eps
            end
        end
        
        if found_match then
            return selected, actual_episode, actual_season, seasons, match_method, match_confidence
        else
            debug_log("WARNING: Cumulative calculation failed - episode exceeds all known seasons", true)
        end
    end
    
    -- FALLBACK: Use default (first result)
    if season_num then
        actual_season = season_num
    end
    
    match_method = "default"
    match_confidence = "low"
    debug_log("Using default match (first search result) - LOW CONFIDENCE")
    
    return selected, actual_episode, actual_season, seasons, match_method, match_confidence
end

-- Main search function with integrated smart matching
local function search_anilist()
    local filename = mp.get_property("filename")
    if not filename then return end

    local parsed = parse_filename(filename)
    if not parsed then
        mp.osd_message("AniList: Failed to parse filename", 3)
        return
    end

    mp.osd_message("AniList: Searching for " .. parsed.title .. "...", 3)

    local query = [[
    query ($search: String) {
      Page (page: 1, perPage: 15) {
        media (search: $search, type: ANIME) {
          id
          title {
            romaji
            english
          }
          synonyms
          status
          episodes
          format
        }
      }
    }
    ]]

    local data = make_anilist_request(query, {search = parsed.title})

    if data and data.Page and data.Page.media then
        local results = data.Page.media
        
        debug_log(string.format("Analyzing %d potential matches for '%s' %sE%s...", 
            #results, 
            parsed.title, 
            parsed.season and string.format("S%d ", parsed.season) or "",
            parsed.episode))

        -- Use improved smart match algorithm (FIX #10)
        local episode_num = tonumber(parsed.episode) or 1
        local season_num = parsed.season
        
        local selected, actual_episode, actual_season, seasons, match_method, match_confidence = 
            smart_match_anilist(results, parsed, episode_num, season_num)

        -- Log match quality
        debug_log(string.format("Match Method: %s | Confidence: %s", match_method, match_confidence))
        
        -- Final reporting with Type/Format
        for i, media in ipairs(results) do
            local romaji = media.title.romaji or "N/A"
            local total_eps = media.episodes or "??"
            local m_format = media.format or "UNK"
            local first_syn = (media.synonyms and media.synonyms[1]) or "None"
            local marker = (media.id == selected.id) and ">>" or "  "
            
            debug_log(string.format("%s [%d] ID: %-7s | %-7s | Eps: %-3s | Syn: %-15s | %s", 
                marker, i, media.id, m_format, total_eps, first_syn, romaji))
        end

        -- Build OSD message with confidence warning
        local osd_msg = string.format("AniList Match: %s\nID: %s | S%d E%d\nFormat: %s | Total Eps: %s", 
            selected.title.romaji, 
            selected.id,
            actual_season,
            actual_episode,
            selected.format or "TV",
            selected.episodes or "?")
        
        -- Add warning for low confidence matches
        if match_confidence == "low" or match_confidence == "uncertain" then
            osd_msg = osd_msg .. "\n⚠ Low confidence - verify result"
        end
        
        mp.osd_message(osd_msg, 5)

        -- Try to fetch subtitles from Jimaku using smart matching
        local jimaku_entry = search_jimaku_subtitles(selected.id)
        if jimaku_entry then
            download_subtitle_smart(
                jimaku_entry.id, 
                actual_episode, 
                actual_season,
                seasons,
                selected.title.romaji
            )
        end
    else
        debug_log("FAILURE: No matches found for " .. parsed.title, true)
        mp.osd_message("AniList: No match found.", 3)
    end
end

-- Initialize
if not STANDALONE_MODE then
    -- Create subtitle cache directory
    ensure_subtitle_cache()
    
    -- Load Jimaku API key
    load_jimaku_api_key()
    
    -- Keybind 'A' to trigger the search
    mp.add_key_binding("A", "anilist-search", search_anilist)
    
    -- Auto-download subtitles on file load if enabled
    if JIMAKU_AUTO_DOWNLOAD then
        mp.register_event("file-loaded", function()
            -- Small delay to ensure file is ready
            mp.add_timeout(0.5, search_anilist)
        end)
        debug_log("AniList Script Initialized with auto-download enabled. Press 'A' to manually search.")
    else
        debug_log("AniList Script Initialized. Press 'A' to search current file.")
    end
end