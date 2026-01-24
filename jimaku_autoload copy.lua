-- Jimaku Subtitle Auto-loader for MPV (Enhanced with AniList integration)
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local JIMAKU_API_BASE = "https://jimaku.cc/api"
local JIMAKU_API_SEARCH = JIMAKU_API_BASE .. "/entries/search"
local JIMAKU_API_DOWNLOAD = JIMAKU_API_BASE .. "/entries"
local ANILIST_API = "https://graphql.anilist.co"
local CONFIG_DIR = mp.command_native({"expand-path", "~~/"})
local DEBUG = true  
local LOG_FILE = CONFIG_DIR .. "/jimaku-debug.log"
local JIMAKU_API_KEY = ""
local COMMON_OFFSETS = {12, 13, 11, 24, 25, 26, 48, 50, 51, 52}
local JIMAKU_PREFERRED_PATTERNS = {}
local JIMAKU_MAX_SUBS = 5
local CACHE_SUB_DIR = CONFIG_DIR .. "/subtitle-cache"

-- Common anime season episode counts for absolute->seasonal conversion
local COMMON_SEASON_LENGTHS = {12, 13, 24, 25, 26}

-- Special show handling for shows with non-standard episode numbering
local SPECIAL_SHOW_MAPPINGS = {
    ["vigilante boku no hero academia illegals"] = {
        season_offsets = {
            [2] = {start_episode = 14, offset = 12} -- S02E01 in video = S02E14 in subs (offset 13)
        }
    },
    ["my hero academia vigilantes"] = {
        season_offsets = {
            [2] = {start_episode = 14, offset = 12} -- S02E01 in video = S02E14 in subs (offset 13)
        }
    },
    ["vigilante boku"] = {
        season_offsets = {
            [2] = {start_episode = 14, offset = 12}
        }
    }
}

-- AniList cache to avoid repeated queries
local ANILIST_CACHE = {}
local ANILIST_CACHE_FILE = CONFIG_DIR .. "/anilist-cache.json"

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

local function make_api_request(url, method, body, headers)
    debug_log("API Request: " .. url)
    
    if not headers then headers = {} end
    headers["Accept"] = "application/json"
    headers["Content-Type"] = "application/json"
    headers["User-Agent"] = "MPV-Jimaku-Loader/1.1"
    
    -- Use --data-binary @- to read body from stdin (most robust way)
    local args = { "curl", "-s", "-X", method }
    
    for k, v in pairs(headers) do
        table.insert(args, "-H")
        table.insert(args, k .. ": " .. v)
    end
    
    if method == "POST" and body then
        table.insert(args, "--data-binary")
        table.insert(args, "@-")
    end
    
    table.insert(args, url)
    
    local result = mp.command_native({ 
        name = "subprocess", 
        capture_stdout = true, 
        playback_only = false, 
        args = args,
        stdin_data = body -- Pipe the JSON body here
    })
    
    if result.status ~= 0 or not result.stdout or result.stdout == "" then 
        write_log("[ERROR] Curl failed or returned empty stdout")
        return nil 
    end
    
    -- No need to strip headers anymore as we removed -i
    local ok, data = pcall(utils.parse_json, result.stdout)
    
    if not ok then 
        write_log("[ERROR] Failed to parse JSON. Raw output: " .. tostring(result.stdout):sub(1, 100))
        return nil 
    end
    
    return data
end

local function make_jimaku_request(url)
    local API_KEY = get_api_key()
    if not API_KEY then 
        write_log("[ERROR] API key not found. Set JIMAKU_API_KEY in script or create " .. CONFIG_DIR .. "/jimaku-api-key.txt")
        return nil 
    end
    
    return make_api_request(url, "GET", nil, {
        ["Authorization"] = API_KEY
    })
end

-- ANILIST FUNCTIONS
local function load_anilist_cache()
    local cache_file = io.open(ANILIST_CACHE_FILE, "r")
    if cache_file then
        local content = cache_file:read("*all")
        cache_file:close()
        local ok, data = pcall(utils.parse_json, content)
        if ok and data then
            ANILIST_CACHE = data
            write_log("Loaded AniList cache with " .. #ANILIST_CACHE .. " entries")
        end
    end
end

local function save_anilist_cache()
    local cache_file = io.open(ANILIST_CACHE_FILE, "w")
    if cache_file then
        cache_file:write(utils.format_json(ANILIST_CACHE))
        cache_file:close()
    end
end

local function search_anilist(title, season, episode)
    local cache_key = string.format("%s|%s|%s", title:lower(), tostring(season), tostring(episode))
    
    if ANILIST_CACHE[cache_key] then
        return ANILIST_CACHE[cache_key]
    end
    
    -- Removed seasonYear from variables to avoid filtering out older shows
    local query = [[
    query ($search: String, $type: MediaType) {
      Page(page: 1, perPage: 10) {
        media(search: $search, type: $type) {
          id
          idMal
          title { romaji english native }
          synonyms
          format
          episodes
          status
          season
          seasonYear
          relations {
            edges {
              node {
                id
                title { romaji english native }
                format
                episodes
                season
                seasonYear
              }
              relationType
            }
          }
        }
      }
    }
    ]]
    
    local variables = {
        search = title,
        type = "ANIME"
    }
    
    local response = make_api_request(ANILIST_API, "POST", utils.format_json({
        query = query,
        variables = variables
    }))
    
    if not response or not response.data or not response.data.Page or not response.data.Page.media then
        write_log("[ERROR] AniList API request failed for: " .. title)
        return nil
    end
    
    local media_list = response.data.Page.media
    if #media_list == 0 then
        write_log("No AniList results for: " .. title)
        return nil
    end
    
    -- Try to find the best match
    local best_match = nil
    local best_score = 0
    
    for _, media in ipairs(media_list) do
        local score = 0
        local title_lower = title:lower()
        
        -- Check title matches
        local titles = {
            media.title.romaji and media.title.romaji:lower() or "",
            media.title.english and media.title.english:lower() or "",
            media.title.native and media.title.native:lower() or ""
        }
        
        for _, t in ipairs(titles) do
            if t == title_lower then
                score = score + 100
            elseif t:find(title_lower, 1, true) or title_lower:find(t, 1, true) then
                score = score + 50
            end
        end
        
        -- Check synonyms
        if media.synonyms then
            for _, synonym in ipairs(media.synonyms) do
                local syn_lower = synonym:lower()
                if syn_lower == title_lower then
                    score = score + 80
                elseif syn_lower:find(title_lower, 1, true) or title_lower:find(syn_lower, 1, true) then
                    score = score + 40
                end
            end
        end
        
        -- TV series get bonus (more likely to have seasons)
        if media.format == "TV" or media.format == "TV_SHORT" then
            score = score + 30
        end
        
        -- Completed/Releasing shows get bonus over Not Yet Released
        if media.status == "FINISHED" or media.status == "RELEASING" then
            score = score + 20
        end
        
        if score > best_score then
            best_score = score
            best_match = media
        end
    end
    
    if best_match and best_score > 50 then
        -- Cache the result
        ANILIST_CACHE[cache_key] = best_match
        save_anilist_cache()
        
        write_log(string.format("AniList found: %s (ID: %d, Score: %d)", 
            best_match.title.romaji or best_match.title.native, 
            best_match.id, 
            best_score))
        
        return best_match
    end
    
    return nil
end

-- Get correct season from AniList
local function get_anilist_season_info(title, absolute_episode)
    local media = search_anilist(title, nil, nil)
    if not media then return nil end
    
    write_log("Analyzing AniList data for season detection...")
    
    -- Check if this is a multi-season show by looking at relations
    local seasons = {}
    table.insert(seasons, {
        id = media.id,
        title = media.title.romaji or media.title.native,
        episodes = media.episodes or 0,
        season = media.season,
        seasonYear = media.seasonYear
    })
    
    if media.relations and media.relations.edges then
        for _, edge in ipairs(media.relations.edges) do
            if edge.relationType == "SEQUEL" or edge.relationType == "PREQUEL" or 
               edge.relationType == "PARENT" or edge.relationType == "SIDE_STORY" then
                local node = edge.node
                if node.format == "TV" or node.format == "TV_SHORT" then
                    table.insert(seasons, {
                        id = node.id,
                        title = node.title.romaji or node.title.native,
                        episodes = node.episodes or 0,
                        season = node.season,
                        seasonYear = node.seasonYear
                    })
                end
            end
        end
    end
    
    -- Sort seasons by year/season
    table.sort(seasons, function(a, b)
        if a.seasonYear and b.seasonYear then
            if a.seasonYear == b.seasonYear then
                -- Same year, sort by season (Winter=1, Spring=2, Summer=3, Fall=4)
                local season_order = {WINTER=1, SPRING=2, SUMMER=3, FALL=4}
                local a_order = season_order[a.season or ""] or 5
                local b_order = season_order[b.season or ""] or 5
                return a_order < b_order
            end
            return a.seasonYear < b.seasonYear
        end
        return (a.seasonYear or 9999) < (b.seasonYear or 9999)
    end)
    
    -- Try to map absolute episode to a season
    local remaining_episode = absolute_episode
    local current_season = 1
    
    for i, season in ipairs(seasons) do
        if season.episodes and season.episodes > 0 then
            if remaining_episode <= season.episodes then
                write_log(string.format("AniList mapping: Episode %d → %s S%02dE%02d", 
                    absolute_episode, season.title, i, remaining_episode))
                return {
                    anilist_id = season.id,
                    season_number = i,
                    episode_number = remaining_episode,
                    title = season.title,
                    total_episodes = season.episodes
                }
            else
                remaining_episode = remaining_episode - season.episodes
                current_season = current_season + 1
            end
        end
    end
    
    -- If we couldn't map it, assume it's the latest season
    local latest_season = seasons[#seasons]
    write_log(string.format("AniList fallback: Episode %d → %s (latest season)", 
        absolute_episode, latest_season.title))
    
    return {
        anilist_id = latest_season.id,
        season_number = #seasons,
        episode_number = absolute_episode,
        title = latest_season.title,
        total_episodes = latest_season.episodes
    }
end

-- Convert absolute episode to possible season/episode combinations using AniList data
local function get_seasonal_candidates_with_anilist(title, abs_episode)
    local candidates = {}
    local seen = {}  -- Prevent duplicates
    
    -- Try AniList first
    local anilist_info = get_anilist_season_info(title, abs_episode)
    if anilist_info then
        local key = "S" .. anilist_info.season_number .. "E" .. anilist_info.episode_number
        if not seen[key] then
            seen[key] = true
            table.insert(candidates, {
                season = anilist_info.season_number,
                episode = anilist_info.episode_number,
                anilist_id = anilist_info.anilist_id,
                source = "anilist"
            })
        end
    end
    
    -- Fallback to old logic if AniList failed
    if #candidates == 0 then
        write_log("AniList failed, using heuristic season detection")
        
        -- Try multiple common season length patterns
        local season_patterns = {
            {12, 12, 12},  -- 12-ep seasons
            {13, 13, 13},  -- 13-ep seasons (split-cour)
            {24, 24, 24},  -- 24-ep seasons
            {25, 25, 25},  -- 25-ep seasons
            {26, 26, 26},  -- 26-ep seasons
        }
        
        for _, pattern in ipairs(season_patterns) do
            local remaining = abs_episode
            for season_num, season_len in ipairs(pattern) do
                if remaining <= season_len then
                    local key = "S" .. season_num .. "E" .. remaining
                    if not seen[key] then
                        seen[key] = true
                        table.insert(candidates, {
                            season = season_num,
                            episode = remaining,
                            source = "heuristic"
                        })
                    end
                    break
                else
                    remaining = remaining - season_len
                end
            end
        end
    end
    
    return candidates
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
    
    -- First try to extract S01E01 pattern
    local file_season, file_episode = fname:match("s0*(%d+)e0*(%d+)")
    
    if file_season then
        file_season = tonumber(file_season)
        file_episode = tonumber(file_episode)
        return file_season, file_episode
    end
    
    -- Try to extract season
    file_season = fname:match("season%s*0*(%d+)") 
        or fname:match("%.s0*(%d+)%.") 
        or fname:match("%ss0*(%d+)%s*%-") 
        or fname:match("%ss0*(%d+)%s*%d") 
        or fname:match("[Pp]art%s*0*(%d+)") 
        or fname:match("[Cc]our%s*0*(%d+)")
    
    -- Try to extract episode - enhanced patterns
    file_episode = fname:match("s%d+%s*-%s*0*(%d+)%D")  -- "S3 - 04" pattern
        or fname:match("s%d+%s*-%s*0*(%d+)$")           -- "S3 - 04" at end
        or fname:match("e0*(%d+)") 
        or fname:match("ep0*(%d+)") 
        or fname:match("%s%-%s*0*(%d+)%D")             -- " - 04" pattern
        or fname:match("%s%-%s*0*(%d+)$")              -- " - 04" at end
        or fname:match("%s0*(%d+)%.")                  -- " 04." pattern
        or fname:match("%s0*(%d+)%s")                  -- " 04 " pattern
        or fname:match("%s0*(%d+)$")                   -- " 04" at end
        or fname:match("%-%s*0*(%d+)%D")              -- "-04" followed by non-digit
        or fname:match("%-%s*0*(%d+)$")               -- "-04" at end
    
    -- If still no episode found, try to extract from common patterns like "[Group] Show - 09"
    if not file_episode then
        -- Remove brackets and their contents
        local clean_name = fname:gsub("%[.-%]", ""):gsub("%(.-%)", "")
        -- Try to match "show - 09" pattern
        file_episode = clean_name:match("%-%s*0*(%d+)%D")  -- "- 09" pattern
            or clean_name:match("%-%s*0*(%d+)$")           -- "- 09" at end
            or clean_name:match("%s0*(%d+)%D")             -- " 09" followed by non-digit
            or clean_name:match("%s0*(%d+)$")              -- " 09" at end
    end
    
    file_season = file_season and tonumber(file_season)
    file_episode = file_episode and tonumber(file_episode)
    
    return file_season, file_episode
end

local function validate_season_match(entry, target_season)
    if not target_season then return true end
    
    local full_name = ((entry.name or "") .. " " .. (entry.english_name or "") .. " " .. (entry.alternative_name or "")):lower()
    
    local patterns = {
        "season%s*0*" .. target_season .. "%D",     -- "season 3"
        "season%s*0*" .. target_season .. "$",      -- "season 3" at end
        "s0*" .. target_season .. "[%s%-:%.]",      -- "s3 " or "s3-"
        "s0*" .. target_season .. "$",              -- "s3" at end
        "%s" .. target_season .. "st%s+season",     -- "1st season"
        "%s" .. target_season .. "nd%s+season",     -- "2nd season"
        "%s" .. target_season .. "rd%s+season",     -- "3rd season"
        "%s" .. target_season .. "th%s+season",     -- "4th season"
        "part%s*0*" .. target_season,              -- "part 3"
        "cour%s*0*" .. target_season,              -- "cour 3"
        "%s" .. target_season .. "%s*$",           -- " 3" at end
        "%-%s*" .. target_season .. "%s*$",        -- "- 3" at end
    }
    
    for _, pattern in ipairs(patterns) do
        if full_name:find(pattern) then
            debug_log("✓ Season match with pattern: " .. pattern)
            return true
        end
    end
    
    -- If no season indicator and we're looking for season 1, assume it's season 1
    if target_season == 1 and not full_name:find("season%s*%d") 
        and not full_name:find("s%d") 
        and not full_name:find("part%s*%d")
        and not full_name:find("%d+%s*$") then 
        debug_log("✓ Assuming S1 (no season indicator)")
        return true 
    end
    
    debug_log("✗ No season match for '" .. full_name .. "'")
    return false
end

local function score_entry(entry, title, season, seasonal_candidates)
    local score = 0
    local entry_name = (entry.name or ""):lower()
    local entry_eng = (entry.english_name or ""):lower()
    local entry_alt = (entry.alternative_name or ""):lower()
    local title_lower = title:lower()
    
    -- Combined entry name for matching
    local entry_full = entry_name .. " " .. entry_eng .. " " .. entry_alt
    
    -- Exact match bonus
    if entry_name == title_lower or entry_eng == title_lower or entry_alt == title_lower then
        score = score + 500
    end
    
    -- Word matching - must match core words from title
    local matches = 0
    local words = 0
    for word in title_lower:gmatch("%S+") do
        if #word > 2 then  -- Only check substantial words
            words = words + 1
            if entry_full:find(word, 1, true) then 
                matches = matches + 1 
            end
        end
    end
    
    if words > 0 then
        local match_ratio = matches / words
        if match_ratio >= 0.5 then  -- At least half the words match
            score = score + (match_ratio * 300)
        else
            -- Not enough word overlap - probably wrong show
            return -1000, false
        end
    end
    
    local is_season_match = validate_season_match(entry, season)
    if is_season_match then 
        score = score + 1000
    elseif season then 
        score = score - 800
    end
    
    -- If we have seasonal candidates but no explicit season, don't penalize
    if not season and seasonal_candidates then
        score = score + 100
    end
    
    -- Bonus for entries with AniList ID that matches our candidates
    if seasonal_candidates and entry.anilist_id then
        for _, candidate in ipairs(seasonal_candidates) do
            if candidate.anilist_id and entry.anilist_id == candidate.anilist_id then
                score = score + 1500
                write_log("★★★ AniList ID match! +1500")
                break
            end
        end
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
local function score_files(files, target_season, target_episode, entry_matches_season, seasonal_candidates, original_title)
    if not files or #files == 0 then return {} end
    
    write_log("\n--- SCORING " .. #files .. " FILES ---")
    local scored_files = {}
    
    -- Check for special episode mapping FIRST
    local special_adjusted_episode = nil
    local use_adjusted_episode = false
    
    local is_ep_match, offset_found
    
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
        
        -- Determine if this matches any seasonal candidate (with priority to AniList candidates)
        local matches_seasonal_candidate = false
        local candidate_source = ""
        
        if seasonal_candidates and file_season and file_episode then
            for _, candidate in ipairs(seasonal_candidates) do
                if file_season == candidate.season and file_episode == candidate.episode then
                    if candidate.source == "anilist" then
                        score = score + 3500  -- HUGE bonus for AniList-verified candidates
                        table.insert(score_breakdown, "★★★★ ANILIST VERIFIED S" .. file_season .. "E" .. file_episode .. " (+3500)")
                    else
                        score = score + 2500
                        table.insert(score_breakdown, "★ Seasonal Conversion Match S" .. file_season .. "E" .. file_episode .. " (+2500)")
                    end
                    matches_seasonal_candidate = true
                    candidate_source = candidate.source
                    break
                end
            end
        end
        
        if not matches_seasonal_candidate then
            -- Episode-only match (only if we don't have season info)
            if target_episode and file_episode and not (target_season and file_season) then
                is_ep_match, offset_found = check_offset_match(file_episode, target_episode)
                if is_ep_match then
                    if offset_found == 0 then
                        score = score + 1500
                        table.insert(score_breakdown, "Episode match, no season data (+1500)")
                    else
                        score = score + 1200
                        table.insert(score_breakdown, "Episode offset match, no season data (+1200)")
                    end
                elseif file_episode and target_episode and math.abs(file_episode - target_episode) <= 3 then
                    -- Close episode numbers (within 3 episodes) get some points
                    local diff = math.abs(file_episode - target_episode)
                    score = score + 1000 - (diff * 200)
                    table.insert(score_breakdown, string.format("Close episode (diff: %d) (+%d)", diff, 1000 - (diff * 200)))
                end
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
        
        -- Penalize archive files (they're not subtitle files)
        if fname_lower:match("%.7z$") or fname_lower:match("%.zip$") or fname_lower:match("%.rar$") then
            score = score - 1000
            table.insert(score_breakdown, "Archive file (-1000)")
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
    local original_title = title  -- Keep original for special mapping
    
    -- Load AniList cache
    load_anilist_cache()
    
    -- Generate seasonal candidates using AniList when available
    local seasonal_candidates = nil
    local inferred_seasons = {}
    
    if episode and not season and episode > 13 then
        seasonal_candidates = get_seasonal_candidates_with_anilist(title, episode)
        write_log("\nAbsolute episode detected (" .. episode .. "), generated seasonal candidates:")
        for _, c in ipairs(seasonal_candidates) do
            local source = c.source == "anilist" and "(AniList)" or "(heuristic)"
            write_log("  - S" .. c.season .. "E" .. c.episode .. " " .. source)
            if not inferred_seasons[c.season] then
                inferred_seasons[c.season] = true
            end
        end
    end
    
    -- Multiple search strategies
    local queries = {}
    
    -- Core title (first 2 words)
    local core_title = title:match("([^%s]+%s+[^%s]+)") or title
    if core_title ~= title then
        table.insert(queries, {query = core_title, desc = "Core title"})
    end
    
    -- Base title
    table.insert(queries, {query = title, desc = "Base title"})
    
    -- Add AniList ID searches if we have them
    if seasonal_candidates then
        for _, candidate in ipairs(seasonal_candidates) do
            if candidate.anilist_id then
                table.insert(queries, {
                    query = "anilist:" .. candidate.anilist_id,
                    desc = "AniList ID: " .. candidate.anilist_id
                })
            end
        end
    end
    
    -- Season variations (from explicit season OR inferred from absolute episode)
    if season then
        table.insert(queries, {query = title .. " season " .. season, desc = "Title + season"})
        table.insert(queries, {query = title .. " " .. season .. "nd season", desc = "Title + Xnd season"})
        table.insert(queries, {query = title .. " " .. season .. "rd season", desc = "Title + Xrd season"})
        table.insert(queries, {query = title .. " " .. season .. "th season", desc = "Title + Xth season"})
        table.insert(queries, {query = title .. " part " .. season, desc = "Title + part"})
        table.insert(queries, {query = title .. " " .. season, desc = "Title + number"})
    else
        -- Add searches for inferred seasons (common Jimaku naming patterns)
        for s, _ in pairs(inferred_seasons) do
            table.insert(queries, {query = title .. " season " .. s, desc = "Title + inferred season " .. s})
            if s == 2 then
                table.insert(queries, {query = title .. " 2nd season", desc = "Title + 2nd season"})
            elseif s == 3 then
                table.insert(queries, {query = title .. " 3rd season", desc = "Title + 3rd season"})
            else
                table.insert(queries, {query = title .. " " .. s .. "th season", desc = "Title + " .. s .. "th season"})
            end
            table.insert(queries, {query = title .. " s" .. s, desc = "Title + S" .. s})
        end
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
        
        local url
        if query_data.query:match("^anilist:") then
            local anilist_id = query_data.query:match("anilist:(%d+)")
            url = JIMAKU_API_SEARCH .. "?anilist_id=" .. anilist_id .. "&anime=true"
        else
            url = JIMAKU_API_SEARCH .. "?query=" .. query_data.query:gsub(" ", "+") .. "&anime=true"
        end
        
        local entries = make_jimaku_request(url)
        
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
        local score, is_season_match = score_entry(entry, title, season, seasonal_candidates)
        if score > -500 then
            table.insert(scored_entries, {entry = entry, score = score, match = is_season_match})
            write_log("Entry: " .. (entry.name or "Unknown") .. " | Score: " .. score)
        end
    end
    table.sort(scored_entries, function(a, b) return a.score > b.score end)
    
    local all_candidates = {}
    
    -- Check top 5 entries
    local entries_to_check = math.min(5, #scored_entries)
    write_log("\nWill check top " .. entries_to_check .. " entries for files")
    
    for i = 1, entries_to_check do
        local item = scored_entries[i]
        write_log("\nChecking Entry " .. i .. "/" .. entries_to_check .. ": " .. (item.entry.name or "Unknown") .. " (score: " .. item.score .. ")")
        
        local files = make_jimaku_request(JIMAKU_API_DOWNLOAD .. "/" .. item.entry.id .. "/files")
        
        if files and #files > 0 then
            write_log("  Found " .. #files .. " files in this entry")
            local entry_scores = score_files(files, season, episode, item.match, seasonal_candidates, original_title)
            
            for _, c in ipairs(entry_scores) do
                table.insert(all_candidates, c)
            end
        else
            write_log("  No files found or API error")
        end
    end
    
    table.sort(all_candidates, function(a, b) return a.score > b.score end)
    
    write_log("\n--- RANKED FILES (Top " .. math.min(10, #all_candidates) .. ") ---")
    for i = 1, math.min(10, #all_candidates) do
        write_log(i .. ". [Score: " .. all_candidates[i].score .. "] " .. all_candidates[i].file.name)
    end

    -- Smart filter: prioritize files with AniList-verified matches
    if #all_candidates > 0 then
        local anilist_matches = {}
        local other_matches = {}
        
        for _, c in ipairs(all_candidates) do
            local f_season, f_episode = parse_subtitle_filename(c.file.name)
            local is_anilist_match = false
            
            -- Check if this matches an AniList candidate
            if seasonal_candidates and f_season and f_episode then
                for _, candidate in ipairs(seasonal_candidates) do
                    if candidate.source == "anilist" and f_season == candidate.season and f_episode == candidate.episode then
                        is_anilist_match = true
                        break
                    end
                end
            end
            
            if is_anilist_match then
                table.insert(anilist_matches, c)
            else
                table.insert(other_matches, c)
            end
        end
        
        if #anilist_matches > 0 then
            all_candidates = anilist_matches
            write_log("Smart Filter: Kept " .. #all_candidates .. " AniList-verified matches")
        elseif all_candidates[1].score >= 2000 then
            local filtered = {}
            for _, c in ipairs(all_candidates) do
                if c.score >= 2000 then
                    table.insert(filtered, c)
                end
            end
            if #filtered > 0 then
                all_candidates = filtered
                write_log("Smart Filter: Kept " .. #all_candidates .. " high-scoring matches")
            end
        end
    end

    -- Select best files with fallback
    local final_files = {}
    local seen_urls = {}
    
    for _, item in ipairs(all_candidates) do
        if #final_files >= JIMAKU_MAX_SUBS then break end
        if not seen_urls[item.file.url] then
            -- Skip archive files (they're not subtitles)
            local fname_lower = item.file.name:lower()
            if not (fname_lower:match("%.7z$") or fname_lower:match("%.zip$") or fname_lower:match("%.rar$")) then
                if item.score > 0 or #final_files == 0 then
                    table.insert(final_files, item.file)
                    seen_urls[item.file.url] = true
                end
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

-- Initialize AniList cache
load_anilist_cache()

mp.register_event("file-loaded", auto_load_subs)
mp.add_key_binding("Ctrl+j", "jimaku-search", auto_load_subs)