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

-- Calculate cumulative episode number for Jimaku (which uses continuous numbering)
local function calculate_jimaku_episode(season_num, episode_num, seasons_data)
    if not season_num or season_num == 1 then
        return episode_num
    end
    
    -- Calculate cumulative episodes from previous seasons
    local cumulative = 0
    for season_idx = 1, season_num - 1 do
        if seasons_data and seasons_data[season_idx] then
            cumulative = cumulative + seasons_data[season_idx].eps
        else
            -- Fallback: assume standard 13-episode season if data unavailable
            cumulative = cumulative + 13
        end
    end
    
    return cumulative + episode_num
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
    
    -- Simple approach: replace common full-width digits
    s = s:gsub("０", "0"):gsub("１", "1"):gsub("２", "2"):gsub("３", "3"):gsub("４", "4")
    s = s:gsub("５", "5"):gsub("６", "6"):gsub("７", "7"):gsub("８", "8"):gsub("９", "9")
    
    return s
end

-- Parse Jimaku subtitle filename to extract episode number(s)
local function parse_jimaku_filename(filename)
    if not filename then return nil, nil end
    
    -- Normalize full-width digits
    filename = normalize_digits(filename)
    
    -- Pattern cascade (ordered by reliability)
    local patterns = {
        -- SxxExx patterns
        {"S(%d+)E(%d+)", "season_episode"},
        {"[Ss](%d+)[Ee](%d+)", "season_episode"},
        {"S(%d+)%s*%-%s*E(%d+)", "season_episode"},
        {"Season%s*(%d+)%s*%-%s*(%d+)", "season_episode"},
        
        -- Fractional episodes (13.5)
        {"%-%s*(%d+%.%d+)", "fractional"},
        {"%s(%d+%.%d+)", "fractional"},
        
        -- EPxx / Exx
        {"EP(%d+)", "episode"},
        {"[Ee]p%s*(%d+)", "episode"},
        {"[Ee](%d+)", "episode"},
        
        -- Episode keyword
        {"Episode%s*(%d+)", "episode"},
        
        -- Japanese patterns
        {"[#＃](%d+)", "episode"},
        {"第(%d+)[話回]", "episode"},
        {"（(%d+)）", "episode"},
        
        -- Common patterns
        {"_(%d+)%.", "episode"},
        {"%s(%d+)%s+BD%.", "episode"},
        {"%s(%d+)%s+Web%s", "episode"},
        {"%-%s*(%d+)%s*[%[(]", "episode"},
        {"%-%s*(%d+)%s*％", "episode"},
        {"%s(%d+)%s*%[", "episode"},
        
        -- Track patterns
        {"track(%d+)", "episode"},
        
        -- Underscore patterns
        {"_(%d%d%d)%.[AaSs]", "episode"},
        {"_(%d%d)%.[AaSs]", "episode"},
        
        -- Dash patterns
        {"%-%s*(%d+)%.", "episode"},
        
        -- Pure number
        {"^(%d+)%.", "episode"},
    }
    
    for _, pattern_data in ipairs(patterns) do
        local pattern = pattern_data[1]
        local ptype = pattern_data[2]
        
        if ptype == "season_episode" then
            local s, e = filename:match(pattern)
            if s and e then
                return tonumber(s), tonumber(e)
            end
        elseif ptype == "fractional" then
            local e = filename:match(pattern)
            if e then
                return nil, e  -- Return as string for fractional
            end
        else
            local e = filename:match(pattern)
            if e then
                local num = tonumber(e)
                -- Sanity check: episode numbers should be reasonable
                if num and num > 0 and num < 9999 then
                    return nil, num
                end
            end
        end
    end
    
    return nil, nil
end

-------------------------------------------------------------------------------
-- FILENAME PARSER LOGIC
-------------------------------------------------------------------------------

-- Helper to extract content inside brackets/parentheses
local function extract_hash(str)
    if not str then return "N/A" end
    local h = str:match("%[([%x]+)%]") or str:match("%(([%x]+)%)")
    return h or "N/A"
end

-- Extract quality from various formats
local function extract_quality(str)
    if not str then return nil end
    local q = str:match("%((%d%d%d%d?p)%)") or 
              str:match("%[(%d%d%d%d?p)%]") or
              str:match("(%d%d%d%d?p)") or
              str:match("(%d%d%d%dx%d%d%d%d)")
    return q or "unknown"
end

-- Normalize title by removing common patterns
local function normalize_title(title)
    if not title then return "" end
    -- Replace underscores and dots with spaces
    title = title:gsub("[%._]", " ")
    -- Clean up multiple spaces
    title = title:gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    return title
end

-- Detect if title contains reversed patterns
local function is_reversed(str)
    return str:match("p027") or str:match("p0801") or str:match("%d%d%dE%-%d%dS")
end

-- Reverse string if needed
local function maybe_reverse(str)
    if is_reversed(str) then
        local chars = {}
        for i = #str, 1, -1 do
            table.insert(chars, str:sub(i, i))
        end
        return table.concat(chars)
    end
    return str
end

-- Clean episode string
local function clean_episode(episode_str)
    if not episode_str then return "" end
    episode_str = episode_str:gsub("^%((.-)%)$", "%1")
    episode_str = episode_str:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return episode_str
end

-- Detect special episodes
local function is_special(episode_str, content)
    local combined = (episode_str or "") .. " " .. (content or "")
    combined = combined:lower()
    return combined:match("sp") or combined:match("special") or combined:match("ova") or combined:match("ovd")
end

local function roman_to_int(s)
    local romans = {I = 1, V = 5, X = 10}
    local res, prev = 0, 0
    s = s:upper()
    for i = #s, 1, -1 do
        local curr = romans[s:sub(i, i)]
        if curr then
            res = res + (curr < prev and -curr or curr)
            prev = curr
        end
    end
    return res > 0 and res or nil
end

local function parse_filename(filename)
    -- 1. Log original filename immediately for traceability
    local original_raw = filename
    debug_log("-------------------------------------------")
    debug_log("INPUT FILENAME: " .. original_raw)

    -- Preprocessing using your existing helper
    filename = maybe_reverse(filename)
    
    local title, episode, season, quality
    local release_group = "unknown"
    
    -- Strip file extension and path (Handle both / and \ for Windows compatibility)
    local no_ext = filename:gsub("%.%w%w%w?$", "")
    local clean_name = no_ext:match("^.+[/\\](.+)$") or no_ext
    
    -- 2. Extract Release Group [Group Name]
    local group_match, content = clean_name:match("^%[([^%]]+)%]%s*(.+)$")
    if group_match then
        release_group = group_match
    else
        content = clean_name
    end

    -- 3. HEURISTIC CASCADE (High confidence to Low confidence)
    
    -- Pattern A: Standard SxxExx or Sxx - Exx (e.g., S02E01, S2 - 01)
    local s, e = content:match("[Ss](%d+)[%s%.%_]*[Ee](%d+%.?%d*)")
    if not s then
         s, e = content:match("[Ss](%d+)%s*-%s*(%d+%.?%d*)")
    end
    
    if s and e then
        season = tonumber(s)
        episode = e
        title = content:match("^(.-)[%s%.%_]*[Ss]%d+[Ee]%d+") or content:match("^(.-)[%s%.%_]*[Ss]%d+%s*%-")
    end

    -- Pattern B: Explicit Episode Tag (e.g., - 01 or Ep 01)
    if not episode then
        -- Handle titles with multiple dashes like "Gintama - 3-nen Z-gumi - 12"
        -- We look for the LAST occurrence of " - Number" that isn't inside brackets
        local t_multi, ep_multi = content:match("^(.-)%s+%-%s+(%d+%.?%d*)%s*")
        
        if t_multi and ep_multi then
            title, episode = t_multi, ep_multi
        else
            -- Fallback to standard Ep 01 or Episode 01
            local t, ep = content:match("^(.-)%s*[Ee][Pp]%.?%s*(%d+%.?%d*)")
            if t and ep then
                title, episode = t, ep
            end
        end
    end

    -- Pattern C: Loose Number (e.g., Title 01)
    if not episode then
        local t, ep = content:match("^(.-)%s+(%d+%.?%d*)$")
        if not t then
            -- Try to find a number before tags/quality brackets
            t, ep = content:match("^(.-)%s+(%d+%.?%d*)%s*[%[%(]")
        end
        if t and ep then
            title, episode = t, ep
        end
    end

    -- 4. CLEANUP & SEASON DETECTION
    if not title then title = content end
    
    -- Remove trailing dashes, underscores, or dots often left by pattern splits
    title = title:gsub("[%s%-%_%.]+$", "")
    title = normalize_title(title)

    -- Detect Season from Roman Numerals (e.g., "Overlord II" -> Season 2)
    if not season then
        local r_map = {I=1, II=2, III=3, IV=4, V=5, VI=6, VII=7, VIII=8, IX=9, X=10}
        local roman = title:match("%s([IVXivx]+)$")
        if roman and r_map[roman:upper()] then
            season = r_map[roman:upper()]
            title = title:gsub("%s" .. roman .. "$", "")
        end
    end
    
    -- Detect Season from Short "S" notation (e.g. "Oshi no Ko S3" -> Season 3)
    if not season then
        local s_num = title:match("[%s%p][Ss](%d+)$")
        if s_num then
            season = tonumber(s_num)
            title = title:gsub("[%s%p][Ss]%d+$", "")
        end
    end

    -- NEW: Detect Loose Season Number (e.g., "Mato Seihei no Slave 2")
    -- Only triggers if the title ends in a number and we don't have a season yet
    if not season then
        -- Check if it's "Part X" - if so, keep it in the title
        local is_part = title:match("[Pp]art%s+(%d+)$")
        if not is_part then
            local loose_s = title:match("%s(%d+)$")
            if loose_s then
                -- Safety: Only treat as season if title is longer than just the number
                -- (Prevents "22/7" from losing its "7")
                if #title > #loose_s + 2 then
                    season = tonumber(loose_s)
                    title = title:gsub("%s%d+$", "")
                end
            end
        end
    end

    -- Detect Season from Keywords (e.g., "2nd Season")
    if not season then
        local k_season = title:match("[Ss]eason%s+(%d+)") or title:match("(%d+)[ndrt][dh]%s+[Ss]eason")
        if k_season then
            season = tonumber(k_season)
            title = title:gsub("%s*%(?%d*[ndrt][dh]%s+[Ss]eason%)?", "")
            title = title:gsub("%s*%(?[Ss]eason%s+%d+%)?", "")
        end
    end

    -- Final cleanup
    title = title:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    episode = episode or "1"
    quality = extract_quality(content)

    local result = {
        title = title,
        season = season,
        episode = episode,
        quality = quality or "unknown",
        is_special = is_special(episode, content),
        group = release_group
    }

    debug_log(string.format("PARSE RESULT:\n  Title:   [%s]\n  Season:  %s\n  Episode: %s\n  Group:   %s", 
        result.title, result.season or "N/A", result.episode, result.group))

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
        local selected = results[1] -- Start with best search match
        
        debug_log(string.format("Analyzing %d potential matches for '%s' %sE%s...", 
            #results, 
            parsed.title, 
            parsed.season and string.format("S%d ", parsed.season) or "",
            parsed.episode))

        -- SMART SELECTION & CUMULATIVE EPISODE LOGIC
        local episode_num = tonumber(parsed.episode) or 1
        local season_num = parsed.season  -- Can be nil for continuous numbering
        local found_smart_match = false
        local actual_episode = episode_num
        local actual_season = 1
        local seasons = {}  -- Store season data for Jimaku calculation
        
        -- Check if this is a special episode based on parsed data
        local is_special_ep = parsed.is_special

        -- Priority 1: Match SPECIAL/OVA format if detected as special
        if is_special_ep and not found_smart_match then
            for i, media in ipairs(results) do
                if media.format == "SPECIAL" or media.format == "OVA" or media.format == "ONA" then
                    selected = media
                    found_smart_match = true
                    debug_log(string.format("Special Match: Detected %s format for special episode", media.format))
                    break
                end
            end
        end

        -- Priority 2: Check if parsed season number indicates we should look for a sequel
        if not found_smart_match and season_num and season_num >= 2 then
            -- User has S2/S3 in filename - search for matching season entry
            for i, media in ipairs(results) do
                local full_text = (media.title.romaji or "") .. " " .. (media.title.english or "")
                for _, syn in ipairs(media.synonyms or {}) do
                    full_text = full_text .. " " .. syn
                end
                
                local is_match = false
                if season_num == 3 and (full_text:lower():match("season 3") or full_text:lower():match("3rd season")) then
                    is_match = true
                elseif season_num == 2 and (full_text:lower():match("season 2") or full_text:lower():match("2nd season")) then
                    is_match = true
                end
                
                if is_match then
                    selected = media
                    found_smart_match = true
                    actual_episode = episode_num
                    actual_season = season_num
                    debug_log(string.format("Smart Match: Matched S%d via parsed season number", season_num))
                    break
                end
            end
        end

        -- Priority 3: Fallback - If episode number exceeds first result's episode count OR no explicit season, try cumulative calculation
        if not found_smart_match and (not season_num or episode_num > (selected.episodes or 0)) then
            -- Build chronological season list by finding season markers
            
            -- Find base season (no season marker)
            for i, media in ipairs(results) do
                if media.format == "TV" and media.episodes then
                    local full_text = (media.title.romaji or "") .. " " .. (media.title.english or "")
                    for _, syn in ipairs(media.synonyms or {}) do
                        full_text = full_text .. " " .. syn
                    end
                    
                    if not full_text:lower():match("season") and not full_text:lower():match("%dnd") and not full_text:lower():match("%drd") and not full_text:lower():match("%dth") then
                        seasons[1] = {media = media, eps = media.episodes, name = media.title.romaji}
                        break
                    end
                end
            end
            
            -- Find Season 2
            for i, media in ipairs(results) do
                if media.format == "TV" and media.episodes then
                    local full_text = (media.title.romaji or "") .. " " .. (media.title.english or "")
                    for _, syn in ipairs(media.synonyms or {}) do
                        full_text = full_text .. " " .. syn
                    end
                    if full_text:lower():match("2nd season") or full_text:lower():match("season 2") then
                        seasons[2] = {media = media, eps = media.episodes, name = media.title.romaji}
                        break
                    end
                end
            end
            
            -- Find Season 3
            for i, media in ipairs(results) do
                if media.format == "TV" and media.episodes then
                    local full_text = (media.title.romaji or "") .. " " .. (media.title.english or "")
                    for _, syn in ipairs(media.synonyms or {}) do
                        full_text = full_text .. " " .. syn
                    end
                    if full_text:lower():match("3rd season") or full_text:lower():match("season 3") then
                        seasons[3] = {media = media, eps = media.episodes, name = media.title.romaji}
                        break
                    end
                end
            end
            
            -- Calculate cumulative episodes
            local cumulative = 0
            for season_idx = 1, 3 do
                if seasons[season_idx] then
                    local season_eps = seasons[season_idx].eps
                    debug_log(string.format("  Season %d: %s (%d eps, cumulative: %d-%d)", 
                        season_idx, seasons[season_idx].name, season_eps, cumulative + 1, cumulative + season_eps))
                    
                    if episode_num <= cumulative + season_eps then
                        selected = seasons[season_idx].media
                        actual_episode = episode_num - cumulative
                        actual_season = season_idx
                        found_smart_match = true
                        debug_log(string.format("Cumulative Match: Ep %d -> %s (Season %d, Episode %d)", 
                            episode_num, selected.title.romaji, season_idx, actual_episode))
                        break
                    end
                    cumulative = cumulative + season_eps
                end
            end
        end
        
        -- If no cumulative match but we have a season number from parsing, use it
        if not found_smart_match and season_num then
            actual_season = season_num
        end

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

        mp.osd_message(string.format("AniList Match: %s\nID: %s | S%d E%d\nFormat: %s | Total Eps: %s", 
            selected.title.romaji, 
            selected.id,
            actual_season,
            actual_episode,
            selected.format or "TV",
            selected.episodes or "?"), 5)

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