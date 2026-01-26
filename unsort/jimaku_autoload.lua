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
    -- {"netflix", 200}, 
    -- {"amazon", 200},
    -- {"webrip", 200},
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

-- Parse video filename to extract title, episode, and season
local function parse_filename(filename)
    local name = filename:gsub("^.*[/\\]", ""):gsub("%.%w+$", "")
    local clean = name:gsub("%[.-%]", ""):gsub("%(.-%)", ""):gsub("%{.-%}", "")
    
    local season, episode = nil, nil
    local match_start = nil

    -- Extract season
    local season_patterns = {
        "[Ss]eason%s*0*(%d+)",
        "[Ss]0*(%d+)[Ee]%d+",
        "%sS0*(%d+)%s*%-",
        "%.S0*(%d+)E",
        "%sS0*(%d+)%s",
        "%-S0*(%d+)%-",
        "[Pp]art%s*0*(%d+)",
        "[Cc]our%s*0*(%d+)",
    }
    
    for _, pattern in ipairs(season_patterns) do
        local s, e, cap = clean:find(pattern)
        if s then
            season = cap
            match_start = s
            break
        end
    end

    -- Extract episode
    local episode_patterns = {
        "[Ee]pisode%s*0*(%d+)",
        "[Ss]%d+[Ee]0*(%d+)",
        "%s%-+%s*0*(%d+)%s*$",
        "%s%-+%s*0*(%d+)%s",
        "^[#]?0*(%d+)%s",
        "[Ee]0*(%d+)",
        "%s0*(%d+)%s*v%d",
    }
    
    for _, pattern in ipairs(episode_patterns) do
        local s, e, cap = clean:find(pattern)
        if s then
            episode = cap
            if not match_start or s < match_start then
                match_start = s
            end
            if season and tonumber(episode) == tonumber(season) and not pattern:find("[Ee]") then
                -- Ambiguous, keep looking
            else
                break
            end
        end
    end

    local title = clean
    
    if match_start and match_start > 1 then
        title = clean:sub(1, match_start - 1)
    end
    
    title = title:gsub("[:%-_%.]", " ")
    title = title:gsub("%sS%d+$", "")
    title = title:gsub("%s%d+[nr]d%s+[Ss]eason", "")
    title = title:gsub("%s+", " ")
    title = trim(title)
    
    debug_log("Parsed Video - Title: [" .. title .. "] | S: " .. tostring(season) .. " | E: " .. tostring(episode))
    return title, tonumber(episode), tonumber(season)
end

-- Parse subtitle filename to extract season and episode
local function parse_subtitle_filename(filename)
    local fname = filename:lower()
    
    local file_season = fname:match("s0*(%d+)e0*(%d+)") 
    local file_episode = nil
    
    if file_season then
        file_season, file_episode = fname:match("s0*(%d+)e0*(%d+)")
        file_season = tonumber(file_season)
        file_episode = tonumber(file_episode)
    else
        file_season = fname:match("season%s*0*(%d+)") or fname:match("%.s0*(%d+)%.") or fname:match("[Pp]art%s*0*(%d+)") or fname:match("[Cc]our%s*0*(%d+)")
        file_episode = fname:match("e0*(%d+)") or fname:match("ep0*(%d+)") or fname:match("%s%-?%s*0*(%d+)%.")
        
        file_season = file_season and tonumber(file_season)
        file_episode = file_episode and tonumber(file_episode)
    end
    
    return file_season, file_episode
end

local function validate_season_match(entry, target_season)
    if not target_season then return true end
    local full_name = ((entry.name or "") .. " " .. (entry.english_name or "")):lower()
    
    local patterns = {
        "season%s*0*" .. target_season .. "%D",
        "s0*" .. target_season .. "[%s:]",
        "s0*" .. target_season .. "$",
        "%s" .. target_season .. "nd%s+season",
        "%s" .. target_season .. "rd%s+season",
        "%s" .. target_season .. "th%s+season",
        "part%s*0*" .. target_season,
        "cour%s*0*" .. target_season,
    }
    
    for _, pattern in ipairs(patterns) do
        if full_name:find(pattern) then
            debug_log("✓ Season match with pattern: " .. pattern)
            return true
        end
    end
    
    if target_season == 1 and not full_name:find("season%s*%d") and not full_name:find("s%d") and not full_name:find("part%s*%d") then 
        debug_log("✓ Assuming S1 (no season indicator)")
        return true 
    end
    
    debug_log("✗ No season match")
    return false
end

local function score_entry(entry, title, season)
    local score = 0
    local entry_name = (entry.name or ""):lower()
    local entry_eng = (entry.english_name or ""):lower()
    local title_lower = title:lower()
    
    -- Exact match bonus
    if entry_name == title_lower or entry_eng == title_lower then
        score = score + 100
    end
    
    -- Word matching
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
    if is_season_match then 
        score = score + 200 
    elseif season then 
        score = score - 150 
    end
    
    return score, is_season_match
end

local function check_offset_match(file_ep, target_ep)
    if not file_ep or not target_ep then return false, 0 end
    if file_ep == target_ep then return true, 0 end
    
    local diff = file_ep - target_ep
    for _, offset in ipairs(COMMON_OFFSETS) do
        if diff == offset then return true, offset end
    end
    return false, 0
end

-- Smart file selection with clear scoring tiers
local function score_files(files, target_season, target_episode, entry_matches_season)
    if not files or #files == 0 then return {} end
    
    write_log("\n--- SCORING " .. #files .. " FILES ---")
    local scored_files = {}
    
    for i, file in ipairs(files) do
        local score = 0
        local fname = file.name
        local fname_lower = fname:lower()
        
        -- Parse subtitle filename
        local file_season, file_episode = parse_subtitle_filename(fname)
        
        -- Fallback: inherit season from entry
        if entry_matches_season and not file_season then 
            file_season = target_season 
        end
        
        write_log("File: " .. fname .. " | S:" .. tostring(file_season) .. " E:" .. tostring(file_episode))
        
        local score_breakdown = {}
        local is_ep_match, offset_found = check_offset_match(file_episode, target_episode)
        
        -- TIER 1: Perfect match (1000)
        if target_season and target_episode and file_season and file_episode then
            if file_season == target_season and file_episode == target_episode then
                score = score + 1000
                table.insert(score_breakdown, "Perfect Match (+1000)")
            elseif is_ep_match and offset_found > 0 then
                score = score + 850
                table.insert(score_breakdown, "Offset Match " .. offset_found .. " (+850)")
            elseif file_episode == target_episode then
                score = score + 500
                table.insert(score_breakdown, "Episode match, season mismatch (+500)")
            end
        end
        
        -- TIER 2: Episode-only match (750)
        if target_episode and file_episode and not (target_season and file_season) then
            if is_ep_match then
                if offset_found == 0 then
                    score = score + 750
                    table.insert(score_breakdown, "Episode match, no season data (+750)")
                else
                    score = score + 700
                    table.insert(score_breakdown, "Episode offset match, no season data (+700)")
                end
            end
        end
        
        -- TIER 3: Implied season match (800)
        if is_ep_match and entry_matches_season and not file_season then
            if score < 800 then -- Don't override higher scores
                score = score + 800
                table.insert(score_breakdown, "Implied Season Match (+800)")
            end
        end
        
        -- Format preferences
        if fname_lower:match("%.srt$") then
            score = score + 100
            table.insert(score_breakdown, ".srt format (+100)")
        elseif fname_lower:match("%.ass$") then
            score = score + 50
            table.insert(score_breakdown, ".ass format (+50)")
        end
        
        -- Pattern matching bonuses
        for _, entry in ipairs(JIMAKU_PREFERRED_PATTERNS) do
            local pattern = entry
            local boost = 50
            
            if type(entry) == "table" then
                pattern = entry[1]
                boost = entry[2] or 50
            end

            if fname_lower:match(pattern) then
                score = score + boost
                table.insert(score_breakdown, "Pattern '" .. pattern .. "' (+" .. boost .. ")")
            end
        end
        
        -- Quality indicators
        if fname_lower:match("fixed") or fname_lower:match("retimed") then
            score = score + 20
            table.insert(score_breakdown, "Fixed/retimed (+20)")
        end
        
        -- Penalties
        if fname_lower:match("draft") or fname_lower:match("wip") then
            score = score - 50
            table.insert(score_breakdown, "Draft/WIP (-50)")
        end
        
        write_log("  Score: " .. score)
        if #score_breakdown > 0 then
             write_log("  -> " .. table.concat(score_breakdown, ", "))
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
    
    -- Multiple search strategies
    local queries = {}
    
    -- Core title (first 2 words)
    local core_title = title:match("([^%s]+%s+[^%s]+)") or title
    if core_title ~= title then
        table.insert(queries, {query = core_title, desc = "Core title"})
    end
    
    -- Base title
    table.insert(queries, {query = title, desc = "Base title"})
    
    -- Season variations
    if season then
        table.insert(queries, {query = title .. " season " .. season, desc = "Title + season"})
        table.insert(queries, {query = title .. " part " .. season, desc = "Title + part"})
        table.insert(queries, {query = title .. " " .. season, desc = "Title + number"})
    end
    
    write_log("\nSearch strategies: " .. #queries)
    for i, q in ipairs(queries) do
        write_log("  " .. i .. ". " .. q.desc .. ": [" .. q.query .. "]")
    end
    
    -- Aggregate results from all searches
    local all_entries = {}
    local seen_ids = {}
    
    for _, query_data in ipairs(queries) do
        write_log("\nSearching: " .. query_data.query)
        local entries = make_api_request(JIMAKU_API_SEARCH .. "?query=" .. query_data.query:gsub(" ", "+") .. "&anime=true")
        
        if entries and #entries > 0 then 
            write_log("Found " .. #entries .. " entries")
            for _, entry in ipairs(entries) do
                if not seen_ids[entry.id] then
                    seen_ids[entry.id] = true
                    table.insert(all_entries, entry)
                end
            end
        end
        
        if #all_entries >= 10 then
            write_log("Sufficient entries found, stopping search")
            break
        end
    end
    
    if #all_entries == 0 then
        write_log("No entries found")
        mp.osd_message("Jimaku: No results", 3)
        return
    end
    
    write_log("Total unique entries: " .. #all_entries)
    
    local scored_entries = {}
    for _, entry in ipairs(all_entries) do
        local score, is_season_match = score_entry(entry, title, season)
        if score > -50 then
            table.insert(scored_entries, {entry = entry, score = score, match = is_season_match})
        end
    end
    table.sort(scored_entries, function(a, b) return a.score > b.score end)
    
    local all_candidates = {}
    
    -- Check top 3 entries
    for i = 1, math.min(3, #scored_entries) do
        local item = scored_entries[i]
        write_log("\nChecking Entry " .. i .. ": " .. (item.entry.name or "Unknown") .. " (score: " .. item.score .. ")")
        
        local files = make_api_request(JIMAKU_API_DOWNLOAD .. "/" .. item.entry.id .. "/files")
        
        if files and #files > 0 then
            write_log("  Found " .. #files .. " files")
            local entry_scores = score_files(files, season, episode, item.match)
            
            for _, c in ipairs(entry_scores) do
                table.insert(all_candidates, c)
            end
        end
    end
    
    table.sort(all_candidates, function(a, b) return a.score > b.score end)
    
    write_log("\n--- RANKED FILES (Top " .. math.min(10, #all_candidates) .. ") ---")
    for i = 1, math.min(10, #all_candidates) do
        write_log(i .. ". [Score: " .. all_candidates[i].score .. "] " .. all_candidates[i].file.name)
    end

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

    -- Select best files with fallback
    local final_files = {}
    local seen_urls = {}
    
    for _, item in ipairs(all_candidates) do
        if #final_files >= JIMAKU_MAX_SUBS then break end
        if not seen_urls[item.file.url] then
            -- Accept files with any positive score, or best file as fallback
            if item.score > 0 or #final_files == 0 then
                table.insert(final_files, item.file)
                seen_urls[item.file.url] = true
            end
        end
    end
    
    if #final_files > 0 then
        mp.osd_message("Jimaku: Downloading " .. #final_files .. " subs...", 2)
        local API_KEY = get_api_key()
        
        mp.command_native({
            name = "subprocess", 
            args = {"cmd", "/c", "mkdir", CACHE_SUB_DIR:gsub("/", "\\")},
            playback_only = false
        })

        for i, f in ipairs(final_files) do
             write_log("\n✓ Downloading (" .. i .. "): " .. f.name)
             
             local sub_path = CACHE_SUB_DIR .. "/" .. f.name
             local args = { "curl", "-s", "-o", sub_path, "-H", "Authorization: " .. API_KEY, f.url }
             
             local res = mp.command_native({name = "subprocess", args = args})
             if res.status == 0 then
                 mp.commandv("sub-add", sub_path, i == 1 and "select" or "auto", f.name)
                 write_log("  ✓ Loaded and " .. (i == 1 and "selected" or "added"))
             else
                 write_log("  ✗ Download failed")
             end
        end
        mp.osd_message("Jimaku: Loaded " .. #final_files .. " subs", 3)
    else
        write_log("\n✗ No suitable subtitle file found")
        mp.osd_message("Jimaku: No matching file", 3)
    end
    write_log("\nSESSION END")
    write_log(string.rep("=", 60))
end

mp.register_event("file-loaded", auto_load_subs)
mp.add_key_binding("Ctrl+j", "jimaku-search", auto_load_subs)