-- passive filename parser for episode extraction
-- input:  all_files.log
-- output: parsed_subs.log

local infile  = io.open("all_files.log", "r")
local outfile = io.open("parsed_subs.log", "w")

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function pad2(n)
    n = tonumber(n)
    if not n then return nil end
    return string.format("%02d", n)
end

-- Normalize full‑width digits → ASCII
local function normalize_digits(s)
    if not s then return s end
    return (s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
        local code = utf8.codepoint(c)

        -- fullwidth ０–９ → ASCII 0–9
        if code >= 0xFF10 and code <= 0xFF19 then
            return string.char(code - 0xFF10 + 48)
        end

        -- circled numbers ①–⑳ etc.
        if code >= 0x2460 and code <= 0x2473 then
            return tostring(code - 0x245F)
        end

        -- parenthesized numbers （１） etc.
        if code >= 0x2474 and code <= 0x2487 then
            return tostring(code - 0x2473)
        end

        return c
    end))
end

------------------------------------------------------------
-- Pattern Cascade (ordered)
------------------------------------------------------------

local patterns = {

    --------------------------------------------------------
    -- 1) Western SxxExx
    --------------------------------------------------------
    function(s)
        local S,E = s:match("[Ss](%d+)[Ee](%d+)")
        if S and E then return string.format("S%02dE%02d", S, E) end
    end,

    --------------------------------------------------------
    -- 2) Loose season: S2 - E25
    --------------------------------------------------------
    function(s)
        local S,E = s:match("[Ss](%d+)%s*%-%s*[Ee](%d+)")
        if S and E then return string.format("S%02dE%02d", S, E) end
    end,

    --------------------------------------------------------
    -- 3) Season <N> - <E>
    --------------------------------------------------------
    function(s)
        local S,E = s:match("[Ss]eason%s*(%d+)%s*%-%s*(%d+)")
        if S and E then return string.format("S%02dE%02d", S, E) end
    end,

    --------------------------------------------------------
    -- 51) Fractional Episode (Kyojin-13.5 / Ep 13.5)
    --------------------------------------------------------
    function(s)
        local e = s:match("%-%s*(%d+%.%d+)")
        if not e then e = s:match("%s(%d+%.%d+)") end
        if e then return e end
    end,

    --------------------------------------------------------
    -- 4) Western EPxx
    --------------------------------------------------------
    function(s)
        local e = s:match("[Ee][Pp](%d+)")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 5) Western single E02 (no season)
    --------------------------------------------------------
    function(s)
        local e = s:match("[Ee](%d%d?)")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 6) "Episode 043"
    --------------------------------------------------------
    function(s)
        local e = s:match("[Ee]pisode%s*(%d+)")
        if e then return tostring(tonumber(e)) end
    end,

    --------------------------------------------------------
    -- 52) Date in Parentheses (2019.12.31) - Specials
    --------------------------------------------------------
    function(s)
        local d = s:match("%((%d%d%d%d%.%d%d%.%d%d)%)")
        if d then return d end
    end,

    --------------------------------------------------------
    -- 7) Japanese ＃01 / #01
    --------------------------------------------------------
    function(s)
        local e = s:match("[＃#](%d+)")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 8) Japanese 第01話 / 第01回
    --------------------------------------------------------
    function(s)
        local e = s:match("第(%d+)[話回]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 9) Japanese full‑width parenthesis: （３０）
    --------------------------------------------------------
    function(s)
        local e = s:match("（(%d+)）")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 10) Japanese シーズン1-10-Title
    --------------------------------------------------------
    function(s)
        local S,E = s:match("シーズン(%d+)%-(%d+)%-.+")
        if S and E then return string.format("S%02dE%02d", tonumber(S), tonumber(E)) end
    end,

    --------------------------------------------------------
    -- 11) Fansub bracket pattern: [Group][Title][02][...]
    --------------------------------------------------------
    function(s)
        for num in s:gmatch("%[(%d+)%]") do
            local n = tonumber(num)
            if n and n < 200 then return pad2(n) end
        end
    end,

    --------------------------------------------------------
    -- 12) Fansub _-_<ep>_-_
    --------------------------------------------------------
    function(s)
        local e = s:match("%_%-_(%d+)%_%-_")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 13) trackNN_und.ass
    --------------------------------------------------------
    function(s)
        local e = s:match("track(%d+)_")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 14) underscore episode: _005.ass / _12.srt / _9.ass
    --------------------------------------------------------
    function(s)
        local e = s:match("_(%d%d?%d?)%.[AaSs][SsRr][Tt]")
        if e then return tostring(tonumber(e)) end
    end,

    --------------------------------------------------------
    -- 15) Title 047.srt
    --------------------------------------------------------
    function(s)
        local e = s:match("%s(%d%d%d)%.[AaSs][SsRr][Tt]")
        if e then return tostring(tonumber(e)) end
    end,
    
    --------------------------------------------------------
    -- 15.6) Title 01 BD.srt / Title 01 BD.ass
    --------------------------------------------------------
    function(s)
        local e = s:match("%s(%d+)%s+BD%.[AaSs][SsRr][Tt]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 15.7) Title 01 Web .JPSC.ass
    --------------------------------------------------------
    function(s)
        local e = s:match("%s(%d+)%s+Web%s+%.")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 16) dash + episode + optional v2/v3 before bracket/paren
    --------------------------------------------------------
    function(s)
        local e = s:match("%-%s*(%d+)%s*[Vv]%d*%s*[%[(]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 17) dash + episode before Japanese quotes
    --------------------------------------------------------
    function(s)
        local e = s:match("%-%s*(%d+)%s*[「(%[]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 18) dash + episode + dash (Atashin’chi RAW)
    --------------------------------------------------------
    function(s)
        local e = s:match("%-%s*(%d+)%s*%-")
        if e then return tostring(tonumber(e)) end
    end,

    --------------------------------------------------------
    -- 19) Japanese broadcast style: " 01-2023..." or " 01[新]"
    --------------------------------------------------------
    function(s)
        local e = s:match("%s(%d%d?)%s*[%[%]-]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 20) Anime raw: " - 01 1080p"
    --------------------------------------------------------
    function(s)
        local e = s:match("%s(%d%d?)%s+1?0?80?p")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 21) Youkai_Watch_Jam_161.srt
    --------------------------------------------------------
    function(s)
        local e = s:match("_(%d+)%.[AaSs][SsRr][Tt]")
        if e then return tostring(tonumber(e)) end
    end,

    --------------------------------------------------------
    -- 22) Underscore separated with versioning: _01v2_
    --------------------------------------------------------
    function(s)
        local e = s:match("_(%d+)[Vv]%d*[_%s%(%[]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 23) Leading episode number with dash: 5-Title
    --------------------------------------------------------
    function(s)
        local e = s:match("^(%d+)%-")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 24) Triple digit underscore suffix: Title_001.ass
    --------------------------------------------------------
    function(s)
        local e = s:match("_(%d%d%d)%.[AaSs][SsRr][Tt]")
        if e then return tostring(tonumber(e)) end
    end,

    --------------------------------------------------------
    -- 25) Bracketed suffix with versioning: [Title 01v2]
    --------------------------------------------------------
    function(s)
        local e = s:match("%[%D+(%d+)[Vv]%d*%]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 26) Title ending with episode number: Title01.srt
    --------------------------------------------------------
    function(s)
        local e = s:match("%D+(%d+)%.[AaSs][SsRr][Tt]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 27) Cleo-style: _-_01_(...
    --------------------------------------------------------
    function(s)
        local e = s:match("%_%-%_(%d+)%_%(")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 28) Underscore suffix double digit: Title_02.ass
    --------------------------------------------------------
    function(s)
        local e = s:match("_(%d%d)%.[AaSs][SsRr][Tt]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 29) Space separated with language suffix: Title 01 JA.srt
    --------------------------------------------------------
    function(s)
        local e = s:match("%s(%d%d)%s+%a%a%.[AaSs][SsRr][Tt]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 30) Dash suffix: Title - 37.srt
    --------------------------------------------------------
    function(s)
        local e = s:match("%s%-%s*(%d+)%.[AaSs][SsRr][Tt]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 31) Fansub space-separated episode: Bokurano 01v2 (...)
    --------------------------------------------------------
    function(s)
        local e = s:match("%s(%d+)[Vv]?%d*%s+%(%D")
        if e then return pad2(e) end
        
        e = s:match("%s(%d+)[Vv]%d*%s")
        if e then return pad2(e) end

        e = s:match("%s(%d+)%s+%[Final%]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 32) Dash separator with trailing tags: Title - 0587 RA ...
    --------------------------------------------------------
    function(s)
        local e = s:match("%s%-%s*(%d+)%s+[%a%d]")
        if e then return tostring(tonumber(e)) end
    end,

    --------------------------------------------------------
    -- 33) Space separated with date in paren: Title 1009 (2019...)
    --------------------------------------------------------
    function(s)
        local e = s:match("%s(%d+)%s+%(%d%d%d%d")
        if e then return tostring(tonumber(e)) end
    end,

    --------------------------------------------------------
    -- 34) "Ep" prefix: Ep 927 (P1)
    --------------------------------------------------------
    function(s)
        local e = s:match("[Ee]p%s+(%d+)")
        if e then return tostring(tonumber(e)) end
    end,

    --------------------------------------------------------
    -- 35) Japanese title + dash: クレヨンしんちゃん - 1048 SP
    --------------------------------------------------------
    function(s)
        local e = s:match("%s%-%s*(%d+)%s+[Ss][Pp]")
        if e then return tostring(tonumber(e)) end
    end,

    --------------------------------------------------------
    -- 36) Generic Underscore (Gintama_202.ass): _<digits>.<ext>
    --------------------------------------------------------
    function(s)
        local e = s:match("_(%d+)%.[AaSs][SsRr][Tt]")
        if e then return tostring(tonumber(e)) end
    end,

    --------------------------------------------------------
    -- 37) Space separated with custom tags: Bleach 58 L@mBerT
    --------------------------------------------------------
    function(s)
        local e = s:match("%s(%d+)%s+[%a%d]*[^%a%d%s]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 38) Dash + Episode + "END": Bad Girl - 12 END
    --------------------------------------------------------
    function(s)
        local e = s:match("%-%s*(%d+)%s+END")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 39) macOS hidden files: ._Baccano!_JP_01.ass
    --------------------------------------------------------
    function(s)
        local e = s:match("%.%_%D+_(%d+)%.[AaSs][SsRr][Tt]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 40) Dash + Episode + Version/CRC: Aikatsu! - 52v2 8DFDEFAB
    --------------------------------------------------------
    function(s)
        local e = s:match("%s%-%s*(%d+)[Vv]?%d*%s+%x%x%x%x%x%x%x%x")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 41) Title with number + Episode: Yu-Gi-Oh! 5D’s 123
    --------------------------------------------------------
    function(s)
        local e = s:match("%s%d%D+%s+(%d+)%s+[%[(]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 42) Dash + Number (Gintama style): Gintama - 325.ass
    --------------------------------------------------------
    function(s)
        local e = s:match("%-%s*(%d+)%.[AaSs][SsRr][Tt]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 43) Pure number filename: 003.srt
    --------------------------------------------------------
    function(s)
        local e = s:match("^(%d+)%.[AaSs][SsRr][Tt]")
        if e then return tostring(tonumber(e)) end
    end,

    --------------------------------------------------------
    -- 44) Group Bracket + Title + Episode: [POPGO] Series 014.ass
    --------------------------------------------------------
    function(s)
        local e = s:match("%]%s+.+%s+(%d+)%.[AaSs][SsRr][Tt]")
        if e then return tostring(tonumber(e)) end
    end,

    --------------------------------------------------------
    -- 45) Mid-underscore (HitsugiNoChaika_01_Whisper.srt)
    --------------------------------------------------------
    function(s)
        local e = s:match("_(%d+)_")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 46) Dash + Episode + Tag Suffix (Hanako-kun - 01.jp.srt)
    --------------------------------------------------------
    function(s)
        local e = s:match("%-%s*(%d+)%.%a+%.[AaSs][SsRr][Tt]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 47) OVA Keywords (Hell Teacher Nube OVA 2 / OVA第1作)
    --------------------------------------------------------
    function(s)
        local e = s:match("[Oo][Vv][Aa]%s*(%d+)")
        if not e then e = s:match("[Oo][Vv][Aa]第(%d+)") end
        if e then return tostring(tonumber(e)) end
    end,

    --------------------------------------------------------
    -- 48) POPGO Space-Separated suffix ([POPGO] Title 01.jp.ass)
    --------------------------------------------------------
    function(s)
        local e = s:match("%s(%d+)%.%a+%.[AaSs][SsRr][Tt]")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 49) Dot-Separated Sequential ([xRed].Title.2012.01.ass)
    --------------------------------------------------------
    function(s)
        -- Match pattern like .2012.01. where 2012 is year and 01 is ep
        local e = s:match("%.%d%d%d%d%.(%d%d)%.")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 50) Underscore + Parentheses (Shingeki_no_Kyojin (01).ass)
    --------------------------------------------------------
    function(s)
        local e = s:match("%s%((%d+)%)")
        if e then return pad2(e) end
    end,

    --------------------------------------------------------
    -- 53) Fallback Year Pattern (Movie/Standalone)
    --------------------------------------------------------
    function(s)
        local y = s:match("[^%d](%d%d%d%d)[^%d]")
        if y then
            local val = tonumber(y)
            if val >= 1930 and val <= 2026 then return y end
        end
    end,
}

------------------------------------------------------------
-- Episode Extractor
------------------------------------------------------------

local function extract_episode(line)
    line = normalize_digits(line)

    for _,fn in ipairs(patterns) do
        local ep = fn(line)
        if ep then return ep end
    end

    return "UNKNOWN"
end

------------------------------------------------------------
-- Main Loop
------------------------------------------------------------

for line in infile:lines() do
    local ep = extract_episode(line)
    outfile:write(ep, " | ", line, "\n")
end

infile:close()
outfile:close()