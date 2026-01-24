-- Enhanced AniList Filename Parser for SubsPlease releases
-- Improved based on Sonarr parser patterns

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

-- Detect if title contains reversed patterns (from Sonarr)
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

-- Parse version tag from episode string
local function extract_version(episode_str)
    local version = episode_str:match("(v%d+)")
    if version then
        -- Remove version from episode string
        local clean_ep = episode_str:gsub("v%d+", ""):gsub("^%s+", ""):gsub("%s+$", "")
        return version, clean_ep
    end
    return "v1", episode_str
end

-- Parse episode range (e.g., "01-04", "01+02")
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
    
    -- Handle multi-episode: 01+02 or 01E02
    for ep in episode_str:gmatch("(%d+)") do
        table.insert(episodes, ep)
    end
    
    return #episodes > 0 and episodes or {episode_str}
end

-- Clean episode string (remove parentheses, etc.)
local function clean_episode(episode_str)
    -- Remove outer parentheses
    episode_str = episode_str:gsub("^%((.-)%)$", "%1")
    
    -- Remove extra spaces
    episode_str = episode_str:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    
    return episode_str
end

-- Extract absolute episode number patterns (like Sonarr)
local function extract_absolute_episode(str)
    -- Pattern: " - 01" or " - 001"
    local abs = str:match("%s%-%s(%d%d%d?)%s")
    if abs then return abs end
    
    -- Pattern: Episode 01
    abs = str:match("[Ee]pisode%s+(%d%d%d?)")
    if abs then return abs end
    
    return nil
end

-- Detect special episodes
local function is_special(episode_str, content)
    if episode_str:lower():match("sp") or 
       episode_str:lower():match("special") or
       episode_str:lower():match("ova") or
       episode_str:lower():match("ovd") then
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
    
    -- Check for reversed title
    filename = maybe_reverse(filename)
    
    local title, episode, version, quality, hash
    local release_group = "unknown"
    local raw_content
    local is_special_ep = false
    local absolute_episode = nil
    
    -- 1. Extract Release Group and inner content
    local group_match, content_match = filename:match("^%[([^%]]+)%]%s+(.+)%.mkv$")
    
    if not group_match then
        group_match, content_match = filename:match("^%[([^%]]+)%]%s+(.+)$")
    end
    
    if group_match then
        release_group = group_match
        raw_content = content_match
        log("  DEBUG: Group: " .. group_match .. " | Content: " .. content_match)
    else
        log("  ERROR: Could not extract release group")
        return nil
    end

    -- 2. Check for absolute episode patterns first (Sonarr-style)
    absolute_episode = extract_absolute_episode(raw_content)
    if absolute_episode then
        log("  DEBUG: Found absolute episode: " .. absolute_episode)
    end

    -- 3. Pattern matching attempts (ordered by specificity)
    
    -- Attempt 1: [SubGroup] Title - AbsoluteEp (SeasonEp) (Quality) [Hash]
    -- Example: [SubsPlease] Title - 01 (S01E01) (1080p) [HASH]
    title, episode, quality, hash = raw_content:match("^(.-)%s+%-%s+(%d+)%s+%(S%d+E%d+%)%s+%((%d+p)%)%s*(.*)$")
    
    if title then
        version, episode = extract_version(episode)
        hash = extract_hash(hash)
        log("  DEBUG: Matched Absolute+Season Style")
    end
    
    -- Attempt 2: Standard "Title - Episode (Quality) [Hash]"
    if not title then
        title, episode, quality, hash = raw_content:match("^(.-)%s+%-%s+([%w%.%+%-%(%)%s]+)%s+%((%d+p)%)%s*(.*)$")
        
        if title then
            version, episode = extract_version(episode)
            episode = clean_episode(episode)
            hash = extract_hash(hash)
            log("  DEBUG: Matched Standard Style (Type A)")
        end
    end

    -- Attempt 3: Standard "Title - Episode [Quality]"
    if not title then
        title, episode, quality, hash = raw_content:match("^(.-)%s+%-%s+([%w%.%+%-%(%)%s]+)%s+%[(%d+p)%]%s*(.*)$")
        
        if title then
            version, episode = extract_version(episode)
            episode = clean_episode(episode)
            hash = extract_hash(hash)
            log("  DEBUG: Matched Standard Style (Type B)")
        end
    end

    -- Attempt 4: Title Only / Movie "Title [Quality]"
    if not title then
        title, quality = raw_content:match("^(.-)%s+%[(%d+p)%]%s*$")
        if title then
            episode = "1"
            version = "v1"
            hash = "N/A"
            log("  DEBUG: Matched Title-Only Style (Movie/Special)")
        end
    end
    
    -- Attempt 5: Batch releases "Title - 01~12 [Quality]"
    if not title then
        local ep_range
        title, ep_range, quality = raw_content:match("^(.-)%s+%-%s+(%d+%s?~%s?%d+)%s+%[(%d+p)%]")
        if title and ep_range then
            episode = ep_range:gsub("~", "-") -- Normalize to dash
            version = "v1"
            hash = "N/A"
            log("  DEBUG: Matched Batch Style")
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
    
    -- Check if this is a special episode
    is_special_ep = is_special(episode, raw_content)
    
    -- Construct Result
    local parsed = {
        original_filename = filename,
        release_group = release_group,
        title = normalize_title(title),
        raw_title = title,
        episode = episode,
        episode_list = parse_episode_range(episode),
        absolute_episode = absolute_episode,
        version = version,
        quality = quality,
        hash = hash,
        is_special = is_special_ep
    }
    
    -- Season detection patterns (Sonarr-inspired)
    local season_patterns = {
        {pattern = "(.-)%s+S(%d+)$", name = "S##"},
        {pattern = "(.-)%s+Season%s+(%d+)$", name = "Season ##"},
        {pattern = "(.-)%s+(%d)nd%s+Season$", name = "2nd Season"},
        {pattern = "(.-)%s+(%d)rd%s+Season$", name = "3rd Season"},
        {pattern = "(.-)%s+(%d)th%s+Season$", name = "4th Season"},
        {pattern = "(.-)%s+Part%s+(%d+)$", name = "Part ##"}
    }
    
    parsed.base_title = parsed.title
    parsed.season = nil
    
    for _, sp in ipairs(season_patterns) do
        local base, season = parsed.title:match(sp.pattern)
        if base and season then
            parsed.base_title = normalize_title(base)
            parsed.season = tonumber(season)
            log("  DEBUG: Detected season " .. season .. " (pattern: " .. sp.name .. ")")
            break
        end
    end
    
    -- Clean up title for AniList search (Sonarr-style cleaning)
    parsed.search_title = parsed.base_title
        :gsub("%s+%-.*$", "")        -- Remove trailing dash content
        :gsub("%s+%b()", "")          -- Remove parenthetical content
        :gsub("%s+%b[]", "")          -- Remove bracketed content
        :gsub("%s+", " ")             -- Normalize spaces
        :gsub("^%s+", "")             -- Trim start
        :gsub("%s+$", "")             -- Trim end
    
    -- Log results
    log(string.format("  Release Group: %s", parsed.release_group))
    log(string.format("  Title: %s", parsed.title))
    log(string.format("  Base Title: %s", parsed.base_title))
    log(string.format("  Search Title: %s", parsed.search_title))
    log(string.format("  Episode: %s (%d episodes)", parsed.episode, #parsed.episode_list))
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
        log("\n--- File " .. i .. "/" .. #filenames .. " ---")
        local parsed = parse_filename(filename)
        
        if parsed then
            table.insert(results, parsed)
            
            -- Build unique key
            local key = parsed.search_title .. (parsed.season and "_S" .. parsed.season or "")
            
            if not unique_titles[key] then
                unique_titles[key] = {
                    search_title = parsed.search_title,
                    season = parsed.season,
                    episodes = {},
                    is_special = parsed.is_special
                }
            end
            
            -- Add all episodes from episode list
            for _, ep in ipairs(parsed.episode_list) do
                table.insert(unique_titles[key].episodes, ep)
            end
        else
            parse_failures = parse_failures + 1
        end
    end
    
    log("\n=== Processing Summary ===")
    log("Successfully parsed: " .. #results .. " files")
    log("Failed to parse: " .. parse_failures .. " files")
    log("Unique titles: " .. count_table(unique_titles))
    
    -- Sort and display unique titles
    local sorted_keys = {}
    for key in pairs(unique_titles) do table.insert(sorted_keys, key) end
    table.sort(sorted_keys)
    
    for _, key in ipairs(sorted_keys) do
        local data = unique_titles[key]
        
        -- Custom sort for episodes
        table.sort(data.episodes, function(a, b)
            local a_num = tonumber(a:match("(%d+)")) or 0
            local b_num = tonumber(b:match("(%d+)")) or 0
            
            if a_num ~= b_num then 
                return a_num < b_num 
            end
            return tostring(a) < tostring(b)
        end)
        
        -- Remove duplicates
        local unique_eps = {}
        local seen = {}
        for _, ep in ipairs(data.episodes) do
            if not seen[ep] then
                table.insert(unique_eps, ep)
                seen[ep] = true
            end
        end
        
        log(string.format("\nTitle: %s%s%s", 
            data.search_title, 
            data.season and " (Season " .. data.season .. ")" or "",
            data.is_special and " [SPECIAL]" or ""))
        log(string.format("  Episodes: %s ... %s (%d total)", 
            unique_eps[1], 
            unique_eps[#unique_eps],
            #unique_eps))
    end
    
    return results, unique_titles
end

-- Main execution
local function main()
    log("=== Enhanced AniList Filename Parser ===")
    log("Based on Sonarr parser patterns\n")
    
    local input_file = "subsplease-entries-torrent-entries.txt"
    local filenames = read_filenames(input_file)
    if not filenames then return end
    
    local results, unique_titles = process_files(filenames)
    
    log("\n=== Complete ===")
    if debug_log then debug_log:close() end
end

main()