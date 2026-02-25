# AGENTS.md - Developer Guide for mpv-jimaku-autoload

## Project Overview

This is an mpv script for auto-loading Japanese subtitles (jimaku = 字幕). It queries the AniList API and Jimaku.cc API to find and download subtitles for anime files.

- **Language**: Lua (mpv scripting)
- **Main file**: `jimaku.lua` (~4100 lines)
- **Configuration**: `jimaku.conf`

---

## Build/Lint/Test Commands

### Running Tests

```bash
# Run parser test (standalone mode - parses a file and outputs to parser-debug.log)
lua jimaku.lua --parser data/torrents.txt

# Run simple test (tests get_indexed_subs function)
lua test_simple.lua

# Run get_indexed_subs test
lua test_get_indexed_subs.lua

# Run tests.lua (if using unsort/tests.lua)
lua unsort/tests.lua
```

### Running a Single Test

The test files are standalone Lua scripts. To run a specific test, execute the test file directly:

```bash
# Example: Run parser test on a specific file
lua jimaku.lua --parser /path/to/your/testfile.txt
```

### Debug Output

Debug logs are written to:
- `jimaku.log` (runtime logs)
- `parser-debug.log` (parser test output)

---

## Code Style Guidelines

### File Structure

- **Single-file architecture**: All code in `jimaku.lua` (~4100 lines)
- **Section comments**: Use `--- SECTION NAME` markers for organization
- **Forward declarations**: Declare functions before use when needed (e.g., `local show_main_menu, show_download_menu`)

### Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Constants (globals) | UPPER_SNAKE_CASE | `JIMAKU_API_URL`, `CONFIG_DIR` |
| Global functions | snake_case | `save_config_to_file()`, `update_sub_index()` |
| Local functions | snake_case | `local function parse_media_title()` |
| Variables | snake_case | `local menu_state = {}` |
| Table keys | snake_case | `{name = "Haruhana", enabled = true}` |

### Imports/Modules

```lua
-- Use mpv's require for mpv modules
local utils = require 'mp.utils'

-- Use mp.options for config reading
require("mp.options").read_options(script_opts, "jimaku")

-- Detect standalone vs mpv context
local STANDALONE_MODE = not pcall(function() return mp.get_property("filename") end)
```

### Error Handling

1. **Always use pcall for potentially failing operations**:
```lua
local ok, res = pcall(fn)
if not ok then debug_log("Error: " .. tostring(res), true) end
```

2. **Validate inputs at function boundaries**:
```lua
local function parse_jimaku_filename(filename)
    if not filename then return nil, nil end
    -- ...
end
```

3. **Return error codes + messages**:
```lua
return nil, "MISSING_KEY"  -- or "NETWORK_ERROR", "CACHE_HIT", etc.
```

4. **Log errors with debug_log**:
```lua
debug_log("Error message", true)  -- second arg = is_error
```

### Formatting

- **Indentation**: 4 spaces (no tabs)
- **Line length**: No strict limit, but keep functions reasonably sized
- **String concatenation**: Use `..` for strings
- **Table access**: Use dot notation for string keys: `table.key` not `table["key"]`
- **Function calls**: No spaces before `(`, spaces after keywords: `if condition then`

### Type Annotations

Lua is dynamically typed. Use clear naming and comments for complex types:

```lua
-- Table structures
local menu_state = {
    active = false,
    stack = {},  -- Stack of menu contexts {name, items, selected, scroll_offset}
    current_match = nil,  -- {title, anilist_id, episode, season, ...}
}
```

### Menu System

- Use `push_menu()` and `pop_menu()` for navigation
- Menu items are tables: `{text, hint, disabled, action}`
- Use `show_paginated_menu()` for paginated content
- Bind keys with `mp.add_forced_key_binding()`

### Async Patterns

Use the built-in promise system:

```lua
local function make_request_async(callback)
    return create_promise(function()
        -- do work
        return result
    end, callback)
end
```

### Common Patterns

1. **Configuration loading**:
```lua
local script_opts = {
    jimaku_api_key = "",
    JIMAKU_MAX_SUBS = 10,
}
require("mp.options").read_options(script_opts, "jimaku")
```

2. **Cache management**:
```lua
local function load_persistent_cache(path)
    local f = io.open(path, "r")
    if not f then return {} end
    -- ...
end
```

3. **Directory traversal**:
```lua
local function walk_directory(path)
    local entries = utils.readdir(path, "files")
    -- recursive with base case checks
end
```

### Testing Guidelines

- Create standalone test files that mock `mp` and `utils` globals
- Use `dofile("jimaku.lua")` to load the script in tests
- Check output files for correctness

---

## File Organization (jimaku.lua)

| Lines | Section |
|-------|---------|
| 1-60 | Configuration & Paths |
| 61-150 | Debug Logging |
| 151-210 | Async State & Promise System |
| 211-260 | Cache Utilities |
| 261-330 | API Request Helpers |
| 331-420 | Indexing Utilities |
| 421-510 | Menu System State & Rendering |
| 511-650 | Menu Definitions |
| 651-780 | Paginated Menu System |
| 781-900 | Subtitle Browser |
| 901-1100 | Preferences Menu |
| 1101-1350 | Cache Management |
| 1351-1550 | Configuration Saving |
| 1551-1700 | Episode Calculation |
| 1701-1850 | Filename Parser |
| 1851-2300 | Media Title Parser |
| 2301-2600 | AniList Integration |
| 2601-3000 | Subtitle Matching & Download |
| 3001-3500 | Auto-load & File Scanning |
| 3501-3800 | Search & Menu Integration |
| 3801-4100 | Event Handlers & Initialization |

---

## Key APIs

- **AniList GraphQL**: `https://graphql.anilist.co`
- **Jimaku API**: `https://jimaku.cc/api`
- **mpv commands**: `mp.command_native()`, `mp.add_forced_key_binding()`, `mp.osd_message()`

---

## Configuration File (jimaku.conf)

Place in `~/.config/mpv/script-opts/jimaku.conf`:

```
jimaku_api_key=YOUR_API_KEY
JIMAKU_MAX_SUBS=10
JIMAKU_AUTO_DOWNLOAD=yes
```
