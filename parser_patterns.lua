local M = {}

local DEBUG_PATTERNS = false
local function sanitize_title(title)
    if not title then return title end
    
    -- 1. Remove trailing dashes/separators specifically
    -- This cleans up: "Title - " -> "Title"
    title = title:gsub("%s*[%-–—]%s*$", "") 
    
    -- 2. NEW: Remove common trailing version/release info
    -- This cleans: "Title v2" or "Title (v3)" -> "Title"
    title = title:gsub("%s*[%(%[]?[Vv]%d+[%)%]]?$", "")
    
    -- 4. Replace dots and underscores with spaces
    title = title:gsub("[%.%_]", " ")
    
    -- 5. NEW: Remove any leftover empty brackets or parentheses
    -- This cleans: "Title ()" -> "Title"
    title = title:gsub("%s*%b()", function(s) return s == "()" and "" or nil end)
    title = title:gsub("%s*%b[]", function(s) return s == "[]" and "" or nil end)
    
    -- 6. Collapse multiple spaces and trim
    title = title:gsub("%s+", " ")
    title = title:match("^%s*(.-)%s*$")
    
    return title
end

local function debug_pattern_hit(pattern_name, confidence, captures)
    if not DEBUG_PATTERNS then return end
    print(string.format(
        "PATTERN MATCHED: %-28s | confidence=%d | captures=[%s]",
        pattern_name, confidence, table.concat(captures, ", ")
    ))
end

-- Pattern cascade (Reorganized by Confidence)
local PATTERNS = {
    -- 1) [Group] Title 123 (absolute) (Season+Episode in parens)
    {
        name = "anime_subgroup_absolute_with_sxxexx_paren",
        confidence = 100,
        regex = "^%[(.-)%]%s*(.-)%s+([0-9][0-9][0-9]%.?%d?)%s*%(%s*[Ss](%d+)[Ee](%d+)%s*%)",
        fields = { "group", "title", "absolute", "season", "episode" }
    },
    {
        name = "subgroup_title_year_episode_metadata_hash",
        confidence = 99,
        -- Matches: [Group] Title (2025) - 10 (WEB 1080p...) [Hash].mkv
        regex = "^%[(.-)%]%s*(.-)%s*%((%d%d%d%d)%)%s*[%-%–—]%s*(%d%d?)%s*%((.-)%)%s*%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "year", "episode", "metadata", "hash" }
    },
    {
    name = "anime_subgroup_sxxexx_absolute",
    confidence = 99, -- Very high confidence due to specific structure
    -- Matches: [Group] Title - S03E04 (51)
    regex = "^%[(.-)%]%s*(.-)%s*[%-–—]%s*[Ss](%d+)[Ee](%d+)%s*%((%d+)%)",
    fields = { "group", "title", "season", "episode", "absolute_episode" }
    },
    {
        name = "subgroup_title_sxxexx_metadata_hash",
        confidence = 98,
        -- Matches: [Group] Title - ## (S##E##) (AMZN 1080p...) [Hash].mkv
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*(%d%d?)%s*%(S(%d+)E(%d+)%)%s*%((.-)%)%s*%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "episode", "season", "episode2", "metadata", "hash" }
    },
    -- 2) [Group] Title - 123  (absolute)  (common fansub style)
    {
        name = "anime_subgroup_absolute_dash",
        confidence = 98,
        regex = "^%[(.-)%]%s*(.-)%s*[-_]%s*([0-9][0-9][0-9]%.?%d?)",
        fields = { "group", "title", "absolute" }
    },
    {
        name = "multi_episode_range_sxxexx",
        confidence = 98,
        regex = "^(.-)[%s%._%-]+S(%d+)[Ee](%d+)%s*[-–—]%s*S?%d*[Ee]?(%d+)",
        fields = { "title", "season", "episode", "episode2" }
    },
    {
        name = "subgroup_title_version_metadata_hash",
        confidence = 98,
        -- Matches: [Group] Title - ##v# (WEB 1080p...) [Hash].mkv
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*(%d+)([vV]%d+)%s*%((.-)%)%s*%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "episode", "version", "metadata", "hash" }
    },
    {
    name = "anime_subgroup_season_letter_dash_episode",
    confidence = 98,
    -- Matches: [Group] Title S2 (Metadata) - 15
    regex = "^%[(.-)%]%s*(.-)%s+[Ss](%d+)%s*%(?(.-)%)?%s*[%-%–—]%s*(%d%d?)",
    fields = { "group", "title", "season", "metadata", "episode" }
    },
    {
    name = "anime_subgroup_roman_season_dash_episode",
    confidence = 98,
    -- Matches: [Group] Title II - 15
    regex = "^%[(.-)%]%s*(.-)%s+([IVXLCDMivxlcdm]+)%s*[%-%–—]%s*(%d%d?)",
    fields = { "group", "title", "season_roman", "episode" }
    },
    {
    name = "anime_subgroup_ordinal_season",
    confidence = 98,
    -- Matches: [Group] Title 6th Season - 12
    regex = "^%[(.-)%]%s*(.-)%s+(%d+)[stndrdth]+%s+[Ss]eason%s*[%-–—]%s*(%d+)",
    fields = { "group", "title", "season", "episode" }
    },
    {
    name = "anime_subgroup_sxxexx_absolute",
    confidence = 98,
    -- Matches: [Group] Title - S01E01 (01) [Metadata]
    regex = "^%[(.-)%]%s*(.-)%s*[%-–—]%s*[Ss](%d+)[Ee](%d+)%s*%(%d+%)",
    fields = { "group", "title", "season", "episode" }
},
    {
        name = "subgroup_title_episode_parenthetical_metadata_multibracket_hash",
        confidence = 97,
        -- Matches: [Group] Title - ## (WEB 1080p AV1 Opus) [Multi Subs][Hash].mkv
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*(%d%d?)%s*%((.-)%)%s*%[(.-)%]%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "episode", "metadata", "subs", "hash" }
    },
    {
        name = "subgroup_title_number_episode_parenthetical_metadata_multibracket_hash",
        confidence = 97,
        -- Matches: [Group] Title 3 - ## (WEB 1080p...) [Multi Subs][Hash].mkv
        regex = "^%[(.-)%]%s*(.-)%s+(%d+)%s*[%-%–—]%s*(%d%d?)%s*%((.-)%)%s*%[(.-)%]%s*%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "season", "episode", "metadata", "subs", "hash" }
    },
    {
        name = "subgroup_title_parenthetical_resolution_metadata_multibracket_hash",
        confidence = 97,
        -- Matches: [Group] Title - ## (1080p AV1 OPUS) [MultiSubs] [Hash].mkv
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*(%d%d?)%s*%((%d%d%d%dp)(.-)%)%s*%[(.-)%]%s*%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "episode", "resolution", "metadata", "subs", "hash" }
    },
    {
        name = "subgroup_title_episode_metadata_hash",
        confidence = 97,
        -- Matches: [Group] Title - ## (WEB 1080p...) [Hash].mkv
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*(%d%d?)%s*%((.-)%)%s*%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "episode", "metadata", "hash" }
    },
    {
        name = "subgroup_title_season_episode_metadata_hash",
        confidence = 97,
        regex = "^%[(.-)%]%s*(.-)%s*[Ss](%d+)%s*[%-%–—]%s*(%d+)%s*%[(.-)%]%s*%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "season", "episode", "metadata", "hash" }
    },
    {
        name = "anime_movie_with_metadata",
        confidence = 97,
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*[Mm]ovie%s*(%[.*%])%.%w+$",
        fields = { "group", "title", "metadata" }
    },
    {
        name = "anime_subgroup_part_episode",
        confidence = 97,
        regex = "^%[(.-)%]%s*(.-%s*[Pp]art%s*%d+)%s*[%-_. ]+%s*(%d%d?%d?)[%s%._%-]*%[",
        fields = { "group", "title", "episode" }
    },
    {
        name = "subgroup_title_num_episode_metadata_hash",
        confidence = 96,
        regex = "^%[(.-)%]%s*(.-)%s+(%d+)%s*[%-%–—]%s*(%d+)%s*%[(.-)%]%s*%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "season", "episode", "metadata", "hash" }
    },
    {
        name = "subgroup_title_year_movie_source_metadata_multibracket_hash",
        confidence = 96,
        -- Matches: [Group] Title (Year) - Movie [Source][Resolution AV1 OPUS][MultiSub][Hash].mkv
        regex = "^%[(.-)%]%s*(.-)%s*%((%d%d%d%d)%)%s*[%-%–—]%s*Movie%s*%[(.-)%]%[(.-)%]%[(.-)%]%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "year", "source", "metadata", "subs", "hash" }
    },
    {
        name = "subgroup_title_dash_special_studio_source_metadata_multibracket_hash",
        confidence = 96,
        -- Matches: [Group] Title - Special [Studio][Source][Resolution AV1 OPUS][MultiSub][Hash].mkv
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*Special%s*%[(.-)%]%[(.-)%]%[(.-)%]%[(.-)%]%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "studio", "source", "metadata", "subs", "hash" }
    },
    {
        name = "subgroup_title_dash_episode_studio_source_metadata_multibracket_hash",
        confidence = 96,
        -- Matches: [Group] Title - E## [Studio][Source][Resolution AV1 OPUS][MultiSub][Hash].mkv
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*E(%d+)%s*%[(.-)%]%[(.-)%]%[(.-)%]%[(.-)%]%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "episode", "studio", "source", "metadata", "subs", "hash" }
    },
    {
        name = "subgroup_title_dash_episode_repack_studio_source_metadata_multibracket_hash",
        confidence = 96,
        -- Matches: [Group] Title - E## (REPACK) [Studio][Source][Resolution AV1 OPUS][MultiSub][Hash].mkv
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*E(%d+)%s*%(REPACK%)%s*%[(.-)%]%[(.-)%]%[(.-)%]%[(.-)%]%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "episode", "studio", "source", "metadata", "subs", "hash" }
    },
    {
        name = "anime_subgroup_sxxexx",
        confidence = 96,
        regex = "^%[(.-)%]%s*(.-)%s*[%-_. ]+[Ss](%d+)[Ee](%d+)",
        fields = { "group", "title", "season", "episode" }
    },
    {
        name = "split_episode_lettered",
        confidence = 96,
        regex = "^(.-)[%s%._%-]+S(%d+)[Ee](%d+)([ab])%b()?",
        fields = { "title", "season", "episode", "split" }
    },
    {
        name = "subgroup_title_season_episode_extra",
        confidence = 96,
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*S(%d+)E(%d+)%s*%(%d+%)%s*%[(%d+p)%].*%.%w+$",
        fields = { "group", "title", "season", "episode", "resolution" }
    },
    {
        name = "subgroup_title_episode_with_version_hash",
        confidence = 96,
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*(%d+[vV]%d*)%s*%(%d+p%)%s*%[?([%x]+)%]?%.%w+$",
        fields = { "group", "title", "episode", "hash" }
    },
    {
        name = "title_year_proper_resolution_dual_codec_group",
        confidence = 95,
        -- Matches: Title.Year.PROPER.1080p.Source.DUAL.Audio.Codec-Group.mkv
        regex = "^(.-)%.(%d%d%d%d)%.PROPER%.(%d%d%d%dp)%.(.-)%.DUAL%.(.-)%.([%w%.]+)%-(.-)%.%w+$",
        fields = { "title", "year", "resolution", "source", "audio", "codec", "group" }
    },
    {
        name = "title_year_proper_resolution_remux_dual_audio_group",
        confidence = 95,
        -- Matches: Title.Year.PROPER.1080p.Blu-ray.Remux.Codec.DUAL.Audio-Group.mkv
        regex = "^(.-)%.(%d%d%d%d)%.PROPER%.(%d%d%d%dp)%.(.-)%.Remux%.(.-)%.DUAL%.(.-)%-(.-)%.%w+$",
        fields = { "title", "year", "resolution", "source", "codec", "audio", "group" }
    },
    {
        name = "title_year_repack_resolution_source_dual_codec_group",
        confidence = 95,
        -- Matches: Title.Year.REPACK.1080p.Source.DUAL.Audio.Codec-Group.mkv
        regex = "^(.-)%.(%d%d%d%d)%.REPACK%.(%d%d%d%dp)%.(.-)%.DUAL%.(.-)%.([%w%.]+)%-(.-)%.%w+$",
        fields = { "title", "year", "resolution", "source", "audio", "codec", "group" }
    },
    {
        name = "title_year_uhd_bluray_resolution_audio_codec_remux_group",
        confidence = 95,
        -- Matches: Title.Year.UHD.BluRay.2160p.Audio.Codec.HYBRID.REMUX-Group.mkv
        regex = "^(.-)%.(%d%d%d%d)%.UHD%.BluRay%.(%d%d%d%dp)%.(.-)%.(.-)%.HYBRID%.REMUX%-(.-)%.%w+$",
        fields = { "title", "year", "resolution", "audio", "codec", "group" }
    },
    {
    name = "anime_subgroup_season_dash_episode",
    confidence = 96,
    -- Captures Group, Title, Season Number, and Episode
    regex = "^%[(.-)%]%s*(.-)%s+(%d+)[stndrdth]+%s+[Ss]eason%s+[%-–—]%s+(%d%d?%d?)[%s%._%-]*%[",
    fields = { "group", "title", "season", "episode" }
    },
    {
        name = "anime_subgroup_dash_episode",
        confidence = 95,
        regex = "^%[(.-)%]%s*(.*)%s+[%-–—]%s+(%d%d?%d?)[%s%._%-]*%[",
        fields = { "group", "title", "episode" }
    },
    {
        name = "title_dash_episode_bracket_meta",
        confidence = 95,
        regex = "^(.-)%s*[%-%–—]%s*(%d+)%s*%[(.-)%]%.%w+$",
        fields = { "title", "episode", "metadata" }
    },
    {
        name = "dots_sxx_scene",
        confidence = 95,
        regex = "^([%w%.]+)%.[Ss](%d%d)%.(.-)%-([%w]+)%.%w+$",
        fields = { "title", "season", "metadata", "group" }
    },
    {
        name = "scene_dots_title_year",
        confidence = 95,
        regex = "^([%w%.%-]+)%.(%d%d%d%d)%.(%d%d%d%dp)",
        fields = { "title", "year", "resolution" }
    },
    {
        name = "subgroup_title_episode_resolution_hash",
        confidence = 95,
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*(%d%d?%d?)%s*%(%d+p%)%s*%[?([%x]+)%]?%.%w+$",
        fields = { "group", "title", "episode", "hash" }
    },
    {
        name = "subgroup_title_episode_lang_multi_bracket",
        confidence = 94,
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*(%d%d?%d?)%s*%((%u%u)%)%s*%[(.-)%]%[(.-)%]%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "episode", "language", "metadata1", "metadata2", "hash" }
    },
    {
        name = "subgroup_title_year_remux",
        confidence = 94,
        regex = "^%[(.-)%]%s*(.-)%s*%(%d%d%d%d%)%s*%[(.-)%]%s*%[([%x]+)%]",
        fields = { "group", "title", "source", "hash" }
    },
    {
        name = "complex_title_with_metadata_parens",
        confidence = 94,
        regex = "^(.-)%s*[%-%–—]%s*%((.-)%)%s*%[([%x]+)%]-(.-)%.%w+$",
        fields = { "title", "metadata", "hash", "suffix" }
    },
    {
        name = "subgroup_double_episode",
        confidence = 94,
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*(%d+)%s*&%s*(%d+)%s*%[",
        fields = { "group", "title", "episode", "episode2" }
    },
    {
        name = "subgroup_title_nc_episode",
        confidence = 94,
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*NCED?%s*(%d*)%s*%[",
        fields = { "group", "title", "special_num" }
    },
    {
        name = "title_dash_episode_group_suffix",
        confidence = 93,
        regex = "^(.-)%s*[%-%–—]%s*(%d+)%s*%[(.-)%]%.%w+$",
        fields = { "title", "episode", "group" }
    },
    {
        name = "title_dash_episode_metadata_tags",
        confidence = 93,
        regex = "^(.-)%s*[%-%–—]%s*(%d+)%s*(%[.-%])",
        fields = { "title", "episode", "metadata" }
    },
    {
        name = "subgroup_title_resolution_hash_no_episode",
        confidence = 93,
        regex = "^%[(.-)%]%s*(.-)%s*%(%d+p%)%s*%[?([%x]+)%]?%.%w+$",
        fields = { "group", "title", "hash" }
    },
    {
        name = "web_dl_tag_sxxexx",
        confidence = 93,
        regex = "^(.-)[%s%._%-]+WEB%-DL[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "bluray_tag_sxxexx",
        confidence = 93,
        regex = "^(.-)[%s%._%-]+BluRay[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "subgroup_title_ova_multi_bracket",
        confidence = 92,
        regex = "^%[(.-)%]%s*(.-[Oo][Vv][Aa].-)%s*%[(.-)%]%s*%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "extra", "hash" }
    },
    {
        name = "ova_special_tag",
        confidence = 92,
        regex = "^(.-)[%s%._%-]+(?:special|ova|oav|oad)[%s%._%-]*(%d?%d?)",
        fields = { "title", "special_num" }
    },
    {
        name = "subgroup_long_title_movie",
        confidence = 92,
        regex = "^%[(.-)%]%s*(.-)%s*%[(%d+p.-)%]%.%w+$",
        fields = { "group", "title", "metadata" }
    },
    {
        name = "subgroup_title_source_bracket",
        confidence = 92,
        regex = "^%[(.-)%]%s*(.-)%s*%(%w+%)%s*%[([%x]+)%]",
        fields = { "group", "title", "hash" }
    },
    {
        name = "paren_group_absolute_hash",
        confidence = 92,
        regex = "^%((.-)%)%s*(.-)%s+(%d+)%s*%[([%x]+)%]%.%w+$",
        fields = { "group", "title", "absolute", "hash" }
    },
    {
        name = "hdtv_tag_sxxexx",
        confidence = 92,
        regex = "^(.-)[%s%._%-]+HDTV[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "proper_repack_tag",
        confidence = 92,
        regex = "^(.-)[%s%._%-]+(?:PROPER|REPACK)[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
    name = "anime_subgroup_roman_season",
    confidence = 92,
    -- Matches: [Group] Title II - 12
    regex = "^%[(.-)%]%s*(.-)%s+([IVX][IVX]+)%s*[%-–—]%s*(%d+)",
    fields = { "group", "title", "season_roman", "episode" }
    },
    {
        name = "bracketed_sxxexx_or_range",
        confidence = 91,
        regex = "^(.-)[%s%._%-]+%[S(%d+)[Ee](%d+)(?:[-E](%d+))?%]",
        fields = { "title", "season", "episode", "episode2" }
    },
    {
        name = "title_year_metadata_parens",
        confidence = 91,
        regex = "^(.-)%s*%(%d%d%d%d%)%s*%(%d+p.-%)",
        fields = { "title", "metadata" }
    },
    {
        name = "internal_release_tag",
        confidence = 91,
        regex = "^(.-)[%s%._%-]+iNTERNAL[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "uncut_extended_tag",
        confidence = 91,
        regex = "^(.-)[%s%._%-]+(?:UNCUT|EXTENDED)[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "sxxexx_title",
        confidence = 90,
        -- Matches: Title.S01E07.metadata or Title S01E07 metadata
        -- Stops at first S##E## to avoid Roman numerals in title
        regex = "^(.-%w)[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "dots_title_sxxexx_metadata",
        confidence = 91,
        -- Higher priority for dot-separated titles with standard metadata
        -- Matches: Title.With.Dots.S01E07.1080p.WEB-DL...
        regex = "^([%w%.]+)%.[Ss](%d+)[Ee](%d+)%.%d+p",
        fields = { "title", "season", "episode" }
    },
    {
        name = "turkish_tracker_bolum",
        confidence = 90,
        regex = "^(.-)[%s%._%-]+(%d{1,4})[%s%._%-]+(?:BLM|B[oö]l[uü]m)",
        fields = { "title", "absolute" }
    },
    {
        name = "spanish_temporada_cap",
        confidence = 90,
        regex = "^(.-)%[?(.+)%]?[%s%._%-]+Temporada[%s%._%-]+(%d+)[%s%._%-]+Cap",
        fields = { "title", "tracker", "season" }
    },
    {
        name = "limited_release_tag",
        confidence = 90,
        regex = "^(.-)[%s%._%-]+LiMiTED[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "directors_cut_tag",
        confidence = 90,
        regex = "^(.-)[%s%._%-]+(?:Directors?[%s%._%-]*Cut|DC)[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
    name = "anime_subgroup_roman_season_dash_episode",
    confidence = 90, -- Lowered because it's prone to False Positives
    -- Requires at least two Roman characters (II, III, IV) to trigger
    regex = "^%[(.-)%]%s*(.-)%s+([IVX][IVX]+)%s*[%-%–—]%s*(%d%d?)",
    fields = { "group", "title", "season_roman", "episode" }
    },
    {
        name = "numeric_prefix_103style",
        confidence = 89,
        regex = "^(.-)[%s%._%-]+([1-9])([0-9][0-9])$",
        fields = { "title", "hundreds", "rest" }
    },
    {
        name = "retail_tag",
        confidence = 89,
        regex = "^(.-)[%s%._%-]+RETAIL[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "subbed_dubbed_tag",
        confidence = 89,
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*(%d+)%s*%((?:SUBBED|DUBBED)%)",
        fields = { "group", "title", "episode" }
    },
    {
        name = "sxxexx_bracketed",
        confidence = 88,
        regex = "^(.-)[%s%._%-]+%[S(%d+)[Ee](%d+)%]",
        fields = { "title", "season", "episode" }
    },
    {
        name = "season_pack_multi_season",
        confidence = 88,
        regex = "^(.-)[%s%._%-]+(?:Complete Series|Complete Collection)?[%s%._%-]+(?:S|Season)[%s%._%-]*(%d+)[%s%._%-]+(?:S|Season)[%s%._%-]*(%d+)",
        fields = { "title", "season", "season2" }
    },
    {
        name = "festival_screener_tag",
        confidence = 88,
        regex = "^(.-)[%s%._%-]+(?:FESTIVAL|SCR|SCREENER)[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "dual_audio_tag",
        confidence = 88,
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*(%d+)%s*%[?Dual[%s%-]?Audio%]?",
        fields = { "group", "title", "episode" }
    },
    {
        name = "trailing_hash_and_group",
        confidence = 87,
        regex = "^(.-)[%s%._%-]+%[(.-)%][%s%._%-]*%[?([%x]+)%]$",
        fields = { "title", "group", "hash" }
    },
    {
        name = "batch_tag_pattern",
        confidence = 87,
        regex = "^%[(.-)%]%s*(.-)%s*[%-%–—]%s*BATCH[%s%._%-]*%[",
        fields = { "group", "title" }
    },
    {
        name = "complete_series_tag",
        confidence = 87,
        regex = "^(.-)[%s%._%-]+Complete[%s%._%-]+(?:Series|Collection|Season)",
        fields = { "title" }
    },
    {
        name = "s2016_style_four_digit_season",
        confidence = 86,
        regex = "^(.-)[%s%._%-]+S(%d%d%d%d)[%s%._%-]*E(%d%d?)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "theatrical_cut_tag",
        confidence = 86,
        regex = "^(.-)[%s%._%-]+Theatrical[%s%._%-]+Cut[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "remastered_tag",
        confidence = 86,
        regex = "^(.-)[%s%._%-]+REMASTERED[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "dash_two_digit_episode",
        confidence = 85,
        regex = "^(.-)%s*[%-%–—]%s*(%d%d)$",
        fields = { "title", "episode" }
    },
    {
        name = "airdate_compact_yyyymmdd",
        confidence = 85,
        regex = "^(.-)[%s%._%-]+(%d%d%d%d)(%d%d)(%d%d)$",
        fields = { "title", "airyear", "airmonth", "airday" }
    },
    {
        name = "remux_long_tail_group",
        confidence = 85,
        regex = "^(.-)%s+(%d%d%d%d)%s+.*%s*[%-%–—]%s*(.-)%.%w+$",
        fields = { "title", "year", "group" }
    },
    {
        name = "criterion_collection",
        confidence = 85,
        regex = "^(.-)[%s%._%-]+Criterion[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "4k_uhd_tag",
        confidence = 85,
        regex = "^(.-)[%s%._%-]+(?:4K|UHD)[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "episode_tag",
        confidence = 84,
        regex = "^(.-)%s+[Ee]pisode[%s%._%-]+(%d+)",
        fields = { "title", "absolute" }
    },
    {
        name = "absolute_in_brackets",
        confidence = 84,
        regex = "^(.-)[%s%._%-]+%[(%d%d%d)(%.?%d?)%]",
        fields = { "title", "absolute", "absolute_frac" }
    },
    {
        name = "imax_tag",
        confidence = 84,
        regex = "^(.-)[%s%._%-]+IMAX[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "hdr_dolby_vision_tag",
        confidence = 84,
        regex = "^(.-)[%s%._%-]+(?:HDR|DV|DoVi)[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "chinese_then_english_bracketed",
        confidence = 83,
        regex = "^([%z\1-\127\194-\244][^\n]-)[%s%._%-]+(.+?)[%s%._%-]+%[S(%d+)[Ee](%d+)%]",
        fields = { "cjk_title", "title", "season", "episode" }
    },
    {
        name = "atmos_dtsx_audio_tag",
        confidence = 83,
        regex = "^(.-)[%s%._%-]+(?:Atmos|DTS[%:%.]?X)[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "hfr_high_frame_rate",
        confidence = 83,
        regex = "^(.-)[%s%._%-]+(?:HFR|60fps|48fps)[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "trailing_3digit_absolute",
        confidence = 82,
        regex = "^(.-)[%s%._%-]+([0-9][0-9][0-9]%.?%d?)$",
        fields = { "title", "absolute" }
    },
    {
        name = "episode_tag_with_hash",
        confidence = 82,
        regex = "^(.-)[%s%._%-]+Episode[%s%._%-]+(%d+).+%[([%x]+)%]$",
        fields = { "title", "absolute", "hash" }
    },
    {
        name = "hybrid_remux_tag",
        confidence = 82,
        regex = "^(.-)[%s%._%-]+HYBRID[%s%._%-]+REMUX[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "open_matte_tag",
        confidence = 82,
        regex = "^(.-)[%s%._%-]+Open[%s%._%-]?Matte[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "multi_sxxexx",
        confidence = 80,
        regex = "^(.-)[%s%._%-]+[Ss](%d+)[Ee](%d+)[Ee%-](%d+)",
        fields = { "title", "season", "episode", "episode2" }
    },
    {
        name = "commentary_track_tag",
        confidence = 80,
        regex = "^(.-)[%s%._%-]+Commentary[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "anniversary_edition",
        confidence = 80,
        regex = "^(.-)[%s%._%-]+(%d+)th[%s%._%-]+Anniversary[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "anniversary", "year" }
    },
    {
        name = "absolute_batch_range",
        confidence = 78,
        regex = "^(.-)[%s%._%-]+([0-9][0-9][0-9]%.?%d?)[%s%._%-]*[%-%~][%s%._%-]*([0-9][0-9][0-9]%.?%d?)",
        fields = { "title", "absolute", "absolute2" }
    },
    {
        name = "restored_tag",
        confidence = 78,
        regex = "^(.-)[%s%._%-]+RESTORED[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "ultimate_edition_tag",
        confidence = 78,
        regex = "^(.-)[%s%._%-]+Ultimate[%s%._%-]+Edition[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "airdate_iso",
        confidence = 76,
        regex = "^(.-)[%s%._%-]+%(?([12]%d%d%d)[%._%-]?(0[1-9]|1[0-2])[%._%-]?([0-2]%d|3[01])%)?",
        fields = { "title", "airyear", "airmonth", "airday" }
    },
    {
        name = "collectors_edition",
        confidence = 76,
        regex = "^(.-)[%s%._%-]+Collectors?[%s%._%-]+Edition[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "special_edition_tag",
        confidence = 76,
        regex = "^(.-)[%s%._%-]+Special[%s%._%-]+Edition[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "cjk_then_english_sxxexx",
        confidence = 74,
        regex = "^([%z\1-\127\194-\244][^\n]-)[%s%._%-]+(.+?)[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "cjk_title", "title", "season", "episode" }
    },
    {
        name = "deluxe_edition_tag",
        confidence = 74,
        regex = "^(.-)[%s%._%-]+Deluxe[%s%._%-]+Edition[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "limited_steelbook",
        confidence = 74,
        regex = "^(.-)[%s%._%-]+(?:Limited|Steelbook)[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "subgroup_absolute_hash",
        confidence = 72,
        regex = "^%[(.-)%]%s*(.-)%s+([0-9][0-9][0-9]%.?%d?)%s*%[?%w+%]?%s*%[?([%x]+)%]?$",
        fields = { "group", "title", "absolute", "hash" }
    },
    {
        name = "fansub_multiple_groups",
        confidence = 72,
        regex = "^%[(.-)%]%[(.-)%]%s*(.-)%s*[%-%–—]%s*(%d+)",
        fields = { "group", "group2", "title", "episode" }
    },
    {
        name = "preview_pilot_tag",
        confidence = 72,
        regex = "^(.-)[%s%._%-]+(?:PREVIEW|PILOT)[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "season_only",
        confidence = 70,
        regex = "^(.-)[%s%._%-]+[Ss]eason[%s%._%-]*(%d+)",
        fields = { "title", "season" }
    },
    {
        name = "trilogy_box_set",
        confidence = 70,
        regex = "^(.-)[%s%._%-]+(?:Trilogy|Collection|Box[%s%._%-]*Set)",
        fields = { "title" }
    },
    {
        name = "uncensored_unrated_tag",
        confidence = 70,
        regex = "^(.-)[%s%._%-]+(?:UNCENSORED|UNRATED)[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "part_number_tag",
        confidence = 68,
        regex = "^(.-)[%s%._%-]+Part[%s%._%-]*(%d+)[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "part", "year" }
    },
    {
        name = "disc_number_tag",
        confidence = 68,
        regex = "^(.-)[%s%._%-]+(?:CD|DISC?)[%s%._%-]*(%d+)",
        fields = { "title", "disc" }
    },
    {
        name = "bonus_features_tag",
        confidence = 66,
        regex = "^(.-)[%s%._%-]+(?:Bonus|Extras|Features)[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "workprint_tag",
        confidence = 66,
        regex = "^(.-)[%s%._%-]+WORKPRINT[%s%._%-]+(%d%d%d%d)",
        fields = { "title", "year" }
    },
    {
        name = "french_vff_vfq_tag",
        confidence = 65,
        regex = "^(.-)[%s%._%-]+(?:VFF|VFQ|FRENCH)[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "german_dubbed_tag",
        confidence = 65,
        regex = "^(.-)[%s%._%-]+(?:GERMAN|DL)[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "nordic_subs_tag",
        confidence = 65,
        regex = "^(.-)[%s%._%-]+NORDIC[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "multi_lang_tag",
        confidence = 65,
        regex = "^(.-)[%s%._%-]+MULTi[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "minimalist_media_tag",
        confidence = 60,
        regex = "^(.-)%s+(DVD|BD|BR|VOD|VHS)%.%w+$",
        fields = { "title", "source" }
    },
    {
        name = "sample_tag",
        confidence = 60,
        regex = "^(.-)%-[Ss]ample%.%w+$",
        fields = { "title" }
    },
    {
        name = "proof_tag",
        confidence = 60,
        regex = "^(.-)%-[Pp]roof%.%w+$",
        fields = { "title" }
    },
    {
        name = "rarbg_tag",
        confidence = 58,
        regex = "^(.-)[%s%._%-]+RARBG%.%w+$",
        fields = { "title" }
    },
    {
        name = "yify_tag",
        confidence = 58,
        regex = "^(.-)[%s%._%-]+(?:YIFY|YTS)%.%w+$",
        fields = { "title" }
    },
    {
        name = "eztv_tag",
        confidence = 58,
        regex = "^(.-)[%s%._%-]+EZTV%.%w+$",
        fields = { "title" }
    },
    {
        name = "xvid_divx_codec",
        confidence = 56,
        regex = "^(.-)[%s%._%-]+(?:XviD|DivX)[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "x264_x265_codec",
        confidence = 56,
        regex = "^(.-)[%s%._%-]+[xXhH]26[45][%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "hevc_h265_tag",
        confidence = 56,
        regex = "^(.-)[%s%._%-]+(?:HEVC|H%.?265)[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "av1_codec_tag",
        confidence = 56,
        regex = "^(.-)[%s%._%-]+AV1[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "ac3_audio_tag",
        confidence = 54,
        regex = "^(.-)[%s%._%-]+AC3[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "aac_audio_tag",
        confidence = 54,
        regex = "^(.-)[%s%._%-]+AAC[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "dts_audio_tag",
        confidence = 54,
        regex = "^(.-)[%s%._%-]+DTS[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "truehd_audio_tag",
        confidence = 54,
        regex = "^(.-)[%s%._%-]+TrueHD[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "flac_audio_tag",
        confidence = 54,
        regex = "^(.-)[%s%._%-]+FLAC[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "ddp_audio_tag",
        confidence = 54,
        regex = "^(.-)[%s%._%-]+DD[P%+][%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "nf_netflix_tag",
        confidence = 52,
        regex = "^(.-)[%s%._%-]+NF[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "amzn_amazon_tag",
        confidence = 52,
        regex = "^(.-)[%s%._%-]+AMZN[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "dsnp_disney_tag",
        confidence = 52,
        regex = "^(.-)[%s%._%-]+(?:DSNP|DPlus)[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "hmax_hbo_tag",
        confidence = 52,
        regex = "^(.-)[%s%._%-]+(?:HMAX|HBO)[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "atvp_appletv_tag",
        confidence = 52,
        regex = "^(.-)[%s%._%-]+(?:ATVP|ATV)[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "pcok_peacock_tag",
        confidence = 52,
        regex = "^(.-)[%s%._%-]+PCOK[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "pmtp_paramount_tag",
        confidence = 52,
        regex = "^(.-)[%s%._%-]+(?:PMTP|PARA)[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "loose_trailing_number",
        confidence = 50,
        regex = "^(.-)%s+(%d+)$",
        fields = { "title", "episode" }
    },
    {
        name = "season_finale_tag",
        confidence = 48,
        regex = "^(.-)[%s%._%-]+(?:Season[%s%._%-]*)?Finale[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "series_premiere_tag",
        confidence = 48,
        regex = "^(.-)[%s%._%-]+(?:Series[%s%._%-]*)?Premiere[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "mid_season_finale_tag",
        confidence = 48,
        regex = "^(.-)[%s%._%-]+Mid[%s%._%-]*Season[%s%._%-]*Finale[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "christmas_special_tag",
        confidence = 46,
        regex = "^(.-)[%s%._%-]+Christmas[%s%._%-]+Special[%s%._%-]*(%d*)",
        fields = { "title", "special_num" }
    },
    {
        name = "halloween_special_tag",
        confidence = 46,
        regex = "^(.-)[%s%._%-]+Halloween[%s%._%-]+Special[%s%._%-]*(%d*)",
        fields = { "title", "special_num" }
    },
    {
        name = "behind_scenes_tag",
        confidence = 44,
        regex = "^(.-)[%s%._%-]+Behind[%s%._%-]+(?:the[%s%._%-]+)?Scenes",
        fields = { "title" }
    },
    {
        name = "making_of_tag",
        confidence = 44,
        regex = "^(.-)[%s%._%-]+Making[%s%._%-]+Of",
        fields = { "title" }
    },
    {
        name = "deleted_scenes_tag",
        confidence = 44,
        regex = "^(.-)[%s%._%-]+Deleted[%s%._%-]+Scenes",
        fields = { "title" }
    },
    {
        name = "gag_reel_tag",
        confidence = 44,
        regex = "^(.-)[%s%._%-]+(?:Gag[%s%._%-]+Reel|Bloopers)",
        fields = { "title" }
    },
    {
        name = "recap_tag",
        confidence = 42,
        regex = "^(.-)[%s%._%-]+Recap[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "previously_on_tag",
        confidence = 42,
        regex = "^(.-)[%s%._%-]+Previously[%s%._%-]+On[%s%._%-]+[Ss](%d+)[Ee](%d+)",
        fields = { "title", "season", "episode" }
    },
    {
        name = "loose_title_metadata_tail",
        confidence = 40,
        regex = "^([^%[%%(]+)%s*[%(%[]",
        fields = { "title" }
    }
}

function M.run_patterns(content, logger)
    for _, p in ipairs(PATTERNS) do
        local caps = { content:match(p.regex) }

        if #caps > 0 then
            -- Handle logging
            if logger then
                if DEBUG_PATTERNS then
                    logger(string.format("PATTERN MATCHED: %-28s | confidence=%d | captures=[%s]",
                        p.name, p.confidence, table.concat(caps, ", ")))
                end
            else
                debug_pattern_hit(p.name, p.confidence, caps)
            end

            -- Process fields
            local out = { pattern = p.name, confidence = p.confidence }
            for i, field in ipairs(p.fields) do
                local value = caps[i]
                
                -- Use the cleaner here
                if field == "title" then
                    value = sanitize_title(value)
                end
                
                out[field] = value
            end
            return out
        end
    end

    -- No match logging
    if DEBUG_PATTERNS then
        local msg = "NO PATTERN MATCHED for: " .. content
        if logger then logger(msg) else print(msg) end
    end

    return nil
end

return M