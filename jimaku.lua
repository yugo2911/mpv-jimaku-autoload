-- jimaku.lua - Refactored for Maintainability
-- Automatic Japanese subtitle downloader for mpv using jimaku.cc API
-- Author: Refactored version
-- Version: 2.0

-------------------------------------------------------------------------------
-- INITIALIZATION & MODE DETECTION
-------------------------------------------------------------------------------
local STANDALONE_MODE = not pcall(function() return mp.get_property("filename") end)
local utils = (not STANDALONE_MODE) and require('mp.utils') or nil

-------------------------------------------------------------------------------
-- MODULE: Configuration
-------------------------------------------------------------------------------
local Config = {
    -- Default values
    defaults = {
        jimaku_api_key       = "",
        SUBTITLE_CACHE_DIR   = "./subtitle-cache",
        JIMAKU_MAX_SUBS      = 10,
        JIMAKU_AUTO_DOWNLOAD = true,
        LOG_ONLY_ERRORS      = false,
        JIMAKU_HIDE_SIGNS    = false,
        JIMAKU_ITEMS_PER_PAGE= 8,
        JIMAKU_MENU_TIMEOUT  = 30,
        JIMAKU_FONT_SIZE     = 16,
        INITIAL_OSD_MESSAGES = true,
        LOG_FILE             = true,
        USE_ANILIST_API      = true,
        USE_JIMAKU_API       = true
    },
    
    -- Runtime values
    values = {},
    
    -- Paths
    paths = {
        config_dir = nil,
        log_file = nil,
        cache_dir = nil,
        anilist_cache = nil,
        jimaku_cache = nil,
        preferred_groups = nil
    }
}

function Config:init()
    -- Determine config directory
    self.paths.config_dir = STANDALONE_MODE and "." 
        or mp.command_native({"expand-path", "~~/"})
    
    -- Load options from file
    if not STANDALONE_MODE then
        require("mp.options").read_options(self.defaults, "jimaku")
    end
    
    -- Copy defaults to values
    for k, v in pairs(self.defaults) do
        self.values[k] = v
    end
    
    -- Setup paths
    self:setup_paths()
    
    return self
end

function Config:setup_paths()
    local dir = self.paths.config_dir
    
    -- Setup cache directory
    local cache_dir = self.values.SUBTITLE_CACHE_DIR
    cache_dir = cache_dir:gsub('^"', ''):gsub('"$', '')  -- Strip quotes
    cache_dir = cache_dir:gsub("^'", ""):gsub("'$", '')
    
    if not cache_dir:match("^/") and not cache_dir:match("^%a:") then
        if not STANDALONE_MODE then
            cache_dir = dir .. "/" .. cache_dir:gsub("^./", "")
        end
    end
    
    self.paths.cache_dir = cache_dir
    self.paths.log_file = self.values.LOG_FILE and dir .. "/jimaku.log" or nil
    self.paths.anilist_cache = dir .. "/cache/anilist-cache.json"
    self.paths.jimaku_cache = dir .. "/cache/jimaku-cache.json"
    self.paths.preferred_groups = dir .. "/cache/preferred-groups.json"
end

function Config:get(key)
    return self.values[key]
end

function Config:get_path(key)
    return self.paths[key]
end

-------------------------------------------------------------------------------
-- MODULE: Logger
-------------------------------------------------------------------------------
local Logger = {
    file_path = nil,
    only_errors = false
}

function Logger:init(log_file, only_errors)
    self.file_path = log_file
    self.only_errors = only_errors or false
end

function Logger:log(message, is_error)
    if self.only_errors and not is_error then return end
    
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local formatted = string.format("[%s] %s", timestamp, message)
    
    -- Console output
    print("Jimaku: " .. message)
    
    -- File output
    if self.file_path then
        local f = io.open(self.file_path, "a")
        if f then
            f:write(formatted .. "\n")
            f:close()
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
-- MODULE: Constants
-------------------------------------------------------------------------------
local Constants = {
    -- API URLs
    ANILIST_API_URL = "https://graphql.anilist.co",
    JIMAKU_API_URL = "https://jimaku.cc/api",
    
    -- Timeouts
    AUTO_SEARCH_DELAY = 0.5,
    MENU_TIMEOUT = 30,
    API_TIMEOUT = 5,
    
    -- Limits
    ANILIST_RESULTS_PER_PAGE = 15,
    CACHE_TTL_SECONDS = 86400,  -- 24 hours
    
    -- Matching
    CONFIDENCE_THRESHOLD = 35,  -- Lower threshold for better matches
    EXACT_TITLE_BONUS = 50,
    PARTIAL_TITLE_BONUS = 30,   -- New: partial match bonus
    YEAR_MATCH_BONUS = 15,
    FORMAT_MATCH_BONUS = 10,
    EPISODE_RANGE_BONUS = 20,
    
    -- UI
    OSD_DURATION_SHORT = 3,
    OSD_DURATION_LONG = 7,
    
    -- Error messages
    API_KEY_ERROR = "Error: Jimaku API key not set"
}

-------------------------------------------------------------------------------
-- MODULE: Utility Functions
-------------------------------------------------------------------------------
local Utils = {}

function Utils.ensure_directory(path)
    if STANDALONE_MODE then return end
    mp.command_native({
        name = "subprocess",
        args = {"mkdir", "-p", path},
        playback_only = false
    })
end

function Utils.run_subprocess(args, parse_json)
    if STANDALONE_MODE then return nil end
    
    local res = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = args
    })
    
    if res.status ~= 0 or not res.stdout then
        return nil
    end
    
    if parse_json then
        local ok, data = pcall(utils.parse_json, res.stdout)
        return ok and data or nil
    end
    
    return res.stdout
end

function Utils.table_length(tbl)
    if not tbl or type(tbl) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    return count
end

function Utils.show_osd(message, duration, is_auto, config)
    if message and (not is_auto or config:get("INITIAL_OSD_MESSAGES")) then
        mp.osd_message(message, duration or Constants.OSD_DURATION_SHORT)
    end
end

-------------------------------------------------------------------------------
-- MODULE: Cache Manager
-------------------------------------------------------------------------------
local CacheManager = {}
CacheManager.__index = CacheManager

function CacheManager:new(cache_file, ttl)
    local obj = setmetatable({}, CacheManager)
    obj.file = cache_file
    obj.data = {}
    obj.ttl = ttl or Constants.CACHE_TTL_SECONDS
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
    
    if content and content ~= "" and utils then
        local ok, data = pcall(utils.parse_json, content)
        if ok then
            self.data = data or {}
            Logger:info("Loaded cache from " .. self.file)
            return self.data
        end
    end
    
    return {}
end

function CacheManager:save()
    if not utils then return false end
    
    -- Ensure directory exists
    local dir = self.file:match("^(.*[/\\])")
    if dir then
        Utils.ensure_directory(dir)
    end
    
    local json = utils.format_json(self.data)
    local f = io.open(self.file, "w")
    if not f then
        Logger:error("Cannot write cache file: " .. self.file)
        return false
    end
    
    f:write(json)
    f:close()
    Logger:info("Saved cache to " .. self.file)
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
    
    return entry.value or entry
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
-- MODULE: Async Handler
-------------------------------------------------------------------------------
local AsyncHandler = {
    pending_requests = {},
    request_id_counter = 0,
    task_queue = {}
}

function AsyncHandler:create_promise(fn, callback)
    local id = self.request_id_counter + 1
    self.request_id_counter = id
    self.pending_requests[id] = true
    
    if STANDALONE_MODE then
        local ok, res = pcall(fn)
        callback(ok, res)
        return id
    end
    
    mp.add_timeout(0, function()
        if not self.pending_requests[id] then return end
        local ok, res = pcall(fn)
        if self.pending_requests[id] then
            self.pending_requests[id] = nil
            callback(ok, res)
        end
    end)
    
    return id
end

function AsyncHandler:cancel_promise(id)
    if id then
        self.pending_requests[id] = nil
    end
end

function AsyncHandler:queue_task(fn, priority)
    table.insert(self.task_queue, {
        fn = fn,
        priority = priority or 999,
        created = os.time()
    })
    table.sort(self.task_queue, function(a, b)
        return a.priority < b.priority
    end)
end

-------------------------------------------------------------------------------
-- MODULE: Filename Parser
-------------------------------------------------------------------------------
local FilenameParser = {}

-- Normalize full-width digits to ASCII
function FilenameParser.normalize_digits(s)
    if not s then return s end
    local map = {
        ["０"]="0", ["１"]="1", ["２"]="2", ["３"]="3", ["４"]="4",
        ["５"]="5", ["６"]="6", ["７"]="7", ["８"]="8", ["９"]="9"
    }
    for k, v in pairs(map) do
        s = s:gsub(k, v)
    end
    return s
end

-- Clean Japanese/CJK characters from title
function FilenameParser.clean_japanese_text(title)
    if not title then return title end
    
    -- Remove Japanese brackets
    title = title:gsub("「[^」]*」", "")
    title = title:gsub("『[^』]*』", "")
    
    -- Remove CJK unicode ranges
    title = title:gsub("[\227-\237][\128-\191]+", "")
    
    -- Clean up spaces
    title = title:gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    
    return title
end

-- Strip version tags (v2, v3, etc.)
function FilenameParser.strip_version_tag(str)
    if not str then return str end
    str = str:gsub("%s*v%d+%s*", " ")
    str = str:gsub("%-v%d+", "")
    str = str:gsub("%s+", " ")
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    return str
end

-- Clean parenthetical content
function FilenameParser.clean_parenthetical(title)
    if not title then return title end
    
    -- Remove hex checksums
    title = title:gsub("%s*%[[0-9A-Fa-f]+%]%s*", " ")
    
    -- Remove resolution tags
    title = title:gsub("%s*%(%d%d%d%d?p%)%s*", " ")
    
    -- Remove quality tags
    local quality_tags = {"BD", "DVD", "WEB", "Blu%-ray", "Remux", "HEVC"}
    for _, tag in ipairs(quality_tags) do
        title = title:gsub("%s*%([^)]*" .. tag .. "[^)]*%)%s*", " ")
    end
    
    -- Remove language codes
    title = title:gsub("%s*%([A-Z][A-Z]%)%s*", " ")
    
    -- Remove RECAP tags
    title = title:gsub("%s*%(RECAP%)%s*", " ")
    title = title:gsub("%s*%[RECAP%]%s*", " ")
    
    -- Clean up
    title = title:gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    
    return title
end

-- Extract release group from brackets
function FilenameParser.extract_group_name(content)
    if not content then return nil end
    
    -- Try to find group in square brackets at start
    local group = content:match("^%[([^%]]+)%]")
    if group and group:len() >= 2 and group:len() <= 50 then
        return group
    end
    
    return nil
end

-- Extract year from filename
function FilenameParser.extract_year(filename)
    if not filename then return nil end
    
    -- Look for 4-digit year in reasonable range
    local year = filename:match("[%(%)%[%]%s]+(19%d%d)[%(%)%[%]%s]+")
                or filename:match("[%(%)%[%]%s]+(20%d%d)[%(%)%[%]%s]+")
    
    if year then
        local y = tonumber(year)
        if y >= 1960 and y <= 2030 then
            return y
        end
    end
    
    return nil
end

-- Parse season/episode from filename
function FilenameParser.parse_episode_info(filename)
    if not filename then return nil, nil end
    
    filename = FilenameParser.normalize_digits(filename)
    
    -- Season and episode patterns (SxxExx format)
    local season, episode = filename:match("[Ss](%d+)[Ee](%d+)")
    if season and episode then
        return tonumber(season), tonumber(episode)
    end
    
    -- Episode-only patterns (ordered by specificity)
    local ep = filename:match("[Ee][Pp]%s*(%d+)")           -- EP01, Ep 01
          or filename:match("%s%-%s+(%d+)%s*%[")            -- " - 05 ["
          or filename:match("%s%-%s+(%d+)%s*%(")            -- " - 05 ("
          or filename:match("%-%s*(%d+)%s*%[")              -- "- 05["
          or filename:match("%-%s*(%d+)%s*%(")              -- "- 05("
          or filename:match("%s(%d+)%s*%[")                 -- " 05 ["
          or filename:match("%s(%d+)%s*%(")                 -- " 05 ("
          or filename:match("_(%d+)%.[aA][sS][sS]")         -- "_05.ass"
          or filename:match("^(%d+)%.")                     -- "05."
    
    if ep then
        local num = tonumber(ep)
        -- Sanity check: episode numbers should be reasonable
        if num and num >= 0 and num <= 999 then
            return nil, num
        end
    end
    
    return nil, nil
end

-- Main parsing function
function FilenameParser.parse(filename)
    if not filename then return nil end
    
    Logger:info("Parsing filename: " .. filename)
    
    local result = {
        original = filename,
        title = nil,
        episode = nil,
        season = nil,
        group = nil,
        year = nil
    }
    
    -- Remove file extension
    local basename = filename:match("^(.+)%.[^%.]+$") or filename
    
    -- Extract components
    result.group = FilenameParser.extract_group_name(basename)
    result.year = FilenameParser.extract_year(basename)
    
    -- Remove group tag from content
    local content = basename
    if result.group then
        content = content:gsub("^%[" .. result.group:gsub("%-", "%%-") .. "%]%s*", "")
    end
    
    -- Parse episode info
    result.season, result.episode = FilenameParser.parse_episode_info(content)
    
    -- Extract title
    local title = content
    
    -- Remove episode markers (more comprehensive)
    title = title:gsub("[Ss]%d+[Ee]%d+", "")              -- S01E01
    title = title:gsub("[Ee][Pp]%s*%d+", "")              -- EP01, Ep 01
    title = title:gsub("%s%-%s+%d+%s*$", "")              -- " - 05" at end
    title = title:gsub("%s%-%s+%d+%s*%[", " [")           -- " - 05 ["
    title = title:gsub("%s%-%s+%d+%s*%(", " (")           -- " - 05 ("
    title = title:gsub("%-%s*%d+%s*%[", " [")             -- "- 05["
    title = title:gsub("%-%s*%d+%s*%(", " (")             -- "- 05("
    
    -- Clean title
    title = FilenameParser.strip_version_tag(title)
    title = FilenameParser.clean_japanese_text(title)
    title = FilenameParser.clean_parenthetical(title)
    
    -- Replace separators with spaces
    title = title:gsub("[%._]", " ")
    title = title:gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    
    -- Validate title
    if title and title:len() >= 2 and title:match("%a") then
        result.title = title
    end
    
    Logger:info(string.format("Parsed: title='%s', S%s E%s, group='%s', year=%s",
        result.title or "N/A",
        result.season or "?",
        result.episode or "?",
        result.group or "N/A",
        result.year or "N/A"))
    
    return result
end

-------------------------------------------------------------------------------
-- MODULE: API Client (AniList)
-------------------------------------------------------------------------------
local AniListAPI = {
    cache = nil
}

function AniListAPI:init(cache_manager)
    self.cache = cache_manager
end

function AniListAPI:make_request(query, variables)
    if not utils then
        Logger:error("Utils not available for API request")
        return nil
    end
    
    local body = utils.format_json({
        query = query,
        variables = variables
    })
    
    local args = {
        "curl", "-s", "-X", "POST",
        "-m", tostring(Constants.API_TIMEOUT),
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "--data", body,
        Constants.ANILIST_API_URL
    }
    
    local data = Utils.run_subprocess(args, true)
    
    if not data or data.errors then
        Logger:error("AniList API request failed")
        return nil
    end
    
    return data.data
end

function AniListAPI:search(title)
    Logger:info("Searching AniList for: " .. title)
    
    -- Check cache first
    local cache_key = "search:" .. title:lower()
    local cached = self.cache:get(cache_key)
    if cached then
        Logger:info("Using cached AniList results")
        return cached
    end
    
    -- Build query
    local query = [[
        query ($search: String) {
            Page (perPage: ]] .. Constants.ANILIST_RESULTS_PER_PAGE .. [[) {
                media (search: $search, type: ANIME) {
                    id
                    title { romaji english native }
                    synonyms
                    status
                    episodes
                    format
                    seasonYear
                    relations {
                        edges {
                            relationType
                            node {
                                id
                                title { romaji english }
                                synonyms
                                episodes
                                format
                                status
                                seasonYear
                            }
                        }
                    }
                }
            }
        }
    ]]
    
    local data = self:make_request(query, {search = title})
    
    if data and data.Page and data.Page.media and #data.Page.media > 0 then
        self.cache:set(cache_key, data.Page.media)
        Logger:info("Found " .. #data.Page.media .. " results")
        return data.Page.media
    end
    
    -- Try fallbacks if no results
    Logger:info("No results, trying fallbacks...")
    
    local fallbacks = {
        title:match("^(.-)%s*%-%s*.+$"),  -- Everything before first " - "
        title:match("^(%S+%s+%S+)"),       -- First two words
        title:match("^(%S+)")              -- First word only
    }
    
    for _, fallback in ipairs(fallbacks) do
        if fallback and #fallback > 2 and fallback ~= title then
            Logger:info("Trying fallback: " .. fallback)
            data = self:make_request(query, {search = fallback})
            
            if data and data.Page and data.Page.media and #data.Page.media > 0 then
                Logger:info("Fallback successful! Found " .. #data.Page.media .. " results")
                self.cache:set(cache_key, data.Page.media)
                return data.Page.media
            end
        end
    end
    
    Logger:info("No results found after fallbacks")
    return nil
end

-------------------------------------------------------------------------------
-- MODULE: API Client (Jimaku)
-------------------------------------------------------------------------------
local JimakuAPI = {
    api_key = nil,
    cache = nil
}

function JimakuAPI:init(api_key, cache_manager)
    self.api_key = api_key
    self.cache = cache_manager
end

function JimakuAPI:has_api_key()
    return self.api_key and self.api_key ~= ""
end

function JimakuAPI:make_request(path)
    if not utils then
        Logger:error("Utils not available for API request")
        return nil
    end
    
    local args = {
        "curl", "-s",
        "-m", tostring(Constants.API_TIMEOUT),
        Constants.JIMAKU_API_URL .. path
    }
    
    return Utils.run_subprocess(args, true)
end

function JimakuAPI:search_by_anilist_id(anilist_id)
    if not self:has_api_key() then
        return nil, "MISSING_KEY"
    end
    
    Logger:info("Searching Jimaku for AniList ID: " .. anilist_id)
    
    -- Check cache
    local cache_key = "anilist:" .. anilist_id
    local cached = self.cache:get(cache_key)
    if cached then
        Logger:info("Using cached Jimaku entry")
        return cached
    end
    
    -- Build API URL with anilist_id and anime flag
    local search_url = string.format("%s/entries/search?anilist_id=%d&anime=true",
        Constants.JIMAKU_API_URL, anilist_id)
    
    Logger:info("Jimaku API URL: " .. search_url)
    
    -- Make request with Authorization header
    local args = {
        "curl", "-s", "-X", "GET",
        "-H", "Authorization: " .. self.api_key,
        search_url
    }
    
    local data = Utils.run_subprocess(args, true)
    
    if data and #data > 0 then
        self.cache:set(cache_key, data[1])
        Logger:info("Found Jimaku entry: " .. data[1].name .. " (ID: " .. data[1].id .. ")")
        return data[1]
    end
    
    Logger:info("No Jimaku entry found")
    return nil
end

function JimakuAPI:download_subtitle(jimaku_entry_id, episode)
    if not self:has_api_key() then
        return nil, "MISSING_KEY"
    end
    
    Logger:info(string.format("Fetching subtitle files: entry=%s, episode=%s",
        jimaku_entry_id, episode))
    
    -- Get ALL files for this entry (not filtered by episode)
    local files_url = string.format("%s/entries/%d/files",
        Constants.JIMAKU_API_URL, jimaku_entry_id)
    
    Logger:info("Fetching from: " .. files_url)
    
    local args = {
        "curl", "-s", "-X", "GET",
        "-H", "Authorization: " .. self.api_key,
        files_url
    }
    
    local data = Utils.run_subprocess(args, true)
    
    if data and #data > 0 then
        Logger:info("Found " .. #data .. " total subtitle files")
        
        -- Filter for matching episode
        local matching = {}
        for _, file in ipairs(data) do
            -- Parse episode from filename
            local _, file_ep = FilenameParser.parse_episode_info(file.name)
            if file_ep and file_ep == episode then
                table.insert(matching, file)
                Logger:info("  Match: " .. file.name)
            end
        end
        
        if #matching > 0 then
            Logger:info(string.format("Found %d matching files for episode %d", #matching, episode))
            return matching
        else
            Logger:info(string.format("No files match episode %d (found %d total files)", episode, #data))
        end
    end
    
    return nil
end

-------------------------------------------------------------------------------
-- MODULE: Matcher (AniList Results)
-------------------------------------------------------------------------------
local Matcher = {}

function Matcher.score_title_match(candidate_title, search_title)
    local score = 0
    local c_lower = candidate_title:lower()
    local s_lower = search_title:lower()
    
    -- Exact match
    if c_lower == s_lower then
        score = Constants.EXACT_TITLE_BONUS
    -- One contains the other
    elseif c_lower:find(s_lower, 1, true) then
        score = Constants.PARTIAL_TITLE_BONUS
    elseif s_lower:find(c_lower, 1, true) then
        score = Constants.PARTIAL_TITLE_BONUS
    else
        -- Try word-by-word matching for partial credit
        local search_words = {}
        for word in s_lower:gmatch("%S+") do
            if #word > 2 then  -- Skip short words
                search_words[word] = true
            end
        end
        
        local matched_words = 0
        local total_words = 0
        for word in c_lower:gmatch("%S+") do
            if #word > 2 then
                total_words = total_words + 1
                if search_words[word] then
                    matched_words = matched_words + 1
                end
            end
        end
        
        if total_words > 0 and matched_words > 0 then
            local match_ratio = matched_words / total_words
            score = math.floor(Constants.PARTIAL_TITLE_BONUS * match_ratio)
        end
    end
    
    return score
end

function Matcher.score_candidate(candidate, parsed, target_ep, target_season, year)
    local score = 0
    
    -- Title match
    if candidate.title.romaji then
        score = score + Matcher.score_title_match(candidate.title.romaji, parsed.title)
    end
    
    -- Year match
    if year and candidate.seasonYear == year then
        score = score + Constants.YEAR_MATCH_BONUS
    end
    
    -- Format preference
    if candidate.format == "TV" or candidate.format == "TV_SHORT" then
        score = score + Constants.FORMAT_MATCH_BONUS
    end
    
    -- Episode range validity
    if candidate.episodes and target_ep then
        if target_ep <= candidate.episodes then
            score = score + Constants.EPISODE_RANGE_BONUS
        else
            score = score - 10
        end
    end
    
    return score
end

function Matcher.find_best_match(results, parsed, episode, season, year)
    if not results or #results == 0 then
        return nil
    end
    
    Logger:info("Matching against " .. #results .. " candidates")
    Logger:info(string.format("Target: episode=%s, season=%s, year=%s",
        tostring(episode), tostring(season), tostring(year)))
    
    local scored = {}
    
    for _, candidate in ipairs(results) do
        local score = Matcher.score_candidate(candidate, parsed, episode, season, year)
        
        if score > 0 then
            table.insert(scored, {
                candidate = candidate,
                score = score
            })
            
            -- Log each candidate's score
            Logger:info(string.format("  Candidate: %s (score: %d, eps: %s, format: %s)",
                candidate.title.romaji or "?",
                score,
                tostring(candidate.episodes or "?"),
                candidate.format or "?"))
        end
    end
    
    -- Sort by score descending
    table.sort(scored, function(a, b) return a.score > b.score end)
    
    if #scored > 0 then
        local best = scored[1]
        Logger:info(string.format("Best match: %s (score: %d, threshold: %d)",
            best.candidate.title.romaji, best.score, Constants.CONFIDENCE_THRESHOLD))
        
        if best.score >= Constants.CONFIDENCE_THRESHOLD then
            return best.candidate, best.score
        else
            Logger:info("Score below threshold - no confident match")
        end
    end
    
    Logger:info("No confident match found")
    return nil
end

-------------------------------------------------------------------------------
-- MODULE: Local Cache Search
-------------------------------------------------------------------------------
local LocalCacheSearcher = {
    cache_dir = nil
}

function LocalCacheSearcher:init(cache_dir)
    self.cache_dir = cache_dir
end

function LocalCacheSearcher:search_local_cache(parsed_title, episode)
    if not utils then return nil end
    
    Logger:info("Searching local subtitle cache...")
    Logger:info("Cache directory: " .. self.cache_dir)
    
    -- Walk the cache directory
    local function walk_dir(path)
        local files = {}
        local entries = utils.readdir(path, "files")
        local dirs = utils.readdir(path, "dirs")
        
        if entries then
            for _, file in ipairs(entries) do
                if file:match("%.ass$") or file:match("%.srt$") then
                    table.insert(files, path .. "/" .. file)
                end
            end
        end
        
        if dirs then
            for _, dir in ipairs(dirs) do
                if dir ~= "." and dir ~= ".." then
                    local sub_files = walk_dir(path .. "/" .. dir)
                    for _, f in ipairs(sub_files) do
                        table.insert(files, f)
                    end
                end
            end
        end
        
        return files
    end
    
    local all_files = walk_dir(self.cache_dir)
    Logger:info("Found " .. #all_files .. " subtitle files in cache")
    
    if #all_files == 0 then
        return nil
    end
    
    -- Search for matching files
    local title_lower = parsed_title:lower()
    local matches = {}
    
    for _, filepath in ipairs(all_files) do
        local filename = filepath:match("([^/\\]+)$") or filepath
        
        -- Simple matching - check if filename contains title
        if filename:lower():find(title_lower, 1, true) then
            -- Parse episode from filename
            local _, file_ep = FilenameParser.parse_episode_info(filename)
            
            if file_ep and file_ep == episode then
                table.insert(matches, filepath)
                Logger:info("Local cache match: " .. filename)
            end
        end
    end
    
    if #matches > 0 then
        Logger:info("Found " .. #matches .. " matching files in local cache")
        return matches[1]  -- Return first match
    end
    
    Logger:info("No matching files in local cache")
    return nil
end

-------------------------------------------------------------------------------
-- MODULE: Subtitle Downloader
-------------------------------------------------------------------------------
local SubtitleDownloader = {
    config = nil,
    api = nil
}

function SubtitleDownloader:init(config, jimaku_api)
    self.config = config
    self.api = jimaku_api
end

function SubtitleDownloader:download_file(url, output_path)
    if not self.api:has_api_key() then
        return false, "MISSING_KEY"
    end
    
    local args = {
        "curl", "-s", "-L",
        "-o", output_path,
        "-H", "Authorization: " .. self.api.api_key,
        url
    }
    
    local result = Utils.run_subprocess(args, false)
    return result ~= nil
end

function SubtitleDownloader:download_subtitle(jimaku_entry_id, episode, output_dir)
    Logger:info(string.format("Downloading subtitle for episode %d", episode))
    
    -- Get available files
    local files, error_code = self.api:download_subtitle(jimaku_entry_id, episode)
    
    if error_code == "MISSING_KEY" then
        return nil, error_code
    end
    
    if not files or #files == 0 then
        Logger:info("No subtitle files available")
        return nil
    end
    
    -- Select first file (or implement preference logic)
    local file = files[1]
    local output_path = output_dir .. "/" .. file.name
    
    Logger:info("Downloading: " .. file.name)
    
    local success, err = self:download_file(file.url, output_path)
    
    if success then
        Logger:info("Downloaded successfully")
        return output_path
    else
        Logger:error("Download failed: " .. tostring(err))
        return nil, err
    end
end

-------------------------------------------------------------------------------
-- MODULE: Main Controller
-------------------------------------------------------------------------------
local JimakuController = {
    config = nil,
    logger = nil,
    anilist_api = nil,
    jimaku_api = nil,
    downloader = nil,
    anilist_cache = nil,
    jimaku_cache = nil
}

function JimakuController:init()
    -- Initialize configuration
    self.config = Config:init()
    
    -- Initialize logger
    Logger:init(
        self.config:get_path("log_file"),
        self.config:get("LOG_ONLY_ERRORS")
    )
    
    Logger:info("Jimaku controller initializing...")
    
    -- Create cache directory
    Utils.ensure_directory(self.config:get_path("cache_dir"))
    
    -- Initialize caches
    self.anilist_cache = CacheManager:new(self.config:get_path("anilist_cache"))
    self.jimaku_cache = CacheManager:new(self.config:get_path("jimaku_cache"))
    
    self.anilist_cache:load()
    self.jimaku_cache:load()
    
    -- Initialize APIs
    self.anilist_api = AniListAPI
    self.anilist_api:init(self.anilist_cache)
    
    self.jimaku_api = JimakuAPI
    self.jimaku_api:init(self.config:get("jimaku_api_key"), self.jimaku_cache)
    
    -- Initialize downloader
    self.downloader = SubtitleDownloader
    self.downloader:init(self.config, self.jimaku_api)
    
    Logger:info("Jimaku initialized successfully")
end

function JimakuController:search_and_download(filename, is_auto)
    Logger:info("=== Starting search and download ===")
    
    -- Parse filename
    local parsed = FilenameParser.parse(filename)
    if not parsed or not parsed.title then
        Logger:error("Failed to parse filename")
        Utils.show_osd("Failed to parse filename", nil, is_auto, self.config)
        return false
    end
    
    -- Search AniList
    local results = self.anilist_api:search(parsed.title)
    if not results then
        Logger:info("No AniList results found")
        Utils.show_osd("No anime matches found", nil, is_auto, self.config)
        return false
    end
    
    -- Find best match
    local match, confidence = Matcher.find_best_match(
        results,
        parsed,
        parsed.episode or 1,
        parsed.season or 1,
        parsed.year
    )
    
    if not match then
        Logger:info("No confident match found")
        Utils.show_osd("No confident matches found", nil, is_auto, self.config)
        return false
    end
    
    -- Show match info
    Utils.show_osd(
        string.format("Match: %s (confidence: %d%%)",
            match.title.romaji, confidence),
        Constants.OSD_DURATION_LONG,
        is_auto,
        self.config
    )
    
    -- Search Jimaku
    local jimaku_entry, error_code = self.jimaku_api:search_by_anilist_id(match.id)
    
    if error_code == "MISSING_KEY" then
        Utils.show_osd(Constants.API_KEY_ERROR, nil, is_auto, self.config)
        return false
    end
    
    if not jimaku_entry then
        Logger:info("No Jimaku entry found")
        Utils.show_osd("No subtitles found on Jimaku", nil, is_auto, self.config)
        return false
    end
    
    -- Download subtitle
    local subtitle_path, dl_error = self.downloader:download_subtitle(
        jimaku_entry.id,
        parsed.episode or 1,
        self.config:get_path("cache_dir")
    )
    
    if dl_error == "MISSING_KEY" then
        Utils.show_osd(Constants.API_KEY_ERROR, nil, is_auto, self.config)
        return false
    end
    
    if subtitle_path then
        Logger:info("Subtitle downloaded successfully")
        Utils.show_osd("Subtitle downloaded!", nil, is_auto, self.config)
        
        -- Load subtitle in mpv
        if not STANDALONE_MODE then
            mp.commandv("sub-add", subtitle_path)
        end
        
        return true
    else
        Logger:error("Failed to download subtitle")
        Utils.show_osd("Failed to download subtitle", nil, is_auto, self.config)
        return false
    end
end

-------------------------------------------------------------------------------
-- MPV INTEGRATION
-------------------------------------------------------------------------------
if not STANDALONE_MODE then
    -- Initialize controller
    local controller = JimakuController
    controller:init()
    
    -- Manual search keybind
    mp.add_key_binding("A", "jimaku-search", function()
        local filename = mp.get_property("filename")
        if filename then
            controller:search_and_download(filename, false)
        end
    end)
    
    -- Auto-download on file load
    mp.register_event("file-loaded", function()
        if controller.config:get("JIMAKU_AUTO_DOWNLOAD") then
            mp.add_timeout(Constants.AUTO_SEARCH_DELAY, function()
                local filename = mp.get_property("filename")
                if filename then
                    controller:search_and_download(filename, true)
                end
            end)
        end
    end)
    
    Logger:info("Jimaku mpv integration ready")
end

-------------------------------------------------------------------------------
-- STANDALONE MODE
-------------------------------------------------------------------------------
if STANDALONE_MODE then
    print("Jimaku.lua - Standalone mode")
    print("This script is designed to run within mpv")
    print("Load it as an mpv script to enable functionality")
end