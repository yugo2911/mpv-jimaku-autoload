#!/usr/bin/env lua

-- Add the current directory to package.path so we can require the jimaku module
package.path = package.path .. ";./?.lua;./?/init.lua"

-- Mock mpv functions that the script expects
local mp = {
    command_native = function(args) 
        return { status = 1 } 
    end,
    get_property = function() return "" end,
    get_property_bool = function() return false end,
    get_property_number = function() return 0 end
}

local utils = {
    parse_json = function(text)
        local ok, data = pcall(function() return require("cjson").decode(text) end)
        if not ok then
            ok, data = pcall(function() 
                local func = load("return " .. text)
                return func()
            end)
        end
        return ok and data or nil
    end
}

-- Load the jimaku script
dofile("jimaku.lua")

print("Testing get_indexed_subs function...")

-- Test 1: Call without auto_create (should return empty table since no index exists)
print("\n1. Testing without auto_create:")
local result1 = get_indexed_subs(false)
print("Result type:", type(result1))
print("Result length:", result1 and #result1 or 0)

-- Test 2: Call with auto_create (should create index and return files)
print("\n2. Testing with auto_create:")
local result2 = get_indexed_subs(true)
print("Result type:", type(result2))
print("Result length:", result2 and #result2 or 0)
if result2 and #result2 > 0 then
    print("First few files:")
    for i = 1, math.min(3, #result2) do
        print("  " .. i .. ": " .. result2[i])
    end
end

-- Test 3: Check if index file was created
print("\n3. Checking if index file was created:")
local index_file = io.open(os.getenv("HOME") .. "/.config/mpv/cache/sub_index.json", "r")
if index_file then
    print("Index file exists!")
    local content = index_file:read("*all")
    index_file:close()
    local data = utils.parse_json(content)
    if data and data.files then
        print("Index contains " .. #data.files .. " files")
    end
else
    print("Index file was not created")
end