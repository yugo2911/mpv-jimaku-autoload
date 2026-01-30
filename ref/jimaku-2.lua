-- Detect if running standalone (command line) or in mpv
local STANDALONE_MODE = not pcall(function() return mp.get_property("filename") end)

local utils
if not STANDALONE_MODE then
    utils = require 'mp.utils'
end

-- CONFIGURATION
local CONFIG_DIR
local LOG_FILE
local PARSER_LOG_FILE
local TEST_FILE
local SUBTITLE_CACHE_DIR
local JIMAKU_API_KEY_FILE
local ANILIST_API_URL = "https://graphql.anilist.co"
local JIMAKU_API_URL = "https://jimaku.cc/api"

if STANDALONE_MODE then
    CONFIG_DIR = "."
    LOG_FILE = "./anilist-debug.log"
    PARSER_LOG_FILE = "./parser-debug.log"
    TEST_FILE = "./torrents.txt"
    SUBTITLE_CACHE_DIR = "./subtitle-cache"
    JIMAKU_API_KEY_FILE = "./jimaku-api-key.txt"
else
    CONFIG_DIR = mp.command_native({"expand-path", "~~/"})
    LOG_FILE = CONFIG_DIR .. "/anilist-debug.log"
    PARSER_LOG_FILE = CONFIG_DIR .. "/parser-debug.log"
    TEST_FILE = CONFIG_DIR .. "/torrents.txt"
    SUBTITLE_CACHE_DIR = CONFIG_DIR .. "/subtitle-cache"
    JIMAKU_API_KEY_FILE = CONFIG_DIR .. "/jimaku-api-key.txt"
end

-- Parser configuration
local LOG_ONLY_ERRORS = false

-- === NEW: PARSER FEATURE SWITCHES ===
local ENABLE_STRICT_REGEX = true        -- Use strict regex patterns first
local ENABLE_FALLBACK_REGEX = true      -- Fall back to looser patterns if strict fails
local ENABLE_FUZZY_SEARCH = true        -- Use fuzzy/heuristic matching as last resort
local REQUIRE_EXACT_BRACKETS = true     -- Require exact bracket matching in patterns
local MINIMUM_CONFIDENCE = 85           -- Only accept patterns with confidence >= this value

-- Network configuration
local NETWORK_TIMEOUT = 10              -- HTTP request timeout in seconds
local ENABLE_NETWORK = true             -- Enable/disable network requests (for testing)

-- Jimaku configuration
local JIMAKU_MAX_SUBS = 5 -- Maximum number of subtitles to download and load (set to "all" to download all available)
local JIMAKU_AUTO_DOWNLOAD = true -- Automatically download subtitles when file starts playing (set to false to require manual key press)

-- Jimaku API key (will be loaded from file)
local JIMAKU_API_KEY = ""

-- Episode file cache
local episode_cache = {}

-- Unified logging function
local function debug_log(message, is_error)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local prefix = is_error and "[ERROR] " or "[INFO] "
    local log_msg = string.format("%s %s%s\n", timestamp, prefix, message)
    
    local target_log = STANDALONE_MODE and PARSER_LOG_FILE or LOG_FILE
    local f = io.open(target_log, "a")
    if f then
        f:write(log_msg)
        f:close()
    end
    
    -- Print to terminal if not suppressed
    local should_log = not LOG_ONLY_ERRORS or is_error
    if should_log then
        print(log_msg:gsub("\n", ""))
    end
end

-- Normalize full-width digits to ASCII
local function normalize_digits(s)
    if not s then return s end
    
    -- Simple approach: replace common full-width digits
    s = s:gsub("０", "0"):gsub("１", "1"):gsub("２", "2"):gsub("３", "3"):gsub("４", "4")
    s = s:gsub("５", "5"):gsub("６", "6"):gsub("７", "7"):gsub("８", "8"):gsub("９", "9")
    
    return s
end

-- === STRICT REGEX PATTERNS (HIGH CONFIDENCE) ===
local STRICT_PATTERNS = {
    -- Anime fansub patterns with exact bracket requirements
    {
        name = "anime_subgroup_absolute_with_sxxexx_paren",
        confidence = 100,
        regex = "^%[([^%]]+)%]%s*([^%[%]%-]+)%s+([0-9][0-9][0-9]%.?%d?)%s*%(%s*[Ss](%d+)[Ee](%d+)%s*%).*$",
        fields = { "group", "title", "absolute", "season", "episode" },
        validator = function(captures)
            return captures[3] and tonumber(captures[3]) >= 100 and tonumber(captures[3]) <= 999
        end
    },
    {
        name = "subgroup_title_year_episode_metadata_hash",
        confidence = 99,
        regex = "^%[([^%]]+)%]%s*([^%[%]%(%)]+)%s*%((%d%d%d%d)%)%s*[%-%–—]%s*(%d%d?)%s*%([^%)]+%)%s*%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "year", "episode", "hash" },
        validator = function(captures)
            local year = tonumber(captures[3])
            return year and year >= 1950 and year <= 2030
        end
    },
    {
        name = "anime_subgroup_sxxexx_absolute",
        confidence = 99,
        regex = "^%[([^%]]+)%]%s*([^%[%]%-]+)%s*[%-–—]%s*[Ss](%d+)[Ee](%d+)%s*%((%d+)%).*$",
        fields = { "group", "title", "season", "episode", "absolute_episode" }
    },
    {
        name = "anime_subgroup_absolute_dash",
        confidence = 98,
        regex = "^%[([^%]]+)%]%s*([^%[%]%-]+)%s*[-_]%s*([0-9][0-9][0-9]%.?%d?).*$",
        fields = { "group", "title", "absolute" },
        validator = function(captures)
            return captures[3] and tonumber(captures[3]) >= 1 and tonumber(captures[3]) <= 999
        end
    },
    {
        name = "anime_subgroup_sxxexx",
        confidence = 96,
        regex = "^%[([^%]]+)%]%s*([^%[%]%-]+)%s*[%-_%. ]+[Ss](%d+)[Ee](%d+).*$",
        fields = { "group", "title", "season", "episode" }
    },
    {
        name = "anime_subgroup_dash_episode",
        confidence = 95,
        regex = "^%[([^%]]+)%]%s*([^%[%]]+)%s+[%-–—]%s+(%d%d?%d?)[%s%._%-]*%[.*$",
        fields = { "group", "title", "episode" },
        validator = function(captures)
            return captures[3] and tonumber(captures[3]) >= 1 and tonumber(captures[3]) <= 999
        end
    },
    -- Standard TV show patterns
    {
        name = "sxxexx_strict",
        confidence = 90,
        regex = "^([^%[%(%-]+)[%s%._%-]+[Ss](%d%d)[Ee](%d%d).*$",
        fields = { "title", "season", "episode" },
        validator = function(captures)
            return captures[1]:match("%w") and #captures[1] >= 3
        end
    },
}

-- === FALLBACK PATTERNS (MEDIUM CONFIDENCE) ===
local FALLBACK_PATTERNS = {
    {
        name = "sxxexx_title",
        confidence = 85,
        regex = "^(.-%w)[%s%._%-]+[Ss](%d+)[Ee](%d+).*$",
        fields = { "title", "season", "episode" }
    },
    {
        name = "title_dash_episode_bracket",
        confidence = 82,
        regex = "^([^%-%[]+)%s*[%-%–—]%s*(%d+)%s*%[.*$",
        fields = { "title", "episode" }
    },
    {
        name = "trailing_3digit_absolute",
        confidence = 80,
        regex = "^(.+)[%s%._%-]+([0-9][0-9][0-9]%.?%d?)$",
        fields = { "title", "absolute" }
    },
    {
        name = "dash_two_digit_episode",
        confidence = 75,
        regex = "^([^%-]+)%s*[%-%–—]%s*(%d%d)$",
        fields = { "title", "episode" }
    },
}

-- === FUZZY PATTERNS (LOW CONFIDENCE) ===
local FUZZY_PATTERNS = {
    {
        name = "loose_trailing_number",
        confidence = 60,
        regex = "^(.+)%s+(%d+)$",
        fields = { "title", "episode" }
    },
    {
        name = "loose_title_metadata",
        confidence = 50,
        regex = "^([^%[%%(]+).*$",
        fields = { "title" }
    },
}

-- Validate captured values
local function validate_captures(pattern, captures)
    if not pattern.validator then
        return true
    end
    
    -- Wrap in pcall to catch any validator errors
    local success, result = pcall(pattern.validator, captures)
    if not success then
        debug_log("Validator error: " .. tostring(result), true)
        return false
    end
    return result
end

-- Clean and normalize title
local function clean_title(title)
    if not title then return nil end
    
    -- Remove extra whitespace
    title = title:gsub("%s+", " ")
    title = title:match("^%s*(.-)%s*$")
    
    -- Remove common suffixes
    title = title:gsub("%s*[%-%._]%s*$", "")
    
    -- Replace dots with spaces in dotted titles
    if title:match("^[%w%.]+$") then
        title = title:gsub("%.", " ")
    end
    
    return title
end

-- Convert Roman numerals to numbers
local function roman_to_number(roman)
    if not roman then return nil end
    
    local roman_map = {
        I = 1, II = 2, III = 3, IV = 4, V = 5,
        VI = 6, VII = 7, VIII = 8, IX = 9, X = 10
    }
    
    return roman_map[roman:upper()]
end

-- Parse filename using strict regex patterns
local function parse_filename_strict(filename)
    if not filename or not ENABLE_STRICT_REGEX then
        return nil
    end
    
    debug_log("=== STRICT REGEX PARSING ===")
    
    for _, pattern in ipairs(STRICT_PATTERNS) do
        if pattern.confidence >= MINIMUM_CONFIDENCE then
            -- Wrap pattern matching in pcall to catch regex errors
            local success, captures = pcall(function()
                return {filename:match(pattern.regex)}
            end)
            
            if not success then
                debug_log("Regex error in pattern " .. pattern.name .. ": " .. tostring(captures), true)
            elseif #captures > 0 and validate_captures(pattern, captures) then
                local result = {
                    method = "strict_regex",
                    pattern_name = pattern.name,
                    confidence = pattern.confidence
                }
                
                for i, field in ipairs(pattern.fields) do
                    result[field] = captures[i]
                end
                
                -- Clean title
                if result.title then
                    result.title = clean_title(result.title)
                end
                
                -- Convert string numbers to integers
                if result.episode then result.episode = tonumber(result.episode) end
                if result.season then result.season = tonumber(result.season) end
                if result.absolute then result.absolute = tonumber(result.absolute) end
                if result.absolute_episode then result.absolute_episode = tonumber(result.absolute_episode) end
                
                -- Convert Roman numerals if present
                if result.season_roman then
                    result.season = roman_to_number(result.season_roman)
                end
                
                debug_log(string.format("✓ Matched: %s (confidence: %d)", pattern.name, pattern.confidence))
                debug_log(string.format("  Title: %s | S:%s E:%s | Abs:%s", 
                    result.title or "?", 
                    result.season or "?", 
                    result.episode or "?",
                    result.absolute or result.absolute_episode or "?"))
                
                return result
            end
        end
    end
    
    debug_log("✗ No strict pattern matched")
    return nil
end

-- Parse filename using fallback regex patterns
local function parse_filename_fallback(filename)
    if not filename or not ENABLE_FALLBACK_REGEX then
        return nil
    end
    
    debug_log("=== FALLBACK REGEX PARSING ===")
    
    for _, pattern in ipairs(FALLBACK_PATTERNS) do
        local success, captures = pcall(function()
            return {filename:match(pattern.regex)}
        end)
        
        if not success then
            debug_log("Regex error in pattern " .. pattern.name .. ": " .. tostring(captures), true)
        elseif #captures > 0 and validate_captures(pattern, captures) then
            local result = {
                method = "fallback_regex",
                pattern_name = pattern.name,
                confidence = pattern.confidence
            }
            
            for i, field in ipairs(pattern.fields) do
                result[field] = captures[i]
            end
            
            -- Clean title
            if result.title then
                result.title = clean_title(result.title)
            end
            
            -- Convert string numbers to integers
            if result.episode then result.episode = tonumber(result.episode) end
            if result.season then result.season = tonumber(result.season) end
            if result.absolute then result.absolute = tonumber(result.absolute) end
            
            debug_log(string.format("✓ Matched: %s (confidence: %d)", pattern.name, pattern.confidence))
            debug_log(string.format("  Title: %s | S:%s E:%s | Abs:%s", 
                result.title or "?", 
                result.season or "?", 
                result.episode or "?",
                result.absolute or "?"))
            
            return result
        end
    end
    
    debug_log("✗ No fallback pattern matched")
    return nil
end

-- Parse filename using fuzzy/heuristic matching
local function parse_filename_fuzzy(filename)
    if not filename or not ENABLE_FUZZY_SEARCH then
        return nil
    end
    
    debug_log("=== FUZZY PARSING ===")
    
    for _, pattern in ipairs(FUZZY_PATTERNS) do
        local success, captures = pcall(function()
            return {filename:match(pattern.regex)}
        end)
        
        if not success then
            debug_log("Regex error in pattern " .. pattern.name .. ": " .. tostring(captures), true)
        elseif #captures > 0 then
            local result = {
                method = "fuzzy",
                pattern_name = pattern.name,
                confidence = pattern.confidence
            }
            
            for i, field in ipairs(pattern.fields) do
                result[field] = captures[i]
            end
            
            -- Clean title
            if result.title then
                result.title = clean_title(result.title)
            end
            
            -- Convert string numbers to integers
            if result.episode then result.episode = tonumber(result.episode) end
            
            debug_log(string.format("⚠ Fuzzy match: %s (confidence: %d)", pattern.name, pattern.confidence))
            debug_log(string.format("  Title: %s | E:%s", 
                result.title or "?", 
                result.episode or "?"))
            
            return result
        end
    end
    
    debug_log("✗ No fuzzy pattern matched")
    return nil
end

-- Main parsing function with cascading fallback
local function parse_filename(filename)
    if not filename then
        debug_log("✗ No filename provided", true)
        return nil
    end
    
    -- Remove file extension
    local base_name = filename:match("^(.+)%.[^%.]+$") or filename
    
    -- Normalize
    base_name = normalize_digits(base_name)
    
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    debug_log("Parsing: " .. base_name)
    debug_log("Settings: Strict=" .. tostring(ENABLE_STRICT_REGEX) .. 
              " | Fallback=" .. tostring(ENABLE_FALLBACK_REGEX) .. 
              " | Fuzzy=" .. tostring(ENABLE_FUZZY_SEARCH))
    
    -- Try strict patterns first
    local result = parse_filename_strict(base_name)
    if result then
        return result
    end
    
    -- Try fallback patterns
    result = parse_filename_fallback(base_name)
    if result then
        return result
    end
    
    -- Try fuzzy patterns as last resort
    result = parse_filename_fuzzy(base_name)
    if result then
        return result
    end
    
    -- Total failure
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    debug_log("✗ PARSING FAILED - No patterns matched", true)
    return nil
end

-- Main test function (standalone mode)
local function run_parser_test()
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    debug_log("JIMAKU PARSER - STANDALONE TEST MODE")
    debug_log("Network requests: " .. (ENABLE_NETWORK and "ENABLED" or "DISABLED"))
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    
    -- Check if test file exists
    local f = io.open(TEST_FILE, "r")
    if not f then
        debug_log("✗ Test file not found: " .. TEST_FILE, true)
        debug_log("Creating test file with sample data...")
        
        -- Create a sample test file
        f = io.open(TEST_FILE, "w")
        if f then
            f:write("[SubsPlease] Frieren - 01 (1080p).mkv\n")
            f:close()
            debug_log("✓ Created test file: " .. TEST_FILE)
            f = io.open(TEST_FILE, "r")
        else
            debug_log("✗ Could not create test file", true)
            return
        end
    end
    
    local line_count = 0
    local success_count = 0
    local fail_count = 0
    
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")  -- Trim whitespace
        
        if line and line ~= "" then
            line_count = line_count + 1
            debug_log("")
            debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            debug_log(string.format("Test #%d: %s", line_count, line))
            
            local result = parse_filename(line)
            
            if result and result.title then
                success_count = success_count + 1
                debug_log(string.format("✓ SUCCESS - Extracted: Title='%s', S=%s, E=%s, Abs=%s", 
                    result.title,
                    result.season or "?",
                    result.episode or "?",
                    result.absolute or "?"))
                debug_log(string.format("  Method: %s | Pattern: %s | Confidence: %d",
                    result.method,
                    result.pattern_name,
                    result.confidence))
            else
                fail_count = fail_count + 1
                debug_log("✗ FAILED - Could not parse filename", true)
            end
        end
    end
    
    f:close()
    
    debug_log("")
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    debug_log(string.format("SUMMARY: %d total | %d success | %d failed", 
        line_count, success_count, fail_count))
    debug_log(string.format("Success rate: %.1f%%", (success_count / line_count) * 100))
    debug_log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
end

-- Initialize
if STANDALONE_MODE then
    -- Standalone mode - run parser test
    run_parser_test()
else
    -- MPV mode - set up keybindings (simplified, network features disabled for now)
    debug_log("AniList Script Initialized (Parser only mode). Press 'A' to test parsing.")
    
    mp.add_key_binding("A", "anilist-search", function()
        local filename = mp.get_property("filename")
        if filename then
            local result = parse_filename(filename)
            if result and result.title then
                mp.osd_message(string.format("Parsed: %s\nS%s E%s (Confidence: %d)",
                    result.title,
                    result.season or "?",
                    result.episode or result.absolute or "?",
                    result.confidence), 5)
            else
                mp.osd_message("Failed to parse filename", 3)
            end
        end
    end)
end