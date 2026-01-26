local M = {}

local DEBUG_PATTERNS = false

-- ==================================================================================
-- HELPER FUNCTIONS
-- ==================================================================================

local function sanitize_title(title)
    if not title then return nil end
    
    -- 1. Strip Release Group if it wasn't caught (e.g. "Title [Group]")
    title = title:gsub("^%s*[%[%(].-[%]%)]%s*", "") -- Leading group
    title = title:gsub("%s*[%[%(].-[%]%)]%s*$", "") -- Trailing group
    
    -- 2. Strip trailing versions/resolutions (v2, 1080p, etc)
    title = title:gsub("%s*[%[%(]?%d+p[%]%)%]?$", "")
    title = title:gsub("%s*[vV]%d+$", "")
    
    -- 3. Replace dots/underscores with spaces
    title = title:gsub("[%.%_]", " ")
    
    -- 4. Strip "Season X" if it accidentally stayed in the title
    title = title:gsub("%s+[Ss]eason%s+%d+$", "")
    
    -- 5. Trim and normalize spaces
    title = title:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    
    return title
end

local function debug_pattern_hit(pattern_name, confidence, captures)
    if not DEBUG_PATTERNS then return end
    print(string.format(
        "HIT: %-30s | Conf: %d | Caps: [%s]",
        pattern_name, confidence, table.concat(captures, ", ")
    ))
end

-- ==================================================================================
-- PATTERN DEFINITIONS
-- ==================================================================================

local PATTERNS = {
    -- =========================================================================
    -- TIER 1: STRICT ANIME (Group + Absolute/Season) - CONFIDENCE 100
    -- =========================================================================

    -- [Group] Title - S01E02 (Standard strict)
    {
        name = "anime_group_strict_sxxexx",
        confidence = 100,
        regex = "^%[(.-)%]%s*(.-)%s+([Ss]%d+[Ee]%d+)%s*.*$", 
        fields = { "group", "title", "sxe" } 
    },

    -- [Group] Title - 01-02 (Multi-Episode Absolute)
    {
        name = "anime_group_absolute_batch",
        confidence = 100,
        regex = "^%[(.-)%]%s*(.-)%s+[%-–—]%s+(%d+)[%-~](%d+)%s*.*$",
        fields = { "group", "title", "absolute", "absolute_end" }
    },

    -- [Group] Title - 05 (S01E05)
    {
        name = "anime_group_absolute_hybrid_parens",
        confidence = 99,
        regex = "^%[(.-)%]%s*(.-)%s+[%-–—]%s+(%d+)%s*%(%s*[Ss](%d+)[Ee](%d+)%s*%)",
        fields = { "group", "title", "absolute", "season", "episode" }
    },

    -- [Group] Title - 05 [Hash]
    {
        name = "anime_group_absolute_hash_strict",
        confidence = 98,
        regex = "^%[(.-)%]%s*(.-)%s+[%-–—]%s+(%d+)%s+.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "absolute", "hash" }
    },

    -- [Group] Title - 05 (Simple Absolute)
    {
        name = "anime_group_absolute_simple",
        confidence = 97,
        regex = "^%[(.-)%]%s*(.-)%s+[%-–—]%s+(%d+)%s*.*$",
        fields = { "group", "title", "absolute" }
    },

    -- =========================================================================
    -- TIER 2: MOVIES & SPECIALS (Handling your Nil results)
    -- =========================================================================

    -- [Group] Title - Movie [Hash]
    {
        name = "anime_movie_with_hash",
        confidence = 95,
        regex = "^%[(.-)%]%s*(.-)%s+[%-–—]%s+[Mm]ovie%s+.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "hash" },
        is_movie = true
    },

    -- [Group] Title - Special ## [Hash] (e.g. SP11)
    {
        name = "anime_special_numbered_hash",
        confidence = 95,
        regex = "^%[(.-)%]%s*(.-)%s+[%-–—]%s+[Ss][Pp]?(%d+)%s+.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "episode", "hash" },
        is_special = true
    },

    -- Title (Year) [DVD Remux] [Hash]
    {
        name = "anime_dvd_remux_year_hash",
        confidence = 90,
        regex = "^%[(.-)%]%s*(.-)%s+%(%d%d%d%d%)%s+.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "hash" }
    },

    -- Title.Year.1080p.BluRay... (Movie format)
    {
        name = "movie_scene_standard",
        confidence = 88,
        regex = "^(.-)[%.%s]+(%d%d%d%d)[%.%s]+%d%d%d%dp",
        fields = { "title", "year" },
        is_movie = true
    },

    -- =========================================================================
    -- TIER 3: STANDARD / SCENE (SxxExx)
    -- =========================================================================

    -- Title S01E01-E02
    {
        name = "scene_multi_verbose",
        confidence = 95,
        regex = "^(.-)[%s%.%_]+[Ss](%d+)[Ee](%d+)[%-%~][Ee](%d+)",
        fields = { "title", "season", "episode", "episode_end" }
    },

    -- Title S01E01
    {
        name = "scene_standard",
        confidence = 93,
        regex = "^(.-)[%s%.%_]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },

    -- =========================================================================
    -- TIER 4: TEXTUAL & LOOSE
    -- =========================================================================

    -- Title - Episode 05
    {
        name = "text_verbose_episode_only",
        confidence = 82,
        regex = "^(.-)[%s%.%_]+[Ee]pisode[%s%.%_]+(%d+)",
        fields = { "title", "absolute" }
    },

    -- Last ditch: Just a group and a title and a hash at the end
    {
        name = "anime_group_title_hash_only",
        confidence = 60,
        regex = "^%[(.-)%]%s*(.-)%s+.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "hash" }
    }
}

-- ==================================================================================
-- LOGIC
-- ==================================================================================

local function parse_sxe(str)
    if not str then return nil, nil end
    return str:lower():match("s(%d+)e(%d+)")
end

function M.run_patterns(filename, logger)
    local clean_name = filename:gsub("%.[Mm][Kk][Vv]$", ""):gsub("%.[Mm][Pp]4$", ""):gsub("%.[Aa][Vv][Ii]$", "")

    for _, p in ipairs(PATTERNS) do
        -- Handle Lua's lack of {8} in regex by expanding the hash pattern manually if needed
        -- or using a simpler check. For now, we use a custom check in the loop.
        local regex = p.regex
        local captures = { clean_name:match(regex) }

        if #captures > 0 then
            if logger then
                logger(string.format("MATCH: %s (Conf: %d)", p.name, p.confidence))
            end

            local result = {
                pattern = p.name,
                confidence = p.confidence,
                is_special = p.is_special or false,
                is_movie = p.is_movie or false
            }

            for i, field in ipairs(p.fields) do
                local val = captures[i]
                if val then
                    if field == "sxe" then
                        result.season, result.episode = parse_sxe(val)
                    elseif field == "title" then
                        result.title = sanitize_title(val)
                    elseif field == "group" then
                        result.group = val:gsub("[%[%]]", "")
                    elseif field == "hash" then
                        result.hash = val:upper()
                    else
                        if field:match("episode") or field:match("season") or field:match("absolute") or field:match("year") then
                             result[field] = tonumber(val)
                        else
                             result[field] = val
                        end
                    end
                end
            end

            return result
        end
    end

    return nil
end

function M.test_patterns()
    -- Internal unit tests can go here
    print("Run parser_test.lua for full test suite.")
end

return M