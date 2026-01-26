local M = {}

local DEBUG_PATTERNS = false

-- ==================================================================================
-- HELPER FUNCTIONS
-- ==================================================================================

local function sanitize_title(title)
    if not title then return nil end
    
    -- 1. Strip Release Group if it wasn't caught (e.g. "Title [Group]")
    title = title:gsub("^%s*[%[%(].-[%]%)]%s*", "") 
    title = title:gsub("%s*[%[%(].-[%]%)]%s*$", "") 
    
    -- 2. Strip trailing versions/resolutions/extensions
    title = title:gsub("%s*[%[%(]?%d+p[%]%)%]?$", "")
    title = title:gsub("%s*[vV]%d+$", "")
    title = title:gsub("%.%a%a%a$", "") 
    
    -- 3. Replace dots/underscores with spaces
    title = title:gsub("[%.%_]", " ")
    
    -- 4. Strip specific keywords that aren't the title
    title = title:gsub("%s+[Ss]eason%s+%d+$", "")
    title = title:gsub("%s+[Mm]ovie$", "")
    title = title:gsub("%s+[Tt]he%s+[Mm]ovie$", "")
    
    -- 5. Trim and normalize spaces
    title = title:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    
    return title
end

-- ==================================================================================
-- PATTERN DEFINITIONS
-- ==================================================================================

local PATTERNS = {
    -- =========================================================================
    -- TIER 1: STRICT ANIME / BATCHES
    -- =========================================================================

    -- [Group] Title - S01E02
    {
        name = "anime_group_strict_sxxexx",
        confidence = 100,
        regex = "^%[(.-)%]%s*(.-)%s+([Ss]%d+[Ee]%d+)%s*.*$", 
        fields = { "group", "title", "sxe" } 
    },

    -- [Group] Title - 01-02 (Batch)
    {
        name = "anime_group_absolute_batch",
        confidence = 100,
        regex = "^%[(.-)%]%s*(.-)%s+[%-–—]%s+(%d+)[%-~](%d+)%s*.*$",
        fields = { "group", "title", "absolute", "absolute_end" }
    },

    -- [Group] Title - 05 [Hash]
    {
        name = "anime_group_absolute_hash_strict",
        confidence = 98,
        regex = "^%[(.-)%]%s*(.-)%s+[%-–—]%s+(%d+)%s+.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "absolute", "hash" }
    },

    -- =========================================================================
    -- TIER 2: MOVIES & SPECIALS
    -- =========================================================================

    -- [Group] Title - Movie [Hash]
    {
        name = "anime_movie_hash",
        confidence = 95,
        regex = "^%[(.-)%]%s*(.-)%s+[%-–—]%s+[Mm]ovie%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "hash" },
        is_movie = true
    },

    -- Title.Year.1080p... or Title Year 1080p (Handles Colorful Stage)
    {
        name = "scene_movie_year",
        confidence = 90,
        regex = "^(.-)[%.%s]+(%d%d%d%d)[%.%s]+%d%d%d%dp",
        fields = { "title", "year" },
        is_movie = true
    },

    -- [Group] Title - SP## [Hash]
    {
        name = "anime_special_numbered_hash",
        confidence = 95,
        regex = "^%[(.-)%]%s*(.-)%s+[Ss][Pp](%d+)%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "absolute", "hash" },
        is_special = true
    },

    -- [Group] Title (Year) [DVD Remux] [Hash]
    {
        name = "anime_remux_year_hash",
        confidence = 92,
        regex = "^%[(.-)%]%s*(.-)%s+%(%d%d%d%d%)%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "hash" }
    },

    -- =========================================================================
    -- TIER 3: RAR & MISC ARCHIVES
    -- =========================================================================

    -- Title - ## [Metadata].rar
    {
        name = "anime_rar_numbered",
        confidence = 90,
        regex = "^(.-)%s+[%-–—]%s+(%d+)%s*.*%.rar$",
        fields = { "title", "absolute" }
    },

    -- =========================================================================
    -- TIER 4: SCENE / STANDALONE
    -- =========================================================================

    -- Title S01E01
    {
        name = "scene_standard",
        confidence = 93,
        regex = "^(.-)[%s%.%_]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },

    -- =========================================================================
    -- TIER 5: FALLBACKS
    -- =========================================================================

    -- Explicit Movie fallback (Title Movie Resolution)
    {
        name = "movie_keyword_fallback",
        confidence = 75,
        regex = "^(.-)[%.%s]+[Mm]ovie[%.%s]+%d%d%d%dp",
        fields = { "title" },
        is_movie = true
    },

    -- Title - ## [Group]
    {
        name = "fallback_title_number_group",
        confidence = 70,
        regex = "^(.-)%s+[%-–—]%s+(%d+)%s*.*%[(.-)%].*$",
        fields = { "title", "absolute", "group" }
    },

    -- [Group] Title [Hash]
    {
        name = "fallback_group_title_hash",
        confidence = 65,
        regex = "^%[(.-)%]%s*(.-)%.?%s*%(?%d%d%d?p?%)?%s*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "hash" }
    },

    -- Just Title - ##
    {
        name = "fallback_simple_number",
        confidence = 50,
        regex = "^(.-)%s+[%-–—]%s+(%d+)%s*.*$",
        fields = { "title", "absolute" }
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
    local clean_name = filename:gsub("%.[Mm][Kk][Vv]$", ""):gsub("%.[Rr][Aa][Rr]$", ""):gsub("%.[Mm][Pp]4$", "")
    clean_name = clean_name:gsub("%.mkv%]", "]")

    for _, p in ipairs(PATTERNS) do
        local captures = { clean_name:match(p.regex) }

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