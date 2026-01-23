-- Jimaku Subtitle Auto-loader for MPV
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local JIMAKU_API_BASE = "https://jimaku.cc/api"
local JIMAKU_API_SEARCH = JIMAKU_API_BASE .. "/entries/search"
local JIMAKU_API_DOWNLOAD = JIMAKU_API_BASE .. "/entries"
local CONFIG_DIR = mp.command_native({"expand-path", "~~/"})
local DEBUG = true  
local LOG_FILE = CONFIG_DIR .. "/jimaku-debug.log"
local JIMAKU_API_KEY = "" -- Optional: set your API key here.When left empty, the script will read the key from 'jimaku-api-key.txt' located in MPV's config directory (it's one level above the 'scripts' folder).
local COMMON_OFFSETS = {12, 13, 11, 24, 25, 26, 48, 50, 51, 52}
local JIMAKU_PREFERRED_PATTERNS = {
    {"netflix", 200}, 
    {"amazon", 200},
    {"webrip", 200},
    -- Example of custom score boost (default is 50):
    -- {"sdh", 200},  -- Strong preference for SDH
}
local JIMAKU_MAX_SUBS = 5 -- Maximum number of subtitles to download and load
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
    if JIMAKU_API_KEY and JIMAKU_API_KEY ~= "" then
        return JIMAKU_API_KEY
    end
    
    local key_file = io.open(CONFIG_DIR .. "/jimaku-api-key.txt", "r")
    if key_file then
        local key = key_file:read("*all"):gsub("%s+", "")
        key_file:close()
        return key
    end
    return nil
end

local function make_api_request(url)
    debug_log("API Request: " .. url)
    
    local API_KEY = get_api_key()
    if not API_KEY then 
        write_log("[ERROR] API key not found. Set JIMAKU_API_KEY in script or create " .. CONFIG_DIR .. "/jimaku-api-key.txt")
        return nil 
    end

    local header_file = os.tmpname()
    local args = { "curl", "-s", "-i", "--dump-header", header_file, 
                   "-H", "Authorization: " .. API_KEY, 
                   "-H", "Accept: application/json", url }
    
    local result = mp.command_native({ 
        name = "subprocess", 
        capture_stdout = true, 
        playback_only = false, 
        args = args 
    })

    local h_file = io.open(header_file, "r")
    if h_file then
        local headers = h_file:read("*all")
        h_file:close()
        os.remove(header_file)
        
        if headers:find("HTTP/%d%.%d 429") then
            local wait = headers:match("x%-ratelimit%-reset%-after: ([%d%.]+)") or "unknown"
            write_log("[LIMIT] Rate limited! Wait " .. wait .. "s")
            mp.osd_message("Jimaku: Rate limited, wait " .. wait .. "s", 5)
            return nil
        end
    end

    if result.status ~= 0 or not result.stdout then return nil end
    
    local body = result.stdout:match("\r?\n\r?\n(.*)$") or result.stdout
    local ok, data = pcall(utils.parse_json, body)
    
    if not ok then return nil end
    return data
end

-- Extracts S/E and returns the start index of the match (to cut the title)
local function extract_season_episode_info(clean_name)
    local season, episode = nil, nil
    local match_start = nil

    -- 1. Try to find SEASON first
    local season_patterns = {
        { pat = "[Ss]eason%s*0*(%d+)", offset = 0 },
        { pat = "[Ss]0*(%d+)[Ee]%d+", offset = 0 },
        { pat = "%sS0*(%d+)%s*%-", offset = 0 },
        { pat = "%.S0*(%d+)E", offset = 0 },
        { pat = "%sS0*(%d+)%s", offset = 0 },
        { pat = "%-S0*(%d+)%-", offset = 0 },
    }
    
    for _, item in ipairs(season_patterns) do
        local s, e, cap = clean_name:find(item.pat)
        if s then
            season = cap
            match_start = s -- Record where the season info started
            break
        end
    end

    -- 2. Try to find EPISODE
    local episode_patterns = {
        "[Ee]pisode%s*0*(%d+)",
        "[Ss]%d+[Ee]0*(%d+)",
        "%s%-+%s*0*(%d+)%s*$", -- " - 02" at end
        "%s%-+%s*0*(%d+)%s",   -- " - 02 "
        "^[#]?0*(%d+)%s",
        "[Ee]0*(%d+)",
        "%s0*(%d+)%s*v%d",
    }
    
    for _, pattern in ipairs(episode_patterns) do
        local s, e, cap = clean_name:find(pattern)
        if s then
            episode = cap
            -- If we found an episode earlier than the season (rare) or no season found, update cutoff
            if not match_start or s < match_start then
                match_start = s
            end
            
            -- Sanity check: if single digit episode equals season, ignore unless it's clearly an episode pattern
            if season and tonumber(episode) == tonumber(season) and not pattern:find("[Ee]") then
                 -- Ambiguous, keep looking
            else
                break
            end
        end
    end

    return tonumber(season), tonumber(episode), match_start
end

local function parse_filename(filename)
    -- Remove path and extension
    local name = filename:gsub("^.*[/\\]", ""):gsub("%.%w+$", "")
    -- Remove brackets content immediately as it's usually metadata (Source, Resolution)
    local clean = name:gsub("%[.-%]", ""):gsub("%(.-%)", ""):gsub("%{.-%}", "")
    
    local season, episode, match_index = extract_season_episode_info(clean)
    local title = clean
    
    -- CRITICAL FIX: If we found S/E info, cut the title string AT that point.
    -- This discards "Day Tripping...", "1080p", etc. that come after.
    if match_index and match_index > 1 then
        title = clean:sub(1, match_index - 1)
    end
    
    -- Clean up the resulting title
    title = title:gsub("[:%-_%.]", " ") -- dots/underscores to spaces
    title = title:gsub("%sS%d+$", "")   -- Remove trailing " S2" if cut missed it
    title = title:gsub("%s%d+[nr]d%s+[Ss]eason", "") -- Remove " 2nd Season"
    title = title:gsub("%s+", " ")       -- Collapse spaces
    title = trim(title)
    
    debug_log("Parsed Video - Title: [" .. title .. "] | S: " .. tostring(season) .. " | E: " .. tostring(episode))
    return title, episode, season
end

local function validate_season_match(entry, target_season)
    if not target_season then return true end
    local full_name = ((entry.name or "") .. " " .. (entry.english_name or "")):lower()
    
    if full_name:find("season%s*0*" .. target_season) or full_name:find("s0*" .. target_season) or
       full_name:find(" " .. target_season .. "nd%s+season") then
        return true
    end
    
    if target_season == 1 and not full_name:find("season") and not full_name:find("s%d") then return true end
    return false
end

local function score_entry(entry, title, season)
    local score = 0
    local entry_name = (entry.name or ""):lower()
    local entry_eng = (entry.english_name or ""):lower()
    local title_lower = title:lower()
    
    -- Simple word matching
    local matches = 0
    local words = 0
    for word in title_lower:gmatch("%S+") do
        if #word > 1 then
            words = words + 1
            if entry_name:find(word, 1, true) or entry_eng:find(word, 1, true) then 
                matches = matches + 1 
            end
        end
    end
    
    if words > 0 then
        score = score + ((matches / words) * 100)
    end
    
    local is_season_match = validate_season_match(entry, season)
    if is_season_match then score = score + 200 elseif season then score = score - 150 end
    
    return score, is_season_match
end

local function check_offset_match(file_ep, target_ep)
    if not file_ep or not target_ep then return false, 0 end
    if file_ep == target_ep then return true, 0 end
    
    -- Check diff (Absolute numbering handling)
    local diff = file_ep - target_ep
    for _, offset in ipairs(COMMON_OFFSETS) do
        if diff == offset then return true, offset end
    end
    return false, 0
end

local function score_files(files, target_season, target_episode, entry_matches_season)
    if not files or #files == 0 then return {} end
    
    write_log("\n--- SCORING " .. #files .. " FILES ---")
    local scored_files = {}
    
    for i, file in ipairs(files) do
        local score = 0
        local fname = file.name
        local file_season, file_episode, _ = extract_season_episode_info(fname)
        
        -- Fallback: inherit season from entry
        if entry_matches_season and not file_season then file_season = target_season end
        
        local is_ep_match, offset_found = check_offset_match(file_episode, target_episode)
        
        write_log("File: " .. fname .. " | S:" .. tostring(file_season) .. " E:" .. tostring(file_episode))
        
        if target_episode and file_episode then
            if target_season and file_season then
                if file_season == target_season then
                    if is_ep_match then
                        if offset_found == 0 then
                            score = score + 1000 -- Perfect
                        else
                            score = score + 850 -- Offset Match (e.g. 14 vs 02)
                            write_log("  -> Offset Match (Offset: " .. offset_found .. ")")
                        end
                    end
                end
            elseif is_ep_match and entry_matches_season then
                score = score + 800 -- Implied season match
            end
        end
        
        for _, entry in ipairs(JIMAKU_PREFERRED_PATTERNS) do
            local pattern = entry
            local boost = 50
            
            if type(entry) == "table" then
                pattern = entry[1]
                boost = entry[2] or 50
            end

            if fname:lower():match(pattern) then
                score = score + boost
                write_log("  -> Preferred Pattern Match: " .. pattern .. " (+" .. boost .. ")")
            end
        end
        
        table.insert(scored_files, {file = file, score = score})
    end
    
    return scored_files
end

local function auto_load_subs()
    local filename = mp.get_property("filename")
    if not filename then return end
    
    write_log("\n" .. string.rep("=", 60))
    write_log("NEW SESSION: " .. filename)

    local title, episode, season = parse_filename(filename)
    
    -- Strategy 1: Title + Season (e.g. "Vigilante 2")
    local queries = {}
    if season then table.insert(queries, title .. " " .. season) end
    table.insert(queries, title) -- Strategy 2: Base Title
    
    local entries = nil
    for _, q in ipairs(queries) do
        write_log("Searching: " .. q)
        entries = make_api_request(JIMAKU_API_SEARCH .. "?query=" .. q:gsub(" ", "+") .. "&anime=true")
        if entries and #entries > 0 then break end
    end
    
    if not entries or #entries == 0 then
        write_log("No entries found")
        mp.osd_message("Jimaku: No results", 3)
        return
    end
    
    local scored_entries = {}
    for _, entry in ipairs(entries) do
        local score, is_season_match = score_entry(entry, title, season)
        if score > -50 then
            table.insert(scored_entries, {entry = entry, score = score, match = is_season_match})
        end
    end
    table.sort(scored_entries, function(a, b) return a.score > b.score end)
    
    local all_candidates = {}
    
    for i = 1, math.min(5, #scored_entries) do -- Check top 5 entries
        local item = scored_entries[i]
        write_log("Checking Entry: " .. (item.entry.name or "Unknown"))
        
        local files = make_api_request(JIMAKU_API_DOWNLOAD .. "/" .. item.entry.id .. "/files")
        local entry_scores = score_files(files, season, episode, item.match)
        
        for _, c in ipairs(entry_scores) do
            if c.score >= 700 then
                 table.insert(all_candidates, c)
            end
        end
    end
    
    table.sort(all_candidates, function(a, b) return a.score > b.score end)
    
    -- Smart Filter: If we have perfect matches (Score >= 1000), discard anything less (e.g. Offset matches ~850)
    if #all_candidates > 0 then
        local best_score = all_candidates[1].score
        if best_score >= 1000 then
            local filtered = {}
            for _, c in ipairs(all_candidates) do
                if c.score >= 1000 then
                    table.insert(filtered, c)
                end
            end
            all_candidates = filtered
            write_log("Smart Filter: Kept " .. #all_candidates .. " perfect matches (discarded lower scores)")
        end
    end

    local final_files = {}
    local seen_urls = {}
    
    for _, item in ipairs(all_candidates) do
        if #final_files >= JIMAKU_MAX_SUBS then break end
        if not seen_urls[item.file.url] then
            table.insert(final_files, item.file)
            seen_urls[item.file.url] = true
        end
    end
    
    if #final_files > 0 then
        mp.osd_message("Jimaku: Downloading " .. #final_files .. " subs...", 2)
        local API_KEY = get_api_key()
        
        -- Create cache directory if it doesn't exist
        -- Use cmd /c mkdir for Windows support (fails silently if exists or we ignore code)
        mp.command_native({
            name = "subprocess", 
            args = {"cmd", "/c", "mkdir", CACHE_SUB_DIR:gsub("/", "\\")},
            playback_only = false
        })

        for i, f in ipairs(final_files) do
             write_log("Downloading ("..i.."): " .. f.name)
             
             -- Use original filename in cache directory
             local sub_path = CACHE_SUB_DIR .. "/" .. f.name
             local args = { "curl", "-s", "-o", sub_path, "-H", "Authorization: " .. API_KEY, f.url }
             
             local res = mp.command_native({name = "subprocess", args = args})
             if res.status == 0 then
                 -- Add as track
                 mp.commandv("sub-add", sub_path, i == 1 and "select" or "auto", f.name)
             end
        end
        mp.osd_message("Jimaku: Loaded " .. #final_files .. " subs", 3)
    else
        write_log("No suitable subtitle file found.")
        mp.osd_message("Jimaku: No matching file", 3)
    end
    write_log("SESSION END")
end

mp.register_event("file-loaded", auto_load_subs)
mp.add_key_binding("Ctrl+j", "jimaku-search", auto_load_subs)