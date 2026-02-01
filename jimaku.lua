-- Detect if running standalone (command line) or in mpv
local STANDALONE_MODE = not pcall(function() return mp.get_property("filename") end)
local utils = (not STANDALONE_MODE) and require 'mp.utils' or nil
-- 1. BASE CONFIGURATION & DEFAULTS
local script_opts = {
    jimaku_api_key       = "",
    SUBTITLE_CACHE_DIR   = "./subtitle-cache",
    JIMAKU_MAX_SUBS      = 10,
    JIMAKU_AUTO_DOWNLOAD = true,
    LOG_ONLY_ERRORS      = false,
    JIMAKU_HIDE_SIGNS    = false,
    JIMAKU_ITEMS_PER_PAGE= 8,
    JIMAKU_MENU_TIMEOUT  = 30,
    JIMAKU_FONT_SIZE     = 16,
    INITIAL_OSD_MESSAGES = true,
    LOG_FILE             = false,
    USE_ANILIST_API      = true,
    USE_JIMAKU_API       = true
}
-- 2. DETERMINE PATHS
CONFIG_DIR = STANDALONE_MODE and "." or mp.command_native({"expand-path", "~~/"})
-- 3. LOAD OPTIONS FROM FILE
if not STANDALONE_MODE then
    require("mp.options").read_options(script_opts, "jimaku")
end
-- 4. MAP TO GLOBAL VARIABLES
ANILIST_API_URL    = "https://graphql.anilist.co"
JIMAKU_API_URL     = "https://jimaku.cc/api"
JIMAKU_API_KEY = (script_opts.jimaku_api_key and script_opts.jimaku_api_key ~= "") and script_opts.jimaku_api_key or nil
LOG_FILE           = script_opts.LOG_FILE and CONFIG_DIR .. "/jimaku.log" or nil
PARSER_LOG_FILE    = CONFIG_DIR .. "/parser-debug.log"
TEST_FILE          = CONFIG_DIR .. "/data/torrents.txt"
ANILIST_CACHE_FILE = CONFIG_DIR .. "/cache/anilist-cache.json"
JIMAKU_CACHE_FILE  = CONFIG_DIR .. "/cache/jimaku-cache.json"
PREFERRED_GROUPS_FILE = CONFIG_DIR .. "/cache/preferred-groups.json"
SUBTITLE_CACHE_DIR = script_opts.SUBTITLE_CACHE_DIR
-- Strip potential quotes from user config (common user error in conf files)
if SUBTITLE_CACHE_DIR then
    SUBTITLE_CACHE_DIR = SUBTITLE_CACHE_DIR:gsub('^"', ''):gsub('"$', '')
    SUBTITLE_CACHE_DIR = SUBTITLE_CACHE_DIR:gsub("^'", ""):gsub("'$", "")
end
if not SUBTITLE_CACHE_DIR:match("^/") and not SUBTITLE_CACHE_DIR:match("^%a:") then
    if not STANDALONE_MODE then
        SUBTITLE_CACHE_DIR = CONFIG_DIR .. "/" .. SUBTITLE_CACHE_DIR:gsub("^./", "")
    end
end
LOG_FILE_HANDLE = nil
LOG_ONLY_ERRORS      = script_opts.LOG_ONLY_ERRORS
JIMAKU_MAX_SUBS      = script_opts.JIMAKU_MAX_SUBS
JIMAKU_AUTO_DOWNLOAD = script_opts.JIMAKU_AUTO_DOWNLOAD
JIMAKU_HIDE_SIGNS_ONLY = script_opts.JIMAKU_HIDE_SIGNS
JIMAKU_ITEMS_PER_PAGE= script_opts.JIMAKU_ITEMS_PER_PAGE
JIMAKU_MENU_TIMEOUT  = script_opts.JIMAKU_MENU_TIMEOUT
JIMAKU_FONT_SIZE     = script_opts.JIMAKU_FONT_SIZE
INITIAL_OSD_MESSAGES = script_opts.INITIAL_OSD_MESSAGES
USE_ANILIST_API      = script_opts.USE_ANILIST_API
USE_JIMAKU_API       = script_opts.USE_JIMAKU_API
-- Configure in what order to subtitiles will get loaded u can disable groups by setting enabled = false
-- Will be loaded from cache during initialization
JIMAKU_PREFERRED_GROUPS = nil
-- Runtime Caches
EPISODE_CACHE = {}
ANILIST_CACHE = {}
JIMAKU_CACHE = {}
-- DEBUG LOGGING FUNCTION - Enhanced with cache-specific logging
debug_log = function(message, is_error)
    if LOG_ONLY_ERRORS and not is_error then return end
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_msg = string.format("[%s] %s\n", timestamp, message)
    -- 1. Always print to terminal
    print("Jimaku: " .. message)
    -- 2. Handle File I/O safely
    if type(LOG_FILE) == "string" then
        local f = io.open(LOG_FILE, "a")
        if f then
            f:write(log_msg)
            f:close()
        else
            -- If we can't open the file, try to create it
            local dir = LOG_FILE:match("^(.*[/\\])")
            if dir then
                os.execute("mkdir -p " .. dir)
                f = io.open(LOG_FILE, "a")
                if f then
                    f:write(log_msg)
                    f:close()
                else
                    print("Jimaku ERROR: Cannot create log file at " .. LOG_FILE)
                end
            end
        end
    elseif LOG_FILE_HANDLE then
        LOG_FILE_HANDLE:write(log_msg)
        LOG_FILE_HANDLE:flush()
    end
end
-- Example Cache Utility with Debug Info
save_persistent_cache = function(file_path, data)
    debug_log("Cache Debug: Attempting to save to " .. file_path)
    if not utils then return end
    local json = utils.format_json(data)
    local f = io.open(file_path, "w")
    if f then
        f:write(json)
        f:close()
        debug_log("Cache Debug: Successfully saved " .. #json .. " bytes.")
    else
        debug_log("Cache Debug: ERROR - Could not open file for writing: " .. file_path, true)
    end
end
load_persistent_cache = function(file_path)
    debug_log("Cache Debug: Checking for cache at " .. file_path)
    local f = io.open(file_path, "r")
    if f then
        local content = f:read("*all")
        f:close()
        if content and content ~= "" then
            local data = utils.parse_json(content)
            debug_log("Cache Debug: HIT - Loaded existing cache from disk.")
            return data
        end
    end
    debug_log("Cache Debug: MISS - No valid cache file found.")
    return {}
end
-- Load preferred groups from cache or use defaults
local function load_preferred_groups()
    local cached = load_persistent_cache(PREFERRED_GROUPS_FILE)
    -- If cache exists and has data, use it
    if cached and cached.groups and #cached.groups > 0 then
        debug_log("Loaded " .. #cached.groups .. " preferred groups from cache")
        return cached.groups
    end
    -- Otherwise use defaults
    debug_log("Using default preferred groups")
    return {
        {name = "Nekomoe kissaten", enabled = true},
        {name = "LoliHouse", enabled = true},
        {name = "Retimed", enabled = true},
        {name = "WEBRip", enabled = true},
        {name = "WEB-DL", enabled = true},
        {name = "WEB", enabled = true},
        {name = "Amazon", enabled = true},
        {name = "AMZN", enabled = true},
        {name = "Netflix", enabled = true},
        {name = "CHS", enabled = false}
    }
end
-- Save preferred groups to cache
save_preferred_groups = function()
    local data = {
        version = 1,
        last_updated = os.time(),
        groups = JIMAKU_PREFERRED_GROUPS
    }
    save_persistent_cache(PREFERRED_GROUPS_FILE, data)
    debug_log("Saved " .. #JIMAKU_PREFERRED_GROUPS .. " preferred groups to cache")
end
-- TODO INDEX FILE LOCATIONS INSTEAD OF DUMB SCAN ON BOOT
-------------------------------------------------------------------------------
-- INDEXING UTILITIES (O(n) Walk / O(1) Boot)
-------------------------------------------------------------------------------
local INDEX_FILE = CONFIG_DIR .. "/cache/sub_index.json"

-- Helper function to count table entries properly
local function count_table_entries(tbl)
    if not tbl or type(tbl) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    return count
end

-- Recursive folder walk (O(n))
local function walk_directory(path)
    local files = {}
    local entries = utils.readdir(path, "files")
    local dirs = utils.readdir(path, "dirs")
    for _, file in ipairs(entries or {}) do
        if file:match("%.ass$") or file:match("%.srt$") then
            table.insert(files, path .. "/" .. file)
        end
    end
    for _, dir in ipairs(dirs or {}) do
        if dir ~= "." and dir ~= ".." then
            local sub_files = walk_directory(path .. "/" .. dir)
            for _, f in ipairs(sub_files) do table.insert(files, f) end
        end
    end
    return files
end
-- Refresh the flat index file
update_sub_index = function()
    debug_log("Refreshing subtitle index...")
    local all_subs = walk_directory(SUBTITLE_CACHE_DIR)
    save_persistent_cache(INDEX_FILE, { last_updated = os.time(), files = all_subs })
    return all_subs
end
-- Fast retrieval (O(1) Disk access)
get_indexed_subs = function(auto_create)
    local data = load_persistent_cache(INDEX_FILE)
    if (not data or not data.files) and auto_create then 
        return update_sub_index() 
    end
    return data and data.files or {}
end
-------------------------------------------------------------------------------
-- MENU SYSTEM STATE
-------------------------------------------------------------------------------
local menu_state = {
    active = false,
    stack = {},  -- Stack of menu contexts {name, items, selected, scroll_offset}
    timeout_timer = nil,
    -- Tracked state for menu display
    current_match = nil,
    loaded_subs_count = 0,
    loaded_subs_files = {},  -- Track loaded subtitle filenames
    jimaku_id = nil,
    jimaku_entry = nil,
    anilist_id = nil,
    parsed_data = nil,
    seasons_data = {},
    -- Subtitle browser state
    browser_page = 1,
    browser_files = nil,  -- Cached file list
    browser_filter = nil, -- Filter text
    items_per_page = JIMAKU_ITEMS_PER_PAGE,
    -- AniList search results (for manual picker)
    search_results = {},
    search_results_page = 1
}
-- Menu configuration
local MENU_TIMEOUT = JIMAKU_MENU_TIMEOUT
-------------------------------------------------------------------------------
-- MENU RENDERING & NAVIGATION
-------------------------------------------------------------------------------
-- Forward declare local functions for correct scoping
local render_menu_osd, close_menu, push_menu, pop_menu
local bind_menu_keys, handle_menu_up, handle_menu_down, handle_menu_left, handle_menu_right, handle_menu_select, handle_menu_num
local search_anilist, is_archive_file
local show_main_menu, show_subtitles_menu, show_search_menu, show_download_menu
local show_info_menu, show_settings_menu, show_cache_menu, show_help_menu, show_manage_menu
local show_ui_settings_menu, show_filter_settings_menu, show_preferred_groups_menu
local show_preferences_menu, show_download_settings_menu
local show_subtitle_browser, fetch_all_episode_files, logical_sort_files
local parse_jimaku_filename, download_selected_subtitle_action
local show_current_match_info_action, reload_subtitles_action
local download_more_action, clear_subs_action, show_search_results_menu
local save_config_to_file
local select_anilist_result, handle_archive_file, apply_browser_filter
-- Close menu and cleanup
close_menu = function()
    if not menu_state.active then return end
    menu_state.active = false
    menu_state.stack = {}
    -- Clear timeout timer
    if menu_state.timeout_timer then
        menu_state.timeout_timer:kill()
        menu_state.timeout_timer = nil
    end
    -- Remove all menu keybindings (primary and alternatives)
    local keys_to_remove = {
        "menu-up", "menu-down", "menu-left", "menu-right", "menu-select", "menu-close",
        "menu-up-alt", "menu-down-alt", "menu-select-alt", "menu-back-alt", "menu-quit-alt",
        "menu-wheel-up", "menu-wheel-down", "menu-mbtn-left", "menu-mbtn-right",
        "menu-search-slash", "menu-filter-f", "menu-clear-x", "menu-delete-ctrl-del"
    }
    for _, name in ipairs(keys_to_remove) do
        mp.remove_key_binding(name)
    end
    for i = 0, 9 do
        mp.remove_key_binding("menu-num-" .. i)
    end
    -- Clear OSD
    mp.osd_message("", 0)
    debug_log("Menu closed")
end
-- Render menu using ASS (Advanced SubStation) styling
render_menu_osd = function()
    if not menu_state.active or #menu_state.stack == 0 then return end
    local context = menu_state.stack[#menu_state.stack]
    local title = context.title
    local items = context.items
    local selected = context.selected
    local footer = context.footer or (#menu_state.stack > 1 and "ESC: Back | 0: Back" or "ESC: Close")
    local header = context.header
    local ass = mp.get_property_osd("osd-ass-cc/0")
    -- Styling
    local style_header = string.format("{\\b1\\fs%d\\c&H00FFFF&}", JIMAKU_FONT_SIZE + 4)
    local style_selected = string.format("{\\b1\\fs%d\\c&H00FF00&}", JIMAKU_FONT_SIZE)
    local style_normal = string.format("{\\fs%d\\c&HFFFFFF&}", JIMAKU_FONT_SIZE)
    local style_disabled = string.format("{\\fs%d\\c&H808080&}", JIMAKU_FONT_SIZE)
    local style_footer = string.format("{\\fs%d\\c&HCCCCCC&}", JIMAKU_FONT_SIZE - 2)
    local style_dim = string.format("{\\fs%d\\c&H888888&}", JIMAKU_FONT_SIZE - 6)
    local style_status = string.format("{\\fs%d\\c&HAAAAAA&}", JIMAKU_FONT_SIZE - 2)
    -- Build menu
    ass = ass .. style_header .. title .. "\\N"
    ass = ass .. string.format("{\\fs%d\\c&H808080&}", JIMAKU_FONT_SIZE - 2) .. string.rep("━", 40) .. "\\N"
    -- Add header section if provided
    if header then
        ass = ass .. style_status .. header .. "\\N"
        ass = ass .. string.format("{\\fs%d\\c&H808080&}", JIMAKU_FONT_SIZE - 2) .. string.rep("─", 40) .. "\\N"
    end
    -- Items
    for i, item in ipairs(items) do
        local prefix = (i == selected) and "→ " or "  "
        local style = (i == selected) and style_selected or style_normal
        if item.disabled then
            style = style_disabled
        end
        local text = item.text
        if item.hint then
            text = text .. " " .. style_dim .. "(" .. item.hint .. ")" .. style
        end
        ass = ass .. style .. prefix .. text .. "\\N"
    end
    -- Footer
    ass = ass .. string.format("{\\fs%d\\c&H808080&}", JIMAKU_FONT_SIZE - 2) .. string.rep("━", 40) .. "\\N"
    ass = ass .. style_footer .. footer .. "\\N"
    mp.osd_message(ass, MENU_TIMEOUT)
    -- Reset timeout
    if menu_state.timeout_timer then
        menu_state.timeout_timer:kill()
    end
    menu_state.timeout_timer = mp.add_timeout(MENU_TIMEOUT, close_menu)
end
-- Helper for conditional OSD messages (suppress during auto-fetch if configured)
local function conditional_osd(message, duration, is_auto)
    if not is_auto or INITIAL_OSD_MESSAGES then
        mp.osd_message(message, duration)
    end
end
-- Navigation functions
-- Key handlers
-- Generic navigation handler
local function handle_menu_nav(direction)
    if not menu_state.active or #menu_state.stack == 0 then return end
    local context = menu_state.stack[#menu_state.stack]
    local initial_selected = context.selected
    repeat
        context.selected = context.selected + direction
        if context.selected < 1 then context.selected = #context.items end
        if context.selected > #context.items then context.selected = 1 end
        local item = context.items[context.selected]
        -- Skip if it's a header OR if it's disabled AND has no action (labels)
        local is_label = item.header or (item.disabled and not item.action)
    until not is_label or context.selected == initial_selected
    render_menu_osd()
end

handle_menu_up = function() handle_menu_nav(-1) end
handle_menu_down = function() handle_menu_nav(1) end
handle_menu_left = function()
    if not menu_state.active or #menu_state.stack == 0 then return end
    local context = menu_state.stack[#menu_state.stack]
    if context.on_left then
        context.on_left()
    end
end
handle_menu_right = function()
    if not menu_state.active or #menu_state.stack == 0 then return end
    local context = menu_state.stack[#menu_state.stack]
    if context.on_right then
        context.on_right()
    end
end
handle_menu_select = function()
    if not menu_state.active or #menu_state.stack == 0 then return end
    local context = menu_state.stack[#menu_state.stack]
    local item = context.items[context.selected]
    if item and item.action and not item.disabled then
        item.action()
    end
end
handle_menu_num = function(n)
    if not menu_state.active or #menu_state.stack == 0 then return end
    local context = menu_state.stack[#menu_state.stack]
    -- Handle 0 for back/close
    if n == 0 then
        pop_menu()
        return
    end
    local item = context.items[n]
    if item and item.action and not item.disabled then
        item.action()
    end
end
-- Navigation functions
push_menu = function(title, items, footer, on_left, on_right, selected, header)
    debug_log("Pushing menu: " .. title)
    if #menu_state.stack == 0 then
        bind_menu_keys()
    end
    table.insert(menu_state.stack, {
        title = title,
        items = items,
        selected = selected or 1,
        footer = footer,
        on_left = on_left,
        on_right = on_right,
        header = header
    })
    menu_state.active = true
    render_menu_osd()
end
pop_menu = function()
    debug_log("Popping menu")
    if #menu_state.stack > 1 then
        table.remove(menu_state.stack)
        render_menu_osd()
    else
        close_menu()
    end
end
bind_menu_keys = function()
    -- Primary keys
    mp.add_forced_key_binding("UP", "menu-up", handle_menu_up)
    mp.add_forced_key_binding("DOWN", "menu-down", handle_menu_down)
    mp.add_forced_key_binding("LEFT", "menu-left", handle_menu_left)
    mp.add_forced_key_binding("RIGHT", "menu-right", handle_menu_right)
    mp.add_forced_key_binding("ENTER", "menu-select", handle_menu_select)
    mp.add_forced_key_binding("ESC", "menu-close", pop_menu)

    -- Alternative keys (no overlap)
    mp.add_forced_key_binding("k", "menu-up-alt", handle_menu_up)
    mp.add_forced_key_binding("j", "menu-down-alt", handle_menu_down)
    mp.add_forced_key_binding("l", "menu-select-alt", handle_menu_select)
    mp.add_forced_key_binding("h", "menu-back-alt", pop_menu)
    mp.add_forced_key_binding("q", "menu-quit-alt", close_menu)

    -- Global actions
    local function trigger_filter()
        local current = menu_state.stack[#menu_state.stack]
        if menu_state.active and current and current.title:match("Browse Jimaku Subs") then
            mp.osd_message("Enter filter/episode in console", 3)
            mp.commandv("script-message-to", "console", "type", "script-message jimaku-browser-filter ")
        end
    end

    mp.add_forced_key_binding("/", "menu-search-slash", trigger_filter)
    mp.add_forced_key_binding("f", "menu-filter-f", trigger_filter)

    -- Fixed: Wrapped the floating logic into a proper binding (assuming 'BACKSPACE' to reset filter)
    mp.add_forced_key_binding("BS", "menu-filter-reset", function()
        local current = menu_state.stack[#menu_state.stack]
        if menu_state.active and current and current.title:match("Browse Jimaku Subs") then
            apply_browser_filter(nil)
        end
    end)

    -- Remove release group
    mp.add_forced_key_binding("Ctrl+DEL", "menu-delete-ctrl-del", function()
        local current = menu_state.stack[#menu_state.stack]
        if menu_state.active and current and current.title == "Release Group Priority" then
            local idx = current.selected
            if idx > 0 and idx <= #JIMAKU_PREFERRED_GROUPS then
                local group_name = JIMAKU_PREFERRED_GROUPS[idx].name
                table.remove(JIMAKU_PREFERRED_GROUPS, idx)
                save_preferred_groups()
                mp.osd_message("Removed: " .. group_name, 2)
                
                pop_menu()
                
                local new_idx = idx
                local count = #JIMAKU_PREFERRED_GROUPS
                if new_idx > count then new_idx = count end
                if new_idx < 1 then new_idx = 1 end
                
                show_preferred_groups_menu(new_idx)
            end
        end
    end)

    -- Mouse bindings
    mp.add_forced_key_binding("WHEEL_UP", "menu-wheel-up", handle_menu_up)
    mp.add_forced_key_binding("WHEEL_DOWN", "menu-wheel-down", handle_menu_down)
    mp.add_forced_key_binding("MBTN_LEFT", "menu-mbtn-left", handle_menu_select)
    mp.add_forced_key_binding("MBTN_RIGHT", "menu-mbtn-right", pop_menu)

    for i = 0, 9 do
        mp.add_forced_key_binding(tostring(i), "menu-num-" .. i, function() handle_menu_num(i) end)
    end
end
-------------------------------------------------------------------------------
-- MENU DEFINITIONS & ACTIONS
-------------------------------------------------------------------------------
-- Action handlers
reload_subtitles_action = function()
    mp.osd_message("Reloading...", 2)
    pop_menu()
end
download_more_action = function()
    mp.osd_message("Downloading more...", 2)
    pop_menu()
end
clear_subs_action = function()
    mp.command("sub-remove")
    mp.osd_message("✓ Subtitles cleared", 2)
    pop_menu()
end
-- Show detailed match info
show_current_match_info_action = function()
    local m = menu_state.current_match
    if not m then
        mp.osd_message("No match information available", 3)
        return
    end
    local info = string.format(
        "Current Match Info:\\N" ..
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━\\N" ..
        "Title: %s\\N" ..
        "AniList ID: %s\\N" ..
        "Season: %s | Episode: %s\\N" ..
        "Format: %s | Episodes: %s\\N" ..
        "Match Method: %s\\N" ..
        "Confidence: %s",
        m.title or "N/A",
        m.anilist_id or "N/A",
        m.season or "N/A",
        m.episode or "N/A",
        m.format or "N/A",
        m.total_episodes or "?",
        m.match_method or "N/A",
        m.confidence or "N/A"
    )
    mp.osd_message(info, 8)
    pop_menu()
end
-- Download a specific subtitle file selected from browser
download_selected_subtitle_action = function(file)
    if not JIMAKU_API_KEY or JIMAKU_API_KEY == "" then
        mp.osd_message("Error: Jimaku API key not set", 3)
        return
    end

    local subtitle_path = SUBTITLE_CACHE_DIR .. "/" .. file.name
    mp.osd_message("Downloading selected subtitle...", 30)

    local download_args = {
        "curl", "-s", "-L", "-o", subtitle_path,
        "-H", "Authorization: " .. JIMAKU_API_KEY,
        file.url
    }

    local download_result = mp.command_native({
        name = "subprocess",
        playback_only = false,
        args = download_args
    })

    if download_result.status == 0 then
        -- Logic for updating OSD if browser is active
        local current_menu = menu_state.stack[#menu_state.stack]
        if menu_state.active and current_menu and current_menu.title:match("Browse Jimaku Subs") then
            local filter = menu_state.browser_filter
            if filter then
                mp.osd_message(string.format("Filter: '%s' (Press / to change)", filter), 3)
            end
        end
    end -- Fixed: This 'end' was missing
end
-- Forward declarations to prevent nil reference errors
local show_main_menu, show_download_menu
-- 1. Main Menu

-- 1. Main Menu (Updated to point to consolidated menu)
show_main_menu = function()
    if menu_state.active then
        if #menu_state.stack > 1 then
            while #menu_state.stack > 1 do table.remove(menu_state.stack) end
            render_menu_osd()
        else
            close_menu()
        end
        return
    end
    menu_state.stack = {}
    menu_state.active = false
    local m = menu_state.current_match
    local has_match = menu_state.jimaku_id ~= nil
    local status = m and string.format("Match: %s S%dE%d", m.title:sub(1,30), m.season or 1, m.episode or 1) 
                     or "Match: None (press 'A' to search)"
    local items = {
        {
            text = "1. Browse All Available", 
            hint = has_match and "View all files" or "No match yet", 
            disabled = not has_match, 
            action = function()
                menu_state.browser_page = nil
                show_subtitle_browser()
            end
        },
        -- Pointing to the consolidated menu
        {text = "2. Search & Download", action = function() show_download_menu() end},
        {text = "3. Preferences",        action = function() show_preferences_menu() end},
        {text = "4. Manage & Cleanup",   action = function() show_manage_menu() end},
    }
    local header = "JIMAKU SUBTITLE MANAGER\\N" .. status .. "\\NSubs: " .. (menu_state.loaded_subs_count or 0) .. "/" .. JIMAKU_MAX_SUBS
    push_menu("Main Menu", items, nil, nil, nil, nil, header)
end
-- Consolidated Search & Download Menu
-- Replaces both show_download_menu and show_search_menu
show_download_menu = function()
    -- Cached local lookups for O(1) access during item construction
    local ms = menu_state
    local m = ms.current_match
    local results_count = #ms.search_results
    local has_match = ms.jimaku_id ~= nil
    local match_name = m and m.title or "None"
    local match_details = m and string.format("ID: %s | Conf: %s", m.anilist_id, m.confidence or "??") or "No active match"
    local results_hint = results_count > 0 and (results_count .. " found") or "No results"
    local items = {
        -- Status Headers (Disabled items for display only)
        {text = "Current:", hint = match_name, disabled = true},
        {text = "Details:", hint = match_details, disabled = true},
        -- Primary Logic Items
        {
            text = "1. Auto-Search & Match", 
            action = function() 
                search_anilist()
                close_menu()
            end
        },
        {
            text = "2. Pick from Results", 
            hint = results_hint, 
            disabled = results_count == 0, 
            action = function()
                ms.search_results_page = 1
                show_search_results_menu()
            end
        },
        {
            text = "2. Manual AniList Search", 
            action = manual_search_action
        },
        {
            text = "3. Manual Jimaku Search", 
            action = function()
                mp.osd_message("Type search in console (press ~)", 3)
                mp.commandv("script-message-to", "console", "type", "script-message jimaku-search ")
            end
        },
        {
            text = "5. Reload Current Match", 
            disabled = not has_match, 
            action = reload_subtitles_action
        },
        {text = "0. Back to Main Menu", action = pop_menu},
    }
    local header = "SEARCH & DOWNLOAD\\N" .. string.rep("—", 20)
    push_menu("Search & Download", items, nil, nil, nil, nil, header)
end
-- Keep old function name for compatibility
show_subtitles_menu = show_download_menu
-- Subtitle Browser (Paginated)
show_subtitle_browser = function()
    local jimaku_id = menu_state.jimaku_id
    if not jimaku_id then
        mp.osd_message("No Jimaku ID available. Run search first.", 3)
        return
    end
    -- Fetch files if not cached
    if not menu_state.browser_files then
        mp.osd_message("Fetching subtitle list...", 30)
        local files = fetch_all_episode_files(jimaku_id)
        if files then
            logical_sort_files(files)
        end
        menu_state.browser_files = files
        mp.osd_message("", 0)
    end
    if not menu_state.browser_files or #menu_state.browser_files == 0 then
        mp.osd_message("No subtitles found on Jimaku", 3)
        return
    end
    local all_files = menu_state.browser_files
    local filtered_files = {}
    -- Apply filter if active
    if menu_state.browser_filter then
        local filter = menu_state.browser_filter:lower()
        for _, file in ipairs(all_files) do
            local name = file.name:lower()
            -- Check filename or parsed episode number
            local s, e = parse_jimaku_filename(file.name)
            local ep_str = e and tostring(e) or ""
            if name:match(filter) or ep_str:match("^" .. filter .. "$") or ep_str:match("^0*" .. filter .. "$") then
                table.insert(filtered_files, file)
            end
        end
    else
        filtered_files = all_files
    end
    -- If page is nil, jump to current episode
    if not menu_state.browser_page or menu_state.browser_page < 1 then
        menu_state.browser_page = 1
        -- Get target episode from current_match
        local target_ep = menu_state.current_match and menu_state.current_match.episode
        local target_season = menu_state.current_match and menu_state.current_match.season
        -- Calculate cumulative episode for matching (like download logic does)
        local target_cumulative = nil
        if target_ep and menu_state.seasons_data then
            if target_season and target_season > 1 then
                local cumulative = 0
                for season_idx = 1, target_season - 1 do
                    if menu_state.seasons_data[season_idx] then
                        cumulative = cumulative + menu_state.seasons_data[season_idx].eps
                    end
                end
                target_cumulative = cumulative + target_ep
            else
                target_cumulative = target_ep
            end
        end
        if target_ep then
            for i, file in ipairs(filtered_files) do
                local s, e = parse_jimaku_filename(file.name)
                local matched = false
                -- Match 1: Direct season/episode match
                if e == target_ep and (not s or not target_season or s == target_season) then
                    matched = true
                end
                -- Match 2: Japanese absolute episode (第222話)
                if not matched and target_cumulative then
                    local japanese_ep = file.name:match("第(%d+)[話回]")
                    if japanese_ep and tonumber(japanese_ep) == target_cumulative then
                        matched = true
                    end
                end
                -- Match 3: Episode number matches cumulative (for files with just E222)
                if not matched and target_cumulative and e == target_cumulative then
                    matched = true
                end
                if matched then
                    menu_state.browser_page = math.ceil(i / menu_state.items_per_page)
                    break
                end
            end
        end
    end
    local page = menu_state.browser_page
    local per_page = menu_state.items_per_page
    local total_pages = math.ceil(#filtered_files / per_page)
    -- Ensure page is valid after filtering
    if page > total_pages and total_pages > 0 then page = total_pages end
    if page < 1 then page = 1 end
    local start_idx = (page - 1) * per_page + 1
    local end_idx = math.min(start_idx + per_page - 1, #filtered_files)
    local items = {}
    for i = start_idx, end_idx do
        local file = filtered_files[i]
        local display_idx = i - start_idx + 1
        -- We skip the parse_jimaku_filename part entirely since we don't want S/E
        local is_loaded = false
        for _, loaded_name in ipairs(menu_state.loaded_subs_files) do
            if loaded_name == file.name then is_loaded = true break end
        end
        -- Removed 'display_num' from the format string below
        local item_text = string.format("{\\fs%d}%d. %s", JIMAKU_FONT_SIZE - 2, display_idx, file.name)
        if is_loaded then item_text = "✓ " .. item_text end
        table.insert(items, {
            text = item_text,
            action = function() download_selected_subtitle_action(file) end
        })
    end
    table.insert(items, {text = "0. Back", action = pop_menu})
    -- Pagination callbacks
    local on_left = function()
        if page > 1 then
            menu_state.browser_page = page - 1
            pop_menu()
            show_subtitle_browser()
        end
    end
    local on_right = function()
        if page < total_pages then
            menu_state.browser_page = page + 1
            pop_menu()
            show_subtitle_browser()
        end
    end
    -- Footer labels (non-numbered shortcuts)
    local footer = "←/→ Page | [F] Filter | [X] Clear | [UP/DOWN] Select"
    local title_prefix = menu_state.browser_filter and string.format("FILTERED: '%s' ", menu_state.browser_filter) or ""
    local title = string.format("%sBrowse Jimaku Subs (%d/%d) - Total %d", 
        title_prefix, page, total_pages, #filtered_files)
    push_menu(title, items, footer, on_left, on_right)
end
-- Helper for sorting browser files logically
logical_sort_files = function(files)
    table.sort(files, function(a, b)
        local s_a, e_a = parse_jimaku_filename(a.name)
        local s_b, e_b = parse_jimaku_filename(b.name)
        -- 1. Primary: Season
        if s_a ~= s_b then
            if s_a and s_b then return s_a < s_b end
            return s_a ~= nil -- Non-nil seasons come first
        end
        -- 2. Secondary: Episode
        if e_a ~= e_b then
            local num_a, num_b = tonumber(e_a), tonumber(e_b)
            if num_a and num_b then
                if num_a ~= num_b then return num_a < num_b end
            elseif num_a then return true
            elseif num_b then return false
            elseif e_a and e_b then 
                return tostring(e_a) < tostring(e_b)
            end
            return e_a ~= nil -- Non-nil episodes come first
        end
        -- 3. Tertiary: Filename (Lowercase for stability)
        return a.name:lower() < b.name:lower()
    end)
end
-- AniList Results Browser (Paginated)
show_search_results_menu = function()
    local results = menu_state.search_results
    if not results or #results == 0 then
        mp.osd_message("No search results to display.", 3)
        return
    end
    local page = menu_state.search_results_page
    local per_page = menu_state.items_per_page
    local total_pages = math.ceil(#results / per_page)
    local start_idx = (page - 1) * per_page + 1
    local end_idx = math.min(start_idx + per_page - 1, #results)
    local items = {}
    for i = start_idx, end_idx do
        local media = results[i]
        local title = media.title.romaji or "Unknown Title"
        local year = media.seasonYear and (" [" .. media.seasonYear .. "]") or ""
        local format = media.format and (" (" .. media.format .. ")") or ""
        local is_current = (menu_state.current_match and menu_state.current_match.anilist_id == media.id)
        local prefix = is_current and "✓ " or ""
        table.insert(items, {
            text = string.format("%d. %s%s", (i - start_idx + 1), prefix, title),
            hint = format .. year,
            action = function()
                select_anilist_result(media)
            end
        })
    end
    table.insert(items, {text = "0. Back", action = pop_menu})
    -- Pagination callbacks
    local on_left = function()
        if page > 1 then
            menu_state.search_results_page = page - 1
            pop_menu()
            show_search_results_menu()
        end
    end
    local on_right = function()
        if page < total_pages then
            menu_state.search_results_page = page + 1
            pop_menu()
            show_search_results_menu()
        end
    end
    local title = string.format("AniList Results (Page %d/%d)", page, total_pages)
    local footer = "←/→ Page | [UP/DOWN] Scroll | [ENTER] Select"
    push_menu(title, items, footer, on_left, on_right)
end
-- Select a specific AniList result and re-run subtitle matching
select_anilist_result = function(selected)
    debug_log("User manually selected AniList result: " .. (selected.title.romaji or selected.id))
    -- We need to re-calculate episode/season logic for THIS specific entry
    -- We can reuse smart_match_anilist by passing it as the ONLY result
    local episode_num = tonumber(menu_state.parsed_data.episode) or 1
    local season_num = menu_state.parsed_data.season
    local file_year = extract_year(mp.get_property("media-title") or mp.get_property("filename"))
    local media, actual_episode, actual_season, seasons, match_method, match_confidence = 
        smart_match_anilist({selected}, menu_state.parsed_data, episode_num, season_num, file_year)
    -- Update state
    menu_state.anilist_id = selected.id
    menu_state.current_match = {
        title = selected.title.romaji,
        anilist_id = selected.id,
        episode = actual_episode,
        season = actual_season,
        format = selected.format,
        total_episodes = selected.episodes,
        match_method = "manual_selection",
        confidence = "certain",
        anilist_entry = selected
    }
    menu_state.seasons_data = seasons
    mp.osd_message("Selected: " .. selected.title.romaji, 3)
    -- Now try to fetch subtitles for this new match
    local jimaku_entry = search_jimaku_subtitles(selected.id)
    if jimaku_entry then
        menu_state.jimaku_id = jimaku_entry.id
        menu_state.jimaku_entry = jimaku_entry
        menu_state.browser_files = nil -- Clear cache to force refresh
        download_subtitle_smart(
            jimaku_entry.id, 
            actual_episode, 
            actual_season,
            seasons,
            selected
        )
    else
        mp.osd_message("No Jimaku entry found for this show.", 3)
    end
    -- Return to main menu or close? Let's return to main menu
    close_menu()
end
-- Apply a filter to the subtitle browser
apply_browser_filter = function(filter_text)
    debug_log("Applying browser filter: " .. (filter_text or "NONE"))
    menu_state.browser_filter = filter_text
    menu_state.browser_page = 1 -- Reset to first page of results
    -- Refresh the menu if it's currently showing the browser
    if menu_state.active and #menu_state.stack > 0 and menu_state.stack[#menu_state.stack].title:match("Browse Jimaku Subs") then
        pop_menu()
        show_subtitle_browser()
    else
        render_menu_osd()
    end
end
-- Preferences Menu (replaces Settings)
show_preferences_menu = function(selected)
    local items = {
        {text = "1. Download Settings   →", action = show_download_settings_menu},
        {text = "2. Release Groups      →", action = show_preferred_groups_menu},
        {text = "3. Interface           →", action = show_ui_settings_menu},
        {text = "4. Save Settings", action = save_config_to_file},
        {text = "0. Back to Main Menu", action = pop_menu},
    }
    push_menu("Preferences", items, nil, nil, nil, selected)
end
-- Download Settings (consolidates auto-download, max subs, hide signs)
show_download_settings_menu = function(selected)
    local auto_dl_status = JIMAKU_AUTO_DOWNLOAD and "✓ Enabled" or "✗ Disabled"
    local signs_status = JIMAKU_HIDE_SIGNS_ONLY and "✓ Hidden" or "✗ Shown"
    local items = {
        {text = "1. Auto-download", hint = auto_dl_status, action = function()
            JIMAKU_AUTO_DOWNLOAD = not JIMAKU_AUTO_DOWNLOAD
            pop_menu(); show_download_settings_menu(1)
        end},
        {text = "2. Max Subtitles: " .. JIMAKU_MAX_SUBS, action = function()
            if JIMAKU_MAX_SUBS == 1 then JIMAKU_MAX_SUBS = 3
            elseif JIMAKU_MAX_SUBS == 3 then JIMAKU_MAX_SUBS = 5
            elseif JIMAKU_MAX_SUBS == 5 then JIMAKU_MAX_SUBS = 10
            else JIMAKU_MAX_SUBS = 1 end
            pop_menu(); show_download_settings_menu(2)
        end},
        {text = "3. Hide Signs-Only Subs", hint = signs_status, action = function()
            JIMAKU_HIDE_SIGNS_ONLY = not JIMAKU_HIDE_SIGNS_ONLY
            pop_menu(); show_download_settings_menu(3)
        end},
        {text = "0. Back to Preferences", action = pop_menu},
    }
    push_menu("Download Settings", items, nil, nil, nil, selected)
end
-- UI Settings Submenu (Interface)
show_ui_settings_menu = function(selected)
    local osd_status = INITIAL_OSD_MESSAGES and "✓ Enabled" or "✗ Disabled"
    local items = {
        {text = "1. Menu Font Size: " .. JIMAKU_FONT_SIZE, action = function()
            if JIMAKU_FONT_SIZE == 12 then JIMAKU_FONT_SIZE = 16
            elseif JIMAKU_FONT_SIZE == 16 then JIMAKU_FONT_SIZE = 20
            elseif JIMAKU_FONT_SIZE == 20 then JIMAKU_FONT_SIZE = 24
            elseif JIMAKU_FONT_SIZE == 24 then JIMAKU_FONT_SIZE = 28
            else JIMAKU_FONT_SIZE = 12 end
            pop_menu(); show_ui_settings_menu(1)
        end},
        {text = "2. Items Per Page: " .. JIMAKU_ITEMS_PER_PAGE, action = function()
            if JIMAKU_ITEMS_PER_PAGE == 4 then JIMAKU_ITEMS_PER_PAGE = 6
            elseif JIMAKU_ITEMS_PER_PAGE == 6 then JIMAKU_ITEMS_PER_PAGE = 8
            elseif JIMAKU_ITEMS_PER_PAGE == 8 then JIMAKU_ITEMS_PER_PAGE = 10
            else JIMAKU_ITEMS_PER_PAGE = 4 end
            menu_state.items_per_page = JIMAKU_ITEMS_PER_PAGE
            pop_menu(); show_ui_settings_menu(2)
        end},
        {text = "3. Menu Timeout: " .. JIMAKU_MENU_TIMEOUT .. "s", action = function()
            if JIMAKU_MENU_TIMEOUT == 15 then JIMAKU_MENU_TIMEOUT = 30
            elseif JIMAKU_MENU_TIMEOUT == 30 then JIMAKU_MENU_TIMEOUT = 60
            elseif JIMAKU_MENU_TIMEOUT == 60 then JIMAKU_MENU_TIMEOUT = 0 -- Indefinite
            else JIMAKU_MENU_TIMEOUT = 15 end
            MENU_TIMEOUT = JIMAKU_MENU_TIMEOUT == 0 and 3600 or JIMAKU_MENU_TIMEOUT
            pop_menu(); show_ui_settings_menu(3)
        end},
        {text = "4. OSD Messages", hint = osd_status, action = function()
            INITIAL_OSD_MESSAGES = not INITIAL_OSD_MESSAGES
            pop_menu(); show_ui_settings_menu(4)
        end},
        {text = "0. Back to Preferences", action = pop_menu},
    }
    push_menu("Interface Settings", items, nil, nil, nil, selected)
end
show_preferred_groups_menu = function(selected)
    -- Ensure preferred groups are loaded
    if not JIMAKU_PREFERRED_GROUPS then
        JIMAKU_PREFERRED_GROUPS = load_preferred_groups()
    end
    local items = {}
    for i, group in ipairs(JIMAKU_PREFERRED_GROUPS) do
        local status = group.enabled and "✓ " or "✗ "
        local text = string.format("%d. %s%s", i, status, group.name)
        -- Apply gray style directly if disabled
        if not group.enabled then
            text = string.format("{\\c&H808080&}%s{\\c&HFFFFFF&}", text)
        end
        table.insert(items, {
            text = text,
            hint = nil,
            action = function()
                group.enabled = not group.enabled
                save_preferred_groups()
                pop_menu(); show_preferred_groups_menu(i)
            end
        })
    end
    table.insert(items, {text = "9. Add New Group", action = function()
        mp.osd_message("Enter groups (comma separated) in console", 3)
        mp.commandv("script-message-to", "console", "type", "script-message jimaku-set-groups ")
    end})
    table.insert(items, {text = "0. Back to Preferences", action = pop_menu})
    local on_left = function()
        local idx = menu_state.stack[#menu_state.stack].selected
        if idx > 1 and idx <= #JIMAKU_PREFERRED_GROUPS then
            local temp = JIMAKU_PREFERRED_GROUPS[idx]
            JIMAKU_PREFERRED_GROUPS[idx] = JIMAKU_PREFERRED_GROUPS[idx-1]
            JIMAKU_PREFERRED_GROUPS[idx-1] = temp
            save_preferred_groups()
            pop_menu(); show_preferred_groups_menu(idx - 1)
        end
    end
    local on_right = function()
        local idx = menu_state.stack[#menu_state.stack].selected
        if idx >= 1 and idx < #JIMAKU_PREFERRED_GROUPS then
            local temp = JIMAKU_PREFERRED_GROUPS[idx]
            JIMAKU_PREFERRED_GROUPS[idx] = JIMAKU_PREFERRED_GROUPS[idx+1]
            JIMAKU_PREFERRED_GROUPS[idx+1] = temp
            save_preferred_groups()
        end
    end
    local footer = "←/→ Change Priority | ENTER Toggle | Ctrl+DEL Remove | 0 Back"
    push_menu("Release Group Priority", items, footer, on_left, on_right, selected)
end
-- Cache Submenu
-- Manage & Cleanup Menu (consolidates Cache + subtitle management)
show_manage_menu = function()
    -- Calculate cache stats
    local count_table = count_table_entries
    local anilist_count = count_table(ANILIST_CACHE)
    local jimaku_count = count_table(JIMAKU_CACHE)
    local episode_count = count_table(EPISODE_CACHE)
    local items = {
        {text = "SUBTITLE MANAGEMENT", disabled = true},
        {text = "1. Clear Loaded Subs", action = clear_subs_action},
        {text = "2. Clear Subtitle Cache (Disk)", action = function()
            clear_subtitle_cache()
            pop_menu()
        end},
        {text = "", disabled = true},  -- Spacer
        {text = "CACHE MANAGEMENT", disabled = true},
        {text = "3. View Cache Stats", action = function()
            local stats = string.format(
                "Cache Statistics:\\N" ..
                "━━━━━━━━━━━━━━━━━━━━━━━━━━━\\N" ..
                "AniList Searches: %d\\N" ..
                "Jimaku Entries: %d\\N" ..
                "File Lists: %d\\N\\N" ..
                "Cache Dir:\\N%s",
                anilist_count, jimaku_count, episode_count,
                SUBTITLE_CACHE_DIR
            )
            mp.osd_message(stats, 8)
        end},
        {text = "4. Clear Search Cache", hint = anilist_count .. " entries", action = function()
            ANILIST_CACHE = {}
            save_ANILIST_CACHE()
            mp.osd_message("AniList search cache cleared", 2)
            pop_menu()
        end},
        {text = "5. Clear Jimaku Cache", hint = jimaku_count .. " entries", action = function()
            JIMAKU_CACHE = {}
            save_JIMAKU_CACHE()
            mp.osd_message("Jimaku entry cache cleared", 2)
            pop_menu()
        end},
        {text = "6. Clear File List Cache", hint = episode_count .. " lists", action = function()
            EPISODE_CACHE = {}
            EPISODE_CACHE_KEYS = {}
            mp.osd_message("File list cache cleared", 2)
            pop_menu()
        end},
        {text = "0. Back to Main Menu", action = pop_menu},
    }
    push_menu("Manage & Cleanup", items)
end
-- Keep old name for compatibility
show_cache_menu = show_manage_menu
-- Create subtitle cache directory if it doesn't exist

-- Create directory without CMD flash (cross-platform)
local function ensure_directory(dir_path)
    if STANDALONE_MODE then
        os.execute("mkdir -p " .. dir_path)
    else
        -- Use mpv's subprocess to avoid CMD window flash on Windows
        local is_windows = package.config:sub(1,1) == '\\'
        local args = is_windows and {"cmd", "/C", "mkdir", dir_path} or {"mkdir", "-p", dir_path}
        mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = args
        })
    end
end

-- Generic runtime cache loader with logging
local function load_runtime_cache(file_path, name)
    if STANDALONE_MODE then 
        debug_log(string.format("Cache Debug: STANDALONE_MODE - returning empty %s cache", name))
        return {}
    end
    local f = io.open(file_path, "r")
    if not f then
        debug_log(string.format("%s cache file not found - will create on first search", name))
        return {}
    end
    local content = f:read("*all")
    f:close()
    if not content or content == "" then
        debug_log(string.format("%s cache file is empty", name))
        return {}
    end
    local ok, data = pcall(utils.parse_json, content)
    if not ok then
        debug_log(string.format("Failed to parse %s cache file (corrupted JSON)", name), true)
        return {}
    end
    if not data or type(data) ~= "table" then
        debug_log(string.format("%s cache data is not a valid table", name))
        return {}
    end
    local entry_count = count_table_entries(data)
    debug_log(string.format("Loaded %s cache with %d entries (keys)", name, entry_count))
    -- Log some sample cache keys for debugging
    if entry_count > 0 then
        local sample_keys = {}
        for key, _ in pairs(data) do
            table.insert(sample_keys, key)
            if #sample_keys >= 3 then break end
        end
        debug_log(string.format("Sample cache keys: %s", table.concat(sample_keys, ", ")))
    end
    return data
end

-- Generic runtime cache saver with logging
local function save_runtime_cache(file_path, data, name)
    if STANDALONE_MODE then 
        debug_log("Cache Debug: STANDALONE_MODE - skipping save")
        return 
    end
    local entry_count = count_table_entries(data)
    debug_log(string.format("Saving %s cache with %d entries", name, entry_count))
    if entry_count == 0 then
        debug_log(string.format("Warning: Saving empty %s cache", name))
    end
    local f = io.open(file_path, "w")
    if not f then
        debug_log(string.format("Failed to open %s cache file for writing", name), true)
        return
    end
    local ok, json = pcall(utils.format_json, data)
    if not ok then
        debug_log(string.format("Failed to serialize %s cache to JSON", name), true)
        f:close()
        return
    end
    f:write(json)
    f:close()
    debug_log(string.format("Successfully saved %s cache to %s", name, file_path))
end

-- Wrappers for specific caches
local function load_ANILIST_CACHE()
    ANILIST_CACHE = load_runtime_cache(ANILIST_CACHE_FILE, "AniList")
end

local function load_JIMAKU_CACHE()
    JIMAKU_CACHE = load_runtime_cache(JIMAKU_CACHE_FILE, "Jimaku")
end

local function save_ANILIST_CACHE()
    save_runtime_cache(ANILIST_CACHE_FILE, ANILIST_CACHE, "AniList")
end

local function save_JIMAKU_CACHE()
    save_runtime_cache(JIMAKU_CACHE_FILE, JIMAKU_CACHE, "Jimaku")
end
save_config_to_file = function()
    debug_log("========== SAVE CONFIG DEBUG START ==========")
    -- Check standalone mode
    if STANDALONE_MODE then 
        debug_log("ERROR: Cannot save config in standalone mode", true)
        mp.osd_message("✗ Cannot save in standalone mode", 3)
        return 
    end
    debug_log("✓ Not in standalone mode")
    -- Debug CONFIG_DIR
    debug_log("CONFIG_DIR = " .. tostring(CONFIG_DIR))
    debug_log("CONFIG_DIR type = " .. type(CONFIG_DIR))
    -- Helper function to mask sensitive data in logs
    local function mask_api_key(key)
        if not key or key == "" or #key < 8 then
            return "***"
        end
        return key:sub(1, 4) .. "..." .. key:sub(-4)
    end
    -- Update script_opts with current values
    -- IMPORTANT: For SUBTITLE_CACHE_DIR, preserve the original relative path format
    -- by NOT overwriting script_opts.SUBTITLE_CACHE_DIR (it already has the user's preferred format)
    debug_log("Updating script_opts with current runtime values...")
    script_opts.jimaku_api_key = JIMAKU_API_KEY or ""
    script_opts.JIMAKU_AUTO_DOWNLOAD = JIMAKU_AUTO_DOWNLOAD
    script_opts.JIMAKU_FONT_SIZE = JIMAKU_FONT_SIZE
    script_opts.JIMAKU_ITEMS_PER_PAGE = JIMAKU_ITEMS_PER_PAGE
    script_opts.JIMAKU_MENU_TIMEOUT = JIMAKU_MENU_TIMEOUT
    script_opts.INITIAL_OSD_MESSAGES = INITIAL_OSD_MESSAGES
    script_opts.LOG_ONLY_ERRORS = LOG_ONLY_ERRORS
    script_opts.JIMAKU_MAX_SUBS = JIMAKU_MAX_SUBS
    script_opts.JIMAKU_HIDE_SIGNS = JIMAKU_HIDE_SIGNS_ONLY
    -- DON'T overwrite SUBTITLE_CACHE_DIR - keep original user format (relative vs absolute)
    script_opts.LOG_FILE = LOG_FILE and true or false
    -- Log current values (with API key masked)
    debug_log("Current settings to save:")
    for k, v in pairs(script_opts) do
        local display_value = (k == "jimaku_api_key") and mask_api_key(tostring(v)) or tostring(v)
        debug_log(string.format("  %s = %s (%s)", k, display_value, type(v)))
    end
    -- Construct paths
    local script_opts_dir = CONFIG_DIR .. "/script-opts"
    local config_path = script_opts_dir .. "/jimaku.conf"
    debug_log("script_opts_dir = " .. script_opts_dir)
    debug_log("config_path = " .. config_path)
    -- Check if directory exists
    debug_log("Checking if script-opts directory exists...")
    local dir_check = io.open(script_opts_dir, "r")
    if dir_check then
        dir_check:close()
        debug_log("✓ Directory appears to exist (or is a file)")
    else
        debug_log("✗ Directory does not exist, attempting to create...")
    end
    -- Try to create directory
    debug_log("Creating directory: " .. script_opts_dir)
    ensure_directory(script_opts_dir)
    debug_log("Directory creation command executed")
    -- Verify directory creation
    local dir_verify = io.open(script_opts_dir, "r")
    if dir_verify then
        dir_verify:close()
        debug_log("✓ Directory verified after mkdir")
    else
        debug_log("✗ Directory still doesn't exist after mkdir!", true)
    end
    -- Try opening file for writing
    debug_log("Attempting to open file for writing: " .. config_path)
    local f, err = io.open(config_path, "w")
    if not f then
        local error_msg = "Failed to open config file: " .. (err or "unknown error")
        debug_log("✗ " .. error_msg, true)
        debug_log("Attempting to get more error details...")
        -- Try to get file info
        local test_read = io.open(config_path, "r")
        if test_read then
            debug_log("  - File exists and is readable")
            test_read:close()
        else
            debug_log("  - File does not exist or is not readable")
        end
        -- Check parent directory permissions
        local parent_test = io.open(CONFIG_DIR .. "/test_write.tmp", "w")
        if parent_test then
            parent_test:close()
            os.remove(CONFIG_DIR .. "/test_write.tmp")
            debug_log("  - Parent directory IS writable")
        else
            debug_log("  - Parent directory NOT writable!", true)
        end
        mp.osd_message("✗ Failed to create config file\n" .. (err or ""), 5)
        debug_log("========== SAVE CONFIG DEBUG END (FAILED) ==========")
        return
    end
    debug_log("✓ File opened successfully, writing config...")
    -- Write configuration with detailed logging
    local write_count = 0
    local keys_order = {
        "jimaku_api_key",
        "SUBTITLE_CACHE_DIR",
        "JIMAKU_AUTO_DOWNLOAD",
        "JIMAKU_MAX_SUBS",
        "JIMAKU_ITEMS_PER_PAGE",
        "JIMAKU_MENU_TIMEOUT",
        "JIMAKU_FONT_SIZE",
        "JIMAKU_HIDE_SIGNS",
        "LOG_ONLY_ERRORS",
        "INITIAL_OSD_MESSAGES",
        "LOG_FILE"
    }
    for _, key in ipairs(keys_order) do
        local value = script_opts[key]
        if value ~= nil then
            local line = ""
            if type(value) == "boolean" then
                line = key .. "=" .. (value and "yes" or "no")
            elseif type(value) == "string" then
                line = key .. "=" .. value
            elseif type(value) == "number" then
                line = key .. "=" .. tostring(value)
            end
            if line ~= "" then
                local success, write_err = pcall(function() f:write(line .. "\n") end)
                if success then
                    write_count = write_count + 1
                    -- Mask API key in log
                    local log_line = (key == "jimaku_api_key") and (key .. "=" .. mask_api_key(value)) or line
                    debug_log(string.format("  Wrote: %s", log_line))
                else
                    debug_log(string.format("  FAILED to write: %s (error: %s)", key, tostring(write_err)), true)
                end
            end
        end
    end
    -- Close file
    local close_success, close_err = pcall(function() f:close() end)
    if close_success then
        debug_log("✓ File closed successfully")
    else
        debug_log("✗ Error closing file: " .. tostring(close_err), true)
    end
    -- Verify file was written
    debug_log("Verifying written file...")
    local verify = io.open(config_path, "r")
    if verify then
        local content = verify:read("*all")
        verify:close()
        debug_log("✓ File verification successful")
        debug_log("File size: " .. #content .. " bytes")
        debug_log("Lines written: " .. write_count)
        debug_log("File content preview (API key masked):")
        for line in content:gmatch("[^\r\n]+") do
            if line:match("^jimaku_api_key=") then
                local key_val = line:match("^jimaku_api_key=(.*)$")
                debug_log("  jimaku_api_key=" .. mask_api_key(key_val))
            else
                debug_log("  " .. line)
            end
        end
    else
        debug_log("✗ File verification FAILED - file not readable after write!", true)
    end
    mp.osd_message("✓ Settings saved to jimaku.conf\n(" .. write_count .. " settings)", 3)
    debug_log("Configuration saved to " .. config_path)
    debug_log("========== SAVE CONFIG DEBUG END (SUCCESS) ==========")
end
-------------------------------------------------------------------------------
-- CUMULATIVE EPISODE CALCULATION
-------------------------------------------------------------------------------
-- Calculate cumulative episode number with confidence tracking
local function calculate_jimaku_episode_safe(season_num, episode_num, seasons_data)
    if not season_num or season_num == 1 then
        return episode_num, "certain"
    end
    -- Calculate cumulative episodes from previous seasons
    local cumulative = 0
    local confidence = "certain"
    for season_idx = 1, season_num - 1 do
        if seasons_data and seasons_data[season_idx] then
            cumulative = cumulative + seasons_data[season_idx].eps
            debug_log(string.format("  S%d has %d episodes (from AniList)", 
                season_idx, seasons_data[season_idx].eps))
        else
            -- Fallback: assume standard 13-episode season
            cumulative = cumulative + 13
            confidence = "uncertain"
            debug_log(string.format("  S%d episode count UNKNOWN - assuming 13 (UNCERTAIN)", 
                season_idx), true)
        end
    end
    local jimaku_ep = cumulative + episode_num
    if confidence == "uncertain" then
        debug_log(string.format("WARNING: Cumulative calculation used fallback assumptions. Result may be incorrect!"), true)
        debug_log(string.format("  Calculated: S%dE%d -> Jimaku Episode %d (UNCERTAIN)", 
            season_num, episode_num, jimaku_ep), true)
    end
    return jimaku_ep, confidence
end
-- Wrapper for backwards compatibility (without confidence tracking)
local function calculate_jimaku_episode(season_num, episode_num, seasons_data)
    local result, _ = calculate_jimaku_episode_safe(season_num, episode_num, seasons_data)
    return result
end
-- Reverse: Convert Jimaku cumulative episode to AniList season episode
local function convert_jimaku_to_anilist_episode(jimaku_ep, target_season, seasons_data)
    if not target_season or target_season == 1 then
        return jimaku_ep
    end
    -- Calculate cumulative offset from previous seasons
    local cumulative = 0
    for season_idx = 1, target_season - 1 do
        if seasons_data and seasons_data[season_idx] then
            cumulative = cumulative + seasons_data[season_idx].eps
        else
            cumulative = cumulative + 13  -- Fallback
        end
    end
    return jimaku_ep - cumulative
end
-- Normalize full-width digits to ASCII
local function normalize_digits(s)
    if not s then return s end
    -- Replace common full-width digits
    s = s:gsub("０", "0"):gsub("１", "1"):gsub("２", "2"):gsub("３", "3"):gsub("４", "4")
    s = s:gsub("５", "5"):gsub("６", "6"):gsub("７", "7"):gsub("８", "8"):gsub("９", "9")
    return s
end
-------------------------------------------------------------------------------
-- JIMAKU SUBTITLE FILENAME PARSER
-------------------------------------------------------------------------------
-- Parse Jimaku subtitle filename to extract episode number(s)
parse_jimaku_filename = function(filename)
    if not filename then return nil, nil end
    -- Normalize full-width digits
    filename = normalize_digits(filename)
    -- Pattern cascade (ordered by specificity - MOST specific first)
    local patterns = {
        -- SxxExx patterns (MOST SPECIFIC - check first with boundaries)
        {"[^%w]S(%d+)E(%d+)[^%w]", "season_episode"},  -- Requires non-word boundaries
        {"^S(%d+)E(%d+)[^%w]", "season_episode"},       -- At start of string
        {"[^%w]S(%d+)E(%d+)$", "season_episode"},       -- At end of string
        {"^S(%d+)E(%d+)$", "season_episode"},           -- Entire string
        {"[Ss](%d+)[%s%._%-]+[Ee](%d+)", "season_episode"}, -- With separator
        {"Season%s*(%d+)%s*[%-%–—]%s*(%d+)", "season_episode"},
        -- Fractional episodes (13.5) - with context checking
        {"[^%d%.v](%d+%.5)[^%dv]", "fractional"},      -- Only .5 decimals, not version numbers
        {"%-%s*(%d+%.5)%s", "fractional"},              -- Preceded by dash
        {"%s(%d+%.5)%s", "fractional"},                 -- Surrounded by spaces
        {"%-%s*(%d+%.5)$", "fractional"},               -- At end after dash
        {"%s(%d+%.5)$", "fractional"},                  -- At end after space
        -- EPxx / Exx (with boundaries to prevent false matches)
        {"[^%a]EP(%d+)[^%d]", "episode"},               -- EP prefix, not preceded by letter
        {"[^%a][Ee]p%s*(%d+)[^%d]", "episode"},
        {"^EP(%d+)", "episode"},                         -- At start
        {"^[Ee]p%s*(%d+)", "episode"},
        -- Episode keyword (explicit)
        {"Episode%s*(%d+)", "episode"},
        -- Japanese patterns
        {"[#＃](%d+)", "episode"},
        {"第(%d+)[話回]", "episode"},
        {"（(%d+)）", "episode"},
        -- Common contextual patterns (ordered by specificity)
        {"_(%d+)%.[AaSs]", "episode"},                  -- _01.ass (very specific)
        {"%s(%d+)%s+BD%.", "episode"},                   -- " 01 BD."
        {"%s(%d+)%s+[Ww]eb[%s%.]", "episode"},          -- " 01 Web "
        {"%-%s*(%d+)%s*[%[(]", "episode"},              -- "- 01 ["
        {"%s(%d+)%s*%[", "episode"},                     -- " 01 ["
        -- Track patterns (low priority - uncommon)
        {"track(%d+)", "episode"},
        -- Underscore patterns
        {"_(%d%d%d)%.[AaSs]", "episode"},
        {"_(%d%d)%.[AaSs]", "episode"},
        -- Generic dash/space patterns (LOWEST priority)
        {"%-%s*(%d+)%.", "episode"},                    -- "- 01."
        {"%s(%d+)%.", "episode"},                        -- " 01."
        -- Last resort: pure number (must be start of filename only)
        {"^(%d+)%.", "episode"},
        -- Loose E pattern (VERY LOW priority - can cause false positives)
        {"[Ee](%d+)", "episode"},                        -- Last resort only
    }
    -- Try each pattern in order
    for _, pattern_data in ipairs(patterns) do
        local pattern = pattern_data[1]
        local ptype = pattern_data[2]
        if ptype == "season_episode" then
            local s, e = filename:match(pattern)
            if s and e then
                local season_num = tonumber(s)
                local episode_num = tonumber(e)
                -- Validation: reasonable season/episode ranges
                if season_num and episode_num and 
                   season_num >= 1 and season_num <= 20 and
                   episode_num >= 0 and episode_num <= 999 then
                    return season_num, episode_num
                end
            end
        elseif ptype == "fractional" then
            local e = filename:match(pattern)
            if e then
                -- Additional validation: not a version number
                local before = filename:match("([^%s]-)%s*" .. e:gsub("%.", "%%."))
                if not before or not before:lower():match("v%d*$") then
                    return nil, e  -- Return as string for fractional
                end
            end
        else  -- Regular episode
            local e = filename:match(pattern)
            if e then
                local num = tonumber(e)
                -- Sanity check: episode numbers should be reasonable
                if num and num >= 0 and num <= 999 then
                    return nil, num
                end
            end
        end
    end
    return nil, nil
end
-------------------------------------------------------------------------------
-- MAIN FILENAME PARSER (WITH CRITICAL HOTFIXES)
-------------------------------------------------------------------------------
-- NEW: Strip Japanese/CJK/Korean characters and clean complex titles
local function clean_japanese_text(title)
    if not title then return title end
    -- Remove content in Japanese brackets 「」『』
    title = title:gsub("「[^」]*」", "")
    title = title:gsub("『[^』]*』", "")
    -- Remove content in Korean/CJK parentheses (often contains native script)
    -- Pattern: (한글...), (中文...), etc
    title = title:gsub("%s*%([\227-\233][\128-\191]+%)%s*", " ")
    -- Remove common Japanese/Korean/Chinese unicode ranges
    -- Hiragana/Katakana: U+3040-U+30FF
    -- CJK: U+4E00-U+9FFF
    -- Hangul: U+AC00-U+D7AF
    title = title:gsub("[\227-\237][\128-\191]+", "")
    -- Remove orphaned parentheses/dashes from removal
    title = title:gsub("%s*%(+%s*%-*%s*%)+%s*", " ")
    title = title:gsub("%s*%(-+%)%s*", " ")
    title = title:gsub("%s+%-+%s+%-+%s+", " - ")  -- "- text -" becomes single dash
    -- Clean up resulting spaces
    title = title:gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    return title
end
-- NEW: Strip version tags (v2, v3, etc.)
local function strip_version_tag(str)
    if not str then return str end
    -- Remove version tags like "v2", "v3" etc
    str = str:gsub("%s*v%d+%s*", " ")
    str = str:gsub("%-v%d+", "")
    -- Clean up spaces
    str = str:gsub("%s+", " ")
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    return str
end
-- NEW: Clean parenthetical content intelligently
local function clean_parenthetical(title)
    if not title then return title end
    -- Remove hex checksums in brackets: [3A100B6C], [ABC123DE], etc.
    title = title:gsub("%s*%[[0-9A-Fa-f]+%]%s*", " ")
    -- Remove resolution tags: (1080p), (720p), (480p), etc.
    title = title:gsub("%s*%(%d%d%d%d?p%)%s*", " ")
    -- Remove quality/format tags in parentheses (more aggressive matching)
    -- Handles: (BD ...), (DVD ...), (WEB ...), (Remux ...), etc.
    title = title:gsub("%s*%([^)]*BD[^)]*%)%s*", " ")
    title = title:gsub("%s*%([^)]*DVD[^)]*%)%s*", " ")
    title = title:gsub("%s*%([^)]*WEB[^)]*%)%s*", " ")
    title = title:gsub("%s*%([^)]*Blu%-ray[^)]*%)%s*", " ")
    title = title:gsub("%s*%([^)]*Remux[^)]*%)%s*", " ")
    title = title:gsub("%s*%([^)]*HEVC[^)]*%)%s*", " ")
    -- Remove any unclosed parentheses with quality keywords
    title = title:gsub("%s*%-?%s*%([^)]*BD.*$", "")
    title = title:gsub("%s*%-?%s*%([^)]*DVD.*$", "")
    title = title:gsub("%s*%-?%s*%([^)]*WEB.*$", "")
    title = title:gsub("%s*%-?%s*%([^)]*Remux.*$", "")
    -- Remove language codes in parentheses: (JP), (EN), (KR), (US), etc.
    title = title:gsub("%s*%([A-Z][A-Z]%)%s*", " ")
    -- Remove RECAP tags
    title = title:gsub("%s*%(RECAP%)%s*", " ")
    title = title:gsub("%s*%[RECAP%]%s*", " ")
    title = title:gsub("%s*RECAP%s*", " ")
    -- Remove empty parentheses
    title = title:gsub("%s*%(%s*%)%s*", " ")
    -- Clean up spaces
    title = title:gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    return title
end
-- Helper function: Extract title safely with validation (IMPROVED)
local function extract_title_safe(content, episode_marker)
    if not content then return nil end
    local title = nil
    -- Method 1: Extract before episode marker (most reliable)
    if episode_marker then
        -- Try to find title before the episode marker
        local patterns = {
            "^(.-)%s*[%-%–—]%s*" .. episode_marker,  -- "Title - E01"
            "^(.-)%s+" .. episode_marker,             -- "Title E01"
            "^(.-)%s*%_%s*" .. episode_marker,       -- "Title_E01"
        }
        for _, pattern in ipairs(patterns) do
            local t = content:match(pattern)
            if t and t:len() >= 2 then
                title = t
                break
            end
        end
    end
    -- Method 2: Remove common trailing patterns
    if not title then
        title = content
        -- Remove quality tags
        title = title:gsub("%s*%[?%d%d%d%d?p%]?.*$", "")
        title = title:gsub("%s*%d%d%d%dx%d%d%d%d.*$", "")
        -- Remove codec tags
        title = title:gsub("%s*[xh]26[45].*$", "")
        title = title:gsub("%s*HEVC.*$", "")
    end
    -- HOTFIX: Strip version tags
    title = strip_version_tag(title)
    -- HOTFIX: Clean Japanese text
    title = clean_japanese_text(title)
    -- HOTFIX: Clean parenthetical content
    title = clean_parenthetical(title)
    -- Clean up
    title = title:gsub("[%._]", " ")        -- Dots and underscores to spaces
    title = title:gsub("%s+", " ")          -- Multiple spaces to single
    title = title:gsub("^%s+", ""):gsub("%s+$", "")  -- Trim
    -- HOTFIX: Remove "Part" suffix that might be left over
    title = title:gsub("%s+Part$", "")
    -- Validation: title must be reasonable
    if not title or title:len() < 2 or title:len() > 200 then
        return nil
    end
    -- Must contain at least one letter (not just numbers)
    if not title:match("%a") then
        return nil
    end
    -- Don't allow titles that are just numbers and spaces
    if title:match("^[%d%s]+$") then
        return nil
    end
    return title
end
-- Better group name extraction with validation
local function extract_group_name(content)
    if not content then return nil end
    -- Pattern 1: [GroupName] at start (most reliable)
    local group = content:match("^%[([%w%._%-%s]+)%]")
    if group and group:len() >= 2 and group:len() <= 50 then
        -- Validate: group names typically have certain characteristics
        -- - Often all caps or mixed case
        -- - Often contain dots, dashes, or are short
        -- - Usually not more than 3 words
        local word_count = select(2, group:gsub("%S+", ""))
        if word_count <= 3 then
            return group
        end
    end
    return nil
end
-- Roman numeral converter (for season detection like "Title II")
local function roman_to_int(s)
    if not s then return nil end
    local romans = {I = 1, V = 5, X = 10, L = 50, C = 100}
    local res, prev = 0, 0
    s = s:upper()
    for i = #s, 1, -1 do
        local curr = romans[s:sub(i, i)]
        if curr then
            res = res + (curr < prev and -curr or curr)
            prev = curr
        else
            return nil  -- Invalid roman numeral
        end
    end
    return res > 0 and res or nil
end
-- Main parsing function with all fixes applied (handles filenames and media-titles)
local function parse_media_title(filename)
    if not filename then return nil end
    -- Log for debugging
    debug_log("-------------------------------------------")
    debug_log("PARSING: " .. filename)
    -- Normalize digits
    filename = normalize_digits(filename)
    -- Initialize result with FIX #8: confidence tracking
    local result = {
        title = nil,
        episode = nil,
        season = nil,
        quality = nil,
        group = nil,
        is_special = false,
        is_movie = false,  -- NEW: Track if it's a movie
        confidence = "low"  -- Track parsing confidence
    }
    -- Strip file extension and path (but preserve URL components and stream titles)
    local is_url = filename:match("^https?://")
    local clean_name = filename
    -- Only strip extension and path if it's a REAL filesystem path
    -- Heuristic: paths typically have . for extensions and / only for directory separators
    -- Media titles like "Title Ep 1" or "Title SUB/DUB" should be left alone
    if not is_url then
        -- Check if this looks like a filesystem path (has file extension)
        local has_extension = filename:match("%.%w%w%w?%w?$")
        if has_extension then
            clean_name = clean_name:gsub("%.%w%w%w?%w?$", "")  -- Remove extension
            clean_name = clean_name:match("([^/\\]+)$") or clean_name  -- Remove path
        end
        -- Otherwise leave it as-is (it's probably a media-title like "Show Name Ep 1")
    else
        -- For URLs, extract just the media-title portion (after last /)
        clean_name = clean_name:match("([^/]+)$") or clean_name
    end
    -- FIX #4: Extract release group first with validation
    result.group = extract_group_name(clean_name)
    if result.group then
        -- Remove group tag from content
        clean_name = clean_name:gsub("^%[[%w%._%-%s]+%]%s*", "")
    end
    local content = clean_name
    -- FIX #1: PATTERN MATCHING (Ordered by specificity)
    -- Pattern A: SxxExx (HIGHEST confidence)
    local s, e = content:match("[^%w]S(%d+)[%s%._%-]*E(%d+%.?%d*)[^%w]")
    if not s then
        s, e = content:match("^S(%d+)[%s%._%-]*E(%d+%.?%d*)") -- At start
    end
    if not s then
        s, e = content:match("S(%d+)[%s%._%-]*E(%d+%.?%d*)$") -- At end
    end
    if not s then
        s, e = content:match("S(%d+)[%s%._%-]*E(%d+%.?%d*)") -- Anywhere
    end
    if s and e then
        result.season = tonumber(s)
        result.episode = e
        result.confidence = "high"
        -- Extract title before SxxExx
        result.title = content:match("^(.-)%s*[Ss]%d+[%s%._%-]*[Ee]%d+") or 
                       content:match("^(.-)%s*%-+%s*[Ss]%d+")
    end
    -- Pattern B: Explicit "Episode" keyword (HIGH confidence)
    if not result.episode then
        local t, ep = content:match("^(.-)%s*[Ee]pisode%s*(%d+%.?%d*)")
        if t and ep then
            result.title = t
            result.episode = ep
            result.confidence = "high"
        end
    end
    -- Pattern C: EPxx or Exx with good boundaries (MEDIUM-HIGH confidence)
    if not result.episode then
        local t, ep = content:match("^(.-)%s*[%-%–—]%s*EP?%s*(%d+%.?%d*)[^%d]")
        if not t then
            t, ep = content:match("^(.-)%s*[%-%–—]%s*EP?%s*(%d+%.?%d*)$")
        end
        if t and ep then
            result.title = t
            result.episode = ep
            result.confidence = "medium-high"
        end
    end
    -- Pattern D: Dash with number (MEDIUM confidence) - IMPROVED for version tags and high episodes
    if not result.episode then
        -- Try to match episode WITH version tag (e.g., "01v2")
            local t, ep, version = content:match("^(.-)%s*[%-%–—]%s*(%d+%.?%d*)(v%d+)")
        if t and ep then
            result.title = t
            result.episode = ep
            result.confidence = "medium-high"
            debug_log(string.format("Detected episode %s with version tag '%s'", ep, version))
        else
            -- Standard dash pattern without version - SUPPORTS HIGH EPISODE NUMBERS
            local t2, ep2 = content:match("^(.-)%s*[%-%–—]%s*(%d+%.?%d*)%s*[%[%(%s]")
            if not t2 then
                t2, ep2 = content:match("^(.-)%s*[%-%–—]%s*(%d+%.?%d*)$")
            end
            if t2 and ep2 then
                local ep_num = tonumber(ep2)
                -- FIXED: Allow high episode numbers for long-running series (up to 9999)
                if ep_num and ep_num >= 0 and ep_num <= 9999 then
                    result.title = t2
                    result.episode = ep2
                    result.confidence = "medium"
                end
            end
        end
    end
    -- Pattern E: Space with number at end (LOW-MEDIUM confidence) - SUPPORTS HIGH EPISODES
    if not result.episode then
        local t, ep = content:match("^(.-)%s+(%d+%.?%d*)%s*%[")
        if not t then
            t, ep = content:match("^(.-)%s+(%d+%.?%d*)$")
        end
        if t and ep then
            local ep_num = tonumber(ep)
            -- FIXED: Support high episode numbers, validate against title
            if ep_num and ep_num >= 1 and ep_num <= 9999 and 
               not t:match("%d$") then  -- Title shouldn't end in number
                result.title = t
                result.episode = ep
                result.confidence = "low-medium"
            end
        end
    end
    -- FIX #3: If we still don't have a title, try safe extraction
    if not result.title then
        result.title = extract_title_safe(content, result.episode)
    end
    -- Clean up title if we got one
    if result.title then
        result.title = result.title:gsub("[%._]", " ")
        result.title = result.title:gsub("%s+", " ")
        result.title = result.title:gsub("^%s+", ""):gsub("%s+$", "")
        -- Remove common trailing junk
        result.title = result.title:gsub("%s*[%-%_%.]+$", "")
        -- HOTFIX: Additional cleaning passes
        result.title = strip_version_tag(result.title)
        result.title = clean_japanese_text(result.title)
        result.title = clean_parenthetical(result.title)
        -- Clean up again after all transformations
        result.title = result.title:gsub("%s+", " ")
        result.title = result.title:gsub("^%s+", ""):gsub("%s+$", "")
    end
    -- SEASON DETECTION (if not already found)
    -- HOTFIX: Detect "Part X" to prevent false season detection, but KEEP in title
    local part_num = nil
    if result.title then
        part_num = result.title:match("%s+Part%s+(%d+)$")
        if part_num then
            debug_log(string.format("Detected 'Part %s' in title - will preserve for AniList search", part_num))
        end
    end
    -- Method 1: Roman numerals (e.g., "Overlord II" -> Season 2)
    -- FIXED: Avoid single letter X/V/I which are often part of titles
    if not result.season and result.title then
        local roman = result.title:match("%s([IVXLCivxlc]+)$")
        if roman then
            -- Only accept if it's actually a valid roman numeral AND reasonable
            local season_num = roman_to_int(roman)
            if season_num and season_num >= 2 and season_num <= 10 then
                -- Additional check: avoid single letters that might be part of title
                -- "Big X" should NOT be season 10
                if roman:len() > 1 or (season_num >= 2 and season_num <= 5) then
                    result.season = season_num
                    result.title = result.title:gsub("%s" .. roman .. "$", "")
                    debug_log(string.format("Detected Season %d from Roman numeral '%s'", season_num, roman))
                else
                    debug_log(string.format("Skipped single-letter Roman numeral '%s' (likely part of title)", roman))
                end
            end
        end
    end
    -- Method 2: "S2" suffix (e.g., "Oshi no Ko S3" or "Dragon Raja S2 (JP)")
    if not result.season and result.title then
        -- Try at end first (most common)
        local s_num = result.title:match("%s[Ss](%d+)$")
        if s_num then
            result.season = tonumber(s_num)
            result.title = result.title:gsub("%s[Ss]%d+$", "")
            debug_log(string.format("Detected Season %d from 'S' suffix (at end)", result.season))
        else
            -- Try in middle of title (before other tags like JP, EN, etc.)
            s_num = result.title:match("%s[Ss](%d+)%s")
            if s_num then
                result.season = tonumber(s_num)
                result.title = result.title:gsub("%s[Ss]%d+%s", " ")
                debug_log(string.format("Detected Season %d from 'S' suffix (mid-title)", result.season))
            end
        end
    end
    -- Method 3: Season keywords
    if not result.season and result.title then
        local season_patterns = {
            "[Ss]eason%s*(%d+)",
            "(%d+)[nrdt][dht]%s+[Ss]eason",
        }
        for _, pattern in ipairs(season_patterns) do
            local s_num = result.title:match(pattern)
            if s_num then
                result.season = tonumber(s_num)
                -- Remove season marker from title
                result.title = result.title:gsub("%s*%(?%d*[nrdt][dht]%s+[Ss]eason%)?", "")
                result.title = result.title:gsub("%s*%(?[Ss]eason%s+%d+%)?", "")
                debug_log(string.format("Detected Season %d from keyword", result.season))
                break
            end
        end
    end
    -- Method 4: Trailing number (conservative - only for small numbers)
    -- HOTFIX: Only run if "Part X" was NOT found AND number looks like season
    if not result.season and result.title and not part_num then
        local trailing = result.title:match("%s(%d+)$")
        if trailing then
            local num = tonumber(trailing)
            -- VERY conservative: only 2-6, avoid numeric titles, and check if preceded by season-like word
            local before_num = result.title:match("(.-)%s%d+$") or ""
            local before_word = before_num:match("(%w+)%s*$")
            local is_season_context = before_word and (
                before_word:lower():match("season") or
                before_word:lower():match("part") or
                before_word:lower():match("cour")
            )
            -- Skip if title has a dash immediately before number (e.g. "Title - 09")
            local has_dash_before = before_num:match("%-%s*$")
            -- Also skip if an episode was already detected earlier (don't infer season)
            if result.episode then
                debug_log("Skipping trailing-number season detection because episode already parsed")
            elseif num and num >= 2 and num <= 6 and 
               not result.title:match("^%d") and  -- Title doesn't start with number
               not result.title:match("%d/%d") and  -- Not a fraction like "22/7"
               not is_season_context and 
               not has_dash_before then  -- NOT preceded by season-related word or dash
                result.season = num
                result.title = result.title:gsub("%s%d+$", "")
                debug_log(string.format("Detected Season %d from trailing number (low confidence)", num))
            elseif is_season_context then
                debug_log(string.format("Skipped trailing number %d - appears to be part of title", num))
            elseif has_dash_before then
                debug_log(string.format("Skipped trailing number %d - prefixed by dash, likely episode", num))
            end
        end
    end
    -- FIX #6: SPECIAL EPISODE DETECTION (Enhanced)
    local combined = (result.episode or "") .. " " .. content:lower()
    if combined:match("ova") or combined:match("oad") or 
       combined:match("special") or combined:match("sp[^a-z]") or
       result.episode == "0" or
       combined:match("recap") then
        result.is_special = true
    end
    -- HOTFIX: MOVIE DETECTION (enhanced)
    local movie_keywords = {"movie", "gekijouban", "the movie", "film"}
    local title_lower = (result.title or ""):lower()
    for _, keyword in ipairs(movie_keywords) do
        if title_lower:match(keyword) then
            result.is_movie = true
            result.is_special = true
            debug_log("Detected as MOVIE")
            break
        end
    end
    -- QUALITY DETECTION (basic)
    local quality_pattern = content:match("(%d%d%d%d?p)")
    if quality_pattern then
        result.quality = quality_pattern
    end
    -- FIX #8: FINAL VALIDATION
    if not result.title or result.title:len() < 2 then
        debug_log("ERROR: Failed to extract valid title", true)
        result.title = content  -- Fallback to full content
        result.confidence = "failed"
    end
    -- Additional title cleaning
    result.title = result.title:gsub("%s*%-+$", "")  -- Remove trailing dashes
    result.title = result.title:gsub("^%-+%s*", "")  -- Remove leading dashes
    result.title = result.title:gsub("%s+", " ")     -- Normalize spaces
    result.title = result.title:gsub("^%s+", ""):gsub("%s+$", "")  -- Trim
    if not result.episode then
        if result.is_movie then
            result.episode = "1"  -- Movies are episode 1
            debug_log("Movie detected - setting episode to 1")
        else
            result.episode = "1"  -- Default
            result.confidence = "failed"
        end
    end
    -- Validate episode number (UPDATED for high episodes)
    local ep_num = tonumber(result.episode)
    if ep_num then
        if ep_num < 0 or ep_num > 9999 then
            debug_log(string.format("WARNING: Episode number %d outside reasonable range (0-9999)", ep_num), true)
        elseif ep_num > 999 then
            debug_log(string.format("High episode number: %d (long-running series)", ep_num))
        end
    end
    -- Validate season number
    if result.season and (result.season < 1 or result.season > 20) then
        debug_log(string.format("WARNING: Season number %d outside reasonable range", result.season), true)
    end
    debug_log(string.format("RESULT: Title='%s' | S=%s | E=%s | Confidence=%s | Special=%s | Movie=%s",
        result.title,
        result.season or "nil",
        result.episode,
        result.confidence,
        result.is_special and "yes" or "no",
        result.is_movie and "yes" or "no"))
    return result
end
-------------------------------------------------------------------------------
-- PARSER TEST MODE
-------------------------------------------------------------------------------
local function test_parser(input_file)
    local test_file = input_file or TEST_FILE
    -- Setup Log Handle
    if PARSER_LOG_FILE then
        local hf = io.open(PARSER_LOG_FILE, "w")
        if hf then hf:close() end
        LOG_FILE_HANDLE = io.open(PARSER_LOG_FILE, "a")
    end
    local file = io.open(test_file, "r")
    if not file then return end
    local count = 0
    local failures = 0
    local start = os.clock()
    -- ITERATION: Process line-by-line directly. 
    -- Do not store in a table to keep memory usage flat.
    for line in file:lines() do
        if line:match("%S") then
            count = count + 1
            local res = parse_media_title(line)
            if not res then
                failures = failures + 1
                debug_log("FAILED TO PARSE: " .. line)
            end
            if count % 10000 == 0 then
                print(string.format("Parsed %d...", count))
            end
        end
    end
    file:close()
    local diff = os.clock() - start
    debug_log(string.format("Total: %d | Success: %d | Fail: %d | Time: %.2fs", 
              count, count-failures, failures, diff))
    if LOG_FILE_HANDLE then 
        LOG_FILE_HANDLE:close()
        LOG_FILE_HANDLE = nil
    end
end
-------------------------------------------------------------------------------
-- STANDALONE MODE EXECUTION
-------------------------------------------------------------------------------
if STANDALONE_MODE then
    -- Parse command line arguments
    local input_file = nil
    local show_help = false
    for i = 1, #arg do
        if arg[i] == "--parser" and arg[i + 1] then
            input_file = arg[i + 1]
        elseif arg[i] == "--help" or arg[i] == "-h" then
            show_help = true
        end
    end
    if show_help then
        print("AniList Parser - Standalone Mode")
        print("")
        print("Usage:")
        print("  lua anilist.lua --parser <filename>")
        print("")
        print("Examples:")
        print("  lua anilist.lua --parser torrents.txt")
        print("  lua anilist.lua --parser /path/to/files.txt")
        print("")
        print("Output:")
        print("  Results are written to parser-debug.log")
        os.exit(0)
    end
    -- Clear log file
    local f = io.open(PARSER_LOG_FILE, "w")
    if f then f:close() end
    -- Run parser test
    test_parser(input_file)
    os.exit(0)
end
-------------------------------------------------------------------------------
-- MPV MODE - JIMAKU INTEGRATION
-------------------------------------------------------------------------------
-- Search Jimaku for subtitle entry by AniList ID
local function search_jimaku_subtitles(anilist_id)
    -- Check toggle first
    if not USE_JIMAKU_API then
        debug_log("Jimaku API disabled by config", false)
        return nil, "DISABLED"
    end
    -- O(1) Guard: Prevent misleading "No entries found" if key is missing
    if not JIMAKU_API_KEY or JIMAKU_API_KEY == "" then
        debug_log("Jimaku API key not configured - skipping subtitle search", false)
        return nil, "MISSING_KEY"
    end
    debug_log(string.format("Searching Jimaku for AniList ID: %d", anilist_id))
    -- Cache Check (O(1))
    local cache_key = tostring(anilist_id)
    if not STANDALONE_MODE and JIMAKU_CACHE[cache_key] then
        local cache_entry = JIMAKU_CACHE[cache_key]
        local cache_age = os.time() - cache_entry.timestamp
        if cache_age < 3600 then
            debug_log(string.format("Using cached Jimaku entry for AniList ID %d (%d seconds old)", 
                anilist_id, cache_age))
            return cache_entry.entry, "CACHE_HIT"
        else
            debug_log(string.format("Jimaku cache expired for AniList ID %d", anilist_id))
            JIMAKU_CACHE[cache_key] = nil
        end
    end
    local search_url = string.format("%s/entries/search?anilist_id=%d&anime=true", 
        JIMAKU_API_URL, anilist_id)
    local result = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = {"curl", "-s", "-X", "GET", "-H", "Authorization: " .. JIMAKU_API_KEY, search_url}
    })
    if result.status ~= 0 or not result.stdout then
        debug_log("Jimaku search request failed", true)
        return nil, "NETWORK_ERROR"
    end
    local ok, entries = pcall(utils.parse_json, result.stdout)
    if not ok or not entries or #entries == 0 then
        debug_log("No Jimaku entries found for AniList ID: " .. anilist_id, false)
        return nil, "NOT_FOUND"
    end
    debug_log(string.format("Found Jimaku entry: %s (ID: %d)", entries[1].name, entries[1].id))
    JIMAKU_CACHE[cache_key] = {
        entry = entries[1],
        timestamp = os.time()
    }
    if not STANDALONE_MODE then save_JIMAKU_CACHE() end
    return entries[1], "SUCCESS"
end
-- Fetch ALL subtitle files for an entry (no episode filter)
fetch_all_episode_files = function(entry_id)
    -- Check cache first
    if EPISODE_CACHE[entry_id] then
        local cache_age = os.time() - EPISODE_CACHE[entry_id].timestamp
        if cache_age < 300 then  -- Cache valid for 5 minutes
            debug_log(string.format("Using cached file list for entry %d (%d files)", entry_id, #EPISODE_CACHE[entry_id].files))
            return EPISODE_CACHE[entry_id].files
        end
    end
    local files_url = string.format("%s/entries/%d/files", JIMAKU_API_URL, entry_id)
    debug_log("Fetching ALL subtitle files from: " .. files_url)
    local args = {
        "curl", "-s", "-X", "GET",
        "-H", "Authorization: " .. JIMAKU_API_KEY,
        files_url
    }
    local result = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = args
    })
    if result.status ~= 0 or not result.stdout then
        debug_log("Failed to fetch file list", true)
        return nil
    end
    local ok, files = pcall(utils.parse_json, result.stdout)
    if not ok or not files then
        debug_log("Failed to parse file list JSON", true)
        return nil
    end
    debug_log(string.format("Retrieved %d total subtitle files", #files))
    -- Cache the result
    EPISODE_CACHE[entry_id] = {
        files = files,
        timestamp = os.time()
    }
    return files
end
-- Extract all possible title variations from AniList entry
local function extract_title_variations(anilist_entry)
    local variations = {}
    -- Add all title forms
    if anilist_entry.title then
        if anilist_entry.title.romaji then
            table.insert(variations, anilist_entry.title.romaji:lower())
        end
        if anilist_entry.title.english then
            table.insert(variations, anilist_entry.title.english:lower())
        end
        if anilist_entry.title.native then
            table.insert(variations, anilist_entry.title.native:lower())
        end
    end
    -- Add synonyms
    if anilist_entry.synonyms then
        for _, syn in ipairs(anilist_entry.synonyms) do
            table.insert(variations, syn:lower())
        end
    end
    -- Extract base title (without season markers)
    for i = 1, #variations do
        local title = variations[i]
        -- Remove season markers to get base title
        local base = title:gsub("%s*:%s*.*$", "")  -- Remove after colon
        base = base:gsub("%s*season%s*%d+", "")
        base = base:gsub("%s*part%s*%d+", "")
        base = base:gsub("%s*final%s*season", "")
        base = base:gsub("%s*%d+[nrdt][dht]%s*season", "")
        if base ~= title and base:len() > 0 then
            table.insert(variations, base)
        end
    end
    return variations
end
-- Extract season number from AniList entry (from synonyms/titles)
local function extract_season_from_anilist(anilist_entry)
    -- Check synonyms first
    if anilist_entry.synonyms then
        for _, syn in ipairs(anilist_entry.synonyms) do
            local syn_lower = syn:lower()
            -- "Season X" or "Xth Season"
            local season_num = syn_lower:match("season%s*(%d+)")
            if not season_num then
                season_num = syn_lower:match("(%d+)[nrdt][dht]%s*season")
            end
            if season_num then
                return tonumber(season_num)
            end
        end
    end
    -- Check romaji title
    if anilist_entry.title and anilist_entry.title.romaji then
        local title_lower = anilist_entry.title.romaji:lower()
        -- Look for season markers
        local season_num = title_lower:match("season%s*(%d+)")
        if not season_num then
            season_num = title_lower:match("(%d+)[nrdt][dht]%s*season")
        end
        if season_num then
            return tonumber(season_num)
        end
    end
    return nil
end
-- Check if subtitle filename contains any of the title variations
local function subtitle_matches_title(subtitle_filename, title_variations)
    local sub_lower = subtitle_filename:lower()
    for _, variation in ipairs(title_variations) do
        -- Remove common separators and compare
        local var_clean = variation:gsub("[%s%-%._:]+", "")
        local sub_clean = sub_lower:gsub("[%s%-%._:]+", "")
        if sub_clean:match(var_clean) then
            return true, variation
        end
    end
    return false, nil
end
-- ENHANCED: Intelligent episode matching with AniList cross-verification
local function match_episodes_intelligent(files, target_episode, target_season, seasons_data, anilist_entry)
    if not files or #files == 0 then
        return {}
    end
    debug_log(string.format("Enhanced matching for S%d E%d from %d files...", 
        target_season or 1, target_episode, #files))
    -- Extract AniList metadata for verification
    local title_variations = extract_title_variations(anilist_entry)
    local anilist_season = extract_season_from_anilist(anilist_entry) or target_season or 1
    local total_episodes = anilist_entry.episodes or 13
    debug_log(string.format("AniList metadata: Season=%s, Episodes=%d, Variations=%d",
        anilist_season or "nil", total_episodes, #title_variations))
    if #title_variations > 0 then
        debug_log("Title variations: " .. table.concat(title_variations, ", "))
    end
    local matches = {}
    local all_parsed = {}
    -- Calculate target cumulative episode
    local target_cumulative = calculate_jimaku_episode(target_season or anilist_season, target_episode, seasons_data)
    debug_log(string.format("Target: S%d E%d = Cumulative Episode %d", 
        anilist_season, target_episode, target_cumulative))
    -- Parse all filenames and build episode map
    for _, file in ipairs(files) do
        local jimaku_season, jimaku_episode = parse_jimaku_filename(file.name)
        if jimaku_episode then
            local anilist_episode = nil
            local match_type = ""
            local is_match = false
            local confidence = "low"
            local priority_score = 0
            -- Filter out "Signs Only" if enabled
            if JIMAKU_HIDE_SIGNS_ONLY then
                local lower_name = file.name:lower()
                if lower_name:match("signs") or lower_name:match("songs") or file.size < 5000 then
                    -- Skip if it's very likely just signs (usually < 5KB)
                    goto next_file
                end
            end
            -- Filter out disabled preferred groups
            for _, pref_group in ipairs(JIMAKU_PREFERRED_GROUPS) do
                if not pref_group.enabled and file.name:lower():match(pref_group.name:lower()) then
                    debug_log(string.format("Skipping subtitle due to disabled group '%s': %s", pref_group.name, file.name))
                    goto next_file
                end
            end
            -- Calculate priority score based on preferred groups
            for i, pref_group in ipairs(JIMAKU_PREFERRED_GROUPS) do
                if pref_group.enabled and file.name:lower():match(pref_group.name:lower()) then
                    -- Priority boost: Higher in list (smaller index) = higher boost
                    priority_score = (#JIMAKU_PREFERRED_GROUPS - i + 1) * 2
                    break
                end
            end
            -- Convert to number if it's a string
            local ep_num = tonumber(jimaku_episode) or 0
            -- VERIFICATION STEP 1: Check if subtitle filename matches any title variation
            local title_match, matched_variation = subtitle_matches_title(file.name, title_variations)
            if title_match then
                confidence = "medium"
            end
            -- CASE 1: Jimaku file has explicit season marker (S02E14, S03E48)
            if jimaku_season then
                -- Try multiple interpretations of season-marked files
                -- Interpretation 1A: Standard season numbering (S2E03 = Season 2, Episode 3)
                if jimaku_season == anilist_season and ep_num == target_episode then
                    is_match = true
                    anilist_episode = target_episode
                    match_type = "direct_season_match"
                    confidence = title_match and "high" or "medium"
                end
                -- Interpretation 1B: Netflix-style absolute numbering in season format
                -- (S02E14 actually means "Episode 14 overall", not "Season 2, Episode 14")
                if not is_match and ep_num == target_cumulative then
                    is_match = true
                    anilist_episode = target_episode
                    match_type = "netflix_absolute_in_season_format"
                    -- Netflix absolute numbering is reliable when it matches cumulative exactly
                    confidence = title_match and "high" or "medium-high"
                end
                -- Interpretation 1C: Season marker but episode is cumulative from that season's start
                -- (S02E03 means 3rd episode of Season 2, where S2 started at overall episode 14)
                if not is_match and jimaku_season == anilist_season then
                    -- Calculate what cumulative episode this would be
                    local file_cumulative = calculate_jimaku_episode(jimaku_season, ep_num, seasons_data)
                    if file_cumulative == target_cumulative then
                        is_match = true
                        anilist_episode = target_episode
                        match_type = "season_relative_cumulative"
                        confidence = title_match and "high" or "medium"
                    end
                end
            -- CASE 2: Jimaku file has NO season marker - could be cumulative OR within-season
            else
                -- Interpretation 2A: It's a cumulative episode number (E14 = overall episode 14)
                if ep_num == target_cumulative then
                    is_match = true
                    anilist_episode = target_episode
                    match_type = "cumulative_match"
                    confidence = title_match and "high" or "medium"
                end
                -- Interpretation 2B: It's the within-season episode (E03 = 3rd episode of current season)
                if not is_match and ep_num == target_episode then
                    is_match = true
                    anilist_episode = target_episode
                    match_type = "direct_episode_match"
                    confidence = title_match and "medium-high" or "low-medium"
                end
                -- Interpretation 2C: Reverse cumulative conversion
                -- (File says E14, but maybe it means something else in context)
                if not is_match then
                    local converted_ep = convert_jimaku_to_anilist_episode(ep_num, anilist_season, seasons_data)
                    if converted_ep == target_episode then
                        is_match = true
                        anilist_episode = target_episode
                        match_type = "reverse_cumulative_conversion"
                        confidence = title_match and "medium" or "low"
                    end
                end
            end
            -- CASE 3: Japanese absolute episode number (第222話) matches target cumulative
            -- Check directly in filename since parse_jimaku_filename returns early on SxxExx match
            if not is_match then
                local japanese_ep = file.name:match("第(%d+)[話回]")
                if japanese_ep then
                    japanese_ep = tonumber(japanese_ep)
                    if japanese_ep == target_cumulative then
                        is_match = true
                        anilist_episode = target_episode
                        match_type = "japanese_absolute_match"
                        confidence = title_match and "high" or "medium-high"
                    end
                end
            end
            -- VERIFICATION STEP 2: Adjust confidence based on AniList metadata
            if is_match then
                if jimaku_season then
                    -- If it has a season marker, it should match AniList season
                    if jimaku_season == anilist_season then
                        -- Boost confidence
                        if confidence == "medium" then confidence = "high" end
                    else
                        -- Lower confidence if season mismatch
                        if confidence == "high" then confidence = "medium" end
                    end
                end
                -- Check if episode number is reasonable
                if ep_num > total_episodes * 2 then
                    confidence = "low"
                end
            end
            -- Store parsed info for debugging
            table.insert(all_parsed, {
                filename = file.name,
                jimaku_season = jimaku_season,
                jimaku_episode = ep_num,
                anilist_episode = anilist_episode,
                match_type = match_type,
                confidence = confidence,
                title_match = title_match,
                is_match = is_match,
                file = file
            })
            -- Add to matches if we found a match
            if is_match then
                table.insert(matches, {
                    file = file,
                    confidence = confidence,
                    match_type = match_type,
                    priority_score = priority_score
                })
                debug_log(string.format("  ✓ MATCH [%s | %s | P=%d]: %s", 
                    match_type, confidence, priority_score, file.name:sub(1, 80)))
            end
        end
        ::next_file::
    end
    -- Sort matches by confidence (high > medium-high > medium > low-medium > low)
    local confidence_order = {
        high = 5,
        ["medium-high"] = 4,
        medium = 3,
        ["low-medium"] = 2,
        low = 1
    }
    table.sort(matches, function(a, b)
        local a_score = (confidence_order[a.confidence] or 0) * 100 + a.priority_score
        local b_score = (confidence_order[b.confidence] or 0) * 100 + b.priority_score
        return a_score > b_score
    end)
    -- If no matches found, show what we parsed for debugging
    if #matches == 0 then
        debug_log(string.format("No matches found for S%d E%d (cumulative: %d). Parsed episodes:", 
            anilist_season, target_episode, target_cumulative))
        for i = 1, math.min(10, #all_parsed) do
            local p = all_parsed[i]
            local jimaku_display = p.jimaku_season and string.format("S%dE%d", p.jimaku_season, p.jimaku_episode) 
                                   or string.format("E%d", p.jimaku_episode)
            debug_log(string.format("  [%d] %s... → Jimaku: %s | Title: %s | Tried: %s", 
                i, 
                p.filename:sub(1, 40),
                jimaku_display,
                p.title_match and "YES" or "NO",
                p.match_type ~= "" and p.match_type or "no_patterns_matched"))
        end
        if #all_parsed > 10 then
            debug_log(string.format("  ... and %d more files", #all_parsed - 10))
        end
    else
        debug_log(string.format("Found %d matching file(s), sorted by confidence:", #matches))
        for i, m in ipairs(matches) do
            debug_log(string.format("  [%d] %s: %s", i, m.confidence, m.file.name:sub(1, 70)))
        end
    end
    -- Return just the files (extract from match objects)
    local result_files = {}
    for _, m in ipairs(matches) do
        table.insert(result_files, m.file)
    end
    return result_files
end
-- Smart subtitle download with intelligent matching
local function download_subtitle_smart(entry_id, target_episode, target_season, seasons_data, anilist_entry, is_auto)
    -- Fetch all files for this entry
    local all_files = fetch_all_episode_files(entry_id)
    if not all_files or #all_files == 0 then
        debug_log("No subtitle files available for this entry", false)
        return false
    end
    -- Match files intelligently with AniList cross-verification
    local matched_files = match_episodes_intelligent(all_files, target_episode, target_season, seasons_data, anilist_entry)
    if #matched_files == 0 then
        debug_log(string.format("No subtitle files matched S%d E%d", target_season or 1, target_episode), false)
        return false
    end
    debug_log(string.format("Found %d matching subtitle file(s) for S%d E%d:", 
        #matched_files, target_season or 1, target_episode))
    -- Log all matched files
    for i, file in ipairs(matched_files) do
        local size_kb = math.floor(file.size / 1024)
        debug_log(string.format("  [%d] %s (%d KB)", i, file.name, size_kb))
    end
    -- Determine how many to download
    local max_downloads = #matched_files
    if JIMAKU_MAX_SUBS ~= "all" and type(JIMAKU_MAX_SUBS) == "number" then
        max_downloads = math.min(JIMAKU_MAX_SUBS, #matched_files)
    end
    debug_log(string.format("Downloading %d of %d matched subtitle(s)...", max_downloads, #matched_files))
    local success_count = 0
    -- Download and load subtitles
    for i = 1, max_downloads do
        local subtitle_file = matched_files[i]
        local subtitle_path = SUBTITLE_CACHE_DIR .. "/" .. subtitle_file.name
        debug_log(string.format("Downloading [%d/%d]: %s (%d bytes)", 
            i, max_downloads, subtitle_file.name, subtitle_file.size))
        -- Download the file
        local download_args = {
            "curl", "-s", "-L", "-o", subtitle_path,
            "-H", "Authorization: " .. JIMAKU_API_KEY,
            subtitle_file.url
        }
        local download_result = mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = download_args
        })
        if download_result.status == 0 then
            -- Pass "select" only for the first subtitle download (TOP MATCH)
            local load_flag = (success_count == 0) and "select" or "auto"
            if is_archive_file(subtitle_file.name) then
                if handle_archive_file(subtitle_path, load_flag) then
                    success_count = success_count + 1
                end
            else
                -- Load subtitle into mpv
                mp.commandv("sub-add", subtitle_path, load_flag)
                debug_log(string.format("Successfully loaded subtitle [%d/%d] (%s): %s", 
                    i, max_downloads, load_flag, subtitle_file.name))
                -- Update menu state tracking for regular files
                table.insert(menu_state.loaded_subs_files, subtitle_file.name)
                menu_state.loaded_subs_count = menu_state.loaded_subs_count + 1
                success_count = success_count + 1
            end
        else
            debug_log(string.format("Failed to download subtitle [%d/%d]: %s", 
                i, max_downloads, subtitle_file.name), true)
        end
    end
    if success_count > 0 then
        conditional_osd(string.format("✓ Loaded matched subtitle(s)"), 4, is_auto)
        return true
    else
        debug_log("Failed to download or extract any subtitles", true)
        return false
    end
end
-- ARCHIVE HANDLING FIX V3 FOR jimaku.lua
-- This version fixes the issue where files from other extracted archives were being loaded
-- The problem: recursive scan was picking up files from the subtitle-cache directory
-- Solution: Only scan within the specific extraction directory, not parent directories
-------------------------------------------------------------------------------
-- HELPER: Detect archive files
-------------------------------------------------------------------------------
is_archive_file = function(path)
    local ext = path:match("%.([^%.]+)$")
    if not ext then return false end
    ext = ext:lower()
    return ext == "zip" or ext == "rar" or ext == "7z" or ext == "tar" or ext == "gz"
end
-------------------------------------------------------------------------------
-- HELPER: Escape path for shell commands (Windows and Unix)
-------------------------------------------------------------------------------
local function escape_path(path)
    -- For Windows, wrap in quotes and escape any embedded quotes
    if package.config:sub(1,1) == '\\' then
        -- Windows
        return '"' .. path:gsub('"', '\\"') .. '"'
    else
        -- Unix-like - escape spaces and special chars
        return path:gsub('([%s%$%`%"%\\])', '\\%1')
    end
end
-------------------------------------------------------------------------------
-- HELPER: Check if a path is within a base directory (prevent escape)
-------------------------------------------------------------------------------
local function is_within_directory(path, base_dir)
    -- Normalize paths (convert to absolute, resolve ..)
    local function normalize(p)
        -- Remove trailing slashes
        p = p:gsub("[/\\]+$", "")
        -- Convert to forward slashes for consistency
        p = p:gsub("\\", "/")
        return p
    end
    local norm_path = normalize(path)
    local norm_base = normalize(base_dir)
    -- Check if path starts with base_dir
    return norm_path:sub(1, #norm_base) == norm_base
end
-------------------------------------------------------------------------------
-- HELPER: Parse episode number from subtitle filename
-------------------------------------------------------------------------------
local function extract_episode_from_filename(filename)
    -- Try various episode number patterns
    local patterns = {
        "S%d+E(%d+)",           -- S01E05
        "%.E(%d+)%.",           -- .E05.
        "%.E(%d+)%-",           -- .E05-
        "%- (%d+) ",            -- - 05 
        "第(%d+)話",            -- 第489話 (Japanese episode marker)
        "%s(%d+)%s",            -- space 05 space
        "%s(%d+)%.",            -- space 05 dot
        "ep?%.?%s?(%d+)",       -- ep 05, ep.05, ep05
        "%[(%d+)%]",            -- [05]
        "^(%d+)%.",             -- 05. at start
        "^(%d+)%-",             -- 05- at start
    }
    for _, pattern in ipairs(patterns) do
        local ep = filename:match(pattern)
        if ep then
            return tonumber(ep)
        end
    end
    return nil
end
-------------------------------------------------------------------------------
-- HELPER: Check if subtitle filename matches the target anime/episode
-------------------------------------------------------------------------------
local function is_relevant_subtitle(filename, target_title, target_episode, target_season)
    -- Normalize for comparison
    local lower_filename = filename:lower()
    local lower_title = target_title:lower()
    -- Remove common noise words
    local noise_words = {"the", "a", "an"}
    for _, word in ipairs(noise_words) do
        lower_title = lower_title:gsub("^" .. word .. "%s+", "")
        lower_title = lower_title:gsub("%s+" .. word .. "%s+", " ")
    end
    -- Generate significant words from title (minimum 3 chars to avoid false matches)
    local title_words = {}
    for word in lower_title:gmatch("%w+") do
        if #word >= 3 then
            table.insert(title_words, word)
        end
    end
    -- Require SIGNIFICANT word match
    -- Heuristic: Must match at least 60% of significant words if title has multiple words
    local matched_count = 0
    if #title_words > 0 then
        for _, word in ipairs(title_words) do
            if lower_filename:find(word, 1, true) then
                matched_count = matched_count + 1
            end
        end
        local match_ratio = matched_count / #title_words
        -- If single word title, must match it. If multiple words, require >60% match
        if (#title_words == 1 and matched_count == 0) or (#title_words > 1 and match_ratio < 0.6) then
            return false, string.format("insufficient title match (%d/%d words)", matched_count, #title_words)
        end
    end

    -- Extract episode number from filename
    -- FIX: Use same parser as Jimaku files for consistency
    local season, episode = parse_jimaku_filename(filename)
    local file_episode = episode
    -- If we found an episode number, check if it matches
    if file_episode and target_episode then
        -- FIXED: Changed from ±3 tolerance to exact match (tolerance = 0)
        -- This prevents loading wrong episodes (e.g., loading E6-E12 when wanting E9)
        local episode_tolerance = 0  -- Changed from 3 to 0 for exact matching
        if math.abs(file_episode - target_episode) <= episode_tolerance then
            return true, string.format("episode match (file:%d, target:%d)", file_episode, target_episode)
        end
        return false, string.format("episode mismatch (file:%d, target:%d)", 
            file_episode, target_episode)
    end
    -- If no episode number found, still require strong title match
    -- Check full title variations match (not just one word)
    if not file_episode then
        local title_variations = {
            lower_title,
            lower_title:gsub("%s+", "%."),     -- spaces to dots
            lower_title:gsub("%s+", "_"),      -- spaces to underscores
            lower_title:gsub("%s+", ""),       -- remove spaces
            lower_title:gsub("%s+", "%-"),     -- spaces to hyphens
        }
        for _, variant in ipairs(title_variations) do
            if #variant >= 5 and lower_filename:find(variant, 1, true) then
                return true, "title match, no episode number"
            end
        end
        return false, "weak title match, no episode"
    end
    return false, "no match"
end
-------------------------------------------------------------------------------
-- HELPER: Recursively scan directory for subtitle files with filtering
-- CRITICAL: Only scans within the specified base_dir to prevent cache pollution
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- HELPER: Read and parse .kitsuinfo.json from a directory
-------------------------------------------------------------------------------
local function read_kitsuinfo(dir_path)
    local info_path = dir_path .. "/.kitsuinfo.json"
    local f = io.open(info_path, "r")
    if not f then return nil end
    
    local content = f:read("*all")
    f:close()
    
    if not content or content == "" then return nil end
    local ok, data = pcall(utils.parse_json, content)
    
    if ok and data then
        return data
    end
    return nil
end

-------------------------------------------------------------------------------
-- HELPER: Recursively scan directory for subtitle files with filtering
-- CRITICAL: Only scans within the specified base_dir to prevent cache pollution
-------------------------------------------------------------------------------
local function scan_for_subtitles(dir_path, base_dir, target_title, target_episode, target_season, max_depth, target_anilist_id)
    max_depth = max_depth or 3
    if max_depth <= 0 then return {} end
    
    if not is_within_directory(dir_path, base_dir) then
        debug_log(string.format("SECURITY: Refusing to scan outside base directory: %s", dir_path), true)
        return {}
    end
    
    local subtitle_files = {}
    
    -- Read metadata for CURRENT directory to validate files within it
    local current_kitsu = read_kitsuinfo(dir_path)
    
    -- VALIDATE METADATA: Does this metadata belong to the anime we are looking for?
    -- This prevents using "BNA" metadata to validate "BNA" files when looking for "Naruto"
    -- just because we wandered into the "BNA" folder.
    local dataset_matches_target = false
    if current_kitsu then
        if target_anilist_id and current_kitsu.anilist_id then
             if tonumber(target_anilist_id) == tonumber(current_kitsu.anilist_id) then
                 dataset_matches_target = true
             end
        elseif target_title and current_kitsu.name then
             -- Fallback title match if no ID provided in arguments or metadata
             local meta_relevant, _ = is_relevant_subtitle(current_kitsu.name, target_title, nil, nil)
             if meta_relevant then dataset_matches_target = true end
        end
    end

    -- 1. Scan Files directly (no need for file_info)
    local files = utils.readdir(dir_path, "files")
    if files then
        for _, item in ipairs(files) do
            local ext = item:match("%.([^%.]+)$")
            if ext then
                ext = ext:lower()
                if ext == "ass" or ext == "srt" or ext == "vtt" or ext == "sub" then
                    local relevant, reason = is_relevant_subtitle(item, target_title, target_episode, target_season)
                    
                    -- Fallback: Check metadata keys if primary title failed AND metadata matches target
                    if not relevant and dataset_matches_target then
                        if current_kitsu.japanese_name then
                            local jp_relevant, jp_reason = is_relevant_subtitle(item, current_kitsu.japanese_name, target_episode, target_season)
                            if jp_relevant then
                                relevant = true
                                reason = jp_reason .. " [match via japanese_name]"
                            end
                        end
                        if not relevant and current_kitsu.english_name then
                            local en_relevant, en_reason = is_relevant_subtitle(item, current_kitsu.english_name, target_episode, target_season)
                            if en_relevant then
                                relevant = true
                                reason = en_reason .. " [match via english_name]"
                            end
                        end
                    end

                    if relevant then
                        -- FIX: Use same parser as Jimaku files
                        local season, episode = parse_jimaku_filename(item)
                        table.insert(subtitle_files, {
                            path = dir_path .. "/" .. item,
                            name = item,
                            episode = episode,
                            season = season
                        })
                        debug_log(string.format("Accepted: %s (%s)", item, reason))
                    end
                end
            end
        end
    else
        debug_log("Cannot read directory files: " .. dir_path, true)
    end
    
    -- 2. Scan Subdirectories with SMART FILTERING
    local dirs = utils.readdir(dir_path, "dirs")
    if dirs then
        local recurse_dirs = {}
        -- HEURISTIC: If directory contains many folders (>50), it's likely a library root.
        -- We should only enter subfolders that fuzzy-match the target title.
        local use_smart_filter = #dirs > 50 and target_title and target_title ~= ""
        
        -- Filter logic
        local candidate_dirs = {}
        if use_smart_filter then
            debug_log(string.format("Large directory detected (%d subdirs). Using smart filtering for '%s'", #dirs, target_title))
            local search_terms = {}
            for w in target_title:lower():gmatch("%w+") do
                if #w > 2 then table.insert(search_terms, w) end
            end
            
            for _, d in ipairs(dirs) do
                if d ~= "." and d ~= ".." and not d:match("^extracted_") then
                    local d_lower = d:lower()
                    
                    -- Structural Whitelist: Always enter these common organization folders
                    local is_structural = d_lower == "anime" or d_lower == "tv" or d_lower == "movies" or d_lower == "movie" or
                                          d_lower:match("anime_") or d_lower:match("_tv$") or d_lower:match("^season") or 
                                          d:len() <= 3  -- Allow "A", "09", "TV" etc
                    
                    if is_structural then
                         table.insert(candidate_dirs, d)
                    else
                        -- Standard Fuzzy Match
                        local match = false
                        if #search_terms > 0 then
                            for _, term in ipairs(search_terms) do
                                if d_lower:find(term, 1, true) then match = true; break end
                            end
                        else
                            match = true
                        end
                        if match then table.insert(candidate_dirs, d) end
                    end
                end
            end
            debug_log(string.format("Smart Filter: Reduced %d dirs to %d candidate(s)", #dirs, #candidate_dirs))
        else
            -- Small directory, consider all non-special folders
            for _, d in ipairs(dirs) do
                if d ~= "." and d ~= ".." and not d:match("^extracted_") then
                    table.insert(candidate_dirs, d)
                end
            end
        end

        -- Process Candidate Directories (Check metadata)
        for _, d in ipairs(candidate_dirs) do
            local full_path = dir_path .. "/" .. d
            local should_enter = true
            
            -- CHECK .kitsuinfo.json for precise matching
            local kitsu = read_kitsuinfo(full_path)
            if kitsu then
                if target_anilist_id and kitsu.anilist_id then
                    -- ID MATCH: If IDs don't match, SKIP this folder (unless it's a very similar ID? No, IDs should be exact)
                    if tonumber(kitsu.anilist_id) ~= tonumber(target_anilist_id) then
                        should_enter = false
                        -- debug_log(string.format("Kitsunekko: Skipping '%s' (ID %s != %s)", d, kitsu.anilist_id, target_anilist_id))
                    else
                        debug_log(string.format("Kitsunekko: ID MATCH for '%s' (ID: %s)", d, kitsu.anilist_id))
                    end
                elseif target_title then
                    -- NAME MATCH: Check English/Japanese names if ID not available
                    local name_match = false
                    local search_lower = target_title:lower()
                    if kitsu.english_name and kitsu.english_name:lower():find(search_lower, 1, true) then name_match = true end
                    if kitsu.japanese_name and kitsu.japanese_name:lower():find(search_lower, 1, true) then name_match = true end
                    
                    -- If we're already inside a candidate folder (passed smart filter), 
                    -- allow entry even if metadata name doesn't perfectly match (could be synonyms).
                    -- But if metadata name strictly contradicts, maybe valid check?
                    -- For now, metadata existence confirms it is an anime folder, so trusting "should_enter" as true is safe
                    -- unless we wanted to be stricter.
                    -- Let's stick to: if ID is provided, enforce it. If not, just proceed.
                end
            end
            
            if should_enter then
                table.insert(recurse_dirs, d)
            end
        end
        
        -- Recurse into selected directories
        for _, d in ipairs(recurse_dirs) do
            local sub_files = scan_for_subtitles(dir_path .. "/" .. d, base_dir, target_title, target_episode, target_season, max_depth - 1, target_anilist_id)
            for _, sf in ipairs(sub_files) do
                table.insert(subtitle_files, sf)
            end
        end
    end
    
    return subtitle_files
end
-------------------------------------------------------------------------------
-- HELPER: Sort subtitle files by episode number
-------------------------------------------------------------------------------
local function sort_subtitles_by_episode(subtitle_files)
    table.sort(subtitle_files, function(a, b)
        if a.episode and b.episode then
            return a.episode < b.episode
        elseif a.episode then
            return true
        elseif b.episode then
            return false
        else
            return a.name < b.name
        end
    end)
end
-------------------------------------------------------------------------------
-- HELPER: Try different extraction methods based on platform and availability
-------------------------------------------------------------------------------
local function try_extract_archive(archive_path, extract_dir)
    local is_windows = package.config:sub(1,1) == '\\'
    local ext = archive_path:match("%.([^%.]+)$")
    if ext then ext = ext:lower() end
    -- Ensure extract directory exists
    if STANDALONE_MODE then
        if is_windows then
            os.execute('mkdir "' .. extract_dir:gsub('/', '\\') .. '" 2>nul')
        else
            os.execute('mkdir -p ' .. escape_path(extract_dir))
        end
    else
        -- Create directory using mpv command
        if is_windows then
            mp.command_native({
                name = "subprocess",
                playback_only = false,
                capture_stdout = true,
                args = {"cmd", "/c", "mkdir", extract_dir:gsub('/', '\\')}
            })
        else
            mp.command_native({
                name = "subprocess",
                playback_only = false,
                args = {"mkdir", "-p", extract_dir}
            })
        end
    end
    debug_log("Extracting to: " .. extract_dir)
    -- Method 1: Try 7z (best cross-platform support)
    local extraction_attempts = {}
    if is_windows then
        -- Windows extraction methods
        table.insert(extraction_attempts, {
            name = "7z",
            args = {"7z", "x", archive_path, "-o" .. extract_dir, "-y"}
        })
        -- PowerShell for ZIP only
        if ext == "zip" then
            table.insert(extraction_attempts, {
                name = "powershell",
                args = {"powershell", "-Command", 
                    "Expand-Archive -Path " .. escape_path(archive_path) .. 
                    " -DestinationPath " .. escape_path(extract_dir) .. " -Force"}
            })
        end
        -- tar (Windows 10+)
        table.insert(extraction_attempts, {
            name = "tar",
            args = {"tar", "-xf", archive_path, "-C", extract_dir}
        })
    else
        -- Unix/Linux extraction methods
        if ext == "zip" then
            table.insert(extraction_attempts, {
                name = "unzip",
                args = {"unzip", "-o", archive_path, "-d", extract_dir}
            })
        elseif ext == "7z" then
            table.insert(extraction_attempts, {
                name = "7z",
                args = {"7z", "x", archive_path, "-o" .. extract_dir, "-y"}
            })
        elseif ext == "rar" then
            table.insert(extraction_attempts, {
                name = "unrar",
                args = {"unrar", "x", "-o+", archive_path, extract_dir}
            })
        end
        -- tar works for most formats on Unix
        table.insert(extraction_attempts, {
            name = "tar",
            args = {"tar", "-xf", archive_path, "-C", extract_dir}
        })
    end
    -- Try each extraction method
    for _, method in ipairs(extraction_attempts) do
        debug_log("Trying extraction with: " .. method.name)
        local result
        if STANDALONE_MODE then
            local cmd_parts = {}
            for _, arg in ipairs(method.args) do
                table.insert(cmd_parts, arg:match("%s") and escape_path(arg) or arg)
            end
            local cmd = table.concat(cmd_parts, " ")
            debug_log("Command: " .. cmd)
            local success = os.execute(cmd)
            result = {status = success and 0 or 1}
        else
            result = mp.command_native({
                name = "subprocess",
                playback_only = false,
                capture_stdout = true,
                capture_stderr = true,
                args = method.args
            })
        end
        if result.status == 0 then
            debug_log("Extraction successful using: " .. method.name)
            return true
        else
            debug_log(string.format("Extraction failed with %s (status: %d)", 
                method.name, result.status))
            if result.stderr then
                debug_log("Error output: " .. result.stderr)
            end
        end
    end
    return false
end
-------------------------------------------------------------------------------
-- MAIN: Handle archive file extraction and loading with smart filtering
-------------------------------------------------------------------------------
handle_archive_file = function(archive_path, default_flag)
    debug_log("Handling archive: " .. archive_path)
    -- Get context about what we're looking for
    local target_title = menu_state.current_match and menu_state.current_match.title or 
                        menu_state.parsed_data and menu_state.parsed_data.title or
                        "Unknown"
    local target_episode = menu_state.current_match and menu_state.current_match.episode or
                          menu_state.parsed_data and tonumber(menu_state.parsed_data.episode) or
                          1
    local target_season = menu_state.current_match and menu_state.current_match.season or
                         menu_state.parsed_data and menu_state.parsed_data.season or
                         1
    debug_log(string.format("Archive filtering context: Title='%s', Season=%s, Episode=%s", 
        target_title, target_season or "nil", target_episode))
    -- Create a unique extraction directory based on filename and timestamp
    local filename = archive_path:match("([^/\\]+)$") or "archive"
    filename = filename:gsub("%.%w+$", "")  -- Remove extension
    filename = filename:gsub("[^%w%-_]", "_")  -- Sanitize filename
    local extract_dir = SUBTITLE_CACHE_DIR .. "/extracted_" .. filename .. "_" .. os.time()
    -- Try to extract the archive
    local extract_success = try_extract_archive(archive_path, extract_dir)
    if not extract_success then
        debug_log("All extraction methods failed for: " .. archive_path, true)
        mp.osd_message("Failed to extract archive!\nTry installing 7z or unzip.", 5)
        return false
    end
    -- Successfully extracted, now scan for RELEVANT subtitle files only
    -- CRITICAL: Pass extract_dir as base_dir to prevent scanning outside
    debug_log("Extraction successful, scanning for relevant subtitles...")
    debug_log(string.format("Scanning base directory: %s", extract_dir))
    local subtitle_files = scan_for_subtitles(extract_dir, extract_dir, target_title, target_episode, target_season)
    if #subtitle_files == 0 then
        debug_log("No relevant subtitle files found in archive", true)
        mp.osd_message("Archive contains no matching subtitles!", 4)
        return false
    end
    -- Sort subtitles by episode number
    sort_subtitles_by_episode(subtitle_files)
    debug_log(string.format("Found %d relevant subtitle file(s) in archive", #subtitle_files))
    -- Determine how many to load
    local max_to_load = JIMAKU_MAX_SUBS or 5
    local files_to_load = math.min(#subtitle_files, max_to_load)
    if #subtitle_files > max_to_load then
        debug_log(string.format("Limiting load to %d of %d files (configurable via JIMAKU_MAX_SUBS)", 
            max_to_load, #subtitle_files))
    end
    -- Load subtitle files
    local loaded_count = 0
    for i = 1, files_to_load do
        local sub_info = subtitle_files[i]
        -- Only the first subtitle gets the specified flag (select/auto)
        local flag = (i == 1) and (default_flag or "auto") or "auto"
        local ep_info = sub_info.episode and string.format(" [Ep %d]", sub_info.episode) or ""
        debug_log(string.format("Loading subtitle [%d/%d]%s: %s (flag: %s)", 
            i, files_to_load, ep_info, sub_info.name, flag))
        local success, err = pcall(function()
            mp.commandv("sub-add", sub_info.path, flag)
        end)
        if success then
            loaded_count = loaded_count + 1
            table.insert(menu_state.loaded_subs_files, sub_info.name)
        else
            debug_log(string.format("Failed to load subtitle: %s (%s)", sub_info.name, err), true)
        end
    end
    if loaded_count > 0 then
        local msg = string.format("✓ Loaded %d subtitle(s) from archive", loaded_count)
        if #subtitle_files > files_to_load then
            msg = msg .. string.format("\n(%d more available but not loaded)", 
                #subtitle_files - files_to_load)
        end
        if loaded_count < files_to_load then
            msg = msg .. string.format("\n(%d failed to load)", files_to_load - loaded_count)
        end
        mp.osd_message(msg, 4)
        menu_state.loaded_subs_count = menu_state.loaded_subs_count + loaded_count
        update_loaded_subs_list()  -- Refresh the loaded subs list
        return true
    else
        debug_log("No subtitles could be loaded from archive", true)
        mp.osd_message("Failed to load subtitles from archive!", 4)
        return false
    end
end
-- New helper to track currently loaded subtitles from track-list
update_loaded_subs_list = function()
    -- Get files from JSON index (O(1) Disk) instead of re-scanning folders
    local indexed_files = get_indexed_subs()
    local count = 0
    -- Clear current list
    menu_state.loaded_subs = {}
    -- O(n) loop through memory is significantly faster than disk I/O
    for _, filepath in ipairs(indexed_files) do
        -- logic to check if this sub matches current video 
        -- (e.g., string matching or just counting total cached)
        count = count + 1
    end
    menu_state.loaded_subs_count = count
    debug_log("Loaded subs updated from index: " .. count)
end
-------------------------------------------------------------------------------
-- ULTRA SIMPLE MANUAL SEARCH
-------------------------------------------------------------------------------
-- Just one function to handle everything
function manual_search_action()
    mp.osd_message("Type search in console (press ~)", 3)
    mp.commandv("script-message-to", "console", "type", "script-message jimaku-search ")
end
-- Single handler for search with pagination support
mp.register_script_message("jimaku-search", function(query)
    if not query or query == "" then return end
    if not JIMAKU_API_KEY or JIMAKU_API_KEY == "" then 
        mp.osd_message("Set API key first", 3) 
        return 
    end
    mp.osd_message("Searching: " .. query, 3)
    local search_url = string.format("%s/entries/search?anime=true&query=%s", JIMAKU_API_URL, query)
    local result = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = { "curl", "-s", "-X", "GET", "-H", "Authorization: " .. JIMAKU_API_KEY, search_url }
    })
    if result.status ~= 0 or not result.stdout then
        mp.osd_message("Search failed", 3)
        return
    end
    local entries = utils.parse_json(result.stdout)
    if not entries or #entries == 0 then
        mp.osd_message("No results", 3)
        return
    end
    -- Implementation of Pagination for Manual Search
    local function show_results_page(page)
        local per_page = script_opts.JIMAKU_ITEMS_PER_PAGE
        local total_pages = math.ceil(#entries / per_page)
        local start_idx = (page - 1) * per_page + 1
        local end_idx = math.min(start_idx + per_page - 1, #entries)
        local items = {}
        for i = start_idx, end_idx do
            local entry = entries[i]
            table.insert(items, {
                text = string.format("%d. %s", i - start_idx + 1, entry.name),
                hint = entry.anilist_id and ("ID: " .. entry.anilist_id) or "No AniList",
                action = function()
                    menu_state.jimaku_id = entry.id
                    menu_state.jimaku_entry = entry
                    menu_state.current_match = { 
                        title = entry.name, 
                        anilist_id = entry.anilist_id, 
                        episode = 1, 
                        season = 1 
                    }
                    menu_state.browser_files = nil
                    -- 1. Remove the search results from the stack
                    pop_menu() 
                    -- 2. Open the browser (it will now be on top of the Search/Main menu)
                    show_subtitle_browser()
                end
            })
        end
        local on_left = function() if page > 1 then show_results_page(page - 1) end end
        local on_right = function() if page < total_pages then show_results_page(page + 1) end end
        local title = string.format("Search: %s (%d/%d)", query, page, total_pages)
        local footer = "←/→ Page | 0: Back"
        push_menu(title, items, footer, on_left, on_right)
    end
    show_results_page(1)
end)
-------------------------------------------------------------------------------
-- MPV MODE - ANILIST INTEGRATION
-------------------------------------------------------------------------------
local function make_anilist_request(query, variables)
    debug_log("AniList Request for: " .. (variables.search or "unknown"))
    local request_body = utils.format_json({query = query, variables = variables})
    local args = { 
        "curl", "-s", "-X", "POST", 
        "-H", "Content-Type: application/json", 
        "-H", "Accept: application/json", 
        "--data", request_body, 
        ANILIST_API_URL 
    }
    local result = mp.command_native({
        name = "subprocess", 
        capture_stdout = true, 
        playback_only = false, 
        args = args
    })
    if result.status ~= 0 or not result.stdout then 
        debug_log("Curl request failed or returned no output", true)
        return nil 
    end
    local ok, data = pcall(utils.parse_json, result.stdout)
    if not ok then
        debug_log("Failed to parse JSON response", true)
        return nil
    end
    if data.errors then
        debug_log("AniList API Error: " .. utils.format_json(data.errors), true)
        return nil
    end
    return data.data
end
-------------------------------------------------------------------------------
-- SMART MATCH ALGORITHM (FIXED)
-------------------------------------------------------------------------------
local function smart_match_anilist(results, parsed, episode_num, season_num, file_year)
    local selected = results[1]  -- Default to best search match
    local actual_episode = episode_num
    local actual_season = season_num or 1
    local match_method = "default"
    local match_confidence = "low"
    local seasons = {}
    -- FIX #10: Weight different signals
    local has_explicit_season = (season_num and season_num >= 2)
    local has_special_indicator = parsed.is_special
    -- Priority scoring system:
    -- Explicit season marker in filename = 10 points (highest trust)
    -- Special keyword in filename = 5 points
    -- Episode number exceeds S1 count = 3 points (suggests later season)
    local explicit_season_weight = has_explicit_season and 10 or 0
    local special_weight = has_special_indicator and 5 or 0
    -- NEW: Check title similarity to prevent completely wrong matches
    local function check_title_similarity(media)
        local search_terms = parsed.title:lower():gsub("[%s%-%._]", "")
        local romaji = (media.title.romaji or ""):lower():gsub("[%s%-%._]", "")
        local english = (media.title.english or ""):lower():gsub("[%s%-%._]", "")
        -- Check if any significant word from search appears in title
        for word in search_terms:gmatch("%w+") do
            if word:len() >= 3 then
                if romaji:match(word) or english:match(word) then
                    return true
                end
            end
        end
        -- Check synonyms
        if media.synonyms then
            for _, syn in ipairs(media.synonyms) do
                local syn_clean = syn:lower():gsub("[%s%-%._]", "")
                for word in search_terms:gmatch("%w+") do
                    if word:len() >= 3 and syn_clean:match(word) then
                        return true
                    end
                end
            end
        end
        return false
    end
    -- If first result seems completely unrelated, log warning
    if not check_title_similarity(selected) then
        debug_log("WARNING: First result may not match - titles seem unrelated", true)
        match_confidence = "very-low"
    end
    debug_log(string.format("Smart Match Weights: Explicit Season=%d, Special=%d", 
        explicit_season_weight, special_weight))
    -- PRIORITY 1: Explicit Season Number (HIGHEST weight)
    -- If user has S2/S3 in filename, this should override special detection
    if has_explicit_season then
        for i, media in ipairs(results) do
            local full_text = (media.title.romaji or "") .. " " .. (media.title.english or "")
            for _, syn in ipairs(media.synonyms or {}) do
                full_text = full_text .. " " .. syn
            end
            local is_match = false
            local search_pattern = nil
            if season_num == 2 then
                search_pattern = "season/part 2"
                is_match = full_text:lower():match("season%s*2") or 
                          full_text:lower():match("2nd%s+season") or
                          full_text:lower():match("part%s*2")
            elseif season_num == 3 then
                search_pattern = "season/part 3"
                is_match = full_text:lower():match("season%s*3") or 
                          full_text:lower():match("3rd%s+season") or
                          full_text:lower():match("part%s*3")
            elseif season_num >= 4 then
                search_pattern = "season/part " .. season_num
                is_match = full_text:lower():match("season%s*" .. season_num) or
                          full_text:lower():match("part%s*" .. season_num)
            end
            if is_match then
                selected = media
                actual_episode = episode_num
                actual_season = season_num
                match_method = "explicit_season"
                match_confidence = "high"
                debug_log(string.format("MATCH: Explicit Season %d via '%s' (HIGH CONFIDENCE)", 
                    season_num, search_pattern))
                -- Store this season's data
                seasons[season_num] = {media = media, eps = media.episodes or 13, name = media.title.romaji}
                return selected, actual_episode, actual_season, seasons, match_method, match_confidence
            end
        end
        -- If we have explicit season but didn't find match, log warning
        debug_log(string.format("WARNING: S%d specified but no matching season entry found in results", 
            season_num), true)
    end
    -- PRIORITY 1.5: "Part 2"/"Part 3" detection (HIGH weight)
    -- Check if filename has "Part X" and match it with AniList entries
    if not has_explicit_season then
        local part_num = parsed.title:match("%s+Part%s+(%d+)$")
        if part_num then
            local part_int = tonumber(part_num)
            debug_log(string.format("Searching for 'Part %d' in results...", part_int))
            for i, media in ipairs(results) do
                local full_text = (media.title.romaji or "") .. " " .. (media.title.english or "")
                for _, syn in ipairs(media.synonyms or {}) do
                    full_text = full_text .. " " .. syn
                end
                -- Check if this entry has "Part X" in title
                if full_text:lower():match("part%s*" .. part_int) then
                    selected = media
                    actual_episode = episode_num
                    actual_season = part_int  -- Treat Part as season for jimaku
                    match_method = "part_match"
                    match_confidence = "high"
                    debug_log(string.format("MATCH: Found 'Part %d' entry (HIGH CONFIDENCE)", part_int))
                    -- Store as season for cumulative calculation
                    seasons[part_int] = {media = media, eps = media.episodes or 13, name = media.title.romaji}
                    return selected, actual_episode, actual_season, seasons, match_method, match_confidence
                end
            end
            debug_log(string.format("WARNING: Part %d in filename but no matching AniList entry found", part_int), true)
        end
    end
    -- PRIORITY 2: Special/OVA Format (MEDIUM-HIGH weight)
    -- Only if no explicit season number, OR if explicit season also has special keyword
    if has_special_indicator and not has_explicit_season then
        for i, media in ipairs(results) do
            if media.format == "SPECIAL" or media.format == "OVA" or media.format == "ONA" then
                selected = media
                actual_episode = episode_num
                actual_season = 1  -- Specials usually don't have seasons
                match_method = "special_format"
                match_confidence = "medium-high"
                debug_log(string.format("MATCH: Special/OVA format '%s' (MEDIUM-HIGH CONFIDENCE)", 
                    media.format))
                return selected, actual_episode, actual_season, seasons, match_method, match_confidence
            end
        end
    end
    -- PRIORITY 3: Cumulative Episode Calculation (MEDIUM weight)
    -- If episode number exceeds first result's count, try to find correct season
    -- BUT: If first result is clearly the right show (title matches) and has unknown episode count,
    -- don't trigger cumulative - just use it as-is
    local first_result_unknown_eps = (selected.episodes == nil or selected.episodes == 0)
    local first_result_title_matches = check_title_similarity(selected)
    if not has_explicit_season and episode_num > (selected.episodes or 0) then
        -- If first result clearly matches title but has unknown episode count, use it anyway
        if first_result_unknown_eps and first_result_title_matches then
            debug_log("First result has unknown episode count but title matches - using it (skipping cumulative)")
            match_method = "title_match_unknown_eps"
            match_confidence = "medium"
            return selected, actual_episode, actual_season, seasons, match_method, match_confidence
        end
        debug_log("Episode number exceeds S1 count - attempting cumulative calculation")
        -- Build season list (only include entries with title similarity)
        for i, media in ipairs(results) do
            -- Skip entries that don't match the search title at all
            if not check_title_similarity(media) then
                debug_log(string.format("  Skipping unrelated entry: %s", media.title.romaji or "N/A"))
                goto skip_media
            end
            if media.format == "TV" and media.episodes then
                local full_text = (media.title.romaji or "") .. " " .. (media.title.english or "")
                for _, syn in ipairs(media.synonyms or {}) do
                    full_text = full_text .. " " .. syn
                end
                -- Season/Part 1 (no season/part marker)
                if not seasons[1] and not full_text:lower():match("season") and 
                   not full_text:lower():match("part") and
                   not full_text:lower():match("%dnd") and 
                   not full_text:lower():match("%drd") and 
                   not full_text:lower():match("%dth") then
                    seasons[1] = {media = media, eps = media.episodes, name = media.title.romaji}
                end
                -- Season/Part 2
                if not seasons[2] and (full_text:lower():match("2nd%s+season") or 
                   full_text:lower():match("season%s*2") or
                   full_text:lower():match("part%s*2")) then
                    seasons[2] = {media = media, eps = media.episodes, name = media.title.romaji}
                end
                -- Season/Part 3
                if not seasons[3] and (full_text:lower():match("3rd%s+season") or 
                   full_text:lower():match("season%s*3") or
                   full_text:lower():match("part%s*3")) then
                    seasons[3] = {media = media, eps = media.episodes, name = media.title.romaji}
                end
            end
            ::skip_media::
        end
        -- Calculate which season this episode belongs to
        local cumulative = 0
        local found_match = false
        for season_idx = 1, 3 do
            if seasons[season_idx] then
                local season_eps = seasons[season_idx].eps
                debug_log(string.format("  Season %d: %s (%d eps, range: %d-%d)", 
                    season_idx, seasons[season_idx].name, season_eps, 
                    cumulative + 1, cumulative + season_eps))
                if episode_num <= cumulative + season_eps then
                    selected = seasons[season_idx].media
                    actual_episode = episode_num - cumulative
                    actual_season = season_idx
                    match_method = "cumulative"
                    match_confidence = "medium"
                    found_match = true
                    debug_log(string.format("MATCH: Cumulative - Ep %d -> S%dE%d of '%s' (MEDIUM CONFIDENCE)", 
                        episode_num, season_idx, actual_episode, selected.title.romaji))
                    break
                end
                cumulative = cumulative + season_eps
            end
        end
        if found_match then
            return selected, actual_episode, actual_season, seasons, match_method, match_confidence
        else
            debug_log("WARNING: Cumulative calculation failed - episode exceeds all known seasons", true)
        end
    end
    -- FALLBACK: Use default (first result)
    if season_num then
        actual_season = season_num
    end
    match_method = "default"
    match_confidence = "low"
    debug_log("Using default match (first search result) - LOW CONFIDENCE")
    return selected, actual_episode, actual_season, seasons, match_method, match_confidence
end
-- Extract year from filename (for disambiguation)
local function extract_year(filename)
    if not filename then return nil end
    -- Look for (2024), (2025), etc.
    local year = filename:match("%(20(%d%d)%)")
    if year then
        return 2000 + tonumber(year)
    end
    -- Look for [2024], [2025]
    year = filename:match("%[20(%d%d)%]")
    if year then
        return 2000 + tonumber(year)
    end
    return nil
end
-- Create a clean version of title for AniList search
local function get_search_title(parsed)
    local search_title = parsed.title
    -- If it's a special, remove special markers for better search
    if parsed.is_special then
        search_title = search_title:gsub("%s*Special%s*", " ")
        search_title = search_title:gsub("%s*OVA%s*", " ")
        search_title = search_title:gsub("%s*OAD%s*", " ")
        search_title = search_title:gsub("%s*ONA%s*", " ")
        search_title = search_title:gsub("%s*%-hen%s*", " ")  -- Japanese "hen" (arc/part)
        -- Clean up
        search_title = search_title:gsub("%s*%-+%s*$", "")
        search_title = search_title:gsub("^%s*%-+%s*", "")
        search_title = search_title:gsub("%s+", " ")
        search_title = search_title:gsub("^%s+", ""):gsub("%s+$", "")
    end
    return search_title
end
-- Main search function with integrated smart matching
-------------------------------------------------------------------------------
-- OFFLINE FALLBACK: Search local subtitle cache when AniList/Jimaku unavailable
-- Scans SUBTITLE_CACHE_DIR for matching subtitle files based on parsed title/episode
-------------------------------------------------------------------------------
search_local_subtitle_cache = function(parsed, is_auto, anilist_id)
    if not parsed or not parsed.title then
        debug_log("Offline search: No parsed title available", true)
        return false
    end
    local target_title = parsed.title
    local target_episode = tonumber(parsed.episode) or 1
    local target_season = parsed.season or 1
    debug_log(string.format("Offline search: Looking for '%s' S%d E%d in %s (ID: %s)", 
        target_title, target_season, target_episode, SUBTITLE_CACHE_DIR, anilist_id or "N/A"))
    -- Scan the subtitle cache directory for matching files
    local subtitle_files = scan_for_subtitles(
        SUBTITLE_CACHE_DIR, 
        SUBTITLE_CACHE_DIR, 
        target_title, 
        target_episode, 
        target_season,
        4,  -- max_depth (Increased to 4 to support nested libraries e.g. subtitles/anime_tv/show/file)
        anilist_id -- Pass AniList ID for precise folder verification
    )
    if #subtitle_files == 0 then
        debug_log("Offline search: No matching subtitles found in local cache", true)
        return false
    end
    -- Sort by episode number
    sort_subtitles_by_episode(subtitle_files)
    debug_log(string.format("Offline search: Found %d matching subtitle(s) in local cache", #subtitle_files))
    -- Load the best matches (up to JIMAKU_MAX_SUBS)
    local max_to_load = math.min(#subtitle_files, JIMAKU_MAX_SUBS or 5)
    local loaded_count = 0
    for i = 1, max_to_load do
        local sub_info = subtitle_files[i]
        local flag = (i == 1) and "select" or "auto"
        local ep_info = sub_info.episode and string.format(" [Ep %d]", sub_info.episode) or ""
        debug_log(string.format("Offline loading [%d/%d]%s: %s", 
            i, max_to_load, ep_info, sub_info.name))
        local success, err = pcall(function()
            mp.commandv("sub-add", sub_info.path, flag)
        end)
        if success then
            loaded_count = loaded_count + 1
            table.insert(menu_state.loaded_subs_files, sub_info.name)
        else
            debug_log(string.format("Offline search: Failed to load %s (%s)", sub_info.name, err), true)
        end
    end
    if loaded_count > 0 then
        local msg = string.format("✓ OFFLINE: Loaded %d subtitle(s) from cache\n%s", 
            loaded_count, subtitle_files[1].name)
        conditional_osd(msg, 5, is_auto)
        debug_log(string.format("Offline search: Successfully loaded %d subtitle(s)", loaded_count))
        return true
    end
    return false
end
search_anilist = function(is_auto)
    -- Try media-title first (for streams/URLs), then filename (for local files)
    local title_source = mp.get_property("media-title") or mp.get_property("filename")
    if not title_source then return end
    -- Check if this is a URL (protocol-based source)
    local is_url = title_source:match("^https?://")
    local parsed = parse_media_title(title_source)
    if not parsed then
        if not is_url then
            conditional_osd("AniList: Failed to parse filename", 3, is_auto)
        else
            conditional_osd("AniList: Failed to parse stream title", 3, is_auto)
        end
        return
    end
    -- Get clean search title (removes "Special", "OVA" etc for better matching)
    local search_title = get_search_title(parsed)
    if search_title ~= parsed.title then
        debug_log(string.format("Search title cleaned: '%s' → '%s'", parsed.title, search_title))
    end
    conditional_osd("AniList: Searching for " .. search_title .. "...", 3, is_auto)
    -- Check cache first
    local cache_key = search_title:lower()
    
    -- API Toggle Check
    if not USE_ANILIST_API then
        debug_log("AniList API disabled by config - Skipping online search")
        -- Directly try offline search since we can't get AniList ID
        local offline_success = search_local_subtitle_cache(parsed, is_auto, nil)
        if not offline_success then
            conditional_osd("Online search disabled.\nNo local subtitles found.", 3, is_auto)
        end
        return
    end

    if not STANDALONE_MODE and ANILIST_CACHE[cache_key] then
        local cache_entry = ANILIST_CACHE[cache_key]
        local cache_age = os.time() - cache_entry.timestamp
        if cache_age < 86400 then  -- Cache valid for 24 hours
            debug_log(string.format("Using cached AniList results for '%s' (%d seconds old)", 
                search_title, cache_age))
            local data = {Page = {media = cache_entry.results}}
            -- Continue with the rest of the function using cached data
        else
            debug_log(string.format("AniList cache expired for '%s' (%d seconds old)", 
                search_title, cache_age))
            ANILIST_CACHE[cache_key] = nil
        end
    end
    -- Make API request if not cached or cache expired
    local data
    if not ANILIST_CACHE[cache_key] then
        local query = [[
        query ($search: String) {
          Page (page: 1, perPage: 15) {
            media (search: $search, type: ANIME) {
              id
              title {
                romaji
                english
              }
              synonyms
              status
              episodes
              format
            }
          }
        }
        ]]
        data = make_anilist_request(query, {search = search_title})
        -- Cache the results
        if data and data.Page and data.Page.media then
            ANILIST_CACHE[cache_key] = {
                results = data.Page.media,
                timestamp = os.time()
            }
            if not STANDALONE_MODE then
                save_ANILIST_CACHE()
            end
            debug_log(string.format("Cached AniList results for '%s'", search_title))
        end
    else
        data = {Page = {media = ANILIST_CACHE[cache_key].results}}
    end
    -- FALLBACK: If no results, try alternative searches
    if data and data.Page and data.Page.media and #data.Page.media == 0 then
        debug_log("No results found - trying fallback searches...")
        -- Fallback 1: Try original title (without cleaning)
        if search_title ~= parsed.title then
            debug_log("Fallback 1: Trying original title: " .. parsed.title)
            data = make_anilist_request(query, {search = parsed.title})
        end
        -- Fallback 2: Try removing subtitle/arc name (text after " - ")
        if data and data.Page and data.Page.media and #data.Page.media == 0 then
            local base_title = search_title:match("^(.-)%s*%-%s*.+$")
            if base_title and base_title:len() > 2 then
                debug_log("Fallback 2: Trying base title without arc: " .. base_title)
                data = make_anilist_request(query, {search = base_title})
            end
        end
        -- Fallback 3: Try first word only (for complex titles)
        if data and data.Page and data.Page.media and #data.Page.media == 0 then
            local first_word = search_title:match("^(%S+)")
            if first_word and first_word:len() > 3 then
                debug_log("Fallback 3: Trying first word only: " .. first_word)
                data = make_anilist_request(query, {search = first_word})
            end
        end
    end
    if data and data.Page and data.Page.media then
        local results = data.Page.media
        -- Store for manual picker
        menu_state.search_results = results
        menu_state.search_results_page = 1
        -- Extract year from filename for disambiguation
        local file_year = extract_year(filename)
        if file_year then
            debug_log(string.format("Detected year in filename: %d", file_year))
        end
        debug_log(string.format("Analyzing %d potential matches for '%s' %sE%s...", 
            #results, 
            search_title,  -- Use search_title instead of parsed.title
            parsed.season and string.format("S%d ", parsed.season) or "",
            parsed.episode))
        -- If we have 0 results, show helpful message
        if #results == 0 then
            debug_log("FAILURE: No matches found after all fallback attempts", true)
            conditional_osd("AniList: No match found.\nTry renaming file or manual search.", 5, is_auto)
            return
        end
        -- Use improved smart match algorithm (FIX #10)
        local episode_num = tonumber(parsed.episode) or 1
        local season_num = parsed.season
        local selected, actual_episode, actual_season, seasons, match_method, match_confidence = 
            smart_match_anilist(results, parsed, episode_num, season_num, file_year)
        -- Log match quality
        debug_log(string.format("Match Method: %s | Confidence: %s", match_method, match_confidence))
        -- Warn user if match confidence is very low (wrong show)
        if match_confidence == "very-low" then
            conditional_osd("⚠ WARNING: Match uncertain - result may be wrong anime!\nPress 'A' to retry or rename file.", 8, is_auto)
        end
        -- Final reporting with Type/Format
        for i, media in ipairs(results) do
            local romaji = media.title.romaji or "N/A"
            local total_eps = media.episodes or "??"
            local m_format = media.format or "UNK"
            local first_syn = (media.synonyms and media.synonyms[1]) or "None"
            local marker = (media.id == selected.id) and ">>" or "  "
            debug_log(string.format("%s [%d] ID: %-7s | %-7s | Eps: %-3s | Syn: %-15s | %s", 
                marker, i, media.id, m_format, total_eps, first_syn, romaji))
        end
        -- Build OSD message with confidence warning
        local osd_msg = string.format("AniList Match: %s\nID: %s | S%d E%d\nFormat: %s | Total Eps: %s", 
            selected.title.romaji, 
            selected.id,
            actual_season,
            actual_episode,
            selected.format or "TV",
            selected.episodes or "?")
        -- Store match data for menu system
        menu_state.anilist_id = selected.id
        menu_state.current_match = {
            title = selected.title.romaji,
            anilist_id = selected.id,
            episode = actual_episode,
            season = actual_season,
            format = selected.format,
            total_episodes = selected.episodes,
            match_method = match_method,
            confidence = match_confidence,
            anilist_entry = selected
        }
        menu_state.seasons_data = seasons
        menu_state.parsed_data = parsed
        -- Add warning for low confidence matches this stuff is just missleading legacy stuff...
        -- if match_confidence == "very-low" then
        --     osd_msg = osd_msg .. "\n⚠⚠ VERY LOW CONFIDENCE - Likely WRONG match!"
        -- elseif match_confidence == "low" or match_confidence == "uncertain" then
        --     osd_msg = osd_msg .. "\n⚠ Low confidence - verify result"
        -- end
        conditional_osd(osd_msg, 5, is_auto)
        -- Try to fetch subtitles from Jimaku using smart matching
        local jimaku_entry = search_jimaku_subtitles(selected.id)
        if jimaku_entry then
            -- Store jimaku ID for menu system
            menu_state.jimaku_id = jimaku_entry.id
            menu_state.jimaku_entry = jimaku_entry
            -- Force refresh of browser files next time it's opened
            menu_state.browser_files = nil
            download_subtitle_smart(
                jimaku_entry.id, 
                actual_episode, 
                actual_season,
                seasons,
                selected,  -- Pass full AniList entry for verification
                is_auto
            )
        else
            -- AniList match found but no Jimaku entry exists
            -- TRY LOCAL SEARCH with confirmed ID
            debug_log(string.format("No Jimaku entry found. Trying local search for ID %d...", selected.id))
            local local_success = search_local_subtitle_cache(parsed, is_auto, selected.id)
            
            if not local_success then
                local no_subs_msg = string.format(
                    "No subtitles on Jimaku or Local for:\n%s (ID: %d)\n",
                    selected.title.romaji,
                    selected.id
                )
                conditional_osd(no_subs_msg, 7, is_auto)
            end
        end
    else
        -- OFFLINE FALLBACK: Search local subtitle cache when AniList/Jimaku are unavailable
        debug_log("FAILURE: No matches found for " .. parsed.title, true)
        debug_log("Attempting offline fallback: scanning local subtitle cache...")
        local offline_success = search_local_subtitle_cache(parsed, is_auto)
        if not offline_success then
            conditional_osd("AniList: No match found.\nOffline cache search also failed.", 3, is_auto)
        end
    end
end
-- Initialize
if not STANDALONE_MODE then
    -- Create subtitle cache directory
    ensure_directory(SUBTITLE_CACHE_DIR)
    -- Note: API key is now loaded only from jimaku.conf via script_opts
    -- Log API key status
    if JIMAKU_API_KEY then
        debug_log("Jimaku API key loaded from jimaku.conf")
    else
        debug_log("Jimaku API key not set. Please set jimaku_api_key in jimaku.conf", true)
    end
    -- Load caches
    load_ANILIST_CACHE()
    load_JIMAKU_CACHE()
    -- Load preferred groups from cache
    JIMAKU_PREFERRED_GROUPS = load_preferred_groups()
    -- Keybind 'A' to trigger the search
    mp.add_key_binding("A", "anilist-search", search_anilist)
    -- Keyboard triggers for menu system (using standard bindings for script permanence)
    mp.add_key_binding("alt+a", "jimaku-menu-alt-a", show_main_menu)
    -- Script message for browser filtering
    mp.register_script_message("jimaku-browser-filter", function(text)
        apply_browser_filter(text ~= "" and text or nil)
    end)
    -- Script message for preferred groups
    mp.register_script_message("jimaku-set-groups", function(text)
        if text and text ~= "" then
            local new_groups = {}
            for group in string.gmatch(text, "([^,]+)") do
                group = group:gsub("^%s*(.-)%s*$", "%1")
                if group ~= "" then
                    table.insert(new_groups, {name = group, enabled = true})
                end
            end
            if #new_groups > 0 then
                for _, ng in ipairs(new_groups) do
                    local exists = false
                    for _, eg in ipairs(JIMAKU_PREFERRED_GROUPS) do
                        if eg.name:lower() == ng.name:lower() then exists = true break end
                    end
                    if not exists then
                        table.insert(JIMAKU_PREFERRED_GROUPS, ng)
                    end
                end
                debug_log("Updated preferred groups list")
                save_preferred_groups()
                mp.osd_message("Added groups to list", 3)
            end
        end
        -- Always refresh or re-render menu if we were in Management
        if menu_state.active and #menu_state.stack > 0 and menu_state.stack[#menu_state.stack].title == "Preferred Groups" then
            local selected = menu_state.stack[#menu_state.stack].selected
            pop_menu()
            show_preferred_groups_menu(selected)
        else
            render_menu_osd()
        end
    end)
    -- Auto-download subtitles on file load if enabled (works for both local files and streams)
    if JIMAKU_AUTO_DOWNLOAD then
        mp.register_event("file-loaded", function()
    -- 1. Reset state
    menu_state.current_match = nil
    menu_state.jimaku_id = nil
    menu_state.browser_files = nil
    -- 2. Update the internal count/list using the FAST index
    update_loaded_subs_list()
    -- 3. Trigger auto-search if enabled
    if JIMAKU_AUTO_DOWNLOAD then
        mp.add_timeout(0.5, function() search_anilist(true) end)
    end
end)
        debug_log("AniList Script Initialized. Works on local files and streams. Press 'Alt+a' for menu.")
    else
        mp.register_event("file-loaded", update_loaded_subs_list)
        debug_log("AniList Script Initialized. Press 'Alt+a' for menu.")
    end
end