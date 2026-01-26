-- PERFORMANCE OPTIMIZATION: Set to false to disable disk writes for logging
local ENABLE_DEBUG_LOG = true
local log_buffer = {}

-- Buffer-aware logging helper
local function buffered_log(msg)
    if not ENABLE_DEBUG_LOG then return end
    table.insert(log_buffer, msg)
end

-- Flush buffer to disk in a single operation
local function flush_log()
    if not ENABLE_DEBUG_LOG or #log_buffer == 0 then return end
    local f = io.open(PARSER_LOG_FILE, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S ") .. table.concat(log_buffer, "\n" .. os.date("%Y-%m-%d %H:%M:%S ")) .. "\n")
        f:close()
    end
    log_buffer = {} -- Clear buffer
end