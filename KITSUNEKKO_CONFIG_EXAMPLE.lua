-- KITSUNEKKO MIRROR INTEGRATION - CONFIGURATION EXAMPLE
-- 
-- Add these lines to your jimaku.lua file (around line 70-73) to enable local subtitle support

-- ============================================================================
-- OPTION 1: Windows - Using Direct Path
-- ============================================================================
-- KITSUNEKKO_MIRROR_PATH = "D:\\kitsunekko-mirror\\subtitles"
-- KITSUNEKKO_MIRROR_PATH = "D:\\kitsunekko-mirror\\kitsunekko-mirror\\subtitles"
-- KITSUNEKKO_ENABLED = true
-- KITSUNEKKO_PREFER_LOCAL = false  -- Try Jimaku first, fallback to local


-- ============================================================================
-- OPTION 2: Windows - Using Forward Slashes (also works)
-- ============================================================================
-- KITSUNEKKO_MIRROR_PATH = "D:/kitsunekko-mirror/subtitles"
-- KITSUNEKKO_ENABLED = true
-- KITSUNEKKO_PREFER_LOCAL = true  -- Prefer local subtitles


-- ============================================================================
-- OPTION 3: Linux/macOS
-- ============================================================================
-- KITSUNEKKO_MIRROR_PATH = "/mnt/media/kitsunekko-mirror/subtitles"
-- KITSUNEKKO_ENABLED = true


-- ============================================================================
-- USAGE SCENARIOS
-- ============================================================================

-- Scenario A: Fastest offline access (Prefer Local)
-- KITSUNEKKO_ENABLED = true
-- KITSUNEKKO_PREFER_LOCAL = true
-- → Tries local files first, falls back to Jimaku API if not found

-- Scenario B: Best quality with fallback (Fallback to Local)
-- KITSUNEKKO_ENABLED = true
-- KITSUNEKKO_PREFER_LOCAL = false
-- → Tries Jimaku first for latest/best quality, uses local as backup

-- Scenario C: Only online (Default - Jimaku Only)
-- KITSUNEKKO_ENABLED = false
-- → Uses only Jimaku API, ignores local mirror


-- ============================================================================
-- TESTING THE INTEGRATION
-- ============================================================================
-- 1. Set KITSUNEKKO_MIRROR_PATH to your mirror location
-- 2. Set KITSUNEKKO_ENABLED = true
-- 3. Load jimaku.lua in MPV
-- 4. Press Ctrl+J to open menu
-- 5. Go to Settings → Kitsunekko Mirror → Scan Mirror Now
-- 6. Should show "Indexed X anime entries"
-- 7. Play a video and press 'A' to search
-- 8. If video title matches mirror, subtitles will load from local files
