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
            debug_log(string.format("Warning: Season %d data unavailable, assuming 13 episodes", season_idx))
        end
    end
    
    return cumulative + episode_num
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

-- Parse a filename with multiple pattern attempts
local function parse_filename(filename)
    local original_raw = filename
    filename = maybe_reverse(filename)
    
    local title, episode, season, quality
    local release_group = "unknown"
    local raw_content
    
    -- 1. Strip file extension
    filename = filename:gsub("%.%w%w%w?$", "")
    
    -- 2. Extract Release Group (Bracket start)
    local group_match, content_match = filename:match("^%[([^%]]+)%]%s*(.+)$")
    if not group_match then
        content_match = filename
    else
        release_group = group_match
    end
    raw_content = content_match

    -- PATTERN MATCHING LOGIC (Case insensitive checks where possible)
    
    -- S##E## or S##e## (Standard)
    if not title then
        title, season, episode = raw_content:match("^(.-)[%s%.%_][Ss](%d+)[Ee](%d+)")
    end
    
    -- S# - Episode (SubsPlease/Inka Style) - MOVED BEFORE Season Pack to take priority
    if not title then
        title, season, episode = raw_content:match("^(.-)[%s%.%_][Ss](%d+)[%s%.%_]+%-[%s%.%_]+(%d+)")
    end
    
    -- Season Pack (No Episode) - e.g. Title.S01.1080p - ONLY if no dash follows
    if not title then
        local temp_title, temp_season = raw_content:match("^(.-)[%s%.%_][Ss](%d+)[%s%.%_]")
        -- Make sure it's not "S2 - 02" pattern (which has dash)
        if temp_title and temp_season and not raw_content:match("^.-[%s%.%_][Ss]%d+[%s%.%_]*%-") then
            title = temp_title
            season = temp_season
            episode = "PACK"
        end
    end

    -- Explicit "Episode ##"
    if not title then
        title, episode = raw_content:match("^(.-)[%s%.%_]Episode[%s%.%_]+(%d+)")
    end

    -- Title - Episode (Standard HyZen/Saizen with underscores)
    if not title then
        title, episode = raw_content:match("^(.-)%s*%-%s*(%d+)")
        -- Mark as continuous numbering (no explicit season in filename)
        if title and episode then
            season = nil  -- Don't assume S1 for continuous numbering
        end
    end

    -- Underscore fallback: Title_-_Episode_
    if not title then
        title, episode = raw_content:match("^(.-)%_?%-%_?(%d+)")
        if title and episode then
            season = nil  -- Don't assume S1 for continuous numbering
        end
    end

    -- Movie style with Year (Title 2014)
    if not title then
        local year
        title, year = raw_content:match("^(.-)[%s%.%_]+(%d%d%d%d)")
        if title and tonumber(year) > 1950 and tonumber(year) < 2030 then
            episode = "1"
        else
            title = nil -- Reset if year is invalid
        end
    end

    -- Failsafe: Group + Title (Last word before quality/hash)
    if not title then
        title, episode = raw_content:match("^(.-)[%s%.%_]+(%d+)[%s%.%_]*%[")
    end
    
    -- Final fallback: Just take the title before any bracket or parenthesis
    if not title then
        title = raw_content:match("^(.-)%s*%[") or raw_content:match("^(.-)%s*%(")
        episode = "1"
    end
    
    -- If we still have nothing, the line is truly unparseable by current logic
    if not title or title == "" then
        debug_log("FAILED TO PARSE: " .. original_raw, true)
        return nil
    end
    
    -- Normalization
    title = normalize_title(title)
    episode = clean_episode(episode)
    quality = extract_quality(raw_content)
    
    -- Post-process: Extract season from title if not found in pattern
    if not season then
        -- Check for "Season 2", "2nd Season", "3rd Season" etc. in title
        season = title:match("(%d+)nd%s+[Ss]eason") or 
                 title:match("(%d+)rd%s+[Ss]eason") or
                 title:match("(%d+)th%s+[Ss]eason") or
                 title:match("[Ss]eason%s+(%d+)")
        
        -- If found, remove it from title
        if season then
            title = title:gsub("%d+nd%s+[Ss]eason", "")
            title = title:gsub("%d+rd%s+[Ss]eason", "")
            title = title:gsub("%d+th%s+[Ss]eason", "")
            title = title:gsub("[Ss]eason%s+%d+", "")
            title = title:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        else
            -- Check for title ending in space + single digit (e.g. "Anime Title 2")
            local temp_season = title:match("%s+(%d)$")
            if temp_season and tonumber(temp_season) >= 2 and tonumber(temp_season) <= 9 then
                season = temp_season
                title = title:gsub("%s+%d$", "")
            else
                -- Last resort: check for S1, S2 pattern in title
                season = title:match("[%s%.%_][Ss](%d+)")
            end
        end
    end
    
    -- Clean up subtitle artifacts for better AniList matching
    -- First, remove parenthetical content (often Japanese duplicates or extra info)
    title = title:gsub("%s*%([^%)]+%)", "")
    title = title:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    
    -- Remove arc/part names that come after main title (common pattern: "Title - Subtitle - Part")
    if title:match("^(.-)%s+%-%s+") then
        local base_title = title:match("^(.-)%s+%-%s+")
        -- Check if what follows looks like an arc name (Japanese text, Part, Zenpen, etc.)
        local subtitle = title:match("^.-%s+%-%s+(.+)$")
        if subtitle and (subtitle:match("[一-龯ぁ-ゔァ-ヴ]") or -- Japanese characters
                        subtitle:lower():match("part") or 
                        subtitle:lower():match("hen$") or  -- Common arc suffix
                        subtitle:lower():match("zenpen") or
                        subtitle:lower():match("kouhen") or
                        subtitle:lower():match("special")) then
            title = base_title
            title = title:gsub("%s+$", "")
        end
    end

    local result = {
        title = title,
        season = tonumber(season),  -- Can be nil for continuous numbering
        episode = episode or "1",
        quality = quality or "unknown",
        is_special = is_special(episode, raw_content),
        group = release_group
    }

    debug_log(string.format("Parsed: [%s] %s E%s | %s", 
        result.title, 
        result.season and string.format("S%02d", result.season) or "Continuous",
        result.episode or "?", 
        original_raw))

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
local function search_jimaku_subtitles(anilist_id, episode_num)
    if not JIMAKU_API_KEY or JIMAKU_API_KEY == "" then
        debug_log("Jimaku API key not configured - skipping subtitle search", false)
        return nil
    end
    
    debug_log(string.format("Searching Jimaku for AniList ID: %d, Episode: %d", anilist_id, episode_num))
    
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

-- Download subtitle file from Jimaku
local function download_subtitle(entry_id, episode_num, anime_title)
    local files_url = string.format("%s/entries/%d/files?episode=%d",
        JIMAKU_API_URL, entry_id, episode_num)
    
    debug_log("Fetching subtitle files from: " .. files_url)
    
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
        debug_log("Failed to get subtitle files", true)
        return false
    end
    
    local ok, files = pcall(utils.parse_json, result.stdout)
    if not ok or not files or #files == 0 then
        debug_log("No subtitle files found for episode " .. episode_num, false)
        return false
    end
    
    debug_log(string.format("Found %d subtitle file(s) for episode %d:", #files, episode_num))
    
    -- Log all available subtitle files
    for i, file in ipairs(files) do
        local size_kb = math.floor(file.size / 1024)
        debug_log(string.format("  [%d] %s (%d KB)", i, file.name, size_kb))
    end
    
    -- Determine how many subtitles to download
    local max_downloads = #files
    if JIMAKU_MAX_SUBS ~= "all" and type(JIMAKU_MAX_SUBS) == "number" then
        max_downloads = math.min(JIMAKU_MAX_SUBS, #files)
    end
    
    debug_log(string.format("Downloading %d of %d available subtitle(s)...", max_downloads, #files))
    
    local success_count = 0
    
    -- Download and load subtitles
    for i = 1, max_downloads do
        local subtitle_file = files[i]
        local subtitle_path = SUBTITLE_CACHE_DIR .. "/" .. subtitle_file.name
        
        debug_log(string.format("Downloading [%d/%d]: %s (%d bytes)", i, max_downloads, subtitle_file.name, subtitle_file.size))
        
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
            debug_log(string.format("Successfully loaded subtitle [%d/%d]: %s", i, max_downloads, subtitle_file.name))
            success_count = success_count + 1
        else
            debug_log(string.format("Failed to download subtitle [%d/%d]: %s", i, max_downloads, subtitle_file.name), true)
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

        -- Calculate Jimaku episode number (handles cumulative numbering)
        local jimaku_episode = actual_episode
        
        -- Build season data for cumulative calculation
        if actual_season > 1 then
            local season_data = {}
            for season_idx = 1, 3 do
                if seasons and seasons[season_idx] then
                    season_data[season_idx] = {eps = seasons[season_idx].eps}
                end
            end
            
            -- If we don't have complete season data, try to infer from results
            if not season_data[1] and actual_season == 2 then
                -- Look for Season 1 in results to get episode count
                for _, media in ipairs(results) do
                    local full_text = (media.title.romaji or "") .. " " .. (media.title.english or "")
                    for _, syn in ipairs(media.synonyms or {}) do
                        full_text = full_text .. " " .. syn
                    end
                    
                    if not full_text:lower():match("season") and not full_text:lower():match("%dnd") and 
                       not full_text:lower():match("%drd") and not full_text:lower():match("%dth") and 
                       media.format == "TV" and media.episodes then
                        season_data[1] = {eps = media.episodes}
                        break
                    end
                end
            end
            
            jimaku_episode = calculate_jimaku_episode(actual_season, actual_episode, season_data)
            debug_log(string.format("Jimaku Episode Conversion: S%d E%d -> Cumulative Episode %d", 
                actual_season, actual_episode, jimaku_episode))
        end

        -- Try to fetch subtitles from Jimaku
        local jimaku_entry = search_jimaku_subtitles(selected.id, jimaku_episode)
        if jimaku_entry then
            download_subtitle(jimaku_entry.id, jimaku_episode, selected.title.romaji)
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