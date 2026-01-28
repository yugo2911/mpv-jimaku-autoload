-- Detect if running standalone (command line) or in mpv
local STANDALONE_MODE = not pcall(function() return mp.get_property("filename") end)

local utils
if not STANDALONE_MODE then
    utils = require 'mp.utils'
end

-- CONFIGURATION
local CONFIG_DIR
local LOG_FILE
local PARSER_LOG_FILE
local TEST_FILE
local SUBTITLE_CACHE_DIR
local JIMAKU_API_KEY_FILE
local ANILIST_API_URL = "https://graphql.anilist.co"
local JIMAKU_API_URL = "https://jimaku.cc/api"
-- local PAUSE_STATE = false -- re


if STANDALONE_MODE then
    CONFIG_DIR = "."
    LOG_FILE = "./anilist-debug.log"
    PARSER_LOG_FILE = "./parser-debug.log"
    TEST_FILE = "./torrents.txt"
    SUBTITLE_CACHE_DIR = "./subtitle-cache"
    JIMAKU_API_KEY_FILE = "./jimaku-api-key.txt"
else
    CONFIG_DIR = mp.command_native({"expand-path", "~~/"})
    LOG_FILE = CONFIG_DIR .. "/anilist-debug.log"
    PARSER_LOG_FILE = CONFIG_DIR .. "/parser-debug.log"
    TEST_FILE = CONFIG_DIR .. "/torrents.txt"
    SUBTITLE_CACHE_DIR = CONFIG_DIR .. "/subtitle-cache"
    JIMAKU_API_KEY_FILE = CONFIG_DIR .. "/jimaku-api-key.txt"
end

-- Parser configuration
local LOG_ONLY_ERRORS = false

-- Jimaku configuration
local JIMAKU_MAX_SUBS = 5 -- Maximum number of subtitles to download and load (set to "all" to download all available)
local JIMAKU_AUTO_DOWNLOAD = true -- Automatically download subtitles when file starts playing (set to false to require manual key press)
local JIMAKU_PREFERRED_GROUPS = {   -- Preferred loaded filename add wanted pattern SDH, NanakoRaws etc.. order matters
    
    {name = "Nekomoe kissaten", enabled = true},
    {name = "LoliHouse", enabled = true},
    {name = "WEBRip", enabled = true},
    {name = "WEB-DL", enabled = true},
    {name = "WEB", enabled = true},
    {name = "Amazon", enabled = true},
    {name = "AMZN", enabled = true},
    {name = "Netflix", enabled = true},
    {name = "CHS", enabled = false}
}
local JIMAKU_HIDE_SIGNS_ONLY = false
local JIMAKU_ITEMS_PER_PAGE = 6
local JIMAKU_MENU_TIMEOUT = 30  -- Auto-close after seconds
local JIMAKU_FONT_SIZE = 16

-- Jimaku API key (will be loaded from file)
local JIMAKU_API_KEY = ""

-- Episode file cache
local episode_cache = {}

-- On-screen message configuration
local INITIAL_OSD_MESSAGES = false -- if false, suppresses initial OSD messages during startup

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
local debug_log, search_anilist, load_jimaku_api_key, is_archive_file
local show_main_menu, show_subtitles_menu, show_search_menu
local show_info_menu, show_settings_menu, show_cache_menu
local show_ui_settings_menu, show_filter_settings_menu, show_preferred_groups_menu
local show_subtitle_browser, fetch_all_episode_files, logical_sort_files
local parse_jimaku_filename, download_selected_subtitle_action
local show_current_match_info_action, reload_subtitles_action
local download_more_action, clear_subs_action, show_search_results_menu
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
        "menu-search-slash", "menu-filter-f", "menu-clear-x"
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
    
    local ass = mp.get_property_osd("osd-ass-cc/0")
    
    -- Styling
    local style_header = string.format("{\\b1\\fs%d\\c&H00FFFF&}", JIMAKU_FONT_SIZE + 4)
    local style_selected = string.format("{\\b1\\fs%d\\c&H00FF00&}", JIMAKU_FONT_SIZE)
    local style_normal = string.format("{\\fs%d\\c&HFFFFFF&}", JIMAKU_FONT_SIZE)
    local style_disabled = string.format("{\\fs%d\\c&H808080&}", JIMAKU_FONT_SIZE)
    local style_footer = string.format("{\\fs%d\\c&HCCCCCC&}", JIMAKU_FONT_SIZE - 2)
    local style_dim = string.format("{\\fs%d\\c&H888888&}", JIMAKU_FONT_SIZE - 6)
    
    -- Build menu
    ass = ass .. style_header .. title .. "\\N"
    ass = ass .. string.format("{\\fs%d\\c&H808080&}", JIMAKU_FONT_SIZE - 2) .. string.rep("━", 40) .. "\\N"
    
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
handle_menu_up = function()
    if not menu_state.active or #menu_state.stack == 0 then return end
    local context = menu_state.stack[#menu_state.stack]
    context.selected = context.selected - 1
    if context.selected < 1 then context.selected = #context.items end
    render_menu_osd()
end

handle_menu_down = function()
    if not menu_state.active or #menu_state.stack == 0 then return end
    local context = menu_state.stack[#menu_state.stack]
    context.selected = context.selected + 1
    if context.selected > #context.items then context.selected = 1 end
    render_menu_osd()
end

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
push_menu = function(title, items, footer, on_left, on_right, selected)
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
        on_right = on_right
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
        if menu_state.active and menu_state.stack[#menu_state.stack].title:match("Browse Jimaku Subs") then
            mp.osd_message("Enter filter/episode in console", 3)
            mp.commandv("script-message-to", "console", "type", "script-message jimaku-browser-filter ")
        end
    end
    
    mp.add_forced_key_binding("/", "menu-search-slash", trigger_filter)
    mp.add_forced_key_binding("f", "menu-filter-f", trigger_filter)
    mp.add_forced_key_binding("x", "menu-clear-x", function()
        if menu_state.active and menu_state.stack[#menu_state.stack].title:match("Browse Jimaku Subs") then
            apply_browser_filter(nil)
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

-- Menu definitions follow...

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
        if is_archive_file(file.name) then
            handle_archive_file(subtitle_path, "select")
        else
            mp.commandv("sub-add", subtitle_path, "select")
            mp.osd_message("✓ Loaded: " .. file.name, 4)
            -- Update state
            table.insert(menu_state.loaded_subs_files, file.name)
            menu_state.loaded_subs_count = menu_state.loaded_subs_count + 1
        end
        -- Refresh browser to show checkmark
        pop_menu()
        show_subtitle_browser()
    else
        mp.osd_message("Download failed!", 3)
    end
end

-- Main Menu
show_main_menu = function()
    debug_log("Main menu action triggered")
    
    -- If already active, close it first (toggle behavior)
    if menu_state.active then
        debug_log("Menu already active, closing first")
        close_menu()
        return
    end
    
    -- Reset state for a fresh start
    menu_state.stack = {}
    menu_state.active = false
    
    local items = {
        {text = "1. Subtitles      →", action = show_subtitles_menu},
        {text = "2. Search         →", action = show_search_menu},
        {text = "3. Information    →", action = show_info_menu},
        {text = "4. Settings       →", action = show_settings_menu},
        {text = "5. Cache          →", action = show_cache_menu},
    }
    
    push_menu("Jimaku Subtitle Menu", items)
end

-- Subtitles Submenu
show_subtitles_menu = function()
    local items = {
        {text = "1. Browse All Jimaku Subs  →", action = function()
            menu_state.browser_page = nil -- Signal to jump to current episode TODO:FIX THIS
            show_subtitle_browser()
        end},
        {text = "2. Reload Current Subtitles", action = reload_subtitles_action},
        {text = "3. Download More (+5)", action = download_more_action},
        {text = "4. Clear All Loaded", action = clear_subs_action},
        {text = "0. Back to Main Menu", action = pop_menu},
    }
    push_menu("Subtitle Actions", items)
end

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
        local item_text = string.format("{\\fs%d}%d. %s", JIMAKU_FONT_SIZE - 8, display_idx, file.name)
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
        
        -- Primary: Season (if exists)
        if s_a and s_b then
            if s_a ~= s_b then return s_a < s_b end
        elseif s_a then return false -- a has season, b doesn't
        elseif s_b then return true  -- b has season, a doesn't
        end
        
        -- Secondary: Episode (handle both numbers and strings for fractional episodes)
        if e_a and e_b then
            -- Convert both to numbers for comparison
            local num_a = tonumber(e_a)
            local num_b = tonumber(e_b)
            
            if num_a and num_b then
                if num_a ~= num_b then return num_a < num_b end
            elseif num_a then 
                return true -- numeric episode comes before non-numeric
            elseif num_b then 
                return false
            else
                -- Both are non-numeric strings, compare as strings
                if e_a ~= e_b then return tostring(e_a) < tostring(e_b) end
            end
        elseif e_a then return true -- a has episode, b doesn't
        elseif e_b then return false -- b has episode, a doesn't
        end
        
        -- Tertiary: Filename
        return a.name:lower() < b.name:lower()
    end)
end

-- Search Submenu
show_search_menu = function()
    local results_count = #menu_state.search_results
    local results_hint = results_count > 0 and (results_count .. " found") or "No results"
    
    local items = {
        {text = "1. Re-run AniList Search", action = function() search_anilist(); pop_menu() end},
        {text = "2. Browse Search Results", hint = results_hint, disabled = results_count == 0, action = function()
            menu_state.search_results_page = 1
            show_search_results_menu()
        end},
        {text = "3. Manual Title Search", action = nil, disabled = true, hint = "Not Implemented"},
        {text = "0. Back to Main Menu", action = pop_menu},
    }
    push_menu("Search & Selection", items)
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
    local file_year = extract_year(mp.get_property("filename"))
    
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

-- Information Submenu
show_info_menu = function()
    local m = menu_state.current_match
    local match_text = "None"
    if m then
        match_text = string.format("%s (ID: %s)", m.title, m.anilist_id)
    end
    
    local items = {
        {text = "Current Match: ", hint = match_text},
        {text = "1. Show Detailed Match Info", action = show_current_match_info_action},
        {text = "2. View Log File Path", action = function() 
            mp.osd_message("Log: " .. LOG_FILE, 5); pop_menu() 
        end},
        {text = "0. Back to Main Menu", action = pop_menu},
    }
    push_menu("Information", items)
end

-- Settings Submenu
show_settings_menu = function(selected)
    local auto_dl_status = JIMAKU_AUTO_DOWNLOAD and "✓ Enabled" or "✗ Disabled"
    
    local items = {
        {text = "1. Toggle Auto-download", hint = auto_dl_status, action = function()
            JIMAKU_AUTO_DOWNLOAD = not JIMAKU_AUTO_DOWNLOAD
            pop_menu(); show_settings_menu(1)  -- Refresh with same selection
        end},
        {text = "2. Max Subtitles: " .. JIMAKU_MAX_SUBS, action = function()
            if JIMAKU_MAX_SUBS == 1 then JIMAKU_MAX_SUBS = 3
            elseif JIMAKU_MAX_SUBS == 3 then JIMAKU_MAX_SUBS = 5
            elseif JIMAKU_MAX_SUBS == 5 then JIMAKU_MAX_SUBS = 10
            else JIMAKU_MAX_SUBS = 1 end
            pop_menu(); show_settings_menu(2)  -- Refresh with same selection
        end},
        {text = "3. UI & Accessibility  →", action = show_ui_settings_menu},
        {text = "4. Filters & Priority  →", action = show_filter_settings_menu},
        {text = "5. Reload API Key", action = function()
            load_jimaku_api_key()
            pop_menu()
        end},
        {text = "0. Back to Main Menu", action = pop_menu},
    }
    
    push_menu("Settings", items, nil, nil, nil, selected)
end

-- UI Settings Submenu
show_ui_settings_menu = function(selected)
    local items = {
        {text = "1. Items Per Page: " .. JIMAKU_ITEMS_PER_PAGE, action = function()
            if JIMAKU_ITEMS_PER_PAGE == 4 then JIMAKU_ITEMS_PER_PAGE = 6
            elseif JIMAKU_ITEMS_PER_PAGE == 6 then JIMAKU_ITEMS_PER_PAGE = 8
            elseif JIMAKU_ITEMS_PER_PAGE == 8 then JIMAKU_ITEMS_PER_PAGE = 10
            else JIMAKU_ITEMS_PER_PAGE = 4 end
            -- Update current menu state if active
            menu_state.items_per_page = JIMAKU_ITEMS_PER_PAGE
            pop_menu(); show_ui_settings_menu(1)
        end},
        {text = "2. Menu Timeout: " .. JIMAKU_MENU_TIMEOUT .. "s", action = function()
            if JIMAKU_MENU_TIMEOUT == 15 then JIMAKU_MENU_TIMEOUT = 30
            elseif JIMAKU_MENU_TIMEOUT == 30 then JIMAKU_MENU_TIMEOUT = 60
            elseif JIMAKU_MENU_TIMEOUT == 60 then JIMAKU_MENU_TIMEOUT = 0 -- Indefinite?
            else JIMAKU_MENU_TIMEOUT = 15 end
            MENU_TIMEOUT = JIMAKU_MENU_TIMEOUT == 0 and 3600 or JIMAKU_MENU_TIMEOUT
            pop_menu(); show_ui_settings_menu(2)
        end},
        {text = "3. Initial OSD Messages", hint = INITIAL_OSD_MESSAGES and "✓ Enabled" or "✗ Disabled", action = function()
            INITIAL_OSD_MESSAGES = not INITIAL_OSD_MESSAGES
            pop_menu(); show_ui_settings_menu(3)
        end},
        {text = "4. Font Size: " .. JIMAKU_FONT_SIZE, action = function()
            if JIMAKU_FONT_SIZE == 12 then JIMAKU_FONT_SIZE = 16
            elseif JIMAKU_FONT_SIZE == 16 then JIMAKU_FONT_SIZE = 20
            elseif JIMAKU_FONT_SIZE == 20 then JIMAKU_FONT_SIZE = 24
            elseif JIMAKU_FONT_SIZE == 24 then JIMAKU_FONT_SIZE = 28
            else JIMAKU_FONT_SIZE = 12 end
            pop_menu(); show_ui_settings_menu(4)
        end},
        {text = "0. Back to Settings", action = pop_menu},
    }
    push_menu("UI Settings", items, nil, nil, nil, selected)
end

-- Filter Settings Submenu
show_filter_settings_menu = function(selected)
    local signs_status = JIMAKU_HIDE_SIGNS_ONLY and "✓ Hidden" or "✗ Shown"
    local enabled_groups = {}
    for _, g in ipairs(JIMAKU_PREFERRED_GROUPS) do
        if g.enabled then table.insert(enabled_groups, g.name) end
    end
    local groups_str = #enabled_groups > 0 and table.concat(enabled_groups, ", ") or "None"
    
    local items = {
        {text = "1. Hide Signs Only Subs", hint = signs_status, action = function()
            JIMAKU_HIDE_SIGNS_ONLY = not JIMAKU_HIDE_SIGNS_ONLY
            pop_menu(); show_filter_settings_menu(1)
        end},
        {text = "2. Preferred Groups  →", hint = groups_str, action = function()
            show_preferred_groups_menu()
        end},
        {text = "0. Back to Settings", action = pop_menu},
    }
    push_menu("Filter Settings", items, nil, nil, nil, selected)
end

-- Preferred Groups Management Submenu
show_preferred_groups_menu = function(selected)
    local items = {}
    for i, group in ipairs(JIMAKU_PREFERRED_GROUPS) do
        local status = group.enabled and "✓ " or "✗ "
        table.insert(items, {
            text = string.format("%d. %s%s", i, status, group.name),
            action = function()
                group.enabled = not group.enabled
                pop_menu(); show_preferred_groups_menu(i)
            end
        })
    end
    
    table.insert(items, {text = "9. Add New Group", action = function()
        mp.osd_message("Enter groups (comma separated) in console", 3)
        mp.commandv("script-message-to", "console", "type", "script-message jimaku-set-groups ")
    end})
    table.insert(items, {text = "0. Back to Filter Settings", action = pop_menu})
    
    local on_left = function()
        local idx = menu_state.stack[#menu_state.stack].selected
        if idx > 1 and idx <= #JIMAKU_PREFERRED_GROUPS then
            local temp = JIMAKU_PREFERRED_GROUPS[idx]
            JIMAKU_PREFERRED_GROUPS[idx] = JIMAKU_PREFERRED_GROUPS[idx-1]
            JIMAKU_PREFERRED_GROUPS[idx-1] = temp
            pop_menu(); show_preferred_groups_menu(idx - 1)
        end
    end
    
    local on_right = function()
        local idx = menu_state.stack[#menu_state.stack].selected
        if idx >= 1 and idx < #JIMAKU_PREFERRED_GROUPS then
            local temp = JIMAKU_PREFERRED_GROUPS[idx]
            JIMAKU_PREFERRED_GROUPS[idx] = JIMAKU_PREFERRED_GROUPS[idx+1]
            JIMAKU_PREFERRED_GROUPS[idx+1] = temp
            pop_menu(); show_preferred_groups_menu(idx + 1)
        end
    end
    
    local footer = "←/→ Reorder Priority | ENTER Toggle | 0 Back"
    push_menu("Preferred Groups", items, footer, on_left, on_right, selected)
end

-- Cache Submenu
show_cache_menu = function()
    local items = {
        {text = "1. Clear Subtitle Cache", action = function()
            -- Placeholder: requires OS command to delete files in SUBTITLE_CACHE_DIR
            mp.osd_message("Clearing subtitle cache...", 2)
            pop_menu()
        end},
        {text = "2. Clear Memory Episode Cache", action = function()
            episode_cache = {}
            mp.osd_message("Memory cache cleared", 2)
            pop_menu()
        end},
        {text = "0. Back to Main Menu", action = pop_menu},
    }
    push_menu("Cache Management", items)
end

-- Unified logging function
debug_log = function(message, is_error)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local prefix = is_error and "[ERROR] " or "[INFO] "
    local log_msg = string.format("%s %s%s\n", timestamp, prefix, message)
    
    local target_log = STANDALONE_MODE and PARSER_LOG_FILE or LOG_FILE

    if LOG_FILE_HANDLE then
        pcall(function() LOG_FILE_HANDLE:write(log_msg) end)
    else
        local f = io.open(target_log, "a")
        if f then
            f:write(log_msg)
            f:close()
        end
    end

    -- Print to terminal if not suppressed
    local should_log = not LOG_ONLY_ERRORS or is_error
    if should_log then
        print(log_msg:gsub("\n", ""))
    end
end

-- Load Jimaku API key from file
load_jimaku_api_key = function()
    local f = io.open(JIMAKU_API_KEY_FILE, "r")
    if f then
        local key = f:read("*l")
        f:close()
        if key and key:match("%S") then
            JIMAKU_API_KEY = key:match("^%s*(.-)%s*$")  -- Trim whitespace
            debug_log("Jimaku API key loaded from: " .. JIMAKU_API_KEY_FILE)
            return true
        end
    end
    debug_log("Jimaku API key not found. Create " .. JIMAKU_API_KEY_FILE .. " with your API key.", true)
    return false
end

-- Create subtitle cache directory if it doesn't exist
local function ensure_subtitle_cache()
    if STANDALONE_MODE then
        os.execute("mkdir -p " .. SUBTITLE_CACHE_DIR)
    else
        -- Use mpv's subprocess to avoid CMD window flash on Windows
        local is_windows = package.config:sub(1,1) == '\\'
        local args = is_windows and {"cmd", "/C", "mkdir", SUBTITLE_CACHE_DIR} or {"mkdir", "-p", SUBTITLE_CACHE_DIR}
        
        mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = args
        })
    end
end

-------------------------------------------------------------------------------
-- CUMULATIVE EPISODE CALCULATION (FIXED)
-- FIX #9: Better fallback handling with confidence tracking
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
-- FIX #1: Improved pattern ordering and boundary checking
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
-- FIX #3: Improved title extraction with validation
-- HOTFIX: Japanese text, version tags, Part detection
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

-- Main parsing function with all fixes applied
local function parse_filename(filename)
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
    
    -- Strip file extension and path
    local clean_name = filename:gsub("%.%w%w%w?%w?$", "")  -- Remove extension
    clean_name = clean_name:match("([^/\\]+)$") or clean_name  -- Remove path
    
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
        local t, ep, version = content:match("^(.-)%s*[%-%–—]%s*(%d+)(v%d+)")
        if t and ep then
            result.title = t
            result.episode = ep
            result.confidence = "medium-high"
            debug_log(string.format("Detected episode %s with version tag '%s'", ep, version))
        else
            -- Standard dash pattern without version - SUPPORTS HIGH EPISODE NUMBERS
            local t2, ep2 = content:match("^(.-)%s*[%-%–—]%s*(%d+)%s*[%[%(%s]")
            if not t2 then
                t2, ep2 = content:match("^(.-)%s*[%-%–—]%s*(%d+)$")
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
        local t, ep = content:match("^(.-)%s+(%d+)%s*%[")
        if not t then
            t, ep = content:match("^(.-)%s+(%d+)$")
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
    -- Open parser log once to minimize IO overhead during testing
    if PARSER_LOG_FILE then
        local hf = io.open(PARSER_LOG_FILE, "w")
        if hf then hf:close() end
        LOG_FILE_HANDLE = io.open(PARSER_LOG_FILE, "a")
    end

    debug_log("=== PARSER TEST MODE STARTED ===")
    debug_log("Reading from: " .. test_file)
    
    local file = io.open(test_file, "r")
    if not file then
        debug_log("Could not find " .. test_file, true)
        debug_log("Please create the file with torrent filenames (one per line)", true)
        return
    end
    
    local lines = {}
    for line in file:lines() do
        if line:match("%S") then
            table.insert(lines, line)
        end
    end
    file:close()
    
    debug_log(string.format("Processing %d entries", #lines))
    debug_log("")
    
    local results = {}
    local failures = 0
    
    for _, filename in ipairs(lines) do
        local res = parse_filename(filename)
        if res then
            table.insert(results, res)
        else
            failures = failures + 1
        end
    end
    
    debug_log("")
    debug_log("=== PARSER TEST SUMMARY ===")
    debug_log(string.format("Total: %d | Success: %d | Failures: %d", #lines, #results, failures), failures > 0)
    debug_log("Results written to: " .. PARSER_LOG_FILE)
    
    -- Close buffered log handle if opened
    if LOG_FILE_HANDLE then
        pcall(function() LOG_FILE_HANDLE:close() end)
        LOG_FILE_HANDLE = nil
    end

    return results, failures
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
    if not JIMAKU_API_KEY or JIMAKU_API_KEY == "" then
        debug_log("Jimaku API key not configured - skipping subtitle search", false)
        return nil
    end
    
    debug_log(string.format("Searching Jimaku for AniList ID: %d", anilist_id))
    
    -- Search for entry by AniList ID
    local search_url = string.format("%s/entries/search?anilist_id=%d&anime=true", 
        JIMAKU_API_URL, anilist_id)
    
    local args = {
        "curl", "-s", "-X", "GET",
        "-H", "Authorization: " .. JIMAKU_API_KEY,
        search_url
    }
    
    local result = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = args
    })
    
    if result.status ~= 0 or not result.stdout then
        debug_log("Jimaku search request failed", true)
        return nil
    end
    
    local ok, entries = pcall(utils.parse_json, result.stdout)
    if not ok or not entries or #entries == 0 then
        debug_log("No Jimaku entries found for AniList ID: " .. anilist_id, false)
        return nil
    end
    
    debug_log(string.format("Found Jimaku entry: %s (ID: %d)", entries[1].name, entries[1].id))
    return entries[1]
end

-- Fetch ALL subtitle files for an entry (no episode filter)
fetch_all_episode_files = function(entry_id)
    -- Check cache first
    if episode_cache[entry_id] then
        local cache_age = os.time() - episode_cache[entry_id].timestamp
        if cache_age < 300 then  -- Cache valid for 5 minutes
            debug_log(string.format("Using cached file list for entry %d (%d files)", entry_id, #episode_cache[entry_id].files))
            return episode_cache[entry_id].files
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
    episode_cache[entry_id] = {
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
                    confidence = title_match and "medium-high" or "low"
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

-- Helper to check if a file is a compressed archive
is_archive_file = function(filename)
    if not filename then return false end
    local ext = filename:match("%.([^%.]+)$")
    if not ext then return false end
    ext = ext:lower()
    return ext == "zip" or ext == "rar" or ext == "7z" or ext == "tar" or ext == "gz"
end

-- Extract and load subtitles from an archive
handle_archive_file = function(archive_path, default_flag)
    debug_log("Handling archive: " .. archive_path)
    
    -- Create a unique extraction directory based on filename
    local filename = archive_path:match("([^/\\%.]+)%.[^%.]+$") or "extracted"
    local extract_dir = SUBTITLE_CACHE_DIR .. "/extracted_" .. filename .. "_" .. os.time()
    
    -- Create directory
    if STANDALONE_MODE then
        os.execute("mkdir -p \"" .. extract_dir .. "\"")
    else
        mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = {"mkdir", extract_dir}
        })
    end
    
    -- Extract using tar (cross-platform)
    -- Note: tar on Windows 10+ supports zip, 7z, rar (if libarchive is present), and tar
    debug_log("Extracting to: " .. extract_dir)
    local tar_args = {"tar", "-xf", archive_path, "-C", extract_dir}
    
    local extract_result
    if STANDALONE_MODE then
        local cmd = table.concat(tar_args, " ")
        extract_result = {status = os.execute(cmd) and 0 or 1}
    else
        extract_result = mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = tar_args
        })
    end
    
    if extract_result.status == 0 then
        debug_log("Extraction successful, scanning for subtitles...")
        
        -- Scan extracted directory for subtitle files
        local files = utils.readdir(extract_dir, "files")
        local loaded_count = 0
        
        if files then
            for _, f in ipairs(files) do
                local ext = f:match("%.([^%.]+)$")
                if ext then
                    ext = ext:lower()
                    if ext == "ass" or ext == "srt" or ext == "vtt" or ext == "sub" then
                        local sub_path = extract_dir .. "/" .. f
                        -- If more than one sub in archive, only select the first one encountered
                        local flag = (loaded_count == 0) and (default_flag or "auto") or "auto"
                        
                        debug_log(string.format("Found internal sub: %s (flag: %s)", f, flag))
                        mp.commandv("sub-add", sub_path, flag)
                        loaded_count = loaded_count + 1
                        
                        -- Track for menu
                        table.insert(menu_state.loaded_subs_files, f)
                    end
                end
            end
        end
        
        if loaded_count > 0 then
            mp.osd_message(string.format("✓ Extracted & loaded %d subtitle(s)", loaded_count), 4)
            menu_state.loaded_subs_count = menu_state.loaded_subs_count + loaded_count
            return true
        else
            debug_log("No subtitle files found inside archive", true)
            mp.osd_message("Archive contains no subtitles!", 4)
            return false
        end
    else
        debug_log("Extraction failed with status: " .. tostring(extract_result.status), true)
        mp.osd_message("Failed to extract archive!", 4)
        return false
    end
end

-- New helper to track currently loaded subtitles from track-list
local function update_loaded_subs_list()
    local tracks = mp.get_property_native("track-list")
    menu_state.loaded_subs_files = {}
    menu_state.loaded_subs_count = 0
    for _, track in ipairs(tracks) do
        if track.type == "sub" and track.external then
            -- Use filename from path
            local filename = track.external_filename or track.title or track.id
            table.insert(menu_state.loaded_subs_files, filename)
            menu_state.loaded_subs_count = menu_state.loaded_subs_count + 1
        end
    end
end

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
-- FIX #10: Improved priority system with conflict resolution
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
    if not has_explicit_season and episode_num > (selected.episodes or 0) then
        debug_log("Episode number exceeds S1 count - attempting cumulative calculation")
        
        -- Build season list
        for i, media in ipairs(results) do
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
search_anilist = function(is_auto)
    local filename = mp.get_property("filename")
    if not filename then return end

    local parsed = parse_filename(filename)
    if not parsed then
        conditional_osd("AniList: Failed to parse filename", 3, is_auto)
        return
    end
    
    -- Get clean search title (removes "Special", "OVA" etc for better matching)
    local search_title = get_search_title(parsed)
    
    if search_title ~= parsed.title then
        debug_log(string.format("Search title cleaned: '%s' → '%s'", parsed.title, search_title))
    end

    conditional_osd("AniList: Searching for " .. search_title .. "...", 3, is_auto)

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

    local data = make_anilist_request(query, {search = search_title})
    
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

        -- Add warning for low confidence matches
        if match_confidence == "very-low" then
            osd_msg = osd_msg .. "\n⚠⚠ VERY LOW CONFIDENCE - Likely WRONG match!"
        elseif match_confidence == "low" or match_confidence == "uncertain" then
            osd_msg = osd_msg .. "\n⚠ Low confidence - verify result"
        end
        
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
        end
    else
        debug_log("FAILURE: No matches found for " .. parsed.title, true)
        conditional_osd("AniList: No match found.", 3, is_auto)
    end
end

-- Initialize
if not STANDALONE_MODE then
    -- Create subtitle cache directory
    ensure_subtitle_cache()
    
    -- Load Jimaku API key
    load_jimaku_api_key()
    
    -- Keybind 'A' to trigger the search
    mp.add_key_binding("A", "anilist-search", search_anilist)
    
    -- Keyboard triggers for menu system (using standard bindings for script permanence)
    mp.add_key_binding("ctrl+j", "jimaku-menu-ctrl-j", show_main_menu)
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
    
    -- Auto-download subtitles on file load if enabled
    if JIMAKU_AUTO_DOWNLOAD then
        mp.register_event("file-loaded", function()
            -- Reset menu state on new file
            menu_state.current_match = nil
            menu_state.jimaku_id = nil
            menu_state.browser_files = nil
            update_loaded_subs_list()
            
            -- Small delay to ensure file is ready
            mp.add_timeout(0.5, function() search_anilist(true) end)
        end)
        debug_log("AniList Script Initialized. Press 'Ctrl+j' or 'Alt+a' for menu.")
    else
        mp.register_event("file-loaded", update_loaded_subs_list)
        debug_log("AniList Script Initialized. Press 'Ctrl+j' or 'Alt+a' for menu.")
    end
end