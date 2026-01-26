-- AniList Filename Parser for SubsPlease releases
-- Reads from subsplease-entries-torrent-entries.txt and parses filenames

-- Open debug log file
local debug_log = io.open("parser_debug.log", "w")

local function log(message)
    if debug_log then
        debug_log:write(os.date("%Y-%m-%d %H:%M:%S") .. " - " .. message .. "\n")
        debug_log:flush()
    end
    print(message)
end

-- Helper to extract content inside brackets/parentheses if strict match fails
local function extract_hash(str)
    if not str then return "N/A" end
    local h = str:match("%[([%x]+)%]")
    return h or "N/A"
end

-- Parse a filename
local function parse_filename(filename)
    log("Parsing: " .. filename)
    
    local title, episode, version, quality, hash
    local release_group = "unknown"
    local raw_content
    
    -- 1. Extract Release Group and inner content (stripping .mkv)
    -- Matches: [Group] Content.mkv
    local group_match, content_match = filename:match("^%[([^%]]+)%]%s+(.+)%.mkv$")
    
    if not group_match then
        -- Try without .mkv if input list is different
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

    -- 2. Define Patterns
    -- We use a more permissive approach now.
    -- Episode part: matches digits, dots, v-tags, +, -, (), and spaces.
    -- Example: "01", "01v2", "01+02", "(01-04)", "SP"
    local ep_pattern = "([%w%.%+%-%(%)%s]+)" 
    
    -- Attempt 1: Standard "Title - Episode (Quality) [Hash]" (SubsPlease style)
    -- Note: We make the hash part optional/flexible
    title, episode, quality, hash = raw_content:match("^(.-)%s+%-%s+" .. ep_pattern .. "%s+%((%d+p)%)%s*(.*)$")
    
    if title then
        -- Check for version in episode string
        local v_tag = episode:match("(v%d+)")
        if v_tag then
            version = v_tag
            -- Clean version from episode if needed, but keeping it usually helps distinctness
        else
            version = "v1"
        end
        hash = extract_hash(hash)
        log("  DEBUG: Matched Standard Style (Type A)")
    end

    -- Attempt 2: Standard "Title - Episode [Quality]..." (HorribleSubs/Generic style)
    if not title then
        -- Matches: Title - Episode [Quality] OR Title - Episode [Quality][Hash]
        title, episode, quality, hash = raw_content:match("^(.-)%s+%-%s+" .. ep_pattern .. "%s+%[(%d+p)%]%s*(.*)$")
        
        if title then
            local v_tag = episode:match("(v%d+)")
            version = v_tag or "v1"
            hash = extract_hash(hash)
            log("  DEBUG: Matched Standard Style (Type B)")
        end
    end

    -- Attempt 3: Title Only / Movie "Title [Quality]" (No " - Episode" separator)
    if not title then
        -- Matches: Hanamonogatari [1080p]
        title, quality = raw_content:match("^(.-)%s+%[(%d+p)%]%s*$")
        if title then
            episode = "1" -- Default to 1 for movies/specials without numbers
            version = "v1"
            hash = "N/A"
            log("  DEBUG: Matched Title-Only Style")
        end
    end

    -- Failed to parse
    if not title then
        log("  ERROR: Failed to parse filename (unsupported format)")
        -- Debugging help
        local t_debug, e_debug = raw_content:match("^(.-)%s+%-%s+(.+)")
        if t_debug then
             log("  DEBUG: Split found -> Title: " .. t_debug .. " | Rest: " .. e_debug)
        end
        return nil
    end
    
    -- Post-Processing Episode String
    -- If episode is complex (e.g., "(01-04)"), clean it up for better sorting
    local clean_episode = episode
    -- Remove outer parens if present
    if clean_episode:match("^%b()$") then
        clean_episode = clean_episode:sub(2, -2)
    end
    
    -- Construct Result
    local parsed = {
        original_filename = filename,
        release_group = release_group,
        title = title,
        episode = clean_episode, 
        version = version,
        quality = quality,
        hash = hash
    }
    
    -- Detect season information
    local season_patterns = {
        {pattern = "(.-)%s+S(%d+)$"},
        {pattern = "(.-)%s+Season%s+(%d+)$"},
        {pattern = "(.-)%s+(%d)nd%s+Season$"},
        {pattern = "(.-)%s+(%d)rd%s+Season$"},
        {pattern = "(.-)%s+(%d)th%s+Season$"}
    }
    
    parsed.base_title = title
    parsed.season = nil
    
    for _, sp in ipairs(season_patterns) do
        local base, season = title:match(sp.pattern)
        if base and season then
            parsed.base_title = base
            parsed.season = tonumber(season)
            log("  Detected season: " .. season)
            break
        end
    end
    
    -- Clean up title for AniList search
    parsed.search_title = parsed.base_title
        :gsub("%s+%-.*$", "") 
        :gsub("%s+%b()", "") 
        :gsub("%s+", " ") 
        :gsub("^%s+", "") 
        :gsub("%s+$", "") 
    
    log(string.format("  Release Group: %s", tostring(parsed.release_group)))
    log(string.format("  Title: %s", tostring(parsed.title)))
    log(string.format("  Episode: %s", tostring(parsed.episode)))
    log(string.format("  Season: %s", parsed.season and tostring(parsed.season) or "none"))
    
    return parsed
end

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

local function count_table(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

local function process_files(filenames)
    log("=== Starting batch processing ===")
    local results = {}
    local unique_titles = {}
    
    for i, filename in ipairs(filenames) do
        log("\n--- File " .. i .. "/" .. #filenames .. " ---")
        local parsed = parse_filename(filename)
        
        if parsed then
            table.insert(results, parsed)
            local key = parsed.search_title .. (parsed.season and "_S" .. parsed.season or "")
            if not unique_titles[key] then
                unique_titles[key] = {
                    search_title = parsed.search_title,
                    season = parsed.season,
                    episodes = {}
                }
            end
            table.insert(unique_titles[key].episodes, parsed.episode)
        end
    end
    
    log("\n=== Processing Summary ===")
    log("Successfully parsed: " .. #results .. " files")
    log("Unique titles: " .. count_table(unique_titles))
    
    local sorted_keys = {}
    for key in pairs(unique_titles) do table.insert(sorted_keys, key) end
    table.sort(sorted_keys)
    
    for _, key in ipairs(sorted_keys) do
        local data = unique_titles[key]
        -- Custom sort to handle mixed numbers, strings, and ranges
        table.sort(data.episodes, function(a, b)
            -- Extract first number from strings like "01+02" or "(01-04)"
            local a_clean = a:match("(%d+)") or 0
            local b_clean = b:match("(%d+)") or 0
            local a_num = tonumber(a_clean)
            local b_num = tonumber(b_clean)
            
            if a_num and b_num and a_num ~= b_num then 
                return a_num < b_num 
            end
            return tostring(a) < tostring(b)
        end)
        
        log(string.format("Title: %s%s", 
            data.search_title, 
            data.season and " (Season " .. data.season .. ")" or ""))
        -- Use %s for episodes in summary to support "SP", "01+02"
        log(string.format("  Episodes: %s ... %s (%d total)", 
            tostring(data.episodes[1]), 
            tostring(data.episodes[#data.episodes]),
            #data.episodes))
    end
    
    return results, unique_titles
end

local function main()
    log("=== AniList Filename Parser ===")
    local input_file = "subsplease-entries-torrent-entries.txt"
    local filenames = read_filenames(input_file)
    if not filenames then return end
    
    local results, unique_titles = process_files(filenames)
    log("\n=== Complete ===")
    if debug_log then debug_log:close() end
end

main()