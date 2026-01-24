-- Jimaku Subtitle Auto-loader for MPV with AniList Integration
local utils = require 'mp.utils'
local msg = require 'mp.msg'

-- API Endpoints
local ANILIST_API_URL = "https://graphql.anilist.co"
local JIMAKU_API_BASE = "https://jimaku.cc/api"
local JIMAKU_API_SEARCH = JIMAKU_API_BASE .. "/entries/search"
local JIMAKU_API_DOWNLOAD = JIMAKU_API_BASE .. "/entries"

-- Config
local CONFIG_DIR = mp.command_native({"expand-path", "~~/"})
local DEBUG = true  
local LOG_FILE = CONFIG_DIR .. "/jimaku-debug.log"
local JIMAKU_API_KEY = "" -- Optional: set your API key here.
local COMMON_OFFSETS = {12, 13, 11, 24, 25, 26, 48, 50, 51, 52}
local JIMAKU_PREFERRED_PATTERNS = {}
local JIMAKU_MAX_SUBS = 5 
local CACHE_SUB_DIR = CONFIG_DIR .. "/subtitle-cache"

local function write_log(message)
    local log = io.open(LOG_FILE, "a")
    if log then
        log:write(os.date("[%H:%M:%S] ") .. message .. "\n")
        log:close()
    end
end

local function debug_log(message)
    if DEBUG then
        msg.info("[DEBUG] " .. message)
        write_log("[DEBUG] " .. message)
    end
end

local function trim(s) return s:match("^%s*(.-)%s*$") end

local function get_api_key()
    if JIMAKU_API_KEY and JIMAKU_API_KEY ~= "" then return JIMAKU_API_KEY end
    local key_file = io.open(CONFIG_DIR .. "/jimaku-api-key.txt", "r")
    if key_file then
        local key = key_file:read("*all"):gsub("%s+", "")
        key_file:close()
        return key
    end
    return nil
end

-- AniList GraphQL Request Logic
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
    local result = mp.command_native({name = "subprocess", capture_stdout = true, playback_only = false, args = args})
    if result.status ~= 0 or not result.stdout then return nil end
    local ok, data = pcall(utils.parse_json, result.stdout)
    if not ok or data.errors then return nil end
    return data.data
end

-- Jimaku API Request Logic
local function make_jimaku_request(url)
    debug_log("Jimaku Request: " .. url)
    local API_KEY = get_api_key()
    if not API_KEY then 
        write_log("[ERROR] Jimaku API key not found.")
        return nil 
    end
    local args = { "curl", "-s", "-H", "Authorization: " .. API_KEY, "-H", "Accept: application/json", url }
    local result = mp.command_native({name = "subprocess", capture_stdout = true, playback_only = false, args = args})
    if result.status ~= 0 or not result.stdout then return nil end
    local ok, data = pcall(utils.parse_json, result.stdout)
    return ok and data or nil
end

local function parse_filename(filename)
    local name = filename:gsub("^.*[/\\]", ""):gsub("%.%w+$", "")
    local clean = name:gsub("%[.-%]", ""):gsub("%(.-%)", ""):gsub("%{.-%}", "")
    local season, episode = nil, nil
    local match_start = nil

    local season_patterns = { "[Ss]eason%s*0*(%d+)", "[Ss]0*(%d+)[Ee]%d+", "[Pp]art%s*0*(%d+)" }
    for _, pattern in ipairs(season_patterns) do
        local s, e, cap = clean:find(pattern)
        if s then season = cap; match_start = s; break end
    end

    local episode_patterns = { "[Ee]pisode%s*0*(%d+)", "[Ss]%d+[Ee]0*(%d+)", "[Ee]0*(%d+)", "%s%-?%s*0*(%d+)%s" }
    for _, pattern in ipairs(episode_patterns) do
        local s, e, cap = clean:find(pattern)
        if s then episode = cap; if not match_start or s < match_start then match_start = s end; break end
    end

    local title = match_start and clean:sub(1, match_start - 1) or clean
    title = title:gsub("[:%-_%.]", " "):gsub("%s+", " ")
    return trim(title), tonumber(episode), tonumber(season)
end

local function parse_subtitle_filename(filename)
    local fname = filename:lower()
    local s, e = fname:match("s0*(%d+)e0*(%d+)")
    if s then return tonumber(s), tonumber(e) end
    local fs = fname:match("season%s*0*(%d+)") or fname:match("%.s0*(%d+)%.")
    local fe = fname:match("e0*(%d+)") or fname:match("ep0*(%d+)") or fname:match("%s%-?%s*0*(%d+)%.")
    return tonumber(fs), tonumber(fe)
end

local function score_files(files, target_season, target_episode)
    local scored = {}
    for _, file in ipairs(files) do
        local score = 0
        local fs, fe = parse_subtitle_filename(file.name)
        
        if fe == target_episode then
            score = score + 500
            if fs == target_season then score = score + 500 end
        end

        -- Extensions preference
        if file.name:lower():match("%.srt$") then score = score + 100
        elseif file.name:lower():match("%.ass$") then score = score + 50 end
        
        table.insert(scored, {file = file, score = score})
    end
    return scored
end

local function auto_load_subs()
    local filename = mp.get_property("filename")
    if not filename then return end
    
    write_log("\n" .. string.rep("=", 60))
    write_log("SESSION START: " .. filename)

    local local_title, episode, season = parse_filename(filename)
    
    -- 1. Query AniList for proper titles, synonyms, and episode names
    local gql_query = [[ 
    query ($search: String) { 
        Page (perPage: 3) { 
            media (search: $search, type: ANIME) { 
                title { romaji english native }
                synonyms
                streamingEpisodes {
                    title
                }
            } 
        } 
    } ]]
    local al_data = make_anilist_request(gql_query, { search = local_title })
    
    local search_titles = { local_title }
    if al_data and al_data.Page.media[1] then
        local m = al_data.Page.media[1]
        
        debug_log("AniList Matched: " .. (m.title.english or m.title.romaji))
        debug_log("Native Title: " .. (m.title.native or "N/A"))

        -- Episode Name Logging from streamingEpisodes
        if episode and m.streamingEpisodes then
            -- Note: streamingEpisodes is an array. We look for the entry matching the episode number.
            -- This usually matches the index, but we check specifically to be sure.
            local ep_found = false
            for _, ep_info in ipairs(m.streamingEpisodes) do
                -- Check if the title starts with "Episode X"
                local ep_num_in_title = ep_info.title:match("^Episode%s*(%d+)")
                if tonumber(ep_num_in_title) == episode then
                    debug_log("Found Episode " .. episode .. " Name: " .. ep_info.title)
                    ep_found = true
                    break
                end
            end
            if not ep_found then
                -- Fallback: try direct indexing if the above search fails
                local ep_data = m.streamingEpisodes[episode]
                if ep_data then
                    debug_log("Episode " .. episode .. " Title (Index Match): " .. ep_data.title)
                end
            end
        end
        
        -- Order search priority: English -> Romaji -> Native -> Synonyms
        if m.title.english then table.insert(search_titles, 1, m.title.english) end
        if m.title.romaji then table.insert(search_titles, 1, m.title.romaji) end
        if m.title.native then table.insert(search_titles, #search_titles + 1, m.title.native) end
        
        if m.synonyms then
            for _, syn in ipairs(m.synonyms) do
                table.insert(search_titles, #search_titles + 1, syn)
            end
        end
        
        -- Log all candidates we found
        debug_log("Titles to attempt: " .. table.concat(search_titles, " | "))
    else
        debug_log("AniList: No match found for " .. local_title)
    end

    -- 2. Search Jimaku with identified titles
    local all_candidates = {}
    local seen_ids = {}
    
    for _, q in ipairs(search_titles) do
        if q and #q > 1 then
            debug_log("Attempting Jimaku search for: " .. q)
            local entries = make_jimaku_request(JIMAKU_API_SEARCH .. "?query=" .. q:gsub(" ", "+") .. "&anime=true")
            if entries and #entries > 0 then
                debug_log("Found " .. #entries .. " entry matches on Jimaku for: " .. q)
                for _, entry in ipairs(entries) do
                    if not seen_ids[entry.id] then
                        seen_ids[entry.id] = true
                        local files = make_jimaku_request(JIMAKU_API_DOWNLOAD .. "/" .. entry.id .. "/files")
                        if files then
                            local scored = score_files(files, season, episode)
                            for _, c in ipairs(scored) do table.insert(all_candidates, c) end
                        end
                    end
                end
            end
        end
        -- Break loop if we found enough candidates to avoid unnecessary API calls
        if #all_candidates >= 5 then 
            debug_log("Sufficient candidates found, skipping remaining title variations.")
            break 
        end
    end

    table.sort(all_candidates, function(a, b) return a.score > b.score end)

    -- 3. Download and Load
    if #all_candidates > 0 then
        mp.osd_message("Jimaku: Downloading match...", 2)
        local API_KEY = get_api_key()
        
        -- Ensure cache dir exists
        mp.command_native({name = "subprocess", args = {"cmd", "/c", "mkdir", CACHE_SUB_DIR:gsub("/", "\\")}, playback_only = false})

        local count = 0
        for i = 1, math.min(JIMAKU_MAX_SUBS, #all_candidates) do
            local f = all_candidates[i].file
            if all_candidates[i].score >= 500 then -- Only load if it likely matches the episode
                local sub_path = CACHE_SUB_DIR .. "/" .. f.name
                debug_log("Downloading: " .. f.name .. " (Score: " .. all_candidates[i].score .. ")")
                local res = mp.command_native({name = "subprocess", args = { "curl", "-s", "-o", sub_path, "-H", "Authorization: " .. API_KEY, f.url }})
                
                if res.status == 0 then
                    mp.commandv("sub-add", sub_path, i == 1 and "select" or "auto", f.name)
                    count = count + 1
                end
            end
        end
        mp.osd_message("Jimaku: Loaded " .. count .. " subs", 3)
    else
        mp.osd_message("Jimaku: No matches found", 3)
        debug_log("No suitable subtitle candidates found after searching all titles.")
    end
    
    write_log("SESSION END")
end

mp.register_event("file-loaded", auto_load_subs)
mp.add_key_binding("Ctrl+j", "jimaku-search", auto_load_subs)