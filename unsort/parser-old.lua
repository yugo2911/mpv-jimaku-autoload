-- Enhanced AniList Filename Parser for Anime releases
-- Improved based on Sonarr parser patterns and real-world data

-- Open debug log file
local debug_log = io.open("parser_debug.log", "w")

local function log(message)
    if debug_log then
        debug_log:write(os.date("%Y-%m-%d %H:%M:%S") .. " - " .. message .. "\n")
        debug_log:flush()
    end
    print(message)
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
    
    -- Pattern: (1080p), [1080p], 1080p, or resolution like 1920x1080
    local q = str:match("%((%d%d%d%d?p)%)") or 
              str:match("%[(%d%d%d%d?p)%]") or
              str:match("(%d%d%d%d?p)") or
              str:match("(%d%d%d%dx%d%d%d%d)")
    
    return q or "unknown"
end

-- Normalize title by removing common patterns
local function normalize_title(title)
    if not title then return "" end
    
    -- Replace common separators with spaces
    title = title:gsub("[%._]", " ")
    
    -- Remove multiple spaces
    title = title:gsub("%s+", " ")
    
    -- Trim
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
        log("  DEBUG: Detected reversed title, reversing...")
        local chars = {}
        for i = #str, 1, -1 do
            table.insert(chars, str:sub(i, i))
        end
        return table.concat(chars)
    end
    return str
end

-- Parse version tag from episode string or content
local function extract_version(episode_str, content)
    local version = episode_str:match("(v%d+)") or (content and content:match("(v%d+)"))
    if version then
        local clean_ep = episode_str:gsub("v%d+", ""):gsub("^%s+", ""):gsub("%s+$", "")
        return version, clean_ep
    end
    return "v1", episode_str
end

-- Parse episode range
local function parse_episode_range(episode_str)
    local episodes = {}
    
    -- Handle ranges: 01-04
    local start_ep, end_ep = episode_str:match("(%d+)%-(%d+)")
    if start_ep and end_ep then
        local s, e = tonumber(start_ep), tonumber(end_ep)
        for i = s, e do
            table.insert(episodes, string.format("%02d", i))
        end
        return episodes
    end
    
    -- Handle comma-separated: 07,10 or 01,02,03
    if episode_str:match(",") then
        for ep in episode_str:gmatch("(%d+)") do
            table.insert(episodes, ep)
        end
        return episodes
    end
    
    -- Handle multi-episode: 01+02 or 01E02
    for ep in episode_str:gmatch("(%d+)") do
        table.insert(episodes, ep)
    end
    
    return #episodes > 0 and episodes or {episode_str}
end

-- Clean episode string
local function clean_episode(episode_str)
    episode_str = episode_str:gsub("^%((.-)%)$", "%1")
    episode_str = episode_str:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return episode_str
end

-- Extract absolute episode number
local function extract_absolute_episode(str)
    local abs = str:match("%s%-%s(%d%d%d?)%s") or
                str:match("[Ee]pisode%s+(%d%d%d?)")
    return abs
end

-- Detect special episodes
local function is_special(episode_str, content)
    if episode_str and (episode_str:lower():match("sp") or 
       episode_str:lower():match("special") or
       episode_str:lower():match("ova") or
       episode_str:lower():match("ovd")) then
        return true
    end
    
    if content and (content:lower():match("special") or 
                    content:lower():match("ova") or 
                    content:lower():match("ovd")) then
        return true
    end
    
    return false
end

-- Parse a filename with multiple pattern attempts
local function parse_filename(filename)
    log("Parsing: " .. filename)
    
    filename = maybe_reverse(filename)
    
    local title, episode, season, version, quality, hash
    local release_group = "unknown"
    local raw_content
    local is_special_ep = false
    local absolute_episode = nil
    
    -- 1. Strip file extension only (mkv, mp4, avi, ts, etc.)
    filename = filename:gsub("%.mkv$", ""):gsub("%.mp4$", ""):gsub("%.avi$", ""):gsub("%.ts$", ""):gsub("%.m4v$", "")
    
    -- 2. Extract Release Group and inner content (optional group)
    local group_match, content_match = filename:match("^%[([^%]]+)%]%s+(.+)$")
    
    -- Handle files without release group in brackets
    if not group_match then
        content_match = filename
        release_group = "unknown"
        log("  DEBUG: No release group found | Content: " .. content_match)
    else
        release_group = group_match
        raw_content = content_match
        log("  DEBUG: Group: " .. group_match .. " | Content: " .. content_match)
    end
    
    raw_content = raw_content or content_match

    -- Check for absolute episode patterns
    absolute_episode = extract_absolute_episode(raw_content)
    if absolute_episode then
        log("  DEBUG: Found absolute episode: " .. absolute_episode)
    end

    -- Pattern matching attempts (ordered by specificity)
    
    -- Pattern: Title S## v# [Quality]
    if not title then
        local ver
        title, season, ver = raw_content:match("^(.-)%s+S(%d+)%s+(v%d+)%s+%[")
        if title and season then
            episode = "SEASON"
            version = ver or "v1"
            quality = extract_quality(raw_content)
            hash = "N/A"
            log("  DEBUG: Matched Season Pack with Version")
        end
    end
    
    -- Pattern: Title.With.Dots.S##E##.More.Info (dot-separated)
    if not title then
        title, season, episode = raw_content:match("^(.-)%.S(%d+)E(%d+)%.")
        if title and season and episode then
            title = title:gsub("%.", " ")
            version = "v1"
            quality = extract_quality(raw_content)
            hash = "N/A"
            log("  DEBUG: Matched Dot-Separated S##E##")
        end
    end
    
    -- Pattern: Title S##E## [Quality] | Alt Title
    if not title then
        title, season, episode = raw_content:match("^(.-)%s+S(%d+)E(%d+)%s+%[")
        if title and season and episode then
            version = "v1"
            quality = extract_quality(raw_content)
            hash = "N/A"
            log("  DEBUG: Matched S##E## [Quality] | Alt Title")
        end
    end
    
    -- Pattern: Title - S##E## [Quality]
    if not title then
        title, season, episode = raw_content:match("^(.-)%s+%-%s+S(%d+)E(%d+)%s+%[")
        if title and season and episode then
            version = "v1"
            quality = extract_quality(raw_content)
            hash = "N/A"
            log("  DEBUG: Matched Title - S##E## [Quality]")
        end
    end
    
    -- Pattern: Title - S##E## (Quality)
    if not title then
        title, season, episode = raw_content:match("^(.-)%s+%-%s+S(%d+)E(%d+)%s+%(")
        if title and season and episode then
            version = "v1"
            quality = extract_quality(raw_content)
            hash = "N/A"
            log("  DEBUG: Matched Title - S##E## (Quality)")
        end
    end
    
    -- Pattern: Title S##E## followed by quality (no brackets)
    if not title then
        title, season, episode = raw_content:match("^(.-)%s+S(%d+)E(%d+)%s+%d+p")
        if title and season and episode then
            version = "v1"
            quality = extract_quality(raw_content)
            hash = "N/A"
            log("  DEBUG: Matched Title S##E## Quality (no dash/brackets)")
        end
    end
    
    -- Pattern: Title S##E## (no quality, just S##E##)
    if not title then
        title, season, episode = raw_content:match("^(.-)%s+S(%d+)E(%d+)%s")
        if title and season and episode then
            version = "v1"
            quality = extract_quality(raw_content)
            hash = "N/A"
            log("  DEBUG: Matched Title S##E## (basic)")
        end
    end
    
    -- Pattern: Title S##E##v# [Quality] (with version)
    if not title then
        local ver
        title, season, episode, ver = raw_content:match("^(.-)%s+S(%d+)E(%d+)(v%d+)%s+%[")
        if title and season and episode then
            version = ver or "v1"
            quality = extract_quality(raw_content)
            hash = extract_hash(raw_content)
            log("  DEBUG: Matched Title S##E##v# [Quality]")
        end
    end
    
    -- Pattern: Title S## (Season Pack with quality in parentheses)
    if not title then
        title, season = raw_content:match("^(.-)%s+S(%d+)%s+%(")
        if title and season then
            episode = "SEASON"
            version = "v1"
            quality = extract_quality(raw_content)
            hash = "N/A"
            log("  DEBUG: Matched Title S## (Quality) Season Pack")
        end
    end
    
    -- Pattern: Title S# - Episode (SubsPlease style)
    if not title then
        local s_num, ep_num
        title, s_num, ep_num, quality, hash = raw_content:match("^(.-)%s+S(%d+)%s+%-%s+(%d+)%s+%((%d+p)%)%s*(.*)$")
        if title and s_num and ep_num then
            season = s_num
            episode = ep_num
            version = "v1"
            hash = extract_hash(hash)
            log("  DEBUG: Matched SubsPlease S# - Episode Style")
        end
    end
    
    -- Pattern: Title - Episode (Quality) [Hash]
    if not title then
        title, episode, quality, hash = raw_content:match("^(.-)%s+%-%s+(%d+)%s+%((%d+p)%)%s*(.*)$")
        if title then
            version, episode = extract_version(episode, raw_content)
            episode = clean_episode(episode)
            hash = extract_hash(hash)
            log("  DEBUG: Matched Title - Episode (Quality)")
        end
    end

    -- Pattern: Title - Subtitle Nth Season - Episode [Quality]
    if not title then
        local full_title, season_num, ep, ver
        full_title, season_num, ep, ver = raw_content:match("^(.-)%s+(%d)%w%w%s+Season%s+%-%s+(%d+)(v%d*)%s")
        if full_title and season_num and ep then
            title = full_title
            season = season_num
            episode = ep
            version = ver ~= "" and ver or "v1"
            quality = extract_quality(raw_content)
            hash = extract_hash(raw_content)
            log("  DEBUG: Matched Title - Subtitle Nth Season - Episode")
        end
    end
    
    -- Pattern: Title - Subtitle - Episode - Subtitle [Group] (multi-dash)
    if not title then
        local full_title, ep
        full_title, ep = raw_content:match("^(.-)%s+%-%s+(%d+)%s+%-%s+.-%s+%[")
        if full_title and ep then
            title = full_title
            episode = ep
            version = "v1"
            quality = extract_quality(raw_content)
            hash = extract_hash(raw_content)
            log("  DEBUG: Matched Title - Subtitle - Episode - Subtitle [Group]")
        end
    end
    
    -- Pattern: Title TV Episode,Episode [Group] (comma-separated episodes)
    if not title then
        title, episode = raw_content:match("^(.-)%s+TV%s+([%d,]+)%s+%[")
        if title and episode then
            version = "v1"
            quality = extract_quality(raw_content)
            hash = extract_hash(raw_content)
            log("  DEBUG: Matched Title TV Episode,Episode [Group]")
        end
    end
    
    -- Pattern: Title Episode,Episode [Group] (comma-separated episodes without TV)
    if not title then
        title, episode = raw_content:match("^(.-)%s+([%d,]+)%s+%[")
        if title and episode and episode:match(",") then
            version = "v1"
            quality = extract_quality(raw_content)
            hash = extract_hash(raw_content)
            log("  DEBUG: Matched Title Episode,Episode [Group]")
        end
    end

    -- Pattern: Title - Episode [Quality complex info]
    if not title then
        title, episode = raw_content:match("^(.-)%s+%-%s+(%d+)%s+%[")
        if title and episode then
            version, episode = extract_version(episode, raw_content)
            episode = clean_episode(episode)
            quality = extract_quality(raw_content)
            hash = extract_hash(raw_content)
            log("  DEBUG: Matched Title - Episode [Quality complex]")
        end
    end

    -- Pattern: Title - Episode [Quality]
    if not title then
        title, episode, quality, hash = raw_content:match("^(.-)%s+%-%s+(%d+)%s+%[(%d+p)%]%s*(.*)$")
        if title then
            version, episode = extract_version(episode, raw_content)
            episode = clean_episode(episode)
            hash = extract_hash(hash)
            log("  DEBUG: Matched Title - Episode [Quality]")
        end
    end
    
    -- Pattern: Title - Movie [Quality] or Title - Movie
    if not title then
        title = raw_content:match("^(.-)%s+%-%s+Movie")
        if title then
            episode = "1"
            version = "v1"
            quality = extract_quality(raw_content)
            hash = extract_hash(raw_content)
            log("  DEBUG: Matched Title - Movie")
        end
    end
    
    -- Pattern: Title - Episode (quality info without p)
    if not title then
        title, episode = raw_content:match("^(.-)%s+%-%s+(%d+)%s+%(")
        if title and episode then
            version = "v1"
            quality = extract_quality(raw_content)
            hash = "N/A"
            log("  DEBUG: Matched Title - Episode (quality info)")
        end
    end
    
    -- Pattern: Title - Episode-Episode (range)
    if not title then
        title, episode = raw_content:match("^(.-)%s+%-%s+(%d+%-%d+)")
        if title and episode then
            version = "v1"
            quality = extract_quality(raw_content)
            hash = "N/A"
            log("  DEBUG: Matched Title - Episode Range")
        end
    end

    -- Pattern: Title [Quality]
    if not title then
        title, quality = raw_content:match("^(.-)%s+%[(%d+p)%]%s*$")
        if title then
            episode = "1"
            version = "v1"
            hash = "N/A"
            log("  DEBUG: Matched Title [Quality] (Movie/Special)")
        end
    end
    
    -- Pattern: Batch releases with tilde
    if not title then
        local ep_range
        title, ep_range = raw_content:match("^(.-)%s+%-%s+(%d+%s?~%s?%d+)")
        if title and ep_range then
            episode = ep_range:gsub("~", "-")
            version = "v1"
            quality = extract_quality(raw_content)
            hash = "N/A"
            log("  DEBUG: Matched Batch Style")
        end
    end

    -- Pattern: Title (Quality) [Hash] (no episode number - movie/special)
    if not title then
        title = raw_content:match("^(.-)%s+%((%d+p)%)%s+%[")
        if title then
            episode = "1"
            version = "v1"
            quality = extract_quality(raw_content)
            hash = extract_hash(raw_content)
            log("  DEBUG: Matched Title (Quality) [Hash] - Movie/Special")
        end
    end
    
    -- Pattern: Title.With.Dots.Year.Quality.Info-Group (movie style)
    if not title then
        local year
        title, year = raw_content:match("^(.-)%.(%d%d%d%d)%.")
        if title and year then
            title = title:gsub("%.", " ")
            episode = "1"
            version = "v1"
            quality = extract_quality(raw_content)
            hash = "N/A"
            log("  DEBUG: Matched Movie Style (Dots with Year)")
        end
    end
    
    -- Failed to parse
    if not title then
        log("  ERROR: Failed to parse filename (unsupported format)")
        local t_debug, e_debug = raw_content:match("^(.-)%s+%-%s+(.+)")
        if t_debug then
            log("  DEBUG: Split found -> Title: " .. t_debug .. " | Rest: " .. e_debug)
        end
        return nil
    end
    
    -- Extract season from title if not found
    if not season then
        season = title:match("S(%d+)E%d+") or title:match("Season%s+(%d+)")
    end
    
    -- Check if special episode
    is_special_ep = is_special(episode, raw_content)
    
    -- Construct Result
    local parsed = {
        original_filename = filename,
        release_group = release_group,
        title = normalize_title(title),
        raw_title = title,
        episode = episode or "unknown",
        episode_list = episode and parse_episode_range(episode) or {},
        absolute_episode = absolute_episode,
        season = season and tonumber(season),
        version = version or "v1",
        quality = quality,
        hash = hash or "N/A",
        is_special = is_special_ep,
        is_season_pack = (episode == "SEASON")
    }
    
    -- Season detection patterns
    local season_patterns = {
        {pattern = "(.-)%s+S(%d+)$", name = "S##"},
        {pattern = "(.-)%s+Season%s+(%d+)$", name = "Season ##"},
        {pattern = "(.-)%s+(%d)nd%s+Season", name = "2nd Season"},
        {pattern = "(.-)%s+(%d)rd%s+Season", name = "3rd Season"},
        {pattern = "(.-)%s+(%d)th%s+Season", name = "4th Season"},
        {pattern = "(.-)%s+Part%s+(%d+)$", name = "Part ##"}
    }
    
    parsed.base_title = parsed.title
    
    -- Only detect season in title if not already found
    if not parsed.season then
        for _, sp in ipairs(season_patterns) do
            local base, sea = parsed.title:match(sp.pattern)
            if base and sea then
                parsed.base_title = normalize_title(base)
                parsed.season = tonumber(sea)
                log("  DEBUG: Detected season " .. sea .. " in title (pattern: " .. sp.name .. ")")
                break
            end
        end
    else
        -- Remove season notation from title
        parsed.base_title = parsed.title:gsub("%s+S%d+E%d+", "")
                                       :gsub("%s+S%d+", "")
                                       :gsub("%s+Season%s+%d+", "")
                                       :gsub("%s+%dnd%s+Season", "")
                                       :gsub("%s+%drd%s+Season", "")
                                       :gsub("%s+%dth%s+Season", "")
        parsed.base_title = normalize_title(parsed.base_title)
    end
    
    -- Clean up title for search
    parsed.search_title = parsed.base_title
        :gsub("%s+%-.*$", "")
        :gsub("%s+%b()", "")
        :gsub("%s+%b[]", "")
        :gsub("%s+|.*$", "")
        :gsub("%s+/.*$", "")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    
    -- Log results
    log(string.format("  Release Group: %s", parsed.release_group))
    log(string.format("  Title: %s", parsed.title))
    log(string.format("  Base Title: %s", parsed.base_title))
    log(string.format("  Search Title: %s", parsed.search_title))
    if parsed.is_season_pack then
        log(string.format("  Season Pack: Season %s", parsed.season or "?"))
    else
        log(string.format("  Episode: %s (%d episodes)", parsed.episode, #parsed.episode_list))
    end
    if parsed.absolute_episode then
        log(string.format("  Absolute Episode: %s", parsed.absolute_episode))
    end
    log(string.format("  Season: %s", parsed.season and tostring(parsed.season) or "none"))
    log(string.format("  Version: %s", parsed.version))
    log(string.format("  Quality: %s", parsed.quality))
    log(string.format("  Special: %s", tostring(parsed.is_special)))
    
    return parsed
end

-- Read filenames from file
local function read_filenames(filepath)
    log("Reading file: " .. filepath)
    local file = io.open(filepath, "r")
    if not file then
        log("ERROR: Cannot open file: " .. filepath)
        return nil
    end
    
    local filenames = {}
    for line in file:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            table.insert(filenames, line)
        end
    end
    file:close()
    log("Read " .. #filenames .. " lines from file")
    return filenames
end

-- Count table entries
local function count_table(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- Process all files
local function process_files(filenames)
    log("=== Starting batch processing ===")
    local results = {}
    local unique_titles = {}
    local parse_failures = 0
    
    for i, filename in ipairs(filenames) do
        log("--- File " .. i .. "/" .. #filenames .. " ---")
        local parsed = parse_filename(filename)
        
        if parsed then
            table.insert(results, parsed)
            
            local key = parsed.search_title .. (parsed.season and "_S" .. parsed.season or "")
            
            if not unique_titles[key] then
                unique_titles[key] = {
                    search_title = parsed.search_title,
                    season = parsed.season,
                    episodes = {},
                    is_special = parsed.is_special,
                    is_season_pack = parsed.is_season_pack
                }
            end
            
            if not parsed.is_season_pack then
                for _, ep in ipairs(parsed.episode_list) do
                    table.insert(unique_titles[key].episodes, ep)
                end
            end
        else
            parse_failures = parse_failures + 1
        end
    end
    
    log("=== Processing Summary ===")
    log("Successfully parsed: " .. #results .. " files")
    log("Failed to parse: " .. parse_failures .. " files")
    log("Unique titles: " .. count_table(unique_titles))
    log(string.format("Success rate: %.1f%%", (#results / #filenames) * 100))
    
    -- Sort and display unique titles
    local sorted_keys = {}
    for key in pairs(unique_titles) do table.insert(sorted_keys, key) end
    table.sort(sorted_keys)
    
    for _, key in ipairs(sorted_keys) do
        local data = unique_titles[key]
        
        if data.is_season_pack then
            log(string.format("Title: %s%s [SEASON PACK]", 
                data.search_title, 
                data.season and " (Season " .. data.season .. ")" or ""))
        elseif #data.episodes > 0 then
            table.sort(data.episodes, function(a, b)
                local a_num = tonumber(a:match("(%d+)")) or 0
                local b_num = tonumber(b:match("(%d+)")) or 0
                
                if a_num ~= b_num then 
                    return a_num < b_num 
                end
                return tostring(a) < tostring(b)
            end)
            
            local unique_eps = {}
            local seen = {}
            for _, ep in ipairs(data.episodes) do
                if not seen[ep] then
                    table.insert(unique_eps, ep)
                    seen[ep] = true
                end
            end
            
            log(string.format("Title: %s%s%s", 
                data.search_title, 
                data.season and " (Season " .. data.season .. ")" or "",
                data.is_special and " [SPECIAL]" or ""))
            log(string.format("  Episodes: %s ... %s (%d total)", 
                unique_eps[1], 
                unique_eps[#unique_eps],
                #unique_eps))
        end
    end
    
    return results, unique_titles
end

-- Main execution
local function main()
    log("=== Enhanced AniList Filename Parser ===")
    log("Based on Sonarr parser patterns")
    
    local input_file = "torrents.txt"
    local filenames = read_filenames(input_file)
    if not filenames then return end
    
    local results, unique_titles = process_files(filenames)
    
    log("=== Complete ===")
    if debug_log then debug_log:close() end
end

main()