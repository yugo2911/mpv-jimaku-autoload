-- ============================================================================
-- JIMAKU MPV SCRIPT - Automatic Subtitle Downloader
-- ============================================================================
-- Automatically fetches Japanese subtitles from jimaku.cc for anime
-- Uses AniList API to identify shows and Jimaku API to fetch subtitles
-- ============================================================================

-- Detect if running standalone (command line) or in mpv
local STANDALONE_MODE = not pcall(function() return mp.get_property("filename") end)

local utils
if not STANDALONE_MODE then
    utils = require 'mp.utils'
end

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

local CONFIG_DIR
local LOG_FILE
local SUBTITLE_CACHE_DIR
local JIMAKU_API_KEY_FILE
local ANILIST_API_URL = "https://graphql.anilist.co"
local JIMAKU_API_URL = "https://jimaku.cc/api"

if STANDALONE_MODE then
    CONFIG_DIR = "."
    LOG_FILE = "./jimaku-debug.log"
    SUBTITLE_CACHE_DIR = "./subtitle-cache"
    JIMAKU_API_KEY_FILE = "./jimaku-api-key.txt"
else
    CONFIG_DIR = mp.command_native({"expand-path", "~~/"})
    LOG_FILE = CONFIG_DIR .. "/jimaku-debug.log"
    SUBTITLE_CACHE_DIR = CONFIG_DIR .. "/subtitle-cache"
    JIMAKU_API_KEY_FILE = CONFIG_DIR .. "/jimaku-api-key.txt"
end

-- === PARSER CONFIGURATION ===
local ENABLE_STRICT_REGEX = true        -- Use strict patterns first
local ENABLE_FALLBACK_REGEX = true      -- Try looser patterns if strict fails
local ENABLE_FUZZY_SEARCH = true        -- Try fuzzy matching as last resort
local MINIMUM_CONFIDENCE = 85           -- Only accept patterns with confidence >= this

-- === JIMAKU CONFIGURATION ===
local JIMAKU_MAX_SUBS = 5               -- Max subtitles to download (or "all")
local JIMAKU_AUTO_DOWNLOAD = true       -- Auto-download on file load
local JIMAKU_API_KEY = ""               -- Will be loaded from file

-- === LOGGING CONFIGURATION ===
local LOG_ONLY_ERRORS = false           -- Set to true to only log errors
local VERBOSE_MODE = true               -- Extra debug output

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

-- Unified logging function
local function debug_log(message, is_error)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local prefix = is_error and "[ERROR] " or "[INFO] "
    local log_msg = string.format("%s %s%s\n", timestamp, prefix, message)
    
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(log_msg)
        f:close()
    end
    
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
            JIMAKU_API_KEY = key:match("^%s*(.-)%s*$")
            debug_log("Jimaku API key loaded")
            return true
        end
    end
    debug_log("Jimaku API key not found. Create " .. JIMAKU_API_KEY_FILE, true)
    return false
end

-- Create subtitle cache directory
local function ensure_subtitle_cache()
    if STANDALONE_MODE then
        os.execute("mkdir -p " .. SUBTITLE_CACHE_DIR)
    else
        local is_windows = package.config:sub(1,1) == '\\'
        local args = is_windows 
            and {"cmd", "/C", "mkdir", SUBTITLE_CACHE_DIR} 
            or {"mkdir", "-p", SUBTITLE_CACHE_DIR}
        
        mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = args
        })
    end
end

-- ============================================================================
-- JSON ENCODING/DECODING
-- ============================================================================

-- JSON encoder
local function json_encode(obj)
    local function encode_string(s)
        s = s:gsub('\\', '\\\\')
             :gsub('"', '\\"')
             :gsub('\n', '\\n')
             :gsub('\r', '\\r')
             :gsub('\t', '\\t')
        return '"' .. s .. '"'
    end
    
    local function encode_table(tbl)
        -- Check if array
        local is_array = true
        local max_index = 0
        
        for k, v in pairs(tbl) do
            if type(k) ~= "number" then
                is_array = false
                break
            end
            max_index = math.max(max_index, k)
        end
        
        if is_array and max_index > 0 then
            local parts = {}
            for i = 1, max_index do
                table.insert(parts, json_encode(tbl[i]))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(tbl) do
                local key = type(k) == "string" and encode_string(k) or tostring(k)
                table.insert(parts, key .. ":" .. json_encode(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    
    local obj_type = type(obj)
    if obj_type == "string" then return encode_string(obj)
    elseif obj_type == "number" then return tostring(obj)
    elseif obj_type == "boolean" then return obj and "true" or "false"
    elseif obj_type == "table" then return encode_table(obj)
    else return "null" end
end

-- JSON decoder
local function json_decode(str)
    if not str or str == "" then return nil end
    
    local pos = 1
    
    local function skip_whitespace()
        while pos <= #str and str:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
    end
    
    local parse_value  -- Forward declaration
    
    local function parse_string()
        pos = pos + 1
        local start = pos
        local result = ""
        
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then
                result = result .. str:sub(start, pos - 1)
                pos = pos + 1
                return result:gsub('\\(.)', function(x)
                    if x == 'n' then return '\n'
                    elseif x == 'r' then return '\r'
                    elseif x == 't' then return '\t'
                    else return x end
                end)
            elseif c == '\\' then
                result = result .. str:sub(start, pos - 1)
                pos = pos + 2
                start = pos
            else
                pos = pos + 1
            end
        end
        return nil
    end
    
    local function parse_number()
        local start = pos
        if str:sub(pos, pos) == '-' then pos = pos + 1 end
        while pos <= #str and str:sub(pos, pos):match("%d") do pos = pos + 1 end
        if pos <= #str and str:sub(pos, pos) == '.' then
            pos = pos + 1
            while pos <= #str and str:sub(pos, pos):match("%d") do pos = pos + 1 end
        end
        return tonumber(str:sub(start, pos - 1))
    end
    
    local function parse_array()
        local arr = {}
        pos = pos + 1
        skip_whitespace()
        
        if str:sub(pos, pos) == ']' then
            pos = pos + 1
            return arr
        end
        
        while true do
            table.insert(arr, parse_value())
            skip_whitespace()
            
            local c = str:sub(pos, pos)
            if c == ']' then pos = pos + 1; return arr
            elseif c == ',' then pos = pos + 1; skip_whitespace()
            else return nil end
        end
    end
    
    local function parse_object()
        local obj = {}
        pos = pos + 1
        skip_whitespace()
        
        if str:sub(pos, pos) == '}' then
            pos = pos + 1
            return obj
        end
        
        while true do
            skip_whitespace()
            if str:sub(pos, pos) ~= '"' then return nil end
            local key = parse_string()
            
            skip_whitespace()
            if str:sub(pos, pos) ~= ':' then return nil end
            pos = pos + 1
            skip_whitespace()
            
            obj[key] = parse_value()
            
            skip_whitespace()
            local c = str:sub(pos, pos)
            if c == '}' then pos = pos + 1; return obj
            elseif c == ',' then pos = pos + 1
            else return nil end
        end
    end
    
    parse_value = function()
        skip_whitespace()
        local c = str:sub(pos, pos)
        
        if c == '"' then return parse_string()
        elseif c == '{' then return parse_object()
        elseif c == '[' then return parse_array()
        elseif c == 't' and str:sub(pos, pos + 3) == 'true' then
            pos = pos + 4; return true
        elseif c == 'f' and str:sub(pos, pos + 4) == 'false' then
            pos = pos + 5; return false
        elseif c == 'n' and str:sub(pos, pos + 3) == 'null' then
            pos = pos + 4; return nil
        elseif c:match("[%d%-]") then return parse_number()
        end
        return nil
    end
    
    return parse_value()
end

-- ============================================================================
-- HTTP REQUEST HANDLER
-- ============================================================================

local function http_request(url, method, headers, body)
    if STANDALONE_MODE then
        local curl_cmd = string.format('curl -s -X %s', method or "GET")
        
        if headers then
            for k, v in pairs(headers) do
                curl_cmd = curl_cmd .. string.format(' -H "%s: %s"', k, v)
            end
        end
        
        if body then
            local escaped = body:gsub('"', '\\"'):gsub('\n', '\\n')
            curl_cmd = curl_cmd .. string.format(' -d "%s"', escaped)
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

-- ============================================================================
-- FILENAME PARSER
-- ============================================================================

-- Normalize full-width digits
local function normalize_digits(s)
    if not s then return s end
    return s:gsub("０", "0"):gsub("１", "1"):gsub("２", "2"):gsub("３", "3")
            :gsub("４", "4"):gsub("５", "5"):gsub("６", "6"):gsub("７", "7")
            :gsub("８", "8"):gsub("９", "9")
end

-- Clean title
local function clean_title(title)
    if not title then return nil end
    
    title = title:gsub("%s+", " "):match("^%s*(.-)%s*$")
    title = title:gsub("%s*[%-%._]%s*$", "")
    
    -- Convert dotted titles: "Title.Name" → "Title Name"
    if title:match("^[%w%.]+$") then
        title = title:gsub("%.", " ")
    end
    
    return title
end

-- Convert Roman numerals
local function roman_to_number(roman)
    if not roman then return nil end
    local map = {I=1, II=2, III=3, IV=4, V=5, VI=6, VII=7, VIII=8, IX=9, X=10}
    return map[roman:upper()]
end

-- === STRICT PATTERNS (90-100 confidence) ===
local STRICT_PATTERNS = {
    {
        name = "anime_subgroup_dash_episode_paren",
        confidence = 95,
        regex = "^%[([^%]]+)%]%s+(.+)%s*[%-–—]%s*(%d%d?%d?)%s+%(",
        fields = { "group", "title", "episode" }
    },
    {
        name = "anime_subgroup_dash_episode_bracket",
        confidence = 94,
        regex = "^%[([^%]]+)%]%s+(.+)%s*[%-–—]%s*(%d%d?%d?)%s+%[",
        fields = { "group", "title", "episode" }
    },
    {
        name = "anime_subgroup_sxxexx",
        confidence = 93,
        regex = "^%[([^%]]+)%]%s+([^%[%]%-]+)%s*[%-_%. ]+[Ss](%d+)[Ee](%d+)",
        fields = { "group", "title", "season", "episode" }
    },
    {
        name = "sxxexx_standard",
        confidence = 90,
        regex = "^([^%[%(]+)%s*[%-_%. ]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
}

-- === FALLBACK PATTERNS (80-89 confidence) ===
local FALLBACK_PATTERNS = {
    {
        name = "title_dash_episode",
        confidence = 85,
        regex = "^(.+)%s*[%-–—]%s*(%d%d?%d?)%s*[%[%(]",
        fields = { "title", "episode" }
    },
    {
        name = "sxxexx_loose",
        confidence = 82,
        regex = "^(.-)%s+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
}

-- === FUZZY PATTERNS (60-79 confidence) ===
local FUZZY_PATTERNS = {
    {
        name = "trailing_number",
        confidence = 70,
        regex = "^(.+)%s+(%d+)$",
        fields = { "title", "episode" }
    },
}

-- Parse with pattern list
local function try_patterns(filename, patterns, tier_name)
    if VERBOSE_MODE then
        debug_log(string.format("=== %s ===", tier_name))
    end
    
    for _, pattern in ipairs(patterns) do
        if pattern.confidence >= MINIMUM_CONFIDENCE then
            local captures = {filename:match(pattern.regex)}
            
            if #captures > 0 then
                local result = {
                    method = tier_name:lower():gsub(" ", "_"),
                    pattern_name = pattern.name,
                    confidence = pattern.confidence
                }
                
                for i, field in ipairs(pattern.fields) do
                    result[field] = captures[i]
                end
                
                if result.title then
                    result.title = clean_title(result.title)
                end
                
                result.episode = tonumber(result.episode)
                result.season = tonumber(result.season)
                
                if result.season_roman then
                    result.season = roman_to_number(result.season_roman)
                end
                
                if VERBOSE_MODE then
                    debug_log(string.format("✓ %s (conf:%d) → %s | S:%s E:%s",
                        pattern.name, pattern.confidence,
                        result.title or "?",
                        result.season or "?",
                        result.episode or "?"))
                end
                
                return result
            end
        end
    end
    
    if VERBOSE_MODE then
        debug_log("✗ No match in " .. tier_name)
    end
    return nil
end

-- Main parser
local function parse_filename(filename)
    if not filename then return nil end
    
    local base_name = filename:match("^(.+)%.[^%.]+$") or filename
    base_name = normalize_digits(base_name)
    
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    debug_log("Parsing: " .. base_name)
    
    local result
    
    if ENABLE_STRICT_REGEX then
        result = try_patterns(base_name, STRICT_PATTERNS, "STRICT PATTERNS")
        if result then return result end
    end
    
    if ENABLE_FALLBACK_REGEX then
        result = try_patterns(base_name, FALLBACK_PATTERNS, "FALLBACK PATTERNS")
        if result then return result end
    end
    
    if ENABLE_FUZZY_SEARCH then
        result = try_patterns(base_name, FUZZY_PATTERNS, "FUZZY PATTERNS")
        if result then return result end
    end
    
    debug_log("✗ PARSING FAILED", true)
    return nil
end

-- ============================================================================
-- ANILIST API
-- ============================================================================

local function search_anilist(title)
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
                    episodes
                    format
                    status
                }
            }
        }
    ]]
    
    local json_body = json_encode({
        query = query,
        variables = { search = title }
    })
    
    debug_log("Searching AniList for: " .. title)
    
    local response = http_request(
        ANILIST_API_URL,
        "POST",
        {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json"
        },
        json_body
    )
    
    if not response or response == "" then
        debug_log("No response from AniList", true)
        return nil
    end
    
    local data = json_decode(response)
    
    if not data then
        debug_log("Failed to parse AniList response", true)
        return nil
    end
    
    if data.errors then
        debug_log("AniList error: " .. (data.errors[1].message or "unknown"), true)
        return nil
    end
    
    if data.data and data.data.Page and data.data.Page.media then
        return data.data.Page.media
    end
    
    return nil
end

-- ============================================================================
-- JIMAKU API
-- ============================================================================

-- Search for entry by AniList ID
local function search_jimaku_by_anilist_id(anilist_id)
    if not JIMAKU_API_KEY or JIMAKU_API_KEY == "" then
        debug_log("No Jimaku API key", true)
        return nil
    end
    
    local url = string.format("%s/entries/search?anilist_id=%d", 
                              JIMAKU_API_URL, anilist_id)
    
    debug_log(string.format("Searching Jimaku for AniList ID: %d", anilist_id))
    
    local response = http_request(
        url,
        "GET",
        {
            ["Authorization"] = "Bearer " .. JIMAKU_API_KEY,
            ["Accept"] = "application/json"
        }
    )
    
    if not response then
        debug_log("No response from Jimaku", true)
        return nil
    end
    
    local data = json_decode(response)
    
    if data and type(data) == "table" and #data > 0 then
        debug_log(string.format("Found Jimaku entry: %s (ID: %d)", 
                                data[1].name, data[1].id))
        return data[1]  -- Return first entry
    end
    
    debug_log("No Jimaku entry found for this anime", true)
    return nil
end

-- Get files for entry with episode filter
local function get_jimaku_files(entry_id, episode_num)
    local url = string.format("%s/entries/%d/files?episode=%d",
                              JIMAKU_API_URL, entry_id, episode_num)
    
    debug_log(string.format("Fetching files for entry %d, episode %d", 
                            entry_id, episode_num))
    
    local response = http_request(
        url,
        "GET",
        {
            ["Authorization"] = "Bearer " .. JIMAKU_API_KEY,
            ["Accept"] = "application/json"
        }
    )
    
    if not response then
        debug_log("No response from Jimaku files endpoint", true)
        return nil
    end
    
    local files = json_decode(response)
    
    if files and type(files) == "table" then
        debug_log(string.format("Found %d file(s)", #files))
        return files
    end
    
    return nil
end

-- Download subtitle file
local function download_subtitle(file_entry, anime_title, episode_num, index)
    -- Extract file ID from URL
    -- URL format: https://jimaku.cc/api/files/{id}
    local file_id = file_entry.url:match("/files/(%d+)$")
    
    if not file_id then
        debug_log("Could not extract file ID from URL: " .. file_entry.url, true)
        return false
    end
    
    debug_log(string.format("Downloading: %s", file_entry.name))
    
    local response = http_request(
        file_entry.url,
        "GET",
        {
            ["Authorization"] = "Bearer " .. JIMAKU_API_KEY
        }
    )
    
    if not response or response == "" then
        debug_log("Failed to download subtitle", true)
        return false
    end
    
    -- Create safe filename
    local safe_title = anime_title:gsub("[^%w%s%-]", "_"):gsub("%s+", "_")
    local output_file = string.format("%s/%s_E%02d_%d.ass",
                                     SUBTITLE_CACHE_DIR, safe_title, episode_num, index)
    
    local f = io.open(output_file, "w")
    if not f then
        debug_log("Could not create output file: " .. output_file, true)
        return false
    end
    
    f:write(response)
    f:close()
    
    debug_log("✓ Saved: " .. output_file)
    
    -- Load in mpv if not standalone
    if not STANDALONE_MODE then
        mp.commandv("sub-add", output_file)
    end
    
    return true
end

-- ============================================================================
-- MAIN WORKFLOW
-- ============================================================================

local function search_and_download()
    local filename
    
    if STANDALONE_MODE then
        -- For testing
        filename = "[SubsPlease] Jujutsu Kaisen - 49 (1080p) [84C776B4].mkv"
        debug_log("STANDALONE TEST MODE")
    else
        filename = mp.get_property("filename")
    end
    
    if not filename then
        debug_log("No filename", true)
        return
    end
    
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    debug_log("Processing: " .. filename)
    
    -- 1. Parse filename
    local parsed = parse_filename(filename)
    
    if not parsed or not parsed.title then
        debug_log("Failed to parse filename", true)
        if not STANDALONE_MODE then
            mp.osd_message("Failed to parse filename", 3)
        end
        return
    end
    
    debug_log(string.format("Parsed → Title: %s | S:%s E:%s (conf:%d)",
                            parsed.title,
                            parsed.season or "?",
                            parsed.episode or "?",
                            parsed.confidence))
    
    if not parsed.episode then
        debug_log("No episode number found", true)
        if not STANDALONE_MODE then
            mp.osd_message("No episode number found", 3)
        end
        return
    end
    
    -- 2. Search AniList
    local anilist_results = search_anilist(parsed.title)
    
    if not anilist_results or #anilist_results == 0 then
        debug_log("No AniList matches", true)
        if not STANDALONE_MODE then
            mp.osd_message("No anime found on AniList", 3)
        end
        return
    end
    
    local selected = anilist_results[1]
    debug_log(string.format("Selected: %s (ID:%d | Episodes:%s | Format:%s)",
                            selected.title.romaji or selected.title.english,
                            selected.id,
                            selected.episodes or "?",
                            selected.format or "?"))
    
    if not STANDALONE_MODE then
        mp.osd_message(string.format("Found: %s\nSearching for subtitles...",
                                     selected.title.romaji or selected.title.english), 3)
    end
    
    -- 3. Search Jimaku
    local jimaku_entry = search_jimaku_by_anilist_id(selected.id)
    
    if not jimaku_entry then
        debug_log("No Jimaku entry found", true)
        if not STANDALONE_MODE then
            mp.osd_message("No subtitles available on Jimaku", 3)
        end
        return
    end
    
    -- 4. Get files for episode
    local files = get_jimaku_files(jimaku_entry.id, parsed.episode)
    
    if not files or #files == 0 then
        debug_log(string.format("No subtitles for episode %d", parsed.episode), true)
        if not STANDALONE_MODE then
            mp.osd_message(string.format("No subtitles for episode %d", parsed.episode), 3)
        end
        return
    end
    
    -- 5. Download subtitles
    local max_download = (JIMAKU_MAX_SUBS == "all") and #files or math.min(JIMAKU_MAX_SUBS, #files)
    local success_count = 0
    
    for i = 1, max_download do
        if download_subtitle(files[i], parsed.title, parsed.episode, i) then
            success_count = success_count + 1
        end
    end
    
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    debug_log(string.format("✓ Downloaded %d subtitle(s)", success_count))
    
    if not STANDALONE_MODE then
        mp.osd_message(string.format("Loaded %d subtitle(s)", success_count), 5)
    end
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

if not STANDALONE_MODE then
    -- MPV mode
    ensure_subtitle_cache()
    
    if not load_jimaku_api_key() then
        debug_log("Cannot proceed without API key", true)
        mp.osd_message("Jimaku: No API key found", 5)
    else
        mp.add_key_binding("J", "jimaku-search", search_and_download)
        
        if JIMAKU_AUTO_DOWNLOAD then
            mp.register_event("file-loaded", function()
                mp.add_timeout(0.5, search_and_download)
            end)
            debug_log("Jimaku initialized (auto-download enabled)")
        else
            debug_log("Jimaku initialized (press 'J' to search)")
        end
    end
else
    -- Standalone test mode
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    debug_log("JIMAKU STANDALONE TEST")
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    ensure_subtitle_cache()
    if load_jimaku_api_key() then
        search_and_download()
    end
end