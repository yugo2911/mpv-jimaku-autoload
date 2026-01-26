-- compare-subs.lua
-- Compares two embedded subtitle tracks in mpv and prints timing drift.

local mp = require "mp"
local msg = require "mp.msg"

-- CONFIG:
local track_a = 1   -- first subtitle track ID (e.g., English)
local track_b = 2   -- second subtitle track ID (e.g., Japanese)
local max_gap = 10  -- seconds: gaps larger than this are flagged

------------------------------------------------------------

local function get_subs(track)
    local res = mp.command_native({
        "sub-export",
        track,
        "memory"
    })

    if not res or not res.data then
        msg.error("Failed to export subtitle track " .. track)
        return nil
    end

    return res.data
end

local function parse_srt(text)
    local subs = {}
    for block in text:gmatch("(%d+%s*\n.-)\n\n") do
        local idx, start, stop, body =
            block:match("(%d+)%s*\n(%d%d:%d%d:%d%d,%d%d%d)%s*-->%s*(%d%d:%d%d:%d%d,%d%d%d)\n(.+)")
        if idx then
            table.insert(subs, {
                index = tonumber(idx),
                start = start,
                stop = stop,
                body = body
            })
        end
    end
    return subs
end

local function to_seconds(t)
    local h, m, s, ms = t:match("(%d+):(%d+):(%d+),(%d+)")
    return h*3600 + m*60 + s + ms/1000
end

local function compare()
    mp.osd_message("Comparing subtitle tracks…")

    local a = get_subs(track_a)
    local b = get_subs(track_b)

    if not a or not b then
        mp.osd_message("Failed to load subtitles")
        return
    end

    local sa = parse_srt(a)
    local sb = parse_srt(b)

    if #sa == 0 or #sb == 0 then
        mp.osd_message("One of the tracks is not SRT or empty")
        return
    end

    local count = math.min(#sa, #sb)
    local drift_report = {}

    for i = 1, count do
        local A = sa[i]
        local B = sb[i]

        local tA = to_seconds(A.start)
        local tB = to_seconds(B.start)
        local diff = tB - tA

        if math.abs(diff) > max_gap then
            table.insert(drift_report,
                string.format("Line %d: DRIFT %.2fs  (%s vs %s)",
                    i, diff, A.start, B.start))
        end
    end

    if #drift_report == 0 then
        mp.osd_message("No major drift detected")
    else
        local msg_text = "Drift detected:\n" .. table.concat(drift_report, "\n")
        msg.info(msg_text)
        mp.osd_message("Drift detected — see console")
    end
end

mp.add_key_binding("Ctrl+c", "compare-subs", compare)
