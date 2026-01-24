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

local function normalize_title(title)
    if not title then return "" end
    title = title:gsub("[%._]", " ")
    title = title:gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    return title
end

local function is_reversed(str)
    return str:match("p027") or str:match("p0801") or str:match("%d%d%dE%-%d%dS")
end

local function maybe_reverse(str)
    if is_reversed(str) then
        local chars = {}
        for i = #str, 1, -1 do table.insert(chars, str:sub(i, i)) end
        return table.concat(chars)
    end
    return str
end

local function parse_filename(filename)
    local original_raw = filename
    filename = maybe_reverse(filename)
    filename = filename:gsub("%.%w%w%w?$", "") -- Strip extension
    
    local title, episode, season
    local group_match, content_match = filename:match("^%[([^%]]+)%]%s*(.+)$")
    local raw_content = content_match or filename

    -- Try standard patterns
    -- S##E##
    title, season, episode = raw_content:match("^(.-)[%s%.%_][Ss](%d+)[Ee](%d+)")
    
    -- Title - ##
    if not title then
        title, episode = raw_content:match("^(.-)%s*%-%s*(%d+)")
    end
    
    -- S#
    if not title then
        title, season = raw_content:match("^(.-)[%s%.%_][Ss](%d+)")
    end

    if not title then
        title = raw_content:match("^(.-)%s*[%[%(]") or raw_content
    end

    local result = {
        title = normalize_title(title),
        season = tonumber(season) or 1,
        episode = tonumber(episode) or 1
    }

    debug_log(string.format("Parsed: Title='%s' S%d E%d from '%s'", result.title, result.season, result.episode, original_raw))
    return result
end

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