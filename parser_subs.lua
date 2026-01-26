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
