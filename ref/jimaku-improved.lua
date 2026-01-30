-- ============================================================================
-- JIMAKU MPV SUBTITLE SCRIPT - FULLY FEATURED REFACTORED VERSION
-- ============================================================================

-- ============================================================================
-- SECTION 1: ENVIRONMENT & COMPATIBILITY
-- ============================================================================

local STANDALONE_MODE = not pcall(function() return mp.get_property("filename") end)
local utils = (not STANDALONE_MODE) and require 'mp.utils' or nil

-- ============================================================================
-- SECTION 2: CONFIGURATION & CONSTANTS
-- ============================================================================

local script_opts = {
    jimaku_api_key       = "",
    SUBTITLE_CACHE_DIR   = "./subtitle-cache",
    JIMAKU_MAX_SUBS      = 5,
    JIMAKU_AUTO_DOWNLOAD = true,
    LOG_ONLY_ERRORS      = false,
    JIMAKU_HIDE_SIGNS    = false,
    JIMAKU_ITEMS_PER_PAGE= 8,
    JIMAKU_MENU_TIMEOUT  = 30,
    JIMAKU_FONT_SIZE     = 16,
    INITIAL_OSD_MESSAGES = true
}

-- Load configuration
local CONFIG_DIR = STANDALONE_MODE and "." or mp.command_native({"expand-path", "~~/"})
if not STANDALONE_MODE then
    require("mp.options").read_options(script_opts, "jimaku")
end

-- API URLs
local ANILIST_API_URL = "https://graphql.anilist.co"
local JIMAKU_API_URL = "https://jimaku.cc/api"

-- File paths
local LOG_FILE = CONFIG_DIR .. "/autoload-subs.log"
local PARSER_LOG_FILE = CONFIG_DIR .. "/parser-debug.log"
local JIMAKU_API_KEY_FILE = CONFIG_DIR .. "/jimaku-api-key.txt"
local ANILIST_CACHE_FILE = CONFIG_DIR .. "/anilist-cache.json"
local JIMAKU_CACHE_FILE = CONFIG_DIR .. "/jimaku-cache.json"

-- Configuration variables
local JIMAKU_API_KEY = script_opts.jimaku_api_key
local SUBTITLE_CACHE_DIR = script_opts.SUBTITLE_CACHE_DIR
if not SUBTITLE_CACHE_DIR:match("^/") and not SUBTITLE_CACHE_DIR:match("^%a:") then
    if not STANDALONE_MODE then
        SUBTITLE_CACHE_DIR = CONFIG_DIR .. "/" .. SUBTITLE_CACHE_DIR:gsub("^./", "")
    end
end

local LOG_ONLY_ERRORS = script_opts.LOG_ONLY_ERRORS
local JIMAKU_MAX_SUBS = script_opts.JIMAKU_MAX_SUBS
local JIMAKU_AUTO_DOWNLOAD = script_opts.JIMAKU_AUTO_DOWNLOAD
local JIMAKU_HIDE_SIGNS_ONLY = script_opts.JIMAKU_HIDE_SIGNS
local JIMAKU_ITEMS_PER_PAGE = script_opts.JIMAKU_ITEMS_PER_PAGE
local JIMAKU_MENU_TIMEOUT = script_opts.JIMAKU_MENU_TIMEOUT
local JIMAKU_FONT_SIZE = script_opts.JIMAKU_FONT_SIZE
local INITIAL_OSD_MESSAGES = script_opts.INITIAL_OSD_MESSAGES
local MENU_TIMEOUT = JIMAKU_MENU_TIMEOUT

-- Preferred groups
local JIMAKU_PREFERRED_GROUPS = {
    {name = "Nekomoe kissaten", enabled = true},
    {name = "LoliHouse", enabled = true},
    {name = "Retimed", enabled = true},
    {name = "WEBRip", enabled = true},
    {name = "WEB-DL", enabled = true},
    {name = "WEB", enabled = true},
    {name = "Amazon", enabled = true},
    {name = "AMZN", enabled = true},
    {name = "Netflix", enabled = true},
    {name = "CHS", enabled = false}
}

-- MPV function shortcuts (performance optimization)
local mp_osd = not STANDALONE_MODE and mp.osd_message or function() end
local mp_prop = not STANDALONE_MODE and mp.get_property or function() return "" end
local mp_timeout = not STANDALONE_MODE and mp.add_timeout or function() end
local mp_commandv = not STANDALONE_MODE and mp.commandv or function() end

-- ============================================================================
-- SECTION 3: STATE MANAGEMENT
-- ============================================================================

-- Runtime caches
local EPISODE_CACHE = {}
local ANILIST_CACHE = {}
local JIMAKU_CACHE = {}

-- Archive file mapping: [archive_path] = { [internal_file] = video_filename }
local ARCHIVE_MAPPINGS = {}

-- Menu state
local menu_state = {
    active = false,
    stack = {},
    timeout_timer = nil,
    
    -- Match data
    current_match = nil,
    loaded_subs_count = 0,
    loaded_subs_files = {},
    jimaku_id = nil,
    jimaku_entry = nil,
    anilist_id = nil,
    parsed_data = nil,
    seasons_data = {},
    
    -- Browser state
    browser_page = 1,
    browser_files = nil,
    browser_filter = nil,
    items_per_page = JIMAKU_ITEMS_PER_PAGE,
    
    -- Search state
    search_results = {},
    search_results_page = 1,
    
    -- Toggle: bypass AniList and search Jimaku directly
    bypass_anilist = false,
    
    -- Manual search override
    manual_query = nil
}

-- ============================================================================
-- SECTION 4: UTILITY FUNCTIONS
-- ============================================================================

-- Logging
local function debug_log(message, is_error)
    if LOG_ONLY_ERRORS and not is_error then return end
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_msg = string.format("[%s] %s\n", timestamp, message)
    
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(log_msg)
        f:close()
    end
    print("Jimaku: " .. message)
end

-- Cache persistence
local function save_persistent_cache(file_path, data)
    if not utils then return end
    local ok, json = pcall(utils.format_json, data)
    if not ok then
        debug_log("Cache: Failed to serialize data", true)
        return
    end
    local f = io.open(file_path, "w")
    if f then
        f:write(json)
        f:close()
    end
end

local function load_persistent_cache(file_path)
    local f = io.open(file_path, "r")
    if f then
        local content = f:read("*all")
        f:close()
        if content and content ~= "" then
            local ok, data = pcall(utils.parse_json, content)
            if ok then return data end
        end
    end
    return {}
end

local function save_ANILIST_CACHE()
    save_persistent_cache(ANILIST_CACHE_FILE, ANILIST_CACHE)
end

local function save_JIMAKU_CACHE()
    save_persistent_cache(JIMAKU_CACHE_FILE, JIMAKU_CACHE)
end

local function load_ANILIST_CACHE()
    if not utils then return end
    ANILIST_CACHE = load_persistent_cache(ANILIST_CACHE_FILE)
end

local function load_JIMAKU_CACHE()
    if not utils then return end
    JIMAKU_CACHE = load_persistent_cache(JIMAKU_CACHE_FILE)
end

-- File utilities
local function ensure_subtitle_cache()
    local test_file = SUBTITLE_CACHE_DIR .. "/.test"
    local f = io.open(test_file, "w")
    if f then
        f:close()
        os.remove(test_file)
    else
        os.execute('mkdir -p "' .. SUBTITLE_CACHE_DIR .. '"')
    end
end

local function clear_subtitle_cache()
    if STANDALONE_MODE then return end
    local is_windows = package.config:sub(1,1) == '\\'
    if is_windows then
        os.execute('del /Q "' .. SUBTITLE_CACHE_DIR .. '\\*.*"')
    else
        os.execute('rm -f "' .. SUBTITLE_CACHE_DIR .. '"/*')
    end
    debug_log("Subtitle cache cleared")
    mp_osd("Subtitle cache cleared", 2)
end

local function load_jimaku_api_key()
    if JIMAKU_API_KEY and JIMAKU_API_KEY ~= "" then return end
    
    local f = io.open(JIMAKU_API_KEY_FILE, "r")
    if f then
        JIMAKU_API_KEY = f:read("*all"):gsub("%s+", "")
        f:close()
        debug_log("Loaded API key from file")
    else
        debug_log("No API key found - downloads will be limited", true)
    end
end

local function is_archive_file(path)
    local ext = path:match("%.([^%.]+)$")
    if not ext then return false end
    ext = ext:lower()
    return ext == "zip" or ext == "rar" or ext == "7z" or ext == "tar" or ext == "gz"
end

local function conditional_osd(message, duration, is_auto)
    if not is_auto or INITIAL_OSD_MESSAGES then
        mp_osd(message, duration)
    end
end

-- String utilities
local function trim(s)
    return s:gsub("^%s*(.-)%s*$", "%1")
end

-- Archive handling
local function get_archive_mapping(archive_path, internal_filename)
    if not ARCHIVE_MAPPINGS[archive_path] then
        return nil
    end
    return ARCHIVE_MAPPINGS[archive_path][internal_filename]
end

local function set_archive_mapping(archive_path, internal_filename, video_filename)
    if not ARCHIVE_MAPPINGS[archive_path] then
        ARCHIVE_MAPPINGS[archive_path] = {}
    end
    ARCHIVE_MAPPINGS[archive_path][internal_filename] = video_filename
    debug_log(string.format("Archive mapping: %s [%s] -> %s", archive_path, internal_filename, video_filename))
end

-- ============================================================================
-- SECTION 5: PARSERS (ORIGINAL LOGIC - DO NOT MODIFY!)
-- ============================================================================

local parse_anime_filename, parse_jimaku_filename, extract_year, extract_title_variations
local extract_group_name, roman_to_int, smart_match_anilist

-- Helper: Extract release group from filename
extract_group_name = function(filename)
    local group = filename:match("^%[([%w%._%-%s]+)%]")
    if group then
        group = group:gsub("^%s+", ""):gsub("%s+$", "")
        if group:len() > 2 and group:len() < 40 then
            return group
        end
    end
    return nil
end

-- Helper: Convert Roman numeral to integer
roman_to_int = function(s)
    if not s or s == "" then return nil end
    local values = {I=1, V=5, X=10, L=50, C=100, D=500, M=1000,
                    i=1, v=5, x=10, l=50, c=100, d=500, m=1000}
    local total = 0
    local prev = 0
    for i = #s, 1, -1 do
        local val = values[s:sub(i,i)]
        if not val then return nil end
        if val < prev then
            total = total - val
        else
            total = total + val
        end
        prev = val
    end
    return total > 0 and total or nil
end

-- Helper: Safe title extraction
local function extract_title_safe(content, episode)
    local title = content
    if episode then
        local patterns = {
            "^(.-)%s*[%-%–—]%s*" .. episode,
            "^(.-)%s+" .. episode .. "%s*%[",
            "^(.-)%s+" .. episode .. "$"
        }
        for _, pattern in ipairs(patterns) do
            local t = content:match(pattern)
            if t and t ~= "" then
                title = t
                break
            end
        end
    end
    return title
end

-- Helper: Strip version tags
local function strip_version_tag(title)
    return title:gsub("%s*v%d+%s*$", "")
end

-- Helper: Clean Japanese text
local function clean_japanese_text(title)
    return title:gsub("【.-】", ""):gsub("「.-」", "")
end

-- Helper: Clean parenthetical
local function clean_parenthetical(title)
    title = title:gsub("%s*%([^%)]*[Dd][Uu][Bb][^%)]*%)", "")
    title = title:gsub("%s*%([^%)]*[Ss][Uu][Bb][^%)]*%)", "")
    return title
end

-- Extract year from filename
extract_year = function(filename)
    local year = filename:match("%[(%d%d%d%d)%]")
    if not year then year = filename:match("%((%d%d%d%d)%)") end
    if not year then year = filename:match("%s(%d%d%d%d)%s") end
    if year then
        local y = tonumber(year)
        if y >= 1950 and y <= 2030 then return y end
    end
    return nil
end

-- Main parser function - ORIGINAL LOGIC PRESERVED
parse_anime_filename = function(filename)
    local result = {
        title = nil,
        episode = nil,
        season = nil,
        group = nil,
        raw = filename
    }
    
    local is_url = filename:match("^https?://")
    local clean_name = filename
    
    if not is_url then
        local has_extension = filename:match("%.%w%w%w?%w?$")
        if has_extension then
            clean_name = clean_name:gsub("%.%w%w%w?%w?$", "")
            clean_name = clean_name:match("([^/\\]+)$") or clean_name
        end
    else
        clean_name = clean_name:match("([^/]+)$") or clean_name
    end
    
    result.group = extract_group_name(clean_name)
    if result.group then
        clean_name = clean_name:gsub("^%[[%w%._%-%s]+%]%s*", "")
    end
    
    local content = clean_name
    
    -- Pattern A: SxxExx
    local s, e = content:match("[^%w]S(%d+)[%s%._%-]*E(%d+%.?%d*)[^%w]")
    if not s then s, e = content:match("^S(%d+)[%s%._%-]*E(%d+%.?%d*)") end
    if not s then s, e = content:match("S(%d+)[%s%._%-]*E(%d+%.?%d*)$") end
    if not s then s, e = content:match("S(%d+)[%s%._%-]*E(%d+%.?%d*)") end
    
    if s and e then
        result.season = tonumber(s)
        result.episode = e
        result.title = content:match("^(.-)%s*[Ss]%d+[%s%._%-]*[Ee]%d+") or 
                       content:match("^(.-)%s*%-+%s*[Ss]%d+")
    end
    
    -- Pattern B: Episode keyword
    if not result.episode then
        local t, ep = content:match("^(.-)%s*[Ee]pisode%s*(%d+%.?%d*)")
        if t and ep then
            result.title = t
            result.episode = ep
        end
    end
    
    -- Pattern C: EPxx
    if not result.episode then
        local t, ep = content:match("^(.-)%s*[%-%–—]%s*EP?%s*(%d+%.?%d*)[^%d]")
        if not t then
            t, ep = content:match("^(.-)%s*[%-%–—]%s*EP?%s*(%d+%.?%d*)$")
        end
        if t and ep then
            result.title = t
            result.episode = ep
        end
    end
    
    -- Pattern D: Dash with number
    if not result.episode then
        local t, ep, version = content:match("^(.-)%s*[%-%–—]%s*(%d+%.?%d*)(v%d+)")
        if t and ep then
            result.title = t
            result.episode = ep
        else
            local t2, ep2 = content:match("^(.-)%s*[%-%–—]%s*(%d+%.?%d*)%s*[%[%(%s]")
            if not t2 then
                t2, ep2 = content:match("^(.-)%s*[%-%–—]%s*(%d+%.?%d*)$")
            end
            if t2 and ep2 then
                local ep_num = tonumber(ep2)
                if ep_num and ep_num >= 0 and ep_num <= 9999 then
                    result.title = t2
                    result.episode = ep2
                end
            end
        end
    end
    
    -- Pattern E: Space with number at end
    if not result.episode then
        local t, ep = content:match("^(.-)%s+(%d+%.?%d*)%s*%[")
        if not t then
            t, ep = content:match("^(.-)%s+(%d+%.?%d*)$")
        end
        if t and ep then
            local ep_num = tonumber(ep)
            if ep_num and ep_num >= 1 and ep_num <= 9999 and 
               not t:match("%d$") then
                result.title = t
                result.episode = ep
            end
        end
    end
    
    if not result.title then
        result.title = extract_title_safe(content, result.episode)
    end
    
    if result.title then
        result.title = result.title:gsub("[%._]", " ")
        result.title = result.title:gsub("%s+", " ")
        result.title = result.title:gsub("^%s+", ""):gsub("%s+$", "")
        result.title = result.title:gsub("%s*[%-%_%.]+$", "")
        result.title = strip_version_tag(result.title)
        result.title = clean_japanese_text(result.title)
        result.title = clean_parenthetical(result.title)
        result.title = result.title:gsub("%s+", " ")
        result.title = result.title:gsub("^%s+", ""):gsub("%s+$", "")
    end
    
    -- Season detection
    if not result.season and result.title then
        local roman = result.title:match("%s([IVXLCivxlc]+)$")
        if roman then
            local season_num = roman_to_int(roman)
            if season_num and season_num >= 2 and season_num <= 10 then
                if roman:len() > 1 or (season_num >= 2 and season_num <= 5) then
                    result.season = season_num
                    result.title = result.title:gsub("%s" .. roman .. "$", "")
                end
            end
        end
    end
    
    if not result.season and result.title then
        local s_num = result.title:match("%s[Ss](%d+)$")
        if s_num then
            result.season = tonumber(s_num)
            result.title = result.title:gsub("%s[Ss]%d+$", "")
        else
            s_num = result.title:match("%s[Ss](%d+)%s")
            if s_num then
                result.season = tonumber(s_num)
                result.title = result.title:gsub("%s[Ss]%d+%s", " ")
            end
        end
    end
    
    if not result.season and result.title then
        local season_patterns = {
            "[Ss]eason%s*(%d+)",
            "(%d+)[nrdt][dht]%s+[Ss]eason",
        }
        for _, pattern in ipairs(season_patterns) do
            local s_num = result.title:match(pattern)
            if s_num then
                result.season = tonumber(s_num)
                result.title = result.title:gsub("%s*%(?%d*[nrdt][dht]%s+[Ss]eason%)?", "")
                result.title = result.title:gsub("%s*%(?[Ss]eason%s+%d+%)?", "")
                break
            end
        end
    end
    
    if not result.season and result.title then
        local trailing_num = result.title:match("%s(%d+)$")
        if trailing_num then
            local num = tonumber(trailing_num)
            if num and num >= 2 and num <= 5 and result.title:len() > 5 then
                result.season = num
                result.title = result.title:gsub("%s%d+$", "")
            end
        end
    end
    
    return result
end

-- Jimaku filename parser - ORIGINAL LOGIC PRESERVED
parse_jimaku_filename = function(filename)
    local season, episode = filename:match("[Ss](%d+)[Ee](%d+)")
    if season and episode then
        return tonumber(season), tonumber(episode)
    end
    
    episode = filename:match("[Ee]pisode%s*(%d+)")
    if episode then return nil, tonumber(episode) end
    
    episode = filename:match("[Ee](%d+)")
    if episode then return nil, tonumber(episode) end
    
    episode = filename:match("(%d+)")
    if episode then return nil, tonumber(episode) end
    
    return nil, nil
end

-- ============================================================================
-- SECTION 6: API & NETWORK LOGIC
-- ============================================================================

local make_anilist_request, search_jimaku_subtitles, search_jimaku_subtitles_direct, fetch_all_episode_files

-- AniList GraphQL query
local function make_anilist_request(query_data, variables)
    if STANDALONE_MODE then return nil end
    
    local query_string = [[
{
  Page(page: 1, perPage: 25) {
    media(search: $search, type: ANIME, sort: SEARCH_MATCH) {
      id
      idMal
      title {
        romaji
        english
        native
      }
      synonyms
      format
      status
      episodes
      season
      seasonYear
      startDate {
        year
        month
        day
      }
      endDate {
        year
        month
        day
      }
      averageScore
      popularity
    }
  }
}
]]
    
    local vars_json = utils.format_json(variables)
    local request_body = string.format('{"query":"%s","variables":%s}', 
        query_string:gsub("\n", "\\n"):gsub('"', '\\"'), vars_json)
    
    local args = {
        "curl", "-s", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "-d", request_body,
        ANILIST_API_URL
    }
    
    local result = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = args
    })
    
    if result.status ~= 0 or not result.stdout then
        return nil
    end
    
    local ok, data = pcall(utils.parse_json, result.stdout)
    if not ok or not data or not data.data then
        return nil
    end
    
    return data.data
end

-- Search Jimaku by AniList ID
search_jimaku_subtitles = function(anilist_id)
    if not JIMAKU_API_KEY or JIMAKU_API_KEY == "" then
        debug_log("Jimaku API key not configured - skipping subtitle search", false)
        return nil
    end
    
    debug_log(string.format("Searching Jimaku for AniList ID: %d", anilist_id))
    
    -- Check cache
    local cache_key = tostring(anilist_id)
    if not STANDALONE_MODE and JIMAKU_CACHE[cache_key] then
        local cache_entry = JIMAKU_CACHE[cache_key]
        local cache_age = os.time() - cache_entry.timestamp
        if cache_age < 3600 then
            debug_log(string.format("Using cached Jimaku entry (age: %ds)", cache_age))
            return cache_entry.entry
        else
            JIMAKU_CACHE[cache_key] = nil
        end
    end
    
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
    
    -- Cache result
    JIMAKU_CACHE[cache_key] = {
        entry = entries[1],
        timestamp = os.time()
    }
    if not STANDALONE_MODE then
        save_JIMAKU_CACHE()
    end
    
    return entries[1]
end

-- Search Jimaku directly by query string (bypass AniList)
search_jimaku_subtitles_direct = function(query)
    if not JIMAKU_API_KEY or JIMAKU_API_KEY == "" then
        debug_log("Jimaku API key not configured", true)
        return nil
    end
    
    debug_log("Searching Jimaku directly for: " .. query)
    
    local encoded_query = query:gsub("%s", "+")
    local search_url = string.format("%s/entries/search?query=%s&anime=true", 
        JIMAKU_API_URL, encoded_query)
    
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
        debug_log("Jimaku direct search failed", true)
        return nil
    end
    
    local ok, entries = pcall(utils.parse_json, result.stdout)
    if not ok or not entries or #entries == 0 then
        debug_log("No Jimaku results for query: " .. query)
        return nil, {}
    end
    
    debug_log(string.format("Found %d Jimaku entries", #entries))
    return entries[1], entries
end

-- Fetch all subtitle files for an entry
fetch_all_episode_files = function(entry_id)
    -- Check cache
    if EPISODE_CACHE[entry_id] then
        local cache_age = os.time() - EPISODE_CACHE[entry_id].timestamp
        if cache_age < 300 then
            debug_log(string.format("Using cached file list (%d files)", #EPISODE_CACHE[entry_id].files))
            return EPISODE_CACHE[entry_id].files
        end
    end
    
    local files_url = string.format("%s/entries/%d/files", JIMAKU_API_URL, entry_id)
    
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
        debug_log("Failed to fetch file list", true)
        return nil
    end
    
    local ok, files = pcall(utils.parse_json, result.stdout)
    if not ok or not files then
        debug_log("Failed to parse file list JSON", true)
        return nil
    end
    
    debug_log(string.format("Retrieved %d subtitle files", #files))
    
    -- Cache result
    EPISODE_CACHE[entry_id] = {
        files = files,
        timestamp = os.time()
    }
    
    return files
end

-- ============================================================================
-- SECTION 7: CORE BUSINESS LOGIC
-- ============================================================================

local download_subtitle_smart, update_loaded_subs_list, search_anilist
local match_episodes_intelligent, subtitle_matches_title, calculate_jimaku_episode
local convert_jimaku_to_anilist_episode, handle_archive_subtitle

-- Title variations helper
extract_title_variations = function(anilist_entry)
    local variations = {}
    
    if anilist_entry.title then
        if anilist_entry.title.romaji then
            table.insert(variations, anilist_entry.title.romaji:lower())
        end
        if anilist_entry.title.english then
            table.insert(variations, anilist_entry.title.english:lower())
        end
        if anilist_entry.title.native then
            table.insert(variations, anilist_entry.title.native:lower())
        end
    end
    
    if anilist_entry.synonyms then
        for _, syn in ipairs(anilist_entry.synonyms) do
            table.insert(variations, syn:lower())
        end
    end
    
    for i = 1, #variations do
        local title = variations[i]
        local base = title:gsub("%s*:%s*.*$", "")
        base = base:gsub("%s*season%s*%d+", "")
        base = base:gsub("%s*part%s*%d+", "")
        base = base:gsub("%s*final%s*season", "")
        base = base:gsub("%s*%d+[nrdt][dht]%s*season", "")
        
        if base ~= title and base:len() > 0 then
            table.insert(variations, base)
        end
    end
    
    return variations
end

-- Check if subtitle filename matches any title variation
subtitle_matches_title = function(filename, title_variations)
    local filename_lower = filename:lower()
    for _, variant in ipairs(title_variations) do
        if filename_lower:find(variant, 1, true) then
            return true, variant
        end
    end
    return false, nil
end

-- Calculate cumulative episode from season/episode
calculate_jimaku_episode = function(season, episode, seasons_data)
    if not season or not seasons_data or season == 1 then
        return episode
    end
    
    local cumulative = 0
    for i = 1, season - 1 do
        if seasons_data[i] then
            cumulative = cumulative + seasons_data[i].eps
        end
    end
    return cumulative + episode
end

-- Convert Jimaku episode to AniList episode
convert_jimaku_to_anilist_episode = function(jimaku_ep, target_season, seasons_data)
    if not seasons_data or target_season == 1 then
        return jimaku_ep
    end
    
    local cumulative = 0
    for i = 1, target_season - 1 do
        if seasons_data[i] then
            cumulative = cumulative + seasons_data[i].eps
        end
    end
    
    if jimaku_ep > cumulative then
        return jimaku_ep - cumulative
    end
    
    return jimaku_ep
end

-- Intelligent episode matching with multiple strategies
match_episodes_intelligent = function(all_files, target_episode, anilist_season, seasons_data, anilist_entry)
    local matches = {}
    local title_variations = extract_title_variations(anilist_entry)
    local total_episodes = anilist_entry.episodes or 999
    
    -- Calculate cumulative episode
    local target_cumulative = calculate_jimaku_episode(anilist_season, target_episode, seasons_data)
    
    debug_log(string.format("Smart matching: S%d E%d (cumulative: %d) from %d files", 
        anilist_season or 1, target_episode, target_cumulative, #all_files))
    
    for _, file in ipairs(all_files) do
        local jimaku_season, jimaku_episode = parse_jimaku_filename(file.name)
        local is_match = false
        local match_type = ""
        local priority_score = 0
        
        -- Check preferred groups
        for i, pref_group in ipairs(JIMAKU_PREFERRED_GROUPS) do
            if pref_group.enabled and file.name:lower():match(pref_group.name:lower()) then
                priority_score = (#JIMAKU_PREFERRED_GROUPS - i + 1) * 2
                break
            end
        end
        
        local ep_num = tonumber(jimaku_episode) or 0
        local title_match = subtitle_matches_title(file.name, title_variations)
        
        -- Matching strategies
        if jimaku_season then
            -- Season-marked files
            if jimaku_season == anilist_season and ep_num == target_episode then
                is_match = true
                match_type = "direct_season_match"
            elseif ep_num == target_cumulative then
                is_match = true
                match_type = "netflix_absolute"
            elseif jimaku_season == anilist_season then
                local file_cumulative = calculate_jimaku_episode(jimaku_season, ep_num, seasons_data)
                if file_cumulative == target_cumulative then
                    is_match = true
                    match_type = "season_relative"
                end
            end
        else
            -- No season marker
            if ep_num == target_cumulative then
                is_match = true
                match_type = "cumulative_match"
            elseif ep_num == target_episode then
                is_match = true
                match_type = "direct_episode_match"
            else
                local converted_ep = convert_jimaku_to_anilist_episode(ep_num, anilist_season, seasons_data)
                if converted_ep == target_episode then
                    is_match = true
                    match_type = "reverse_cumulative"
                end
            end
        end
        
        -- Japanese absolute episode
        if not is_match then
            local japanese_ep = file.name:match("第(%d+)[話回]")
            if japanese_ep and tonumber(japanese_ep) == target_cumulative then
                is_match = true
                match_type = "japanese_absolute"
            end
        end
        
        if is_match then
            table.insert(matches, {
                file = file,
                match_type = match_type,
                priority_score = priority_score,
                title_match = title_match
            })
            debug_log(string.format("  ✓ MATCH [%s | P=%d]: %s", 
                match_type, priority_score, file.name:sub(1, 60)))
        end
    end
    
    -- Sort by priority
    table.sort(matches, function(a, b)
        if a.title_match ~= b.title_match then return a.title_match end
        return a.priority_score > b.priority_score
    end)
    
    debug_log(string.format("Found %d matching files", #matches))
    
    local result_files = {}
    for _, m in ipairs(matches) do
        table.insert(result_files, m.file)
    end
    
    return result_files
end

-- Smart matching algorithm - ORIGINAL LOGIC PRESERVED
smart_match_anilist = function(results, parsed, episode_num, season_num, file_year)
    local function calc_score(media, parsed, file_year)
        local score = 0
        local title_match = false
        
        local variations = extract_title_variations(media)
        local search_title = parsed.title:lower()
        
        for _, variant in ipairs(variations) do
            if variant == search_title then
                score = score + 100
                title_match = true
                break
            elseif variant:find(search_title, 1, true) then
                score = score + 50
                title_match = true
            elseif search_title:find(variant, 1, true) then
                score = score + 30
                title_match = true
            end
        end
        
        if not title_match then return 0 end
        
        if media.format == "TV" or media.format == "TV_SHORT" then
            score = score + 20
        elseif media.format == "ONA" or media.format == "WEB" then
            score = score + 15
        elseif media.format == "MOVIE" then
            score = score - 30
        end
        
        if media.episodes then
            if episode_num <= media.episodes then
                score = score + 15
            else
                score = score - 20
            end
        end
        
        if file_year and media.seasonYear then
            local year_diff = math.abs(media.seasonYear - file_year)
            if year_diff == 0 then
                score = score + 25
            elseif year_diff <= 1 then
                score = score + 10
            else
                score = score - (year_diff * 5)
            end
        end
        
        if media.popularity then
            score = score + math.min(media.popularity / 1000, 10)
        end
        
        return score
    end
    
    local best_media = nil
    local best_score = -999
    
    for _, media in ipairs(results) do
        local score = calc_score(media, parsed, file_year)
        if score > best_score then
            best_score = score
            best_media = media
        end
    end
    
    if not best_media then
        return results[1], episode_num, season_num or 1, {}, "fallback-first"
    end
    
    local match_method = "smart-match"
    if best_score >= 100 then
        match_method = "exact-title"
    elseif best_score >= 50 then
        match_method = "partial-title"
    end
    
    return best_media, episode_num, season_num or 1, {}, match_method
end

-- Handle archive subtitle extraction
handle_archive_subtitle = function(archive_path, load_flag)
    if STANDALONE_MODE then return false end
    
    local temp_dir = SUBTITLE_CACHE_DIR .. "/archive_temp"
    os.execute('mkdir -p "' .. temp_dir .. '"')
    
    local extract_cmd
    if archive_path:match("%.zip$") then
        extract_cmd = string.format('unzip -o "%s" -d "%s"', archive_path, temp_dir)
    elseif archive_path:match("%.rar$") then
        extract_cmd = string.format('unrar e -o+ "%s" "%s/"', archive_path, temp_dir)
    elseif archive_path:match("%.7z$") then
        extract_cmd = string.format('7z e -o"%s" -y "%s"', temp_dir, archive_path)
    else
        return false
    end
    
    os.execute(extract_cmd)
    
    -- Find subtitle files
    local find_subs = io.popen('find "' .. temp_dir .. '" -type f \\( -name "*.ass" -o -name "*.srt" \\)')
    if not find_subs then return false end
    
    local success = false
    for sub_file in find_subs:lines() do
        mp_commandv("sub-add", sub_file, load_flag)
        debug_log("Loaded from archive: " .. sub_file)
        success = true
        load_flag = "auto"  -- Only select first one
    end
    find_subs:close()
    
    return success
end

-- Download subtitle with smart matching
download_subtitle_smart = function(jimaku_id, episode, season, seasons_data, anilist_entry, is_auto)
    local files = fetch_all_episode_files(jimaku_id)
    if not files or #files == 0 then
        conditional_osd("No subtitle files available", 3, is_auto)
        return false
    end
    
    local matched_files = match_episodes_intelligent(files, episode, season, seasons_data, anilist_entry)
    
    if #matched_files == 0 then
        debug_log(string.format("No matches for S%d E%d", season or 1, episode))
        conditional_osd("No matching subtitles found", 3, is_auto)
        return false
    end
    
    local max_downloads = math.min(JIMAKU_MAX_SUBS, #matched_files)
    debug_log(string.format("Downloading %d of %d matched subtitles", max_downloads, #matched_files))
    
    local success_count = 0
    
    for i = 1, max_downloads do
        local subtitle_file = matched_files[i]
        local subtitle_path = SUBTITLE_CACHE_DIR .. "/" .. subtitle_file.name
        
        local download_url = subtitle_file.url or string.format("%s/files/%d", JIMAKU_API_URL, subtitle_file.id)
        
        local args = {
            "curl", "-s", "-L", "-o", subtitle_path,
            "-H", "Authorization: " .. JIMAKU_API_KEY,
            download_url
        }
        
        local result = mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = args
        })
        
        if result.status == 0 then
            local load_flag = (success_count == 0) and "select" or "auto"
            
            if is_archive_file(subtitle_file.name) then
                if handle_archive_subtitle(subtitle_path, load_flag) then
                    success_count = success_count + 1
                end
            else
                mp_commandv("sub-add", subtitle_path, load_flag)
                debug_log(string.format("Loaded subtitle [%d/%d]: %s", i, max_downloads, subtitle_file.name))
                table.insert(menu_state.loaded_subs_files, subtitle_file.name)
                menu_state.loaded_subs_count = menu_state.loaded_subs_count + 1
                success_count = success_count + 1
            end
        else
            debug_log(string.format("Download failed [%d/%d]: %s", i, max_downloads, subtitle_file.name), true)
        end
    end
    
    if success_count > 0 then
        conditional_osd(string.format("✓ Loaded %d subtitle(s)", success_count), 4, is_auto)
        return true
    else
        conditional_osd("Failed to download subtitles", 3, is_auto)
        return false
    end
end

-- Track loaded subtitles
update_loaded_subs_list = function()
    if STANDALONE_MODE then return end
    menu_state.loaded_subs_files = {}
    menu_state.loaded_subs_count = 0
    
    local count = mp_prop("track-list/count")
    if not count then return end
    
    for i = 0, tonumber(count) - 1 do
        local track_type = mp_prop(string.format("track-list/%d/type", i))
        if track_type == "sub" then
            local title = mp_prop(string.format("track-list/%d/title", i))
            if title and title ~= "" then
                table.insert(menu_state.loaded_subs_files, title)
                menu_state.loaded_subs_count = menu_state.loaded_subs_count + 1
            end
        end
    end
end

-- Main search function
search_anilist = function(is_auto)
    is_auto = is_auto or false
    
    local filename = mp_prop("filename")
    if not filename or filename == "" then
        mp_osd("No file loaded", 3)
        return
    end
    
    -- Handle archive files
    local path = mp_prop("path")
    if is_archive_file(filename) or (path and path:match("archive://")) then
        local archive_path, internal_file = path:match("^archive://(.+)%|(.+)$")
        if archive_path and internal_file then
            local mapped_file = get_archive_mapping(archive_path, internal_file)
            if mapped_file then
                filename = mapped_file
            else
                filename = internal_file
            end
        end
    end
    
    local query_text = menu_state.manual_query or filename
    debug_log("Search initiated: " .. query_text)
    
    -- Bypass AniList mode
    if menu_state.bypass_anilist then
        debug_log("Bypass mode - searching Jimaku directly")
        local entry, all_entries = search_jimaku_subtitles_direct(query_text)
        
        if entry then
            menu_state.jimaku_id = entry.id
            menu_state.jimaku_entry = entry
            menu_state.search_results = all_entries or {entry}
            
            conditional_osd(string.format("Direct match: %s\nID: %d", 
                entry.name, entry.id), 5, is_auto)
            
            if JIMAKU_AUTO_DOWNLOAD or not is_auto then
                local files = fetch_all_episode_files(entry.id)
                if files and #files > 0 then
                    download_subtitle_smart(entry.id, 1, 1, {}, {title={romaji=entry.name}, episodes=999}, is_auto)
                end
            end
        else
            conditional_osd("No direct Jimaku results", 3, is_auto)
        end
        
        menu_state.manual_query = nil
        return
    end
    
    -- Normal AniList flow
    local parsed = parse_anime_filename(query_text)
    if not parsed.title or not parsed.episode then
        conditional_osd("Could not parse filename", 3, is_auto)
        menu_state.manual_query = nil
        return
    end
    
    debug_log(string.format("Parsed: '%s' S%s E%s", 
        parsed.title, parsed.season or "?", parsed.episode))
    
    -- Search AniList with cache
    local cache_key = parsed.title:lower()
    local data
    
    if ANILIST_CACHE[cache_key] then
        local cache_age = os.time() - ANILIST_CACHE[cache_key].timestamp
        if cache_age < 86400 then  -- 24 hour cache
            debug_log("Using cached AniList results")
            data = {Page = {media = ANILIST_CACHE[cache_key].results}}
        end
    end
    
    if not data then
        data = make_anilist_request({}, {search = parsed.title})
        if data and data.Page and data.Page.media then
            ANILIST_CACHE[cache_key] = {
                results = data.Page.media,
                timestamp = os.time()
            }
            save_ANILIST_CACHE()
        end
    end
    
    if data and data.Page and data.Page.media then
        local results = data.Page.media
        menu_state.search_results = results
        
        if #results == 0 then
            conditional_osd("No AniList matches", 3, is_auto)
            menu_state.manual_query = nil
            return
        end
        
        local episode_num = tonumber(parsed.episode) or 1
        local season_num = parsed.season
        local file_year = extract_year(query_text)
        
        local selected, actual_episode, actual_season, seasons, match_method = 
            smart_match_anilist(results, parsed, episode_num, season_num, file_year)
        
        menu_state.current_match = {
            title = selected.title.romaji,
            anilist_id = selected.id,
            episode = actual_episode,
            season = actual_season,
            format = selected.format,
            total_episodes = selected.episodes,
            match_method = match_method,
            anilist_entry = selected
        }
        menu_state.seasons_data = seasons
        menu_state.anilist_id = selected.id
        
        local osd_msg = string.format("Match: %s\nID: %s | S%d E%d", 
            selected.title.romaji, selected.id, actual_season, actual_episode)
        
        conditional_osd(osd_msg, 5, is_auto)
        
        -- Search Jimaku
        local jimaku_entry = search_jimaku_subtitles(selected.id)
        if jimaku_entry then
            menu_state.jimaku_id = jimaku_entry.id
            menu_state.jimaku_entry = jimaku_entry
            menu_state.browser_files = nil
            
            download_subtitle_smart(jimaku_entry.id, actual_episode, actual_season, 
                seasons, selected, is_auto)
        else
            conditional_osd("No Jimaku entry found", 3, is_auto)
        end
    else
        conditional_osd("AniList search failed", 3, is_auto)
    end
    
    menu_state.manual_query = nil
end

-- ============================================================================
-- SECTION 8: UI RENDERING & MENU NAVIGATION
-- ============================================================================

local render_menu_osd, close_menu, push_menu, pop_menu, bind_menu_keys
local handle_menu_up, handle_menu_down, handle_menu_left, handle_menu_right
local handle_menu_select, handle_menu_num
local show_main_menu, show_search_menu, show_preferences_menu, show_help_menu
local show_manage_menu, show_subtitle_browser, logical_sort_files
local show_download_settings_menu, show_ui_settings_menu, show_preferred_groups_menu
local reload_subtitles_action, clear_subs_action, apply_browser_filter

-- Render menu
render_menu_osd = function()
    if not menu_state.active or #menu_state.stack == 0 then return end
    
    local context = menu_state.stack[#menu_state.stack]
    local title = context.title
    local items = context.items
    local selected = context.selected
    local footer = context.footer or (#menu_state.stack > 1 and "ESC: Back" or "ESC: Close")
    local header = context.header
    
    local ass = mp.get_property_osd("osd-ass-cc/0")
    
    local style_header = string.format("{\\b1\\fs%d\\c&H00FFFF&}", JIMAKU_FONT_SIZE + 4)
    local style_selected = string.format("{\\b1\\fs%d\\c&H00FF00&}", JIMAKU_FONT_SIZE)
    local style_normal = string.format("{\\fs%d\\c&HFFFFFF&}", JIMAKU_FONT_SIZE)
    local style_disabled = string.format("{\\fs%d\\c&H808080&}", JIMAKU_FONT_SIZE)
    local style_footer = string.format("{\\fs%d\\c&HCCCCCC&}", JIMAKU_FONT_SIZE - 2)
    local style_dim = string.format("{\\fs%d\\c&H888888&}", JIMAKU_FONT_SIZE - 6)
    
    ass = ass .. style_header .. title .. "\\N"
    ass = ass .. string.format("{\\fs%d\\c&H808080&}", JIMAKU_FONT_SIZE - 2) .. string.rep("━", 40) .. "\\N"
    
    if header then
        ass = ass .. style_normal .. header .. "\\N"
        ass = ass .. string.format("{\\fs%d\\c&H808080&}", JIMAKU_FONT_SIZE - 2) .. string.rep("─", 40) .. "\\N"
    end
    
    for i, item in ipairs(items) do
        local prefix = (i == selected) and "→ " or "  "
        local style = (i == selected) and style_selected or style_normal
        
        if item.disabled then
            style = style_disabled
        end
        
        local text = item.text
        if item.hint then
            text = text .. " " .. style_dim .. "(" .. item.hint .. ")"
        end
        
        ass = ass .. style .. prefix .. text .. "\\N"
    end
    
    ass = ass .. string.format("{\\fs%d\\c&H808080&}", JIMAKU_FONT_SIZE - 2) .. string.rep("━", 40) .. "\\N"
    ass = ass .. style_footer .. footer .. "\\N"
    
    mp_osd(ass, MENU_TIMEOUT == 0 and 3600 or MENU_TIMEOUT)
    
    if menu_state.timeout_timer then
        menu_state.timeout_timer:kill()
    end
    if MENU_TIMEOUT > 0 then
        menu_state.timeout_timer = mp_timeout(MENU_TIMEOUT, close_menu)
    end
end

-- Close menu
close_menu = function()
    if not menu_state.active then return end
    
    menu_state.active = false
    menu_state.stack = {}
    
    if menu_state.timeout_timer then
        menu_state.timeout_timer:kill()
        menu_state.timeout_timer = nil
    end
    
    local keys = {
        "menu-up", "menu-down", "menu-left", "menu-right", "menu-select", "menu-close",
        "menu-up-alt", "menu-down-alt", "menu-select-alt", "menu-back-alt",
        "menu-search-slash", "menu-filter-f", "menu-clear-x",
        "menu-wheel-up", "menu-wheel-down", "menu-mbtn-left", "menu-mbtn-right"
    }
    for _, name in ipairs(keys) do
        mp.remove_key_binding(name)
    end
    
    for i = 0, 9 do
        mp.remove_key_binding("menu-num-" .. i)
    end
    
    mp_osd("", 0)
end

-- Navigation handlers
handle_menu_up = function()
    if not menu_state.active or #menu_state.stack == 0 then return end
    local context = menu_state.stack[#menu_state.stack]
    context.selected = context.selected - 1
    if context.selected < 1 then context.selected = #context.items end
    render_menu_osd()
end

handle_menu_down = function()
    if not menu_state.active or #menu_state.stack == 0 then return end
    local context = menu_state.stack[#menu_state.stack]
    context.selected = context.selected + 1
    if context.selected > #context.items then context.selected = 1 end
    render_menu_osd()
end

handle_menu_left = function()
    if not menu_state.active or #menu_state.stack == 0 then return end
    local context = menu_state.stack[#menu_state.stack]
    if context.on_left then context.on_left() end
end

handle_menu_right = function()
    if not menu_state.active or #menu_state.stack == 0 then return end
    local context = menu_state.stack[#menu_state.stack]
    if context.on_right then context.on_right() end
end

handle_menu_select = function()
    if not menu_state.active or #menu_state.stack == 0 then return end
    local context = menu_state.stack[#menu_state.stack]
    local item = context.items[context.selected]
    if item and item.action and not item.disabled then
        item.action()
    end
end

handle_menu_num = function(n)
    if not menu_state.active or #menu_state.stack == 0 then return end
    local context = menu_state.stack[#menu_state.stack]
    
    if n == 0 then
        pop_menu()
        return
    end
    
    local item = context.items[n]
    if item and item.action and not item.disabled then
        item.action()
    end
end

-- Menu stack management
push_menu = function(title, items, footer, on_left, on_right, selected, header)
    if #menu_state.stack == 0 then
        bind_menu_keys()
    end
    table.insert(menu_state.stack, {
        title = title,
        items = items,
        selected = selected or 1,
        footer = footer,
        on_left = on_left,
        on_right = on_right,
        header = header
    })
    menu_state.active = true
    render_menu_osd()
end

pop_menu = function()
    if #menu_state.stack > 1 then
        table.remove(menu_state.stack)
        render_menu_osd()
    else
        close_menu()
    end
end

-- Bind keys
bind_menu_keys = function()
    mp.add_forced_key_binding("UP", "menu-up", handle_menu_up)
    mp.add_forced_key_binding("DOWN", "menu-down", handle_menu_down)
    mp.add_forced_key_binding("LEFT", "menu-left", handle_menu_left)
    mp.add_forced_key_binding("RIGHT", "menu-right", handle_menu_right)
    mp.add_forced_key_binding("ENTER", "menu-select", handle_menu_select)
    mp.add_forced_key_binding("ESC", "menu-close", pop_menu)
    
    mp.add_forced_key_binding("k", "menu-up-alt", handle_menu_up)
    mp.add_forced_key_binding("j", "menu-down-alt", handle_menu_down)
    mp.add_forced_key_binding("l", "menu-select-alt", handle_menu_select)
    mp.add_forced_key_binding("h", "menu-back-alt", pop_menu)
    
    mp.add_forced_key_binding("WHEEL_UP", "menu-wheel-up", handle_menu_up)
    mp.add_forced_key_binding("WHEEL_DOWN", "menu-wheel-down", handle_menu_down)
    mp.add_forced_key_binding("MBTN_LEFT", "menu-mbtn-left", handle_menu_select)
    mp.add_forced_key_binding("MBTN_RIGHT", "menu-mbtn-right", pop_menu)
    
    -- Browser filter triggers
    local function trigger_filter()
        if menu_state.active and menu_state.stack[#menu_state.stack].title:match("Browse") then
            mp_osd("Enter filter in console", 3)
            mp.commandv("script-message-to", "console", "type", "script-message jimaku-browser-filter ")
        end
    end
    
    mp.add_forced_key_binding("/", "menu-search-slash", trigger_filter)
    mp.add_forced_key_binding("f", "menu-filter-f", trigger_filter)
    mp.add_forced_key_binding("x", "menu-clear-x", function()
        if menu_state.active and menu_state.stack[#menu_state.stack].title:match("Browse") then
            apply_browser_filter(nil)
        end
    end)
    
    for i = 0, 9 do
        mp.add_forced_key_binding(tostring(i), "menu-num-" .. i, function() handle_menu_num(i) end)
    end
end

-- ============================================================================
-- SECTION 9: MENU ACTIONS & SCREENS
-- ============================================================================

-- Action: Reload subtitles
reload_subtitles_action = function()
    mp_commandv("sub-reload")
    mp_osd("Subtitles reloaded", 2)
    pop_menu()
end

-- Action: Clear loaded subtitles
clear_subs_action = function()
    mp_commandv("sub-remove")
    menu_state.loaded_subs_files = {}
    menu_state.loaded_subs_count = 0
    mp_osd("Cleared all subtitles", 2)
    pop_menu()
end

-- Subtitle browser filter
apply_browser_filter = function(filter_text)
    menu_state.browser_filter = filter_text
    menu_state.browser_page = 1
    menu_state.browser_files = nil
    pop_menu()
    show_subtitle_browser()
end

-- Logical file sorting
logical_sort_files = function(files)
    table.sort(files, function(a, b)
        local s_a, e_a = parse_jimaku_filename(a.name)
        local s_b, e_b = parse_jimaku_filename(b.name)
        
        if s_a and s_b and s_a ~= s_b then return s_a < s_b end
        if s_a and not s_b then return false end
        if s_b and not s_a then return true end
        
        if e_a and e_b then
            local num_a = tonumber(e_a)
            local num_b = tonumber(e_b)
            if num_a and num_b and num_a ~= num_b then return num_a < num_b end
        end
        
        return a.name:lower() < b.name:lower()
    end)
end

-- Subtitle browser
show_subtitle_browser = function()
    if not menu_state.jimaku_id then
        mp_osd("No Jimaku entry loaded", 3)
        return
    end
    
    if not menu_state.browser_files then
        local files = fetch_all_episode_files(menu_state.jimaku_id)
        if not files then
            mp_osd("Failed to fetch files", 3)
            return
        end
        logical_sort_files(files)
        menu_state.browser_files = files
    end
    
    local all_files = menu_state.browser_files
    local filtered_files = {}
    
    if menu_state.browser_filter then
        local filter = menu_state.browser_filter:lower()
        for _, file in ipairs(all_files) do
            if file.name:lower():match(filter) then
                table.insert(filtered_files, file)
            end
        end
    else
        filtered_files = all_files
    end
    
    local page = menu_state.browser_page or 1
    local per_page = menu_state.items_per_page
    local total_pages = math.ceil(#filtered_files / per_page)
    
    if page > total_pages and total_pages > 0 then page = total_pages end
    if page < 1 then page = 1 end
    
    local start_idx = (page - 1) * per_page + 1
    local end_idx = math.min(start_idx + per_page - 1, #filtered_files)
    
    local items = {}
    
    for i = start_idx, end_idx do
        local file = filtered_files[i]
        local display_idx = i - start_idx + 1
        
        local is_loaded = false
        for _, loaded_name in ipairs(menu_state.loaded_subs_files) do
            if loaded_name == file.name then is_loaded = true break end
        end
        
        local item_text = string.format("%d. %s", display_idx, file.name)
        if is_loaded then item_text = "✓ " .. item_text end
        
        table.insert(items, {
            text = item_text,
            action = function()
                local subtitle_path = SUBTITLE_CACHE_DIR .. "/" .. file.name
                local download_url = file.url or string.format("%s/files/%d", JIMAKU_API_URL, file.id)
                
                local args = {
                    "curl", "-s", "-L", "-o", subtitle_path,
                    "-H", "Authorization: " .. JIMAKU_API_KEY,
                    download_url
                }
                
                local result = mp.command_native({
                    name = "subprocess",
                    playback_only = false,
                    args = args
                })
                
                if result.status == 0 then
                    mp_commandv("sub-add", subtitle_path, "select")
                    mp_osd("Loaded: " .. file.name, 3)
                    update_loaded_subs_list()
                    pop_menu()
                    show_subtitle_browser()
                else
                    mp_osd("Download failed", 3)
                end
            end
        })
    end
    
    table.insert(items, {text = "0. Back", action = pop_menu})
    
    local on_left = function()
        if page > 1 then
            menu_state.browser_page = page - 1
            pop_menu()
            show_subtitle_browser()
        end
    end
    
    local on_right = function()
        if page < total_pages then
            menu_state.browser_page = page + 1
            pop_menu()
            show_subtitle_browser()
        end
    end
    
    local footer = "←/→ Page | F Filter | X Clear"
    local title_prefix = menu_state.browser_filter and string.format("FILTER: '%s' ", menu_state.browser_filter) or ""
    local title = string.format("%sBrowse Subtitles (%d/%d) - %d files", 
        title_prefix, page, total_pages, #filtered_files)
    
    push_menu(title, items, footer, on_left, on_right)
end

-- Search menu
show_search_menu = function()
    local m = menu_state.current_match
    local match_text = m and string.format("%s (ID: %s)", m.title, m.anilist_id) or "None"
    
    local items = {
        {text = "Current Match:", hint = match_text, disabled = true},
        {text = "1. Re-run Auto Search", action = function() close_menu(); search_anilist(false) end},
        {text = "2. Manual AniList Search", action = function() 
            mp_osd("Enter query in console", 3)
            mp.commandv("script-message-to", "console", "type", "script-message jimaku-manual-anilist ")
        end},
        {text = "3. Manual Jimaku Search", action = function() 
            mp_osd("Enter query in console", 3)
            mp.commandv("script-message-to", "console", "type", "script-message jimaku-manual-jimaku ")
        end},
        {text = "4. Toggle AniList Bypass", hint = menu_state.bypass_anilist and "ON" or "OFF",
         action = function()
            menu_state.bypass_anilist = not menu_state.bypass_anilist
            pop_menu()
            show_search_menu()
         end},
        {text = "0. Back", action = pop_menu},
    }
    push_menu("Search & Match", items)
end

-- Help menu
show_help_menu = function()
    local items = {
        {text = "1. View Log File", action = function() 
            mp_osd("Log: " .. LOG_FILE, 5)
            pop_menu()
        end},
        {text = "2. Reload API Key", action = function()
            load_jimaku_api_key()
            mp_osd("API key reloaded", 2)
            pop_menu()
        end},
        {text = "3. Keyboard Shortcuts", action = function()
            local shortcuts = 
                "Keyboard Shortcuts:\\N" ..
                "━━━━━━━━━━━━━━━━━━━━━━━━━━━\\N" ..
                "Ctrl+J / Alt+A  Open Menu\\N" ..
                "A               Auto Search\\N" ..
                "↑/↓            Navigate\\N" ..
                "←/→            Page\\N" ..
                "Enter           Select\\N" ..
                "Esc / 0         Back/Close\\N" ..
                "1-9             Quick Select"
            mp_osd(shortcuts, 8)
        end},
        {text = "0. Back", action = pop_menu},
    }
    push_menu("Help", items)
end

-- Preferences menu
show_preferences_menu = function(selected)
    local items = {
        {text = "1. Download Settings   →", action = show_download_settings_menu},
        {text = "2. Release Groups      →", action = show_preferred_groups_menu},
        {text = "3. Interface           →", action = show_ui_settings_menu},
        {text = "0. Back", action = pop_menu},
    }
    push_menu("Preferences", items, nil, nil, nil, selected)
end

-- Download settings
show_download_settings_menu = function(selected)
    local auto_status = JIMAKU_AUTO_DOWNLOAD and "✓ ON" or "✗ OFF"
    local signs_status = JIMAKU_HIDE_SIGNS_ONLY and "✓ ON" or "✗ OFF"
    
    local items = {
        {text = "1. Auto-download", hint = auto_status, action = function()
            JIMAKU_AUTO_DOWNLOAD = not JIMAKU_AUTO_DOWNLOAD
            pop_menu()
            show_download_settings_menu(1)
        end},
        {text = "2. Max Subtitles: " .. JIMAKU_MAX_SUBS, action = function()
            if JIMAKU_MAX_SUBS == 1 then JIMAKU_MAX_SUBS = 3
            elseif JIMAKU_MAX_SUBS == 3 then JIMAKU_MAX_SUBS = 5
            elseif JIMAKU_MAX_SUBS == 5 then JIMAKU_MAX_SUBS = 10
            else JIMAKU_MAX_SUBS = 1 end
            pop_menu()
            show_download_settings_menu(2)
        end},
        {text = "3. Hide Signs-Only", hint = signs_status, action = function()
            JIMAKU_HIDE_SIGNS_ONLY = not JIMAKU_HIDE_SIGNS_ONLY
            pop_menu()
            show_download_settings_menu(3)
        end},
        {text = "0. Back", action = pop_menu},
    }
    push_menu("Download Settings", items, nil, nil, nil, selected)
end

-- UI settings
show_ui_settings_menu = function(selected)
    local osd_status = INITIAL_OSD_MESSAGES and "✓ ON" or "✗ OFF"
    
    local items = {
        {text = "1. Font Size: " .. JIMAKU_FONT_SIZE, action = function()
            if JIMAKU_FONT_SIZE == 12 then JIMAKU_FONT_SIZE = 16
            elseif JIMAKU_FONT_SIZE == 16 then JIMAKU_FONT_SIZE = 20
            elseif JIMAKU_FONT_SIZE == 20 then JIMAKU_FONT_SIZE = 24
            else JIMAKU_FONT_SIZE = 12 end
            pop_menu()
            show_ui_settings_menu(1)
        end},
        {text = "2. Items Per Page: " .. JIMAKU_ITEMS_PER_PAGE, action = function()
            if JIMAKU_ITEMS_PER_PAGE == 4 then JIMAKU_ITEMS_PER_PAGE = 6
            elseif JIMAKU_ITEMS_PER_PAGE == 6 then JIMAKU_ITEMS_PER_PAGE = 8
            elseif JIMAKU_ITEMS_PER_PAGE == 8 then JIMAKU_ITEMS_PER_PAGE = 10
            else JIMAKU_ITEMS_PER_PAGE = 4 end
            menu_state.items_per_page = JIMAKU_ITEMS_PER_PAGE
            pop_menu()
            show_ui_settings_menu(2)
        end},
        {text = "3. Menu Timeout: " .. JIMAKU_MENU_TIMEOUT .. "s", action = function()
            if JIMAKU_MENU_TIMEOUT == 15 then JIMAKU_MENU_TIMEOUT = 30
            elseif JIMAKU_MENU_TIMEOUT == 30 then JIMAKU_MENU_TIMEOUT = 60
            elseif JIMAKU_MENU_TIMEOUT == 60 then JIMAKU_MENU_TIMEOUT = 0
            else JIMAKU_MENU_TIMEOUT = 15 end
            MENU_TIMEOUT = JIMAKU_MENU_TIMEOUT == 0 and 3600 or JIMAKU_MENU_TIMEOUT
            pop_menu()
            show_ui_settings_menu(3)
        end},
        {text = "4. OSD Messages", hint = osd_status, action = function()
            INITIAL_OSD_MESSAGES = not INITIAL_OSD_MESSAGES
            pop_menu()
            show_ui_settings_menu(4)
        end},
        {text = "0. Back", action = pop_menu},
    }
    push_menu("Interface Settings", items, nil, nil, nil, selected)
end

-- Preferred groups
show_preferred_groups_menu = function(selected)
    local items = {}
    for i, group in ipairs(JIMAKU_PREFERRED_GROUPS) do
        local status = group.enabled and "✓" or "✗"
        table.insert(items, {
            text = string.format("%d. %s %s", i, status, group.name),
            action = function()
                group.enabled = not group.enabled
                pop_menu()
                show_preferred_groups_menu(i)
            end
        })
    end
    
    table.insert(items, {text = "9. Add New Group", action = function()
        mp_osd("Enter groups (comma-separated) in console", 3)
        mp.commandv("script-message-to", "console", "type", "script-message jimaku-set-groups ")
    end})
    table.insert(items, {text = "0. Back", action = pop_menu})
    
    local on_left = function()
        local idx = menu_state.stack[#menu_state.stack].selected
        if idx > 1 and idx <= #JIMAKU_PREFERRED_GROUPS then
            local temp = JIMAKU_PREFERRED_GROUPS[idx]
            JIMAKU_PREFERRED_GROUPS[idx] = JIMAKU_PREFERRED_GROUPS[idx-1]
            JIMAKU_PREFERRED_GROUPS[idx-1] = temp
            pop_menu()
            show_preferred_groups_menu(idx - 1)
        end
    end
    
    local on_right = function()
        local idx = menu_state.stack[#menu_state.stack].selected
        if idx >= 1 and idx < #JIMAKU_PREFERRED_GROUPS then
            local temp = JIMAKU_PREFERRED_GROUPS[idx]
            JIMAKU_PREFERRED_GROUPS[idx] = JIMAKU_PREFERRED_GROUPS[idx+1]
            JIMAKU_PREFERRED_GROUPS[idx+1] = temp
            pop_menu()
            show_preferred_groups_menu(idx + 1)
        end
    end
    
    local footer = "←/→ Change Priority | ENTER Toggle"
    push_menu("Release Groups", items, footer, on_left, on_right, selected)
end

-- Manage menu
show_manage_menu = function()
    local function count_table(tbl)
        local count = 0
        for _ in pairs(tbl) do count = count + 1 end
        return count
    end
    
    local anilist_count = count_table(ANILIST_CACHE)
    local jimaku_count = count_table(JIMAKU_CACHE)
    
    local items = {
        {text = "SUBTITLES", disabled = true},
        {text = "1. Clear Loaded Subs", action = clear_subs_action},
        {text = "2. Clear Subtitle Cache", action = function()
            clear_subtitle_cache()
            pop_menu()
        end},
        {text = "", disabled = true},
        {text = "CACHE", disabled = true},
        {text = "3. Clear AniList Cache", hint = anilist_count .. " entries", action = function()
            ANILIST_CACHE = {}
            save_ANILIST_CACHE()
            mp_osd("AniList cache cleared", 2)
            pop_menu()
        end},
        {text = "4. Clear Jimaku Cache", hint = jimaku_count .. " entries", action = function()
            JIMAKU_CACHE = {}
            save_JIMAKU_CACHE()
            mp_osd("Jimaku cache cleared", 2)
            pop_menu()
        end},
        {text = "0. Back", action = pop_menu},
    }
    push_menu("Manage & Cleanup", items)
end

-- Main menu
show_main_menu = function()
    local m = menu_state.current_match
    local match_info = m and string.format("%s (S%d E%d)", m.title, m.season, m.episode) or "None"
    local bypass_indicator = menu_state.bypass_anilist and "[DIRECT JIMAKU MODE]" or ""
    
    local header = string.format("Match: %s\n%s", match_info, bypass_indicator)
    
    local items = {
        {text = "1. Search / Reload", action = function() close_menu(); search_anilist(false) end},
        {text = "2. Search Options   →", action = show_search_menu},
        {text = "3. Browse Subtitles →", disabled = not menu_state.jimaku_id, action = function()
            menu_state.browser_page = 1
            menu_state.browser_files = nil
            show_subtitle_browser()
        end},
        {text = "4. Preferences      →", action = show_preferences_menu},
        {text = "5. Manage & Cleanup →", action = show_manage_menu},
        {text = "6. Help & About     →", action = show_help_menu},
        {text = "0. Close Menu", action = close_menu},
    }
    
    push_menu("Jimaku Subtitle Manager", items, "ESC: Close", nil, nil, 1, header)
end

-- ============================================================================
-- SECTION 10: INITIALIZATION
-- ============================================================================

if not STANDALONE_MODE then
    ensure_subtitle_cache()
    load_jimaku_api_key()
    load_ANILIST_CACHE()
    load_JIMAKU_CACHE()
    
    -- Keybindings
    mp.add_key_binding("A", "anilist-search", function() search_anilist(false) end)
    mp.add_key_binding("ctrl+j", "jimaku-menu", show_main_menu)
    mp.add_key_binding("alt+a", "jimaku-menu-alt", show_main_menu)
    
    -- Script messages
    mp.register_script_message("jimaku-manual-anilist", function(text)
        if text and text ~= "" then
            menu_state.manual_query = text
            menu_state.bypass_anilist = false
            search_anilist(false)
        end
    end)
    
    mp.register_script_message("jimaku-manual-jimaku", function(text)
        if text and text ~= "" then
            menu_state.manual_query = text
            menu_state.bypass_anilist = true
            search_anilist(false)
        end
    end)
    
    mp.register_script_message("jimaku-browser-filter", function(text)
        apply_browser_filter(text ~= "" and text or nil)
    end)
    
    mp.register_script_message("jimaku-set-groups", function(text)
        if text and text ~= "" then
            local new_groups = {}
            for group in string.gmatch(text, "([^,]+)") do
                group = trim(group)
                if group ~= "" then
                    table.insert(new_groups, {name = group, enabled = true})
                end
            end
            for _, ng in ipairs(new_groups) do
                local exists = false
                for _, eg in ipairs(JIMAKU_PREFERRED_GROUPS) do
                    if eg.name:lower() == ng.name:lower() then exists = true break end
                end
                if not exists then
                    table.insert(JIMAKU_PREFERRED_GROUPS, ng)
                end
            end
            mp_osd("Added groups", 2)
        end
        
        if menu_state.active and #menu_state.stack > 0 and 
           menu_state.stack[#menu_state.stack].title:match("Release") then
            local selected = menu_state.stack[#menu_state.stack].selected
            pop_menu()
            show_preferred_groups_menu(selected)
        end
    end)
    
    -- Auto-download on file load
    if JIMAKU_AUTO_DOWNLOAD then
        mp.register_event("file-loaded", function()
            menu_state.current_match = nil
            menu_state.jimaku_id = nil
            menu_state.browser_files = nil
            menu_state.bypass_anilist = false
            menu_state.manual_query = nil
            update_loaded_subs_list()
            mp_timeout(0.5, function() search_anilist(true) end)
        end)
    else
        mp.register_event("file-loaded", update_loaded_subs_list)
    end
    
    debug_log("Jimaku Script Initialized (Full Featured)")
end
