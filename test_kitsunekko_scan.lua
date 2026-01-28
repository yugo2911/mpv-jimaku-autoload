#!/usr/bin/env lua
-- Standalone test script to debug Kitsunekko mirror scanning

local KITSUNEKKO_MIRROR_PATH = "D:\\kitsunekko-mirror\\subtitles"

local function path_exists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function normalize_path(path)
    if not path then return path end
    if package.config:sub(1, 1) == "\\" then
        return path:gsub("/", "\\")
    else
        return path:gsub("\\", "/")
    end
end

-- Check if a JSON file can be read
local function test_kitsuinfo_read(kitsuinfo_path)
    print("Testing: " .. kitsuinfo_path)
    
    if not path_exists(kitsuinfo_path) then
        print("  ✗ File does not exist")
        return false
    end
    
    print("  ✓ File exists")
    
    local ok, f = pcall(io.open, kitsuinfo_path, "r")
    if not ok or not f then
        print("  ✗ Failed to open file")
        return false
    end
    
    print("  ✓ File opened")
    
    local content = f:read("*a")
    f:close()
    
    if not content or content == "" then
        print("  ✗ File is empty")
        return false
    end
    
    print("  ✓ File has content (" .. #content .. " bytes)")
    print("  Content preview: " .. content:sub(1, 100))
    
    return true
end

-- Test the directory listing
local function test_directory_listing()
    local mirror_path = normalize_path(KITSUNEKKO_MIRROR_PATH)
    print("\nTesting directory listing:")
    print("Mirror path: " .. mirror_path)
    
    if not path_exists(mirror_path) then
        print("✗ Mirror path does not exist")
        return
    end
    
    print("✓ Mirror path exists")
    
    local category_path = mirror_path .. "\\" .. "anime_tv"
    print("\nTesting category: " .. category_path)
    
    if not path_exists(category_path) then
        print("✗ Category path does not exist")
        return
    end
    
    print("✓ Category path exists")
    
    -- Try to list a few known directories
    local test_dirs = {
        "One Punch Man 2",
        "[Oshi no Ko]",
        "07-Ghost"
    }
    
    for _, dir_name in ipairs(test_dirs) do
        local dir_path = category_path .. "\\" .. dir_name
        local kitsuinfo_path = dir_path .. "\\.kitsuinfo.json"
        
        print("\n" .. string.format("Testing anime: %s", dir_name))
        test_kitsuinfo_read(kitsuinfo_path)
    end
end

-- Main
print("=== Kitsunekko Mirror Diagnostic Tool ===\n")
test_directory_listing()
print("\n✓ Diagnostic complete")
