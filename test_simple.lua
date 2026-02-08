#!/usr/bin/env lua

-- Mock minimal mpv environment
local mp = {
    command_native = function() return {status = 1} end,
    get_property = function() return "" end,
    get_property_bool = function() return false end,
    get_property_number = function() return 0 end
}

local utils = {
    parse_json = function(text)
        local ok, data = pcall(function() 
            if text and text ~= "" then
                return load("return " .. text)()
            end
            return nil
        end)
        return ok and data or nil
    end
}

-- Load the script quietly
local old_print = print
print = function() end  -- Suppress debug output
dofile("jimaku.lua")
print = old_print

print("Testing get_indexed_subs function:")

-- Test without auto_create (should return empty table)
local result1 = get_indexed_subs(false)
print("Without auto_create:", type(result1), #result1)

-- Test with auto_create (should create index and return files)
print("\nWith auto_create:")
local result2 = get_indexed_subs(true)
print("Result type:", type(result2))
print("Result length:", result2 and #result2 or 0)

if result2 and #result2 > 0 then
    print("First file:", result2[1])
end

-- Check if index file exists
local f = io.open(os.getenv("HOME") .. "/.config/mpv/cache/sub_index.json", "r")
if f then
    print("Index file created successfully!")
    f:close()
else
    print("Index file not created")
end