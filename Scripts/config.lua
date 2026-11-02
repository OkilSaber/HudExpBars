-- HudExpBars configuration. Restart the game after editing.
return {
    ENABLED = true,

    -- Position in the HUD's 1920x1080 layout, measured from the anchor. This
    -- layout is drawn curved, so screen positions differ a little near the edges.
    -- Default: top left, beside the party panels and under the native gauges.
    ANCHOR_X = 0.0,      -- 0 = left edge, 0.5 = centre, 1 = right edge
    ANCHOR_Y = 0.0,      -- 0 = top edge, 1 = bottom edge
    OFFSET_X = 214,
    OFFSET_Y = 265,     -- positive = downwards; level with the party panels

    -- The two gauges are stacked.
    GAUGE_WIDTH = 143,
    RAIL_WIDTH = 8,      -- the bracket on the left of each gauge
    GAUGE_GAP = 3,
    BAR_THICKNESS = 8,
    FRAME_PADDING = 5,   -- left and right of the bar
    FRAME_TOP = 11,      -- above the bar: it sits low, like the native ones
    FRAME_BOTTOM = 3,    -- below the bar

    -- Linear colours (as UMG expects), picked to sit next to the native
    -- green / amber / cyan gauges without being mistaken for them.
    EXP_COLOR = { R = 1.00, G = 0.68, B = 0.16, A = 1.0 },     -- warm gold
    WEAPON_COLOR = { R = 0.46, G = 0.31, B = 1.00, A = 1.0 },  -- lavender, like the party icons
    -- Only used if the game's own frame texture cannot be found.
    FRAME_COLOR = { R = 0.061, G = 0.064, B = 0.070, A = 0.85 },

    -- Seconds between refreshes.
    REFRESH_SECONDS = 0.5,
    -- Seconds between checks of the HUD's visibility: short, so fades look smooth.
    VISIBILITY_SECONDS = 0.1,

    DEBUG_LOGS = false,
    -- Logs which HUD widgets appear and disappear. For diagnosis only.
    WATCH_HUD = false,
}
