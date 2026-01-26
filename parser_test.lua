-- parser_test.lua (updated with NIL toggle)
local patterns = require("parser_patterns")

local input_file = arg[1] or "torrents.txt"
local log_file = "parser_test.log"

-- TOGGLE: Set to true to hide successful matches and only see failures
local ONLY_NIL = true
local FALSE_POSITIVE_TEST = false  -- Set to true to treat successful matches as failures

-- open input
local f = io.open(input_file, "r")
if not f then
    print("Cannot open " .. input_file)
    os.exit(1)
end

-- open log
local log = io.open(log_file, "w")
if not log then
    print("Cannot create log file: " .. log_file)
    os.exit(1)
end

-- helper to print to console + log
local function log_print(msg)
    io.write(msg .. "\n")   -- console
    log:write(msg .. "\n")  -- file
end

log_print("=== PATTERN TEST MODE ===")
log_print("Reading: " .. input_file)
log_print("Only Nil Output: " .. tostring(ONLY_NIL))
log_print("")

-- logger function passed to pattern engine
local function engine_logger(msg)
    -- We only pass engine logs if we aren't in strict NIL mode
    if not ONLY_NIL then
        log_print(msg)
    end
end

local total = 0
local matched = 0

for line in f:lines() do
    if line:match("%S") then
        total = total + 1
        local res = patterns.run_patterns(line, engine_logger)
        
        if res then
            matched = matched + 1
            if not ONLY_NIL then
                log_print("FILENAME: " .. line)
                local parts = {}
                for k, v in pairs(res) do
                    table.insert(parts, tostring(k) .. "=" .. tostring(v))
                end
                log_print("MATCH RESULT: " .. table.concat(parts, ", "))
                log_print("")
            end
        else
            -- Always print nil results
            log_print("FILENAME: " .. line)
            log_print("MATCH RESULT: nil")
            log_print("")
        end
    end
end

f:close()
local summary = string.format("SUMMARY: total=%d matched=%d failed=%d\n", total, matched, total - matched)
log_print(summary)
log:close()

print("Log written to: " .. log_file)