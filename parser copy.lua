-- Enhanced AniList Filename Parser for Anime releases
-- Improved based on Sonarr parser patterns and real-world data

-- CONFIGURATION
local LOG_ONLY_ERRORS = false -- Set to true to suppress successful parse logs
local INPUT_FILE = "torrents.txt"
local DEBUG_LOG_PATH = "parser_debug.log"

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