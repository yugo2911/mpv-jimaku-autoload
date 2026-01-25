local utils = require 'mp.utils'

-- CONFIGURATION
local CONFIG_DIR = mp.command_native({"expand-path", "~~/"})
local LOG_FILE = CONFIG_DIR .. "/anilist-debug.log"
local ANILIST_API_URL = "https://graphql.anilist.co"

-- Helper function to write to log file
local function debug_log(message, is_error)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local prefix = is_error and "[ERROR] " or "[INFO] "
    local log_msg = string.format("%s %s%s\n", timestamp, prefix, message)
    
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(log_msg)
        f:close()
    end
    -- Also print to mpv terminal
    print(log_msg:gsub("\n", ""))
end

-------------------------------------------------------------------------------
-- FILENAME PARSER LOGIC (Based on parser.lua)
-------------------------------------------------------------------------------

-- CONFIGURATION
local LOG_ONLY_ERRORS = false -- Set to true to suppress successful parse logs
local DEBUG_LOG_PATH = "/parser_debug.log"

-- Open debug log file
local debug_log = io.open(DEBUG_LOG_PATH, "w")

local function log(message, is_error)
    -- If LOG_ONLY_ERRORS is true, we only print if is_error is true
    local should_log = not LOG_ONLY_ERRORS or is_error
    
    if debug_log then
        debug_log:write(os.date("%Y-%m-%d %H:%M:%S") .. " - " .. (is_error and "[ERROR] " or "") .. message .. "\n")
        debug_log:flush()
    end
    
    if should_log then
        print(message)
    end
end

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
    
    -- Season Pack (No Episode) - e.g. Title.S01.1080p
    if not title then
        title, season = raw_content:match("^(.-)[%s%.%_][Ss](%d+)")
        if title and season then episode = "PACK" end
    end
    
    -- S# - Episode (SubsPlease/Inka Style)
    if not title then
        title, season, episode = raw_content:match("^(.-)[%s%.%_][Ss](%d+)[%s%.%_]+%-[%s%.%_]+(%d+)")
    end

    -- Explicit "Episode ##"
    if not title then
        title, episode = raw_content:match("^(.-)[%s%.%_]Episode[%s%.%_]+(%d+)")
    end

    -- Title - Episode (Standard HyZen/Saizen with underscores)
    if not title then
        title, episode = raw_content:match("^(.-)%s*%-%s*(%d+)")
    end

    -- Underscore fallback: Title_-_Episode_
    if not title then
        title, episode = raw_content:match("^(.-)%_?%-%_?(%d+)")
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
        log("FAILED TO PARSE: " .. original_raw, true)
        return nil
    end
    
    -- Normalization
    title = normalize_title(title)
    episode = clean_episode(episode)
    quality = extract_quality(raw_content)
    
    -- Post-process: If season wasn't found, check the normalized title for "S1" or "Season 1"
    if not season then
        season = title:match("[Ss]eason%s+(%d+)") or title:match("[%s%.%_][Ss](%d+)")
    end

    local result = {
        title = title,
        season = tonumber(season) or 1,
        episode = episode or "1",
        quality = quality or "unknown",
        is_special = is_special(episode, raw_content),
        group = release_group
    }

    log(string.format("Parsed: [%s] S%02d E%s | %s", 
        result.title, 
        result.season, 
        result.episode, 
        original_raw))

    return result
end

local function process_files(filenames)
    log("=== Processing " .. #filenames .. " entries ===")
    local results = {}
    local failures = 0
    
    for _, filename in ipairs(filenames) do
        local res = parse_filename(filename)
        if res then
            table.insert(results, res)
        else
            failures = failures + 1
        end
    end
    
    log("\n=== SUMMARY ===")
    log(string.format("Total: %d | Success: %d | Failures: %d", #filenames, #results, failures), failures > 0)
    return results
end

local function main()
    local file = io.open(INPUT_FILE, "r")
    if not file then
        log("Could not find " .. INPUT_FILE, true)
        return
    end
    
    local lines = {}
    for line in file:lines() do
        if line:match("%S") then table.insert(lines, line) end
    end
    file:close()
    
    process_files(lines)
    
    if debug_log then debug_log:close() end
end

main()

-------------------------------------------------------------------------------
-- ANILIST GRAPHQL LOGIC
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
        
        debug_log(string.format("Analyzing %d potential matches for '%s' (E%d)...", #results, parsed.title, parsed.episode))

        -- SMART SELECTION & CUMULATIVE EPISODE LOGIC
        local remaining_episodes = parsed.episode
        local found_smart_match = false

        -- Filter for TV shows or likely sequels to calculate cumulative offsets
        -- Note: AniList search results aren't always in chronological order, 
        -- so we prioritize searching for Season keywords if episode count is high.
        if parsed.episode > (selected.episodes or 0) then
            -- 1. Try Keyword Match first (S2, S3, etc)
            for i, media in ipairs(results) do
                local full_text = (media.title.romaji or "") .. " " .. (media.title.english or "")
                for _, syn in ipairs(media.synonyms or {}) do
                    full_text = full_text .. " " .. syn
                end
                
                -- Check for Season 2, Season 3, etc.
                if full_text:lower():match("season 3") or full_text:lower():match("3rd season") then
                    if parsed.episode > 47 then -- Heuristic for JJK S3
                        selected = media
                        found_smart_match = true
                        debug_log(string.format("Smart Match: Detected Season 3 via Keywords for Ep %d", parsed.episode))
                        break
                    end
                elseif full_text:lower():match("season 2") or full_text:lower():match("2nd season") then
                    if not found_smart_match and parsed.episode > 24 then
                        selected = media
                        found_smart_match = true
                        debug_log(string.format("Smart Match: Detected Season 2 via Keywords for Ep %d", parsed.episode))
                    end
                end
            end
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

        mp.osd_message(string.format("AniList Match: %s\nID: %s\nFormat: %s | Eps: %s", 
            selected.title.romaji, 
            selected.id, 
            selected.format or "TV",
            selected.episodes or "?"), 5)
    else
        debug_log("FAILURE: No matches found for " .. parsed.title, true)
        mp.osd_message("AniList: No match found.", 3)
    end
end

-- Keybind 'A' to trigger the search
mp.add_key_binding("A", "anilist-search", search_anilist)

-- Initial log entry
debug_log("AniList Script Initialized. Press 'A' to search current file.")