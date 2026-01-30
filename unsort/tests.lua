#!/usr/bin/env lua
--[[
    Jimaku Test Pipeline
    Tests filename parsing and episode matching logic
    
    Usage:
        lua test_pipeline.lua [options]
        
    Options:
        --torrents <file>     Test torrent filename parsing (default: torrents.txt)
        --subs <file>         Test subtitle filename parsing (default: sub_files.txt)
        --match               Test matching logic with sample data
        --stats               Show statistics only
        --verbose             Show all parsed results
]]

-------------------------------------------------------------------------------
-- CONFIGURATION
-------------------------------------------------------------------------------

local TORRENTS_FILE = "torrents.txt"
local SUBS_FILE = "sub_files.txt"
local OUTPUT_FILE = "test_results.log"

local verbose = false
local show_stats = false
local test_torrents = true
local test_subs = true
local test_matching = true

-------------------------------------------------------------------------------
-- ARGUMENT PARSING
-------------------------------------------------------------------------------

for i = 1, #arg do
    if arg[i] == "--torrents" and arg[i + 1] then
        TORRENTS_FILE = arg[i + 1]
        test_torrents = true
    elseif arg[i] == "--subs" and arg[i + 1] then
        SUBS_FILE = arg[i + 1]
        test_subs = true
    elseif arg[i] == "--match" then
        test_matching = true
    elseif arg[i] == "--stats" then
        show_stats = true
    elseif arg[i] == "--verbose" then
        verbose = true
    elseif arg[i] == "--help" or arg[i] == "-h" then
        print([[
Jimaku Test Pipeline

Usage:
    lua test_pipeline.lua [options]
    
Options:
    --torrents <file>     Test torrent filename parsing (default: torrents.txt)
    --subs <file>         Test subtitle filename parsing (default: sub_files.txt)
    --match               Test matching logic with sample scenarios
    --stats               Show statistics only
    --verbose             Show all parsed results
    --help, -h            Show this help message

Examples:
    lua test_pipeline.lua --torrents torrents.txt --verbose
    lua test_pipeline.lua --subs sub_files.txt --stats
    lua test_pipeline.lua --match
]])
        os.exit(0)
    end
end

-- Default: test everything if no flags specified
if not test_torrents and not test_subs and not test_matching then
    test_torrents = true
    test_subs = true
    test_matching = true
end

-------------------------------------------------------------------------------
-- UTILITY FUNCTIONS
-------------------------------------------------------------------------------

local function log_output(msg)
    print(msg)
    local f = io.open(OUTPUT_FILE, "a")
    if f then
        f:write(msg .. "\n")
        f:close()
    end
end

local function normalize_digits(s)
    if not s then return s end
    s = s:gsub("０", "0"):gsub("１", "1"):gsub("２", "2"):gsub("３", "3"):gsub("４", "4")
    s = s:gsub("５", "5"):gsub("６", "6"):gsub("７", "7"):gsub("８", "8"):gsub("９", "9")
    return s
end

-------------------------------------------------------------------------------
-- TORRENT FILENAME PARSER (from jimaku.lua)
-------------------------------------------------------------------------------

local function normalize_title(title)
    if not title then return "" end
    title = title:gsub("[%._]", " ")
    title = title:gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    return title
end

local function clean_episode(episode_str)
    if not episode_str then return "" end
    episode_str = episode_str:gsub("^%((.-)%)$", "%1")
    episode_str = episode_str:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return episode_str
end

local function parse_torrent_filename(filename)
    local original = filename
    
    -- Strip extension
    filename = filename:gsub("%.%w%w%w?$", "")
    
    -- Extract release group
    local release_group = "unknown"
    local group_match, content_match = filename:match("^%[([^%]]+)%]%s*(.+)$")
    if group_match then
        release_group = group_match
        filename = content_match
    end
    
    local title, episode, season
    
    -- Pattern matching
    if not title then
        title, season, episode = filename:match("^(.-)[%s%.%_][Ss](%d+)[Ee](%d+)")
    end
    
    if not title then
        title, season, episode = filename:match("^(.-)[%s%.%_][Ss](%d+)[%s%.%_]+%-[%s%.%_]+(%d+)")
    end
    
    if not title then
        title, episode = filename:match("^(.-)%s*%-%s*(%d+)")
        if title and episode then
            season = nil
        end
    end
    
    if not title then
        title = filename:match("^(.-)%s*%[") or filename:match("^(.-)%s*%(") or filename
        episode = "1"
    end
    
    title = normalize_title(title)
    episode = clean_episode(episode)
    
    -- Extract season from title if not found
    if not season then
        season = title:match("(%d+)nd%s+[Ss]eason") or 
                 title:match("(%d+)rd%s+[Ss]eason") or
                 title:match("[Ss]eason%s+(%d+)")
        
        if season then
            title = title:gsub("%d+nd%s+[Ss]eason", "")
            title = title:gsub("%d+rd%s+[Ss]eason", "")
            title = title:gsub("[Ss]eason%s+%d+", "")
            title = title:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        end
    end
    
    -- Clean up title
    title = title:gsub("%s*%([^%)]+%)", "")
    title = title:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    
    return {
        title = title,
        season = tonumber(season),
        episode = episode or "1",
        group = release_group,
        original = original
    }
end

-------------------------------------------------------------------------------
-- SUBTITLE FILENAME PARSER (from jimaku.lua)
-------------------------------------------------------------------------------

local function parse_subtitle_filename(filename)
    if not filename then return nil, nil end
    
    filename = normalize_digits(filename)
    
    local patterns = {
        {"S(%d+)E(%d+)", "season_episode"},
        {"[Ss](%d+)[Ee](%d+)", "season_episode"},
        {"S(%d+)%s*%-%s*E(%d+)", "season_episode"},
        {"Season%s*(%d+)%s*%-%s*(%d+)", "season_episode"},
        {"%-%s*(%d+%.%d+)", "fractional"},
        {"%s(%d+%.%d+)", "fractional"},
        {"EP(%d+)", "episode"},
        {"[Ee]p%s*(%d+)", "episode"},
        {"[Ee](%d+)", "episode"},
        {"Episode%s*(%d+)", "episode"},
        {"[#＃](%d+)", "episode"},
        {"第(%d+)[話回]", "episode"},
        {"（(%d+)）", "episode"},
        {"_(%d+)%.", "episode"},
        {"%s(%d+)%s+BD%.", "episode"},
        {"%s(%d+)%s+Web%s", "episode"},
        {"%-%s*(%d+)%s*[%[(]", "episode"},
        {"track(%d+)", "episode"},
        {"_(%d%d%d)%.[AaSs]", "episode"},
        {"_(%d%d)%.[AaSs]", "episode"},
        {"%-%s*(%d+)%.", "episode"},
        {"^(%d+)%.", "episode"},
    }
    
    for _, pattern_data in ipairs(patterns) do
        local pattern = pattern_data[1]
        local ptype = pattern_data[2]
        
        if ptype == "season_episode" then
            local s, e = filename:match(pattern)
            if s and e then
                return tonumber(s), tonumber(e)
            end
        elseif ptype == "fractional" then
            local e = filename:match(pattern)
            if e then
                return nil, e
            end
        else
            local e = filename:match(pattern)
            if e then
                local num = tonumber(e)
                if num and num > 0 and num < 9999 then
                    return nil, num
                end
            end
        end
    end
    
    return nil, nil
end

-------------------------------------------------------------------------------
-- MATCHING LOGIC TEST
-------------------------------------------------------------------------------

local function test_episode_matching()
    log_output("\n" .. string.rep("=", 80))
    log_output("EPISODE MATCHING TESTS")
    log_output(string.rep("=", 80))
    
    local test_cases = {
        {
            name = "Vigilante S2E03 - Netflix Absolute",
            torrent = "[SubsPlease] Vigilante S2 - 03 (1080p).mkv",
            subtitle = "ヴィジランテ.ILLEGALS-.S02E16.WEBRip.Netflix.ja[cc].srt",
            target_season = 2,
            target_episode = 3,
            s1_episodes = 13,
            should_match = true,
            reason = "S2E03 with S1=13eps should match cumulative E16"
        },
        {
            name = "Jujutsu Kaisen S3E04 - Standard Numbering",
            torrent = "[NanakoRaws] Jujutsu Kaisen S3 - 04.mkv",
            subtitle = "[NanakoRaws] Jujutsu Kaisen S3 - 04.ass",
            target_season = 3,
            target_episode = 4,
            s1_episodes = 24,
            s2_episodes = 23,
            should_match = true,
            reason = "Direct season and episode match"
        },
        {
            name = "Continuous Numbering - No Season",
            torrent = "[SubsPlease] Anime - 51 (1080p).mkv",
            subtitle = "Anime_51.ass",
            target_season = 3,
            target_episode = 4,
            s1_episodes = 24,
            s2_episodes = 23,
            should_match = true,
            reason = "E51 cumulative = S3E04 (24+23+4=51)"
        },
    }
    
    log_output("\nRunning " .. #test_cases .. " test cases...\n")
    
    local passed = 0
    local failed = 0
    
    for i, test in ipairs(test_cases) do
        log_output(string.format("[Test %d] %s", i, test.name))
        log_output(string.format("  Torrent:  %s", test.torrent))
        log_output(string.format("  Subtitle: %s", test.subtitle))
        
        -- Parse filenames
        local torrent_parsed = parse_torrent_filename(test.torrent)
        local sub_season, sub_episode = parse_subtitle_filename(test.subtitle)
        
        log_output(string.format("  Parsed Torrent: S%s E%s - %s", 
            torrent_parsed.season or "?", torrent_parsed.episode, torrent_parsed.title))
        log_output(string.format("  Parsed Subtitle: S%s E%s", 
            sub_season or "?", sub_episode or "?"))
        
        -- Calculate cumulative
        local cumulative = test.target_episode
        if test.target_season == 2 and test.s1_episodes then
            cumulative = test.s1_episodes + test.target_episode
        elseif test.target_season == 3 and test.s1_episodes and test.s2_episodes then
            cumulative = test.s1_episodes + test.s2_episodes + test.target_episode
        end
        
        log_output(string.format("  Target: S%d E%d (cumulative: %d)", 
            test.target_season, test.target_episode, cumulative))
        
        -- Check if match
        local is_match = false
        local match_type = "no_match"
        
        if sub_season and sub_episode then
            if sub_season == test.target_season and sub_episode == test.target_episode then
                is_match = true
                match_type = "direct_season_match"
            elseif sub_episode == cumulative then
                is_match = true
                match_type = "netflix_absolute"
            end
        elseif sub_episode then
            if sub_episode == cumulative then
                is_match = true
                match_type = "cumulative_match"
            elseif sub_episode == test.target_episode then
                is_match = true
                match_type = "direct_episode"
            end
        end
        
        local result = is_match == test.should_match and "PASS" or "FAIL"
        log_output(string.format("  Match: %s (%s)", is_match and "YES" or "NO", match_type))
        log_output(string.format("  Result: %s - %s", result, test.reason))
        log_output("")
        
        if result == "PASS" then
            passed = passed + 1
        else
            failed = failed + 1
        end
    end
    
    log_output(string.rep("-", 80))
    log_output(string.format("Results: %d passed, %d failed (%.1f%% success rate)", 
        passed, failed, (passed / #test_cases) * 100))
    log_output(string.rep("=", 80))
end

-------------------------------------------------------------------------------
-- TORRENT PARSING TEST
-------------------------------------------------------------------------------

local function test_torrent_parsing()
    log_output("\n" .. string.rep("=", 80))
    log_output("TORRENT FILENAME PARSING TEST")
    log_output(string.rep("=", 80))
    
    local f = io.open(TORRENTS_FILE, "r")
    if not f then
        log_output("ERROR: Could not open " .. TORRENTS_FILE)
        return
    end
    
    local total = 0
    local parsed = 0
    local failed = 0
    
    local season_dist = {}
    local episode_dist = {}
    
    log_output("\nParsing torrents from: " .. TORRENTS_FILE .. "\n")
    
    for line in f:lines() do
        if line:match("%S") then
            total = total + 1
            
            local result = parse_torrent_filename(line)
            
            if result and result.title ~= "" then
                parsed = parsed + 1
                
                if verbose then
                    log_output(string.format("[%d] %s → S%s E%s | %s", 
                        total, 
                        result.group,
                        result.season or "?",
                        result.episode,
                        result.title))
                end
                
                -- Statistics
                local season_key = result.season and tostring(result.season) or "continuous"
                season_dist[season_key] = (season_dist[season_key] or 0) + 1
                
                local ep_num = tonumber(result.episode)
                if ep_num then
                    if ep_num <= 13 then
                        episode_dist["1-13"] = (episode_dist["1-13"] or 0) + 1
                    elseif ep_num <= 26 then
                        episode_dist["14-26"] = (episode_dist["14-26"] or 0) + 1
                    elseif ep_num <= 50 then
                        episode_dist["27-50"] = (episode_dist["27-50"] or 0) + 1
                    else
                        episode_dist["51+"] = (episode_dist["51+"] or 0) + 1
                    end
                end
            else
                failed = failed + 1
                if verbose then
                    log_output(string.format("[%d] FAILED: %s", total, line))
                end
            end
            
            if total % 10000 == 0 then
                log_output(string.format("Progress: %d files processed...", total))
            end
        end
    end
    
    f:close()
    
    -- Summary
    log_output("\n" .. string.rep("-", 80))
    log_output("TORRENT PARSING SUMMARY")
    log_output(string.rep("-", 80))
    log_output(string.format("Total files:     %d", total))
    log_output(string.format("Successfully parsed: %d (%.1f%%)", parsed, (parsed/total)*100))
    log_output(string.format("Failed:          %d (%.1f%%)", failed, (failed/total)*100))
    
    log_output("\nSeason Distribution:")
    for season, count in pairs(season_dist) do
        log_output(string.format("  %s: %d (%.1f%%)", season, count, (count/parsed)*100))
    end
    
    log_output("\nEpisode Distribution:")
    for range, count in pairs(episode_dist) do
        log_output(string.format("  Episodes %s: %d (%.1f%%)", range, count, (count/parsed)*100))
    end
    
    log_output(string.rep("=", 80))
end

-------------------------------------------------------------------------------
-- SUBTITLE PARSING TEST
-------------------------------------------------------------------------------

local function test_subtitle_parsing()
    log_output("\n" .. string.rep("=", 80))
    log_output("SUBTITLE FILENAME PARSING TEST")
    log_output(string.rep("=", 80))
    
    local f = io.open(SUBS_FILE, "r")
    if not f then
        log_output("ERROR: Could not open " .. SUBS_FILE)
        return
    end
    
    local total = 0
    local parsed = 0
    local failed = 0
    
    local season_dist = {}
    local episode_dist = {}
    
    log_output("\nParsing subtitles from: " .. SUBS_FILE .. "\n")
    
    for line in f:lines() do
        if line:match("%S") then
            total = total + 1
            
            local season, episode = parse_subtitle_filename(line)
            
            if episode then
                parsed = parsed + 1
                
                if verbose then
                    log_output(string.format("[%d] S%s E%s | %s", 
                        total,
                        season or "?",
                        episode,
                        line:sub(1, 80)))
                end
                
                -- Statistics
                local season_key = season and tostring(season) or "no_season"
                season_dist[season_key] = (season_dist[season_key] or 0) + 1
                
                local ep_num = tonumber(episode)
                if ep_num then
                    if ep_num <= 13 then
                        episode_dist["1-13"] = (episode_dist["1-13"] or 0) + 1
                    elseif ep_num <= 26 then
                        episode_dist["14-26"] = (episode_dist["14-26"] or 0) + 1
                    elseif ep_num <= 50 then
                        episode_dist["27-50"] = (episode_dist["27-50"] or 0) + 1
                    else
                        episode_dist["51+"] = (episode_dist["51+"] or 0) + 1
                    end
                end
            else
                failed = failed + 1
                if verbose then
                    log_output(string.format("[%d] FAILED: %s", total, line))
                end
            end
            
            if total % 10000 == 0 then
                log_output(string.format("Progress: %d files processed...", total))
            end
        end
    end
    
    f:close()
    
    -- Summary
    log_output("\n" .. string.rep("-", 80))
    log_output("SUBTITLE PARSING SUMMARY")
    log_output(string.rep("-", 80))
    log_output(string.format("Total files:     %d", total))
    log_output(string.format("Successfully parsed: %d (%.1f%%)", parsed, (parsed/total)*100))
    log_output(string.format("Failed:          %d (%.1f%%)", failed, (failed/total)*100))
    
    log_output("\nSeason Distribution:")
    for season, count in pairs(season_dist) do
        log_output(string.format("  %s: %d (%.1f%%)", season, count, (count/parsed)*100))
    end
    
    log_output("\nEpisode Distribution:")
    for range, count in pairs(episode_dist) do
        log_output(string.format("  Episodes %s: %d (%.1f%%)", range, count, (count/parsed)*100))
    end
    
    log_output(string.rep("=", 80))
end

-------------------------------------------------------------------------------
-- MAIN
-------------------------------------------------------------------------------

-- Clear output file
local f = io.open(OUTPUT_FILE, "w")
if f then f:close() end

log_output("Jimaku Test Pipeline")
log_output("Started: " .. os.date("%Y-%m-%d %H:%M:%S"))
log_output("")

if test_torrents then
    test_torrent_parsing()
end

if test_subs then
    test_subtitle_parsing()
end

if test_matching then
    test_episode_matching()
end

log_output("\nCompleted: " .. os.date("%Y-%m-%d %H:%M:%S"))
log_output("Results written to: " .. OUTPUT_FILE)