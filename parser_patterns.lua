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
    
    -- 2. Strip trailing versions/resolutions/metadata
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
    -- TIER 2: SPECIALS & MOVIES (Handling your Nil results)
    -- =========================================================================

    -- [Group] Title - Movie [Hash]
    {
        name = "anime_movie_with_hash",
        confidence = 95,
        regex = "^%[(.-)%]%s*(.-)%s+[%-–—]%s-[Mm]ovie%s+.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "hash" },
        is_movie = true
    },

    -- [Group] Title - Special ## [Hash] (e.g. SP11, Egghead SP11)
    {
        name = "anime_special_numbered_hash",
        confidence = 95,
        regex = "^%[(.-)%]%s*(.-)%s+[%-–—]%s-[Ss][Pp]?(%d+)%s+.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "episode", "hash" },
        is_special = true
    },

    -- Title - 03 [Metadata.mkv].rar (Bilibili/Crunchy style batches)
    {
        name = "anime_loose_metadata_rar",
        confidence = 92,
        regex = "^(.-)%s+[%-–—]%s+(%d+)%s+.*%[.*%].*%.rar$",
        fields = { "title", "absolute" }
    },

    -- Title - 01 [Group] (KingMenu/DOMO style)
    {
        name = "anime_trailing_group_absolute",
        confidence = 91,
        regex = "^(.-)%s+[%-–—]%s+(%d+)%s+.*%[(.-)%]$",
        fields = { "title", "absolute", "group" }
    },

    -- Title (Year) [DVD Remux] [Hash]
    {
        name = "anime_dvd_remux_year_hash",
        confidence = 90,
        regex = "^%[(.-)%]%s*(.-)%s+%(%d%d%d%d%)%s+.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "hash" }
    },

    -- =========================================================================
    -- TIER 3: STANDARD / SCENE (SxxExx)
    -- =========================================================================

    -- Title S01E01
    {
        name = "scene_standard",
        confidence = 93,
        regex = "^(.-)[%s%.%_]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },

    -- Title.Year.1080p.BluRay (Movie format)
    {
        name = "movie_scene_standard",
        confidence = 88,
        regex = "^(.-)[%.%s]+(%d%d%d%d)[%.%s]+%d%d%d%dp",
        fields = { "title", "year" },
        is_movie = true
    },

    -- =========================================================================
    -- TIER 4: LOOSE / LAST RESORT
    -- =========================================================================

    -- [SubsPlease] Title. (1080p) [Hash] (No episode number = Movie/One-shot)
    {
        name = "anime_one_shot_hash",
        confidence = 85,
        regex = "^%[(.-)%]%s*(.-)%.?%s*%(%d+p%)%s*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "hash" }
    },

    -- Title - OVA 01
    {
        name = "anime_ova_numbered",
        confidence = 85,
        regex = "^(.-)%s+[Oo][Vv][Aa]%s+(%d+)",
        fields = { "title", "absolute" },
        is_special = true
    },

    -- Final Fallback: [Group] Title [Hash]
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
    -- Clean multiple levels of extensions/wrappers
    local clean_name = filename:gsub("%.rar$", ""):gsub("%.mkv%]%.rar$", ""):gsub("%.mkv$", ""):gsub("%.mp4$", ""):gsub("%.avi$", "")

    for _, p in ipairs(PATTERNS) do
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

return M