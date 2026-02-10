-- REFACTORED JIMAKU.LUA - Critical Sections Example
-- This demonstrates how to refactor the most problematic parts

-------------------------------------------------------------------------------
-- 1. MODULE ENCAPSULATION - Replace Global Variables
-------------------------------------------------------------------------------

local Jimaku = {
    -- Configuration
    config = {
        api_key = nil,
        cache_dir = "./subtitle-cache",
        max_subs = 10,
        auto_download = true,
        items_per_page = 8,
        menu_timeout = 30,
        font_size = 16,
        hide_signs = false,
        log_only_errors = false,
        use_anilist = true,
        use_jimaku = true
    },
    
    -- Runtime state
    state = {
        standalone_mode = false,
        menu = {
            active = false,
            stack = {},
            timeout_timer = nil
        },
        search = {
            results = nil,
            query = nil
        },
        match = {
            anilist_id = nil,
            jimaku_id = nil,
            current = nil,
            seasons_data = nil
        }
    },
    
    -- Caches
    cache = {
        anilist = {},
        jimaku = {},
        episodes = {},
        preferred_groups = {}
    },
    
    -- API clients
    api = {
        anilist = nil,  -- Will be initialized
        jimaku = nil
    }
}

-------------------------------------------------------------------------------
-- 2. SIMPLIFIED LOGGING - Replace 83-line debug_log()
-------------------------------------------------------------------------------

local Logger = {
    file = nil,
    only_errors = false
}

function Logger:init(log_file, only_errors)
    self.file = log_file
    self.only_errors = only_errors
end

function Logger:log(message, is_error)
    if self.only_errors and not is_error then return end
    
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local formatted = string.format("[%s] %s", timestamp, message)
    
    -- Console output
    print("Jimaku: " .. message)
    
    -- File output
    if self.file then
        local f = io.open(self.file, "a")
        if f then
            f:write(formatted .. "\n")
            f:close()
        else
            print("Jimaku: Warning - Cannot write to log file")
        end
    end
end

function Logger:error(message)
    self:log(message, true)
end

function Logger:info(message)
    self:log(message, false)
end

-------------------------------------------------------------------------------
-- 3. CONSISTENT ERROR HANDLING
-------------------------------------------------------------------------------

-- Error types
local ErrorCodes = {
    MISSING_API_KEY = "MISSING_API_KEY",
    NETWORK_ERROR = "NETWORK_ERROR",
    PARSE_ERROR = "PARSE_ERROR",
    NOT_FOUND = "NOT_FOUND",
    CACHE_ERROR = "CACHE_ERROR"
}

-- Result type for operations that can fail
local function success(value)
    return { ok = true, value = value }
end

local function failure(error_code, message)
    return { ok = false, error_code = error_code, message = message }
end

-- Example usage:
local function search_jimaku_api(anilist_id)
    if not Jimaku.config.api_key then
        return failure(ErrorCodes.MISSING_API_KEY, "API key not configured")
    end
    
    local result = make_api_request(anilist_id)
    if not result then
        return failure(ErrorCodes.NETWORK_ERROR, "Failed to connect to Jimaku API")
    end
    
    return success(result)
end

-------------------------------------------------------------------------------
-- 4. CACHE MANAGEMENT - Generic Instead of Duplicated
-------------------------------------------------------------------------------

local CacheManager = {}

function CacheManager:new(cache_file)
    local obj = {
        file = cache_file,
        data = {},
        ttl = 86400  -- 24 hours default
    }
    setattr(obj, self)
    self.__index = self
    return obj
end

function CacheManager:load()
    local f = io.open(self.file, "r")
    if not f then
        Logger:info("No cache file found at " .. self.file)
        return {}
    end
    
    local content = f:read("*all")
    f:close()
    
    local ok, decoded = pcall(json.decode, content)
    if not ok then
        Logger:error("Failed to parse cache file: " .. self.file)
        return {}
    end
    
    self.data = decoded or {}
    return self.data
end

function CacheManager:save()
    local encoded = json.encode(self.data)
    if not encoded then
        Logger:error("Failed to encode cache data")
        return false
    end
    
    local f = io.open(self.file, "w")
    if not f then
        Logger:error("Failed to open cache file for writing: " .. self.file)
        return false
    end
    
    f:write(encoded)
    f:close()
    return true
end

function CacheManager:get(key)
    local entry = self.data[key]
    if not entry then return nil end
    
    -- Check TTL
    if entry.timestamp and (os.time() - entry.timestamp) > self.ttl then
        self.data[key] = nil
        return nil
    end
    
    return entry.value
end

function CacheManager:set(key, value)
    self.data[key] = {
        value = value,
        timestamp = os.time()
    }
end

function CacheManager:clear()
    self.data = {}
    self:save()
end

-------------------------------------------------------------------------------
-- 5. BREAKING UP GOD FUNCTIONS - smart_match_anilist
-------------------------------------------------------------------------------

-- Constants for matching algorithm
local MATCH_CONSTANTS = {
    CONFIDENCE_THRESHOLD = 75,
    EXACT_TITLE_BONUS = 50,
    YEAR_MATCH_BONUS = 15,
    FORMAT_MATCH_BONUS = 10,
    EPISODE_RANGE_BONUS = 20,
    SEQUEL_PENALTY = 5
}

-- Step 1: Filter candidates
local function filter_by_title(results, parsed_title)
    local candidates = {}
    local search_lower = parsed_title:lower()
    
    for _, entry in ipairs(results) do
        local titles = {
            entry.title.romaji and entry.title.romaji:lower(),
            entry.title.english and entry.title.english:lower(),
            entry.title.native
        }
        
        -- Add synonyms
        if entry.synonyms then
            for _, syn in ipairs(entry.synonyms) do
                table.insert(titles, syn:lower())
            end
        end
        
        -- Check if any title matches
        for _, title in ipairs(titles) do
            if title and title:find(search_lower, 1, true) then
                table.insert(candidates, entry)
                break
            end
        end
    end
    
    return candidates
end

-- Step 2: Score candidates
local function score_candidate(candidate, parsed, target_ep, target_season, year)
    local score = 0
    
    -- Title exactness (0-50 points)
    local title_lower = candidate.title.romaji:lower()
    local parsed_lower = parsed.title:lower()
    
    if title_lower == parsed_lower then
        score = score + MATCH_CONSTANTS.EXACT_TITLE_BONUS
    elseif title_lower:find(parsed_lower, 1, true) then
        score = score + MATCH_CONSTANTS.EXACT_TITLE_BONUS * 0.7
    end
    
    -- Year match (0-15 points)
    if year and candidate.seasonYear == year then
        score = score + MATCH_CONSTANTS.YEAR_MATCH_BONUS
    end
    
    -- Format preference (0-10 points)
    if candidate.format == "TV" or candidate.format == "TV_SHORT" then
        score = score + MATCH_CONSTANTS.FORMAT_MATCH_BONUS
    end
    
    -- Episode range validity (0-20 points)
    if candidate.episodes then
        if target_ep <= candidate.episodes then
            score = score + MATCH_CONSTANTS.EPISODE_RANGE_BONUS
        else
            score = score - 10  -- Penalty for out of range
        end
    end
    
    return score
end

-- Step 3: Select best match
local function select_best_match(scored_candidates, min_confidence)
    min_confidence = min_confidence or MATCH_CONSTANTS.CONFIDENCE_THRESHOLD
    
    -- Sort by score descending
    table.sort(scored_candidates, function(a, b)
        return a.score > b.score
    end)
    
    local best = scored_candidates[1]
    if not best or best.score < min_confidence then
        return nil
    end
    
    return best.candidate, best.score
end

-- Main function - now much cleaner
local function smart_match_anilist(results, parsed, ep, season, year)
    Logger:info(string.format("Matching: %s S%d E%d", parsed.title, season or 1, ep or 1))
    
    -- Step 1: Filter
    local candidates = filter_by_title(results, parsed.title)
    if #candidates == 0 then
        Logger:info("No title matches found")
        return nil
    end
    
    Logger:info(string.format("Found %d title matches", #candidates))
    
    -- Step 2: Score
    local scored = {}
    for _, candidate in ipairs(candidates) do
        local score = score_candidate(candidate, parsed, ep, season, year)
        table.insert(scored, {
            candidate = candidate,
            score = score
        })
    end
    
    -- Step 3: Select
    local match, confidence = select_best_match(scored)
    
    if match then
        Logger:info(string.format("Selected: %s (score: %d)", 
            match.title.romaji, confidence))
        return match, ep, season, "smart_match", confidence
    else
        Logger:info("No confident match found")
        return nil
    end
end

-------------------------------------------------------------------------------
-- 6. NAMED CONSTANTS - Replace Magic Numbers
-------------------------------------------------------------------------------

local TIMEOUTS = {
    AUTO_SEARCH_DELAY = 0.5,
    MENU_DISPLAY = 30,
    RETRY_DELAY = 2.0
}

local API_LIMITS = {
    ANILIST_RESULTS_PER_PAGE = 15,
    JIMAKU_MAX_ENTRIES = 10,
    CACHE_TTL_SECONDS = 86400  -- 24 hours
}

local UI_SETTINGS = {
    ITEMS_PER_PAGE = 8,
    FONT_SIZE = 16,
    OSD_DURATION_SHORT = 3,
    OSD_DURATION_LONG = 7
}

-- Usage example:
mp.add_timeout(TIMEOUTS.AUTO_SEARCH_DELAY, function()
    search_anilist(true)
end)

-------------------------------------------------------------------------------
-- 7. SIMPLIFIED BOOLEAN LOGIC - Helper Functions
-------------------------------------------------------------------------------

local function has_api_results(data)
    return data 
        and data.Page 
        and data.Page.media 
        and #data.Page.media > 0
end

local function has_anilist_id(match)
    return match and match.anilist_id and match.anilist_id ~= ""
end

local function is_cache_valid(cache_entry, ttl)
    if not cache_entry or not cache_entry.timestamp then
        return false
    end
    
    local age = os.time() - cache_entry.timestamp
    return age < (ttl or API_LIMITS.CACHE_TTL_SECONDS)
end

-- Usage - compare readability:

-- BEFORE:
if not (data and data.Page and data.Page.media and #data.Page.media > 0) then
    if not search_local_subtitle_cache(parsed, is_auto) then
        conditional_osd("No matches found.", 3, is_auto)
    end
end

-- AFTER:
if not has_api_results(data) then
    if not search_local_subtitle_cache(parsed, is_auto) then
        show_osd("No matches found.", UI_SETTINGS.OSD_DURATION_SHORT, is_auto)
    end
    return
end

-------------------------------------------------------------------------------
-- 8. STRING BUILDING OPTIMIZATION
-------------------------------------------------------------------------------

local function build_menu_text(items, current_index)
    local lines = {}
    
    for i, item in ipairs(items) do
        local prefix = (i == current_index) and "▶ " or "  "
        local line = string.format("%s%d. %s", prefix, i, item.title)
        table.insert(lines, line)
    end
    
    return table.concat(lines, "\n")
end

-------------------------------------------------------------------------------
-- 9. DEPENDENCY INJECTION FOR TESTABILITY
-------------------------------------------------------------------------------

-- Make functions accept dependencies instead of using globals
local function create_subtitle_searcher(api_client, cache_manager, logger)
    return {
        search = function(self, anilist_id)
            logger:info("Searching subtitles for: " .. anilist_id)
            
            -- Try cache first
            local cached = cache_manager:get(anilist_id)
            if cached then
                logger:info("Using cached result")
                return success(cached)
            end
            
            -- API call
            local result = api_client:search(anilist_id)
            if not result.ok then
                return result
            end
            
            -- Cache the result
            cache_manager:set(anilist_id, result.value)
            return result
        end
    }
end

-- Now testable:
local mock_api = { search = function() return success({id = 123}) end }
local mock_cache = { get = function() return nil end, set = function() end }
local mock_logger = { info = function() end }

local searcher = create_subtitle_searcher(mock_api, mock_cache, mock_logger)
local result = searcher:search("test-id")
assert(result.ok == true)

-------------------------------------------------------------------------------
-- 10. USAGE EXAMPLE - Putting It All Together
-------------------------------------------------------------------------------

function Jimaku:init()
    -- Initialize logger
    Logger:init(self.config.log_file, self.config.log_only_errors)
    
    -- Initialize caches
    self.cache.anilist = CacheManager:new(ANILIST_CACHE_FILE)
    self.cache.jimaku = CacheManager:new(JIMAKU_CACHE_FILE)
    
    -- Load cached data
    self.cache.anilist:load()
    self.cache.jimaku:load()
    
    Logger:info("Jimaku initialized successfully")
end

function Jimaku:search(filename, is_auto)
    -- Parse filename
    local parsed = parse_filename(filename)
    if not parsed then
        Logger:error("Failed to parse filename: " .. filename)
        return failure(ErrorCodes.PARSE_ERROR, "Invalid filename format")
    end
    
    -- Search AniList
    local anilist_result = self:search_anilist(parsed)
    if not anilist_result.ok then
        Logger:error("AniList search failed: " .. anilist_result.message)
        return anilist_result
    end
    
    -- Search Jimaku
    local jimaku_result = self:search_jimaku(anilist_result.value.id)
    if not jimaku_result.ok then
        Logger:error("Jimaku search failed: " .. jimaku_result.message)
        return jimaku_result
    end
    
    -- Download subtitle
    return self:download_subtitle(jimaku_result.value, parsed.episode)
end

return Jimaku