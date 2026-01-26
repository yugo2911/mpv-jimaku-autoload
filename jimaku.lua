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

-- === NEW: PARSER FEATURE SWITCHES ===
local ENABLE_STRICT_REGEX = true        -- Use strict regex patterns first
local ENABLE_FALLBACK_REGEX = true      -- Fall back to looser patterns if strict fails
local ENABLE_FUZZY_SEARCH = true        -- Use fuzzy/heuristic matching as last resort
local REQUIRE_EXACT_BRACKETS = true     -- Require exact bracket matching in patterns
local MINIMUM_CONFIDENCE = 85           -- Only accept patterns with confidence >= this value

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
        local pattern, pattern_type = pattern_data[1], pattern_data[2]
        
        if pattern_type == "season_episode" then
            local season, episode = filename:match(pattern)
            if season and episode then
                return tonumber(episode), tonumber(season)
            end
        elseif pattern_type == "fractional" then
            local ep = filename:match(pattern)
            if ep then
                return tonumber(ep), nil
            end
        else
            local ep = filename:match(pattern)
            if ep then
                return tonumber(ep), nil
            end
        end
    end
    
    return nil, nil
end

-- === STRICT REGEX PATTERNS (HIGH CONFIDENCE) ===
-- These patterns require exact structure and will only match well-formatted filenames
local STRICT_PATTERNS = {
    -- Anime fansub patterns with exact bracket requirements
    {
        name = "anime_subgroup_absolute_with_sxxexx_paren",
        confidence = 100,
        regex = "^%[([^%]]+)%]%s*([^%[%]%-]+)%s+([0-9][0-9][0-9]%.?%d?)%s*%(%s*[Ss](%d+)[Ee](%d+)%s*%).*$",
        fields = { "group", "title", "absolute", "season", "episode" },
        validator = function(captures)
            return captures[3] and tonumber(captures[3]) >= 100 and tonumber(captures[3]) <= 999
        end
    },
    {
        name = "subgroup_title_year_episode_metadata_hash",
        confidence = 99,
        regex = "^%[([^%]]+)%]%s*([^%[%]%(%)]+)%s*%((%d%d%d%d)%)%s*[%-%–—]%s*(%d%d?)%s*%([^%)]+%)%s*%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "year", "episode", "hash" },
        validator = function(captures)
            local year = tonumber(captures[3])
            return year and year >= 1950 and year <= 2030
        end
    },
    {
        name = "anime_subgroup_sxxexx_absolute",
        confidence = 99,
        regex = "^%[([^%]]+)%]%s*([^%[%]%-]+)%s*[%-–—]%s*[Ss](%d+)[Ee](%d+)%s*%((%d+)%).*$",
        fields = { "group", "title", "season", "episode", "absolute_episode" }
    },
    {
        name = "anime_subgroup_absolute_dash",
        confidence = 98,
        regex = "^%[([^%]]+)%]%s*([^%[%]%-]+)%s*[-_]%s*([0-9][0-9][0-9]%.?%d?).*$",
        fields = { "group", "title", "absolute" },
        validator = function(captures)
            return captures[3] and tonumber(captures[3]) >= 1 and tonumber(captures[3]) <= 999
        end
    },
    {
        name = "anime_subgroup_sxxexx",
        confidence = 96,
        regex = "^%[([^%]]+)%]%s*([^%[%]%-]+)%s*[%-_%. ]+[Ss](%d+)[Ee](%d+).*$",
        fields = { "group", "title", "season", "episode" }
    },
    {
        name = "anime_subgroup_dash_episode",
        confidence = 95,
        regex = "^%[([^%]]+)%]%s*([^%[%]]+)%s+[%-–—]%s+(%d%d?%d?)[%s%._%-]*%[.*$",
        fields = { "group", "title", "episode" },
        validator = function(captures)
            return captures[3] and tonumber(captures[3]) >= 1 and tonumber(captures[3]) <= 999
        end
    },
    -- Standard TV show patterns
    {
        name = "sxxexx_strict",
        confidence = 90,
        regex = "^([^%[%(%-]+)[%s%._%-]+[Ss](%d%d)[Ee](%d%d).*$",
        fields = { "title", "season", "episode" },
        validator = function(captures)
            return captures[1]:match("%w") and #captures[1] >= 3
        end
    },
}

-- === FALLBACK PATTERNS (MEDIUM CONFIDENCE) ===
-- More lenient patterns for when strict patterns fail
local FALLBACK_PATTERNS = {
    {
        name = "sxxexx_title",
        confidence = 85,
        regex = "^(.-%w)[%s%._%-]+[Ss](%d+)[Ee](%d+).*$",
        fields = { "title", "season", "episode" }
    },
    {
        name = "title_dash_episode_bracket",
        confidence = 82,
        regex = "^([^%-%[]+)%s*[%-%–—]%s*(%d+)%s*%[.*$",
        fields = { "title", "episode" }
    },
    {
        name = "trailing_3digit_absolute",
        confidence = 80,
        regex = "^(.+)[%s%._%-]+([0-9][0-9][0-9]%.?%d?)$",
        fields = { "title", "absolute" }
    },
    {
        name = "dash_two_digit_episode",
        confidence = 75,
        regex = "^([^%-]+)%s*[%-%–—]%s*(%d%d)$",
        fields = { "title", "episode" }
    },
}

-- === FUZZY PATTERNS (LOW CONFIDENCE) ===
-- Last resort patterns for poorly formatted files
local FUZZY_PATTERNS = {
    {
        name = "loose_trailing_number",
        confidence = 60,
        regex = "^(.+)%s+(%d+)$",
        fields = { "title", "episode" }
    },
    {
        name = "loose_title_metadata",
        confidence = 50,
        regex = "^([^%[%%(]+).*$",
        fields = { "title" }
    },
}

-- Validate captured values
local function validate_captures(pattern, captures)
    if not pattern.validator then
        return true
    end
    return pattern.validator(captures)
end

-- Clean and normalize title
local function clean_title(title)
    if not title then return nil end
    
    -- Remove extra whitespace
    title = title:gsub("%s+", " ")
    title = title:match("^%s*(.-)%s*$")
    
    -- Remove common suffixes
    title = title:gsub("%s*[%-%._]%s*$", "")
    
    -- Replace dots with spaces in dotted titles
    if title:match("^[%w%.]+$") then
        title = title:gsub("%.", " ")
    end
    
    return title
end

-- Convert Roman numerals to numbers
local function roman_to_number(roman)
    if not roman then return nil end
    
    local roman_map = {
        I = 1, II = 2, III = 3, IV = 4, V = 5,
        VI = 6, VII = 7, VIII = 8, IX = 9, X = 10
    }
    
    return roman_map[roman:upper()]
end

-- Parse filename using strict regex patterns
local function parse_filename_strict(filename)
    if not filename or not ENABLE_STRICT_REGEX then
        return nil
    end
    
    debug_log("=== STRICT REGEX PARSING ===")
    
    for _, pattern in ipairs(STRICT_PATTERNS) do
        if pattern.confidence >= MINIMUM_CONFIDENCE then
            local captures = {filename:match(pattern.regex)}
            
            if #captures > 0 and validate_captures(pattern, captures) then
                local result = {
                    method = "strict_regex",
                    pattern_name = pattern.name,
                    confidence = pattern.confidence
                }
                
                for i, field in ipairs(pattern.fields) do
                    result[field] = captures[i]
                end
                
                -- Clean title
                if result.title then
                    result.title = clean_title(result.title)
                end
                
                -- Convert string numbers to integers
                if result.episode then result.episode = tonumber(result.episode) end
                if result.season then result.season = tonumber(result.season) end
                if result.absolute then result.absolute = tonumber(result.absolute) end
                if result.absolute_episode then result.absolute_episode = tonumber(result.absolute_episode) end
                
                -- Convert Roman numerals if present
                if result.season_roman then
                    result.season = roman_to_number(result.season_roman)
                end
                
                debug_log(string.format("✓ Matched: %s (confidence: %d)", pattern.name, pattern.confidence))
                debug_log(string.format("  Title: %s | S:%s E:%s | Abs:%s", 
                    result.title or "?", 
                    result.season or "?", 
                    result.episode or "?",
                    result.absolute or result.absolute_episode or "?"))
                
                return result
            end
        end
    end
    
    debug_log("✗ No strict pattern matched")
    return nil
end

-- Parse filename using fallback regex patterns
local function parse_filename_fallback(filename)
    if not filename or not ENABLE_FALLBACK_REGEX then
        return nil
    end
    
    debug_log("=== FALLBACK REGEX PARSING ===")
    
    for _, pattern in ipairs(FALLBACK_PATTERNS) do
        local captures = {filename:match(pattern.regex)}
        
        if #captures > 0 and validate_captures(pattern, captures) then
            local result = {
                method = "fallback_regex",
                pattern_name = pattern.name,
                confidence = pattern.confidence
            }
            
            for i, field in ipairs(pattern.fields) do
                result[field] = captures[i]
            end
            
            -- Clean title
            if result.title then
                result.title = clean_title(result.title)
            end
            
            -- Convert string numbers to integers
            if result.episode then result.episode = tonumber(result.episode) end
            if result.season then result.season = tonumber(result.season) end
            if result.absolute then result.absolute = tonumber(result.absolute) end
            
            debug_log(string.format("✓ Matched: %s (confidence: %d)", pattern.name, pattern.confidence))
            debug_log(string.format("  Title: %s | S:%s E:%s | Abs:%s", 
                result.title or "?", 
                result.season or "?", 
                result.episode or "?",
                result.absolute or "?"))
            
            return result
        end
    end
    
    debug_log("✗ No fallback pattern matched")
    return nil
end

-- Parse filename using fuzzy/heuristic matching
local function parse_filename_fuzzy(filename)
    if not filename or not ENABLE_FUZZY_SEARCH then
        return nil
    end
    
    debug_log("=== FUZZY PARSING ===")
    
    for _, pattern in ipairs(FUZZY_PATTERNS) do
        local captures = {filename:match(pattern.regex)}
        
        if #captures > 0 then
            local result = {
                method = "fuzzy",
                pattern_name = pattern.name,
                confidence = pattern.confidence
            }
            
            for i, field in ipairs(pattern.fields) do
                result[field] = captures[i]
            end
            
            -- Clean title
            if result.title then
                result.title = clean_title(result.title)
            end
            
            -- Convert string numbers to integers
            if result.episode then result.episode = tonumber(result.episode) end
            
            debug_log(string.format("⚠ Fuzzy match: %s (confidence: %d)", pattern.name, pattern.confidence))
            debug_log(string.format("  Title: %s | E:%s", 
                result.title or "?", 
                result.episode or "?"))
            
            return result
        end
    end
    
    debug_log("✗ No fuzzy pattern matched")
    return nil
end

-- Main parsing function with cascading fallback
local function parse_filename(filename)
    if not filename then
        debug_log("✗ No filename provided", true)
        return nil
    end
    
    -- Remove file extension
    local base_name = filename:match("^(.+)%.[^%.]+$") or filename
    
    -- Normalize
    base_name = normalize_digits(base_name)
    
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    debug_log("Parsing: " .. base_name)
    debug_log("Settings: Strict=" .. tostring(ENABLE_STRICT_REGEX) .. 
              " | Fallback=" .. tostring(ENABLE_FALLBACK_REGEX) .. 
              " | Fuzzy=" .. tostring(ENABLE_FUZZY_SEARCH))
    
    -- Try strict patterns first
    local result = parse_filename_strict(base_name)
    if result then
        return result
    end
    
    -- Try fallback patterns
    result = parse_filename_fallback(base_name)
    if result then
        return result
    end
    
    -- Try fuzzy patterns as last resort
    result = parse_filename_fuzzy(base_name)
    if result then
        return result
    end
    
    -- Total failure
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    debug_log("✗ PARSING FAILED - No patterns matched", true)
    return nil
end

-- Check if parsed result is a special episode
local function is_special_episode(parsed)
    if not parsed then return false end
    
    -- Check for special indicators
    local special_keywords = {
        "ova", "oad", "ona", "special", "sp", "nc", "nced", "ncop",
        "recap", "preview", "pilot", "bonus", "extra"
    }
    
    local filename_lower = (parsed.raw_filename or ""):lower()
    
    for _, keyword in ipairs(special_keywords) do
        if filename_lower:match(keyword) then
            return true
        end
    end
    
    return false
end

-- HTTP request helper
local function http_request(url, method, headers, body)
    if STANDALONE_MODE then
        local curl_cmd = string.format('curl -s -X %s', method or "GET")
        
        if headers then
            for k, v in pairs(headers) do
                curl_cmd = curl_cmd .. string.format(' -H "%s: %s"', k, v)
            end
        end
        
        if body then
            local escaped_body = body:gsub('"', '\\"'):gsub('\n', '\\n')
            curl_cmd = curl_cmd .. string.format(' -d "%s"', escaped_body)
        end
        
        curl_cmd = curl_cmd .. string.format(' "%s"', url)
        
        local handle = io.popen(curl_cmd)
        local result = handle:read("*a")
        handle:close()
        
        return result
    else
        local args = {"curl", "-s", "-X", method or "GET"}
        
        if headers then
            for k, v in pairs(headers) do
                table.insert(args, "-H")
                table.insert(args, k .. ": " .. v)
            end
        end
        
        if body then
            table.insert(args, "-d")
            table.insert(args, body)
        end
        
        table.insert(args, url)
        
        local result = mp.command_native({
            name = "subprocess",
            playback_only = false,
            capture_stdout = true,
            args = args
        })
        
        return result.stdout
    end
end

-- JSON decode helper
local function json_decode(str)
    if not str or str == "" then return nil end
    
    -- Simple JSON parser for basic cases
    local function parse_value(s, pos)
        local c = s:sub(pos, pos)
        
        if c == '"' then
            local end_pos = s:find('"', pos + 1, true)
            return s:sub(pos + 1, end_pos - 1), end_pos + 1
        elseif c == '{' then
            local obj = {}
            pos = pos + 1
            while true do
                -- Skip whitespace
                while s:sub(pos, pos):match("%s") do pos = pos + 1 end
                if s:sub(pos, pos) == '}' then break end
                
                -- Parse key
                local key, next_pos = parse_value(s, pos)
                pos = next_pos
                
                -- Skip : and whitespace
                while s:sub(pos, pos):match("[%s:]") do pos = pos + 1 end
                
                -- Parse value
                local value, next_pos = parse_value(s, pos)
                if key then
                    obj[key] = value
                end
                pos = next_pos
                
                -- Skip , and whitespace
                while s:sub(pos, pos):match("[%s,]") do pos = pos + 1 end
            end
            return obj, pos + 1
        elseif c == '[' then
            local arr = {}
            pos = pos + 1
            while true do
                while s:sub(pos, pos):match("%s") do pos = pos + 1 end
                if s:sub(pos, pos) == ']' then break end
                
                local value, next_pos = parse_value(s, pos)
                table.insert(arr, value)
                pos = next_pos
                
                while s:sub(pos, pos):match("[%s,]") do pos = pos + 1 end
            end
            return arr, pos + 1
        elseif c:match("%d") or c == '-' then
            local num_str = s:match("^-?%d+%.?%d*", pos)
            return tonumber(num_str), pos + #num_str
        elseif s:sub(pos, pos + 3) == "true" then
            return true, pos + 4
        elseif s:sub(pos, pos + 4) == "false" then
            return false, pos + 5
        elseif s:sub(pos, pos + 3) == "null" then
            return nil, pos + 4
        end
        
        return nil, pos
    end
    
    local result, _ = parse_value(str, 1)
    return result
end

-- Make AniList API request
local function make_anilist_request(query, variables)
    local body = {
        query = query,
        variables = variables or {}
    }
    
    -- Convert to JSON string
    local json_body = string.format('{"query":%q,"variables":%s}', 
        query, 
        "{}")  -- Simplified for now
    
    local response = http_request(
        ANILIST_API_URL,
        "POST",
        {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json"
        },
        json_body
    )
    
    if response then
        return json_decode(response)
    end
    
    return nil
end

-- Search for anime on AniList
local function search_anilist_anime(title)
    local query = [[
    query ($search: String) {
      Page {
        media(search: $search, type: ANIME) {
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
    
    return make_anilist_request(query, {search = title})
end

-- Search Jimaku for subtitles
local function search_jimaku_subtitles(anilist_id)
    if not JIMAKU_API_KEY or JIMAKU_API_KEY == "" then
        debug_log("No Jimaku API key configured", true)
        return nil
    end
    
    local url = string.format("%s/entries/search?anilist_id=%s", JIMAKU_API_URL, anilist_id)
    
    local response = http_request(
        url,
        "GET",
        {
            ["Authorization"] = "Bearer " .. JIMAKU_API_KEY,
            ["Accept"] = "application/json"
        }
    )
    
    if response then
        local data = json_decode(response)
        if data and data.entries and #data.entries > 0 then
            return data.entries[1]
        end
    end
    
    return nil
end

-- Download subtitle files
local function download_subtitle_smart(jimaku_entry_id, episode_num, season_num, seasons_data, anime_title)
    debug_log(string.format("Searching Jimaku for subtitles: S%d E%d", season_num or 1, episode_num))
    
    -- Calculate Jimaku episode number (cumulative)
    local jimaku_episode = calculate_jimaku_episode(season_num, episode_num, seasons_data)
    
    debug_log(string.format("Looking for Jimaku episode: %d (from S%d E%d)", 
        jimaku_episode, season_num or 1, episode_num))
    
    -- Fetch available subtitles
    local url = string.format("%s/entries/%s/files", JIMAKU_API_URL, jimaku_entry_id)
    local response = http_request(
        url,
        "GET",
        {
            ["Authorization"] = "Bearer " .. JIMAKU_API_KEY,
            ["Accept"] = "application/json"
        }
    )
    
    if not response then
        debug_log("Failed to fetch subtitle files from Jimaku", true)
        return
    end
    
    local data = json_decode(response)
    if not data or not data.files then
        debug_log("No subtitle files found", true)
        return
    end
    
    debug_log(string.format("Found %d subtitle files", #data.files))
    
    -- Find matching subtitles
    local matches = {}
    for _, file in ipairs(data.files) do
        local file_ep, file_season = parse_jimaku_filename(file.name)
        
        if file_ep then
            -- Check if this matches our episode
            if file_ep == jimaku_episode then
                table.insert(matches, file)
                debug_log(string.format("  ✓ Match: %s (ep %d)", file.name, file_ep))
            end
        end
    end
    
    if #matches == 0 then
        debug_log("No matching subtitles found for this episode", true)
        mp.osd_message("No subtitles found for this episode", 3)
        return
    end
    
    -- Download and load subtitles
    local loaded_count = 0
    local max_to_load = (JIMAKU_MAX_SUBS == "all") and #matches or math.min(JIMAKU_MAX_SUBS, #matches)
    
    for i = 1, max_to_load do
        local file = matches[i]
        local download_url = string.format("%s/files/%s", JIMAKU_API_URL, file.id)
        
        local subtitle_data = http_request(
            download_url,
            "GET",
            {
                ["Authorization"] = "Bearer " .. JIMAKU_API_KEY
            }
        )
        
        if subtitle_data then
            local safe_title = anime_title:gsub("[^%w%s%-]", "_")
            local output_path = string.format("%s/%s_S%02dE%02d_%d.ass",
                SUBTITLE_CACHE_DIR,
                safe_title,
                season_num or 1,
                episode_num,
                i
            )
            
            local f = io.open(output_path, "w")
            if f then
                f:write(subtitle_data)
                f:close()
                
                if not STANDALONE_MODE then
                    mp.commandv("sub-add", output_path)
                end
                
                loaded_count = loaded_count + 1
                debug_log(string.format("✓ Loaded: %s", file.name))
            end
        end
    end
    
    if loaded_count > 0 then
        mp.osd_message(string.format("Loaded %d subtitle(s)", loaded_count), 3)
        debug_log(string.format("Successfully loaded %d subtitle(s)", loaded_count))
    end
end

-- Main search function
local function search_anilist()
    local filename
    
    if STANDALONE_MODE then
        -- Read from test file
        local f = io.open(TEST_FILE, "r")
        if not f then
            debug_log("Test file not found: " .. TEST_FILE, true)
            return
        end
        filename = f:read("*l")
        f:close()
    else
        filename = mp.get_property("filename")
    end
    
    if not filename then
        debug_log("No filename available", true)
        return
    end
    
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    debug_log("Starting AniList search for: " .. filename)
    
    -- Parse filename
    local parsed = parse_filename(filename)
    
    if not parsed or not parsed.title then
        debug_log("Failed to parse filename", true)
        if not STANDALONE_MODE then
            mp.osd_message("Failed to parse filename", 3)
        end
        return
    end
    
    -- Store parsed info
    parsed.raw_filename = filename
    parsed.is_special = is_special_episode(parsed)
    
    debug_log(string.format("Parsed: %s | S:%s E:%s (method: %s, confidence: %d)", 
        parsed.title,
        parsed.season or "?",
        parsed.episode or parsed.absolute or "?",
        parsed.method,
        parsed.confidence or 0))
    
    -- Search AniList
    local data = search_anilist_anime(parsed.title)
    
    if data and data.Page and data.Page.media then
        local results = data.Page.media
        local selected = results[1]
        
        debug_log(string.format("Found %d potential matches", #results))
        
        for i, media in ipairs(results) do
            local marker = (i == 1) and ">>" or "  "
            debug_log(string.format("%s [%d] %s (ID: %s, Format: %s, Episodes: %s)",
                marker,
                i,
                media.title.romaji or media.title.english or "?",
                media.id,
                media.format or "?",
                media.episodes or "?"))
        end
        
        if not STANDALONE_MODE then
            mp.osd_message(string.format("Match: %s\nID: %s | Format: %s",
                selected.title.romaji or selected.title.english,
                selected.id,
                selected.format or "?"), 5)
        end
        
        -- Try to fetch subtitles
        local jimaku_entry = search_jimaku_subtitles(selected.id)
        if jimaku_entry then
            download_subtitle_smart(
                jimaku_entry.id,
                parsed.episode or parsed.absolute or 1,
                parsed.season or 1,
                nil,
                selected.title.romaji or selected.title.english
            )
        end
    else
        debug_log("No matches found on AniList", true)
        if not STANDALONE_MODE then
            mp.osd_message("No AniList match found", 3)
        end
    end
    
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
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
            mp.add_timeout(0.5, search_anilist)
        end)
        debug_log("AniList Script Initialized with auto-download enabled. Press 'A' to manually search.")
    else
        debug_log("AniList Script Initialized. Press 'A' to search current file.")
    end
else
    -- Standalone mode - run parser test
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    debug_log("JIMAKU PARSER - STANDALONE TEST MODE")
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    search_anilist()
end