local M = {}

local DEBUG_PATTERNS = false

-- ==================================================================================
-- HELPER FUNCTIONS
-- ==================================================================================

-- S2,S3 2nd,3rd,4th,5th, etc season detection
local function season_detection

    -- Placeholder for future season detection logic if needed
    return nil
end

-- Extract data if its offered in the title
-- MATCH RESULT: group=H3LL, episode=03, season=03, pattern=anime_group_strict_sxxexx, is_movie=false, is_special=false, confidence=100, title=Jujutsu Kaisen - The Culling Game (呪術廻戦「死滅回游 前編」)

-- FIX
-- MATCH RESULT: absolute=3, group=SubsPlease, pattern=fallback_group_title_num, is_movie=false, is_special=false, confidence=60, title=Gintama
-- MATCH RESULT: group=Erai-raws, pattern=anime_movie_no_hash, is_movie=true, is_special=false, confidence=90, title=Seishun Buta Yarou wa Odekake Sister no Yume o Minai
--

local function sanitize_title(title)
    if not title then return nil end
    
    -- 1. Strip Release Group if it wasn't caught (e.g. "Title [Group]")
    title = title:gsub("^%s*[%[%(].-[%]%)]%s*", "") 
    title = title:gsub("%s*[%[%(].-[%]%)]%s*$", "") 
    
    -- 2. Strip trailing versions/resolutions/extensions
    -- FIXED: In Lua patterns, to include ']' in a set, it MUST be the first character.
    title = title:gsub("%s*[%[%(]?%d+p[]%)]%]?$", "")
    title = title:gsub("%s*[vV]%d+$", "")
    title = title:gsub("%.%a%a%a$", "") 
    
    -- 3. Replace dots/underscores with spaces
    title = title:gsub("[%.%_]", " ")
    
    -- 4. Strip specific keywords that aren't the title
    title = title:gsub("%s+[Ss]eason%s+%d+$", "")
    title = title:gsub("%s+[Mm]ovie$", "")
    title = title:gsub("%s+[Tt]he%s+[Mm]ovie$", "")
    title = title:gsub("%s+[%-–—]%s*$", "") -- Trailing dashes
    
    -- 5. Trim and normalize spaces
    title = title:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    
    return title
end

-- ==================================================================================
-- PATTERN DEFINITIONS
-- ==================================================================================

-- ==================================================================================
-- PATTERN DEFINITIONS (EXPANDED)
-- ==================================================================================

local PATTERNS = {
    -- =========================================================================
    -- TIER 1: STRICT ANIME / BATCHES / SxxExx
    -- =========================================================================

    -- [Group] Title - S01E02
    {
        name = "anime_group_strict_sxxexx",
        confidence = 100,
        regex = "^%[(.-)%][%s%.]*(.-)%s+([Ss]%d+[Ee]%d+)%s*.*$", 
        fields = { "group", "title", "sxe" } 
    },

    -- [Group] Title S01E02 (no dash)
    {
        name = "anime_group_sxxexx_no_dash",
        confidence = 100,
        regex = "^%[(.-)%][%s%.]*(.-)%s+([Ss]%d+[Ee]%d+)%s*.*$", 
        fields = { "group", "title", "sxe" } 
    },

    -- Title.S01E02.Metadata-Group (Scene style)
    {
        name = "scene_dotted_sxxexx",
        confidence = 99,
        regex = "^(.-)%.([Ss]%d+[Ee]%d+)%.(.-)%-([%a%d%.]+)$",
        fields = { "title", "sxe", "metadata", "group" }
    },

    -- [Group] Title - 01-02 (Batch)
    {
        name = "anime_group_absolute_batch",
        confidence = 100,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[%-–—]%s+(%d+)[%-~](%d+)%s*.*$",
        fields = { "group", "title", "absolute", "absolute_end" }
    },

    -- [Group] Title - 01v2 [Hash] (Revised episode)
    {
        name = "anime_group_absolute_version",
        confidence = 98,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[%-–—]%s+(%d+)[vV](%d+)%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "absolute", "version", "hash" }
    },

    -- [Group] Title - 05 [Hash] (Standard episodic)
    {
        name = "anime_group_absolute_hash_strict",
        confidence = 98,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[%-–—]%s+(%d+)%s+.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "absolute", "hash" }
    },

    -- [Group] Title - 05 (No hash variant)
    {
        name = "anime_group_absolute_no_hash",
        confidence = 95,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[%-–—]%s+(%d+)%s*%[",
        fields = { "group", "title", "absolute" }
    },

    -- (Group) Title - ## [Hash] (Parenthesis group style)
    {
        name = "anime_parenthesis_group_absolute",
        confidence = 97,
        regex = "^%((.-)%)%s+(.-)%s+(%d+)%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "absolute", "hash" }
    },

    -- [Group] Title EP01 [Hash] (EP prefix)
    {
        name = "anime_group_ep_prefix",
        confidence = 96,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[EePp]+(%d+)%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "absolute", "hash" }
    },

    -- =========================================================================
    -- TIER 2: MOVIES & SPECIALS
    -- =========================================================================

    -- [Group] Title - Movie [Metadata][Hash]
    {
        name = "anime_movie_with_hash",
        confidence = 96,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[%-–—]?%s*[Mm]ovie%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "hash" },
        is_movie = true
    },

    -- [Group] Title Movie [Dub/Metadata]
    {
        name = "anime_movie_no_hash",
        confidence = 90,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[Mm]ovie%s*.*",
        fields = { "group", "title" },
        is_movie = true
    },

    -- [Group] Title - OVA/OAD [Hash]
    {
        name = "anime_ova_oad",
        confidence = 95,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[%-–—]%s*([OoAaDd][VvAaDd]+)%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "special_type", "hash" },
        is_special = true
    },

    -- [Group] Title - Special ## [Hash]
    {
        name = "anime_special_numbered",
        confidence = 94,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[%-–—]%s*[Ss]pecial%s+(%d+)%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "absolute", "hash" },
        is_special = true
    },

    -- [Group] Title - NCOP/NCED ## [Hash] (Opening/Ending)
    {
        name = "anime_ncop_nced",
        confidence = 93,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[%-–—]%s*([NnCcOoPpEeDd]+)%s*(%d*)%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "special_type", "absolute", "hash" },
        is_special = true
    },

    -- =========================================================================
    -- TIER 3: COMPLEX TITLES & DOT-SEPARATED
    -- =========================================================================

    -- [Group].Title.Year.Metadata.[Hash] (Magical Mirai / LOU-Doremi style)
    {
        name = "anime_dot_group_metadata_hash",
        confidence = 95,
        regex = "^%[(.-)%]%.(.-)%.?%s*%[[%d%a].*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "hash" }
    },

    -- [Group].Title.##.[Hash] (Fully dotted episodic)
    {
        name = "anime_dot_group_episode",
        confidence = 94,
        regex = "^%[(.-)%]%.(.-)%.(%d+)%..*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "absolute", "hash" }
    },

    -- Title - S3 - Subtitle (Jujutsu Kaisen style)
    {
        name = "scene_season_subtitle_metadata",
        confidence = 94,
        regex = "^(.-)%s+[%-–—]%s+[Ss](%d+)%s+[%-–—]%s+(.-)%s*.*%[(.-)%].*",
        fields = { "title", "season", "subtitle", "metadata" }
    },

    -- Title · Episode [Hash] (Ayakashi style with middle dot)
    {
        name = "anime_dot_episode_hash",
        confidence = 92,
        regex = "^(.-)%s*·%s*(%d+)%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "title", "absolute", "hash" }
    },

    -- Title #Episode [Hash] (Hash prefix style)
    {
        name = "anime_hash_episode_prefix",
        confidence = 91,
        regex = "^(.-)%s*#(%d+)%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "title", "absolute", "hash" }
    },

    -- [Group] Title (Year) [Hash] (Year in parenthesis)
    {
        name = "anime_group_year_hash",
        confidence = 93,
        regex = "^%[(.-)%][%s%.]*(.-)%s+%((%d%d%d%d)%)%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "year", "hash" }
    },

    -- =========================================================================
    -- TIER 4: SCENE / WEB-DL / NAKED TITLES
    -- =========================================================================

    -- Title (Year) (Metadata - Group) (Lost in Starlight style)
    {
        name = "scene_movie_parenthesis_year",
        confidence = 90,
        regex = "^(.-)%s+%(%d%d%d%d%)%s*%(.*[%s%-](.-)%)",
        fields = { "title", "group" },
        is_movie = true
    },

    -- Title.Year.Quality.Source.Audio.Codec-Group (Ramayana style)
    {
        name = "scene_full_dotted",
        confidence = 88,
        regex = "^([%a%d%.%-]+)%.(%d%d%d%d)%.%d+p%.(.-)%-([%a%d%.]+)$",
        fields = { "title", "year", "metadata", "group" }
    },

    -- Title Year Quality-Group (Space separated scene)
    {
        name = "scene_space_separated",
        confidence = 87,
        regex = "^(.-)%s+(%d%d%d%d)%s+%d+p%s+(.-)%-([%a%d]+)$",
        fields = { "title", "year", "metadata", "group" }
    },

    -- Title [Hash] (White Snake style)
    {
        name = "naked_title_hash",
        confidence = 85,
        regex = "^(.-)%s*%[([0-9A-Fa-f]{8})%]",
        fields = { "title", "hash" }
    },

    -- Title [UHD][Year]
    {
        name = "naked_title_quality_year",
        confidence = 82,
        regex = "^(.-)%s*%[(.-)%]%[(%d%d%d%d)%]",
        fields = { "title", "metadata", "year" }
    },

    -- Title [1080p] [Hash] (Takopii style)
    {
        name = "naked_title_quality_hash",
        confidence = 80,
        regex = "^(.-)%s*%[%d+p%]%s*%[([0-9A-Fa-f]{8})%]",
        fields = { "title", "hash" }
    },

    -- Title [Multiple][Metadata][Blocks] [Hash]
    {
        name = "naked_multi_metadata_hash",
        confidence = 78,
        regex = "^(.-)%s*%[.-%]%[.-%].*%[([0-9A-Fa-f]{8})%]",
        fields = { "title", "hash" }
    },

    -- =========================================================================
    -- TIER 5: MULTI-EPISODE & RANGES
    -- =========================================================================

    -- [Group] Title - S01E01-E02 (Multi-episode)
    {
        name = "anime_group_multi_episode",
        confidence = 97,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[Ss](%d+)[Ee](%d+)[%-~][Ee](%d+)%s*.*$",
        fields = { "group", "title", "season", "episode", "episode_end" }
    },

    -- [Group] Title - 01+02 [Hash] (Plus separator)
    {
        name = "anime_group_episode_plus",
        confidence = 96,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[%-–—]%s+(%d+)%+(%d+)%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "absolute", "absolute_end", "hash" }
    },

    -- =========================================================================
    -- TIER 6: DUAL AUDIO & LANGUAGE VARIANTS
    -- =========================================================================

    -- [Group] Title - ## [DUAL-AUDIO][Hash]
    {
        name = "anime_dual_audio",
        confidence = 95,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[%-–—]%s+(%d+)%s*.*%[[DdUuAaLl%-]+%]%s*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "absolute", "hash" }
    },

    -- [Group] Title - ## [SUB] [Hash]
    {
        name = "anime_subtitle_marker",
        confidence = 92,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[%-–—]%s+(%d+)%s*%[[SsUuBbDdUu]+%]%s*.*%[([0-9A-Fa-f]{8})%]",
        fields = { "group", "title", "absolute", "hash" }
    },

    -- =========================================================================
    -- TIER 7: FALLBACKS (Aggressive)
    -- =========================================================================

    -- Title (Quality Codec) (Nomo no Kuni style)
    {
        name = "fallback_scene_no_group",
        confidence = 40,
        regex = "^(.-)%s+%(%d+p%s+.*%)",
        fields = { "title" }
    },

    -- [Group] Title - 01
    {
        name = "fallback_group_title_num",
        confidence = 60,
        regex = "^%[(.-)%][%s%.]*(.-)%s+[%-–—]%s+(%d+)",
        fields = { "group", "title", "absolute" }
    },

    -- Title - ##
    {
        name = "fallback_simple_number",
        confidence = 35,
        regex = "^(.-)%s+[%-–—]%s+(%d+)",
        fields = { "title", "absolute" }
    },

    -- [Group] Title (Minimal group+title)
    {
        name = "fallback_group_title_only",
        confidence = 30,
        regex = "^%[(.-)%][%s%.]*(.+)$",
        fields = { "group", "title" }
    },

    -- Title only (Last resort)
    {
        name = "fallback_title_only",
        confidence = 20,
        regex = "^(.+)$",
        fields = { "title" }
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
    -- Pre-clean filename extensions
    local clean_name = filename:gsub("%.[Mm][Kk][Vv]$", "")
                               :gsub("%.[Rr][Aa][Rr]$", "")
                               :gsub("%.[Mm][Pp]4$", "")
                               :gsub("%.[Aa][Vv][Ii]$", "")
    -- Handle nested .mkv] edge case
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

            if result.title and result.title ~= "" then
                return result
            end
        end
    end

    return nil
end

return M