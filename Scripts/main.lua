-- HudExpBars: hero EXP and weapon proficiency bars on the cockpit HUD.
--
-- Data: RODPlayerState.ExperienceData { HeroLevel, HeroExperience,
-- WeaponLevel, WeaponExperience } (the weapon part follows the equipped
-- weapon), with thresholds from RODPlayerState:GetNextHeroExp(Level) and
-- GetNextWeaponExp(Level).
--
-- Display: plain UMG widgets built at runtime inside WBP_Cockpit's CockpitUI
-- canvas, so they fade with the native HUD. No game asset is replaced.

local MOD_NAME = "HudExpBars"
local MOD_VERSION = "1.7.1"

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function scriptsDir()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    return source:match("^(.*)[\\/][^\\/]+$")
end

local SCRIPTS = scriptsDir()
local CONFIG = dofile(SCRIPTS .. "\\config.lua")

local function dbg(message)
    if CONFIG.DEBUG_LOGS then log(message) end
end

-- UE4SS does not null-check UObject calls: a method on a null object is an
-- access violation pcall cannot catch. Check every UObject before using it.
local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function fullName(object)
    if not valid(object) then return "" end
    local ok, name = pcall(function() return object:GetFullName() end)
    return ok and tostring(name) or ""
end

local function isTemplate(name)
    return name:find("Default__", 1, true) or name:find("SKEL_", 1, true) or name:find("REINST_", 1, true)
end

local classes = {}
local function uclass(path)
    if not valid(classes[path]) then
        local found
        pcall(function() found = StaticFindObject(path) end)
        classes[path] = valid(found) and found or nil
    end
    return classes[path]
end

---------------------------------------------------------------------------
-- Game data
---------------------------------------------------------------------------

local cachedPlayerState = nil

local function findPlayerState()
    if valid(cachedPlayerState) then return cachedPlayerState end
    cachedPlayerState = nil
    local controller
    pcall(function() controller = FindFirstOf("RODInGamePlayerController") end)
    if valid(controller) then
        local state
        pcall(function() state = controller.PlayerState end)
        if valid(state) then cachedPlayerState = state end
    end
    return cachedPlayerState
end

local function toInt(value)
    local number = tonumber(value)
    if number == nil or number ~= number then return nil end
    return math.floor(number + 0.5)
end

local reportedThresholds = {}

-- Returns level, value inside the level, size of the level, isMax.
-- The game may store either the running total or the progress inside the
-- current level; the thresholds tell which one this is.
local function progress(state, level, experience, nextFunction)
    local nextNeeded, previousNeeded
    pcall(function() nextNeeded = toInt(state[nextFunction](state, level)) end)
    pcall(function() previousNeeded = toInt(state[nextFunction](state, level - 1)) end)
    if nextNeeded == nil or nextNeeded <= 0 then
        return level, experience, 0, true
    end
    previousNeeded = previousNeeded or 0
    if not reportedThresholds[nextFunction] then
        -- Logged once so the total-vs-in-level interpretation can be checked.
        reportedThresholds[nextFunction] = true
        log(string.format("%s | level=%d experience=%d previous=%d next=%d",
            nextFunction, level, experience, previousNeeded, nextNeeded))
    end
    if previousNeeded > 0 and previousNeeded < nextNeeded
        and experience >= previousNeeded and experience <= nextNeeded then
        return level, experience - previousNeeded, nextNeeded - previousNeeded, false
    end
    return level, experience, nextNeeded, false
end

local function readData()
    local state = findPlayerState()
    if state == nil then return nil end
    local data
    local ok = pcall(function()
        local raw = state.ExperienceData
        data = {
            heroLevel = toInt(raw.HeroLevel),
            heroExp = toInt(raw.HeroExperience),
            weaponLevel = toInt(raw.WeaponLevel),
            weaponExp = toInt(raw.WeaponExperience),
        }
    end)
    if not ok or data == nil or data.heroLevel == nil or data.heroExp == nil
        or data.weaponLevel == nil or data.weaponExp == nil then
        return nil
    end
    local hero = { progress(state, data.heroLevel, data.heroExp, "GetNextHeroExp") }
    local weapon = { progress(state, data.weaponLevel, data.weaponExp, "GetNextWeaponExp") }
    return { hero = hero, weapon = weapon }
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------

local ui = nil          -- { cockpit, root, bars = { hero = {...}, weapon = {...} } }
local lastShown = {}
local lastCockpitSearch = 0
local buildWarned = false

local function findCockpit()
    local cockpits
    pcall(function() cockpits = FindAllOf("WBP_Cockpit_C") end)
    if type(cockpits) ~= "table" then return nil end
    for _, cockpit in ipairs(cockpits) do
        local name = fullName(cockpit)
        if name:find("/Engine/Transient", 1, true) and not isTemplate(name) then
            return cockpit
        end
    end
    return nil
end

local function widgetName(widget)
    local ok, name = pcall(function() return widget:GetFName():ToString() end)
    return ok and name or ""
end

local function className(widget)
    local class
    pcall(function() class = widget:GetClass() end)
    if not valid(class) then return "" end
    return widgetName(class)
end

-- Breadth-first walk of a widget tree, stepping into nested UserWidgets.
-- Stops at the first widget for which predicate returns true.
local function findWidget(root, predicate, limit)
    local queue, cursor = { root }, 1
    while cursor <= #queue and cursor <= (limit or 600) do
        local current = queue[cursor]
        cursor = cursor + 1
        if valid(current) then
            if predicate(current) then return current end
            local count = 0
            pcall(function() count = current:GetChildrenCount() end)
            for index = 0, count - 1 do
                local child
                pcall(function() child = current:GetChildAt(index) end)
                if valid(child) then queue[#queue + 1] = child end
            end
            local tree, nested
            pcall(function() tree = current.WidgetTree end)
            if valid(tree) then pcall(function() nested = tree.RootWidget end) end
            if valid(nested) then queue[#queue + 1] = nested end
        end
    end
    return nil
end

local function cockpitRoot(cockpit)
    local tree, root
    pcall(function() tree = cockpit.WidgetTree end)
    if valid(tree) then pcall(function() root = tree.RootWidget end) end
    return valid(tree) and tree or nil, valid(root) and root or nil
end

-- CockpitUI holds the native gauges and is drawn through a curved screen
-- material, so living inside it gives the bars the same tilt as their neighbours.
local function findHost(root)
    for _, name in ipairs({ "CockpitUI", "CockpitUIParallel" }) do
        local widget = findWidget(root, function(w) return widgetName(w) == name end, 200)
        if widget ~= nil then return widget, name end
    end
    return root, "root"
end

local function construct(classPath, outer)
    local class = uclass(classPath)
    if class == nil then error("class not found: " .. classPath) end
    local widget = StaticConstructObject(class, outer)
    if not valid(widget) then error("could not construct " .. classPath) end
    return widget
end

local function linear(c, alpha)
    return { R = c.R, G = c.G, B = c.B, A = alpha or c.A }
end

-- A solid rectangle. A nil width or height stretches with the slot.
local function block(tree, color, width, height)
    local box = construct("/Script/UMG.SizeBox", tree)
    if width ~= nil then box:SetWidthOverride(width) end
    if height ~= nil then box:SetHeightOverride(height) end
    local image = construct("/Script/UMG.Image", tree)
    image:SetColorAndOpacity(linear(color))
    box:SetContent(image)
    return box
end

local function place(panel, child, horizontal, vertical, padding)
    local slot = panel:AddChildToOverlay(child)
    slot:SetHorizontalAlignment(horizontal)
    slot:SetVerticalAlignment(vertical)
    if padding ~= nil then
        pcall(function()
            slot:SetPadding({ Left = padding.Left or 0, Top = padding.Top or 0,
                              Right = padding.Right or 0, Bottom = padding.Bottom or 0 })
        end)
    end
    return slot
end

local H_FILL, H_LEFT, H_RIGHT = 0, 1, 3
local V_FILL, V_TOP, V_BOTTOM = 0, 1, 3

-- The game's own gauge, whose textures the frames reuse.
local function findNativeParts(host)
    local parts = {}
    local soul = findWidget(host, function(w) return widgetName(w) == "PlayerUnitGauge_Soul" end)
    if soul == nil then
        log("native gauge not found: the frames fall back to plain colours")
        return parts
    end
    for _, name in ipairs({ "SoulBG", "SoulBG_Back", "SoulGaugeDot", "SPGaugeDeco", "SPGaugeDeco_Back" }) do
        parts[name] = findWidget(soul, function(w) return widgetName(w) == name end, 60)
    end
    -- Inside the "Soul" widget: PlayerUnitGauge_Soul has another "Gauge", a canvas.
    local fill = findWidget(soul, function(w) return widgetName(w) == "Soul" end, 60)
    if fill ~= nil then
        for _, name in ipairs({ "GaugeBG", "Gauge", "GaugeLine" }) do
            parts[name] = findWidget(fill, function(w) return widgetName(w) == name end, 30)
        end
    end
    return parts
end

-- An image showing the same texture as a native one. The brush is rebuilt field
-- by field in this image's own struct: passing the native struct straight to the
-- setter is suspected of having left the game font invisible in v1.1.
local function nativeImage(tree, native)
    local image = construct("/Script/UMG.Image", tree)
    local source = native.Brush
    image:SetBrushFromTexture(source.ResourceObject, false)
    local brush = image.Brush
    brush.DrawAs = source.DrawAs
    for _, side in ipairs({ "Left", "Top", "Right", "Bottom" }) do
        brush.Margin[side] = source.Margin[side]
    end
    image:SetBrush(brush)
    local tint = native.ColorAndOpacity
    image:SetColorAndOpacity({ R = tint.R, G = tint.G, B = tint.B, A = tint.A })
    return image
end

-- A layer copied from a native part, or nothing if it could not be copied.
local function placeNative(panel, tree, native, horizontal, vertical, padding, height)
    if native == nil then return false end
    local ok, image = pcall(nativeImage, tree, native)
    if not ok then
        log("could not copy " .. widgetName(native) .. ": " .. tostring(image))
        return false
    end
    if height == nil then
        place(panel, image, horizontal, vertical, padding)
    else
        local box = construct("/Script/UMG.SizeBox", tree)
        box:SetHeightOverride(height)
        box:SetContent(image)
        place(panel, box, horizontal, vertical, padding)
    end
    return true
end

-- The native fill materials draw over a very wide image and stop at GaugeOffset,
-- a fraction of that width, with their own slanted end. Each layer gets its own
-- material instance: sharing the game's would tie it to the real gauge.
local NATIVE_FILL_WIDTH = 1540

local function placeFillLayer(canvas, tree, native, height, color)
    local image = construct("/Script/UMG.Image", tree)
    image:SetBrushFromMaterial(native.Brush.ResourceObject.Parent)
    local material = image:GetDynamicMaterial()
    if not valid(material) then error("no material instance") end
    local tint = color or native.ColorAndOpacity
    image:SetColorAndOpacity({ R = tint.R, G = tint.G, B = tint.B, A = tint.A })
    local slot = canvas:AddChildToCanvas(image)
    slot:SetPosition({ X = 0, Y = 0 })
    slot:SetSize({ X = NATIVE_FILL_WIDTH, Y = height })
    return material
end

-- One gauge, laid out like the native one with the native textures and fill
-- materials: the left rail, the frame and its offset shadow, the row of dots,
-- and the bar sitting low in the frame.
local function buildGauge(tree, color, native)
    local pad, gap, thickness = CONFIG.FRAME_PADDING, CONFIG.FRAME_TOP, CONFIG.BAR_THICKNESS
    local height = gap + thickness + CONFIG.FRAME_BOTTOM

    local column = construct("/Script/UMG.HorizontalBox", tree)

    local rail = construct("/Script/UMG.SizeBox", tree)
    rail:SetWidthOverride(CONFIG.RAIL_WIDTH)
    rail:SetHeightOverride(height)
    local railPanel = construct("/Script/UMG.Overlay", tree)
    rail:SetContent(railPanel)
    placeNative(railPanel, tree, native.SPGaugeDeco_Back, H_FILL, V_FILL)
    placeNative(railPanel, tree, native.SPGaugeDeco, H_FILL, V_FILL)
    column:AddChildToHorizontalBox(rail)

    local frame = construct("/Script/UMG.SizeBox", tree)
    frame:SetWidthOverride(CONFIG.GAUGE_WIDTH)
    frame:SetHeightOverride(height)
    column:AddChildToHorizontalBox(frame)

    local panel = construct("/Script/UMG.Overlay", tree)
    frame:SetContent(panel)
    placeNative(panel, tree, native.SoulBG_Back, H_FILL, V_FILL, { Left = -2, Top = 2, Right = 1, Bottom = -2 })
    if not placeNative(panel, tree, native.SoulBG, H_FILL, V_FILL) then
        place(panel, block(tree, CONFIG.FRAME_COLOR), H_FILL, V_FILL)
    end
    placeNative(panel, tree, native.SoulGaugeDot, H_FILL, V_TOP, { Left = 2, Top = 3, Right = 3 }, 4)

    local bar = construct("/Script/UMG.Overlay", tree)
    place(panel, bar, H_FILL, V_TOP, { Left = pad, Top = gap, Right = pad })

    local barBox = construct("/Script/UMG.SizeBox", tree)
    barBox:SetHeightOverride(thickness)
    bar:AddChildToOverlay(barBox)
    local canvas = construct("/Script/UMG.CanvasPanel", tree)
    barBox:SetContent(canvas)

    local ok, materials = pcall(function()
        -- The shadow stays at full length: it is the dark trough seen behind a
        -- native gauge that is not full.
        local trough = placeFillLayer(canvas, tree, native.GaugeBG, thickness)
        trough:SetScalarParameterValue(FName("GaugeOffset"),
            (CONFIG.GAUGE_WIDTH - 2 * pad) / NATIVE_FILL_WIDTH)
        return {
            placeFillLayer(canvas, tree, native.Gauge, thickness, color),
            placeFillLayer(canvas, tree, native.GaugeLine, thickness),
        }
    end)
    if ok then return { column = column, materials = materials } end

    log("native fill unavailable, using a plain bar: " .. tostring(materials))
    local fillBox = block(tree, color, 0, thickness)
    canvas:AddChildToCanvas(fillBox):SetAutoSize(true)
    return { column = column, fillBox = fillBox }
end

local function build(cockpit)
    local tree, root = cockpitRoot(cockpit)
    if tree == nil or root == nil then error("cockpit WidgetTree is unavailable") end
    local host, hostName = findHost(root)

    local container = construct("/Script/UMG.VerticalBox", tree)
    local slot = host:AddChildToCanvas(container)
    if not valid(slot) then error("cockpit canvas rejected the bars") end
    slot:SetAnchors({ Minimum = { X = CONFIG.ANCHOR_X, Y = CONFIG.ANCHOR_Y },
                      Maximum = { X = CONFIG.ANCHOR_X, Y = CONFIG.ANCHOR_Y } })
    slot:SetAlignment({ X = CONFIG.ANCHOR_X, Y = CONFIG.ANCHOR_Y })
    slot:SetPosition({ X = CONFIG.OFFSET_X, Y = CONFIG.OFFSET_Y })
    slot:SetAutoSize(true)
    pcall(function() slot:SetZOrder(50) end)
    pcall(function() container:SetVisibility(3) end) -- SelfHitTestInvisible: never eats input

    local native = findNativeParts(host)
    local bars = {
        hero = buildGauge(tree, CONFIG.EXP_COLOR, native),
        weapon = buildGauge(tree, CONFIG.WEAPON_COLOR, native),
    }
    container:AddChildToVerticalBox(bars.hero.column)
    local secondSlot = container:AddChildToVerticalBox(bars.weapon.column)
    pcall(function() secondSlot:SetPadding({ Left = 0, Top = CONFIG.GAUGE_GAP, Right = 0, Bottom = 0 }) end)

    log("bars attached to cockpit " .. hostName)
    return { cockpit = cockpit, root = container, host = host, hostRoot = root, bars = bars }
end

local function ensureUi()
    if ui ~= nil and valid(ui.cockpit) and valid(ui.root) then return ui end
    ui = nil
    lastShown = {}
    local now = os.clock()
    if now - lastCockpitSearch < 2 then return nil end
    lastCockpitSearch = now

    local cockpit = findCockpit()
    if cockpit == nil then return nil end
    local ok, result = pcall(build, cockpit)
    if ok then
        ui = result
        buildWarned = false
    elseif not buildWarned then
        buildWarned = true
        log("could not build bars: " .. tostring(result))
    end
    return ui
end

local function show(key, gauge, values)
    local current, total, isMax = values[2], values[3], values[4]
    local percent = 1
    if not isMax then
        percent = total > 0 and math.max(0, math.min(1, current / total)) or 0
    end
    local signature = math.floor(percent * 1000)
    if lastShown[key] == signature then return end
    lastShown[key] = signature

    local width = (CONFIG.GAUGE_WIDTH - 2 * CONFIG.FRAME_PADDING) * percent
    if gauge.materials ~= nil then
        local offset = width / NATIVE_FILL_WIDTH
        for _, material in ipairs(gauge.materials) do
            local ok, err = pcall(function() material:SetScalarParameterValue(FName("GaugeOffset"), offset) end)
            if not ok then log("could not set the fill: " .. tostring(err)) end
        end
    else
        gauge.fillBox:SetWidthOverride(width)
    end
    dbg(key .. " | " .. current .. " / " .. total)
end

local function update()
    if not CONFIG.ENABLED then return end
    local data = readData()
    if data == nil then return end
    local current = ensureUi()
    if current == nil then return end
    local ok, err = pcall(function()
        show("hero", current.bars.hero, data.hero)
        show("weapon", current.bars.weapon, data.weapon)
    end)
    if not ok then
        log("update failed, rebuilding: " .. tostring(err))
        ui = nil
    end
end

---------------------------------------------------------------------------
-- HUD visibility
---------------------------------------------------------------------------

-- The game hides the cockpit parts one by one (the minimap stays up), so the
-- host canvas never fades. Follow the player's HP gauge instead: it is always
-- on screen while the HUD is shown, unlike the boss or party gauges. The gauge
-- widget itself stays at full opacity: only its contents fade out, see
-- GAUGE_PARTS.
local function isHpGauge(widget)
    return widgetName(widget) == "PlayerUnitGauge_HP"
        or className(widget) == "WBP_PlayerUnitGauge_HP_C"
end

-- The gauge's own root, the gauge, then its parents up to (not including) the
-- host: anything from the host upwards already applies to the bars natively.
local function visibilityChain(gauge, host)
    local chain = {}
    local tree, inner
    pcall(function() tree = gauge.WidgetTree end)
    if valid(tree) then pcall(function() inner = tree.RootWidget end) end
    if valid(inner) then chain[#chain + 1] = inner end

    local hostName = fullName(host)
    local current = gauge
    for _ = 1, 32 do
        if not valid(current) or fullName(current) == hostName then break end
        chain[#chain + 1] = current
        local parent
        pcall(function() parent = current.Slot.Parent end)
        current = parent
    end
    return chain
end

-- What the game fades inside the HP gauge: at 0 in town, where the gauge is hidden.
local GAUGE_PARTS = { "HP", "GaugeDeco" }

local function gaugeParts(gauge)
    local parts = {}
    local tree, inner
    pcall(function() tree = gauge.WidgetTree end)
    if valid(tree) then pcall(function() inner = tree.RootWidget end) end
    if not valid(inner) then return parts end
    for _, name in ipairs(GAUGE_PARTS) do
        local part = findWidget(inner, function(w) return widgetName(w) == name end, 40)
        if part ~= nil then parts[#parts + 1] = part end
    end
    return parts
end

local function widgetOpacity(widget)
    local visible, value = true, 1
    pcall(function() visible = widget:IsVisible() end)
    if visible == false then return 0 end
    pcall(function() value = widget:GetRenderOpacity() end)
    if type(value) ~= "number" then return 1 end
    return math.max(0, math.min(1, value))
end

-- nil when a widget has gone away. The parts count through the most visible
-- one, so a single part kept at 0 by the game cannot hide the bars for good.
local function hudOpacity(chain, parts)
    local opacity = 1
    for _, widget in ipairs(chain) do
        if not valid(widget) then return nil end
        opacity = opacity * widgetOpacity(widget)
    end
    if #parts == 0 then return opacity end
    local brightest = 0
    for _, part in ipairs(parts) do
        if not valid(part) then return nil end
        brightest = math.max(brightest, widgetOpacity(part))
    end
    return opacity * brightest
end

local function syncVisibility()
    local current = ui
    if current == nil or not valid(current.root) then return end

    if current.chain == nil then
        local now = os.clock()
        if now < (current.nextChainSearch or 0) then return end
        current.nextChainSearch = now + 2
        local gauge = findWidget(current.hostRoot, isHpGauge)
        if gauge == nil then
            if not current.chainWarned then
                current.chainWarned = true
                log("HP gauge not found: the bars cannot follow the HUD yet")
            end
            return
        end
        current.chain = visibilityChain(gauge, current.host)
        current.parts = gaugeParts(gauge)
        log("following HUD visibility through " .. #current.chain .. " widgets and "
            .. #current.parts .. " gauge parts")
    end

    local opacity = hudOpacity(current.chain, current.parts)
    if opacity == nil then
        current.chain = nil
        return
    end
    if current.opacity ~= nil and math.abs(current.opacity - opacity) < 0.01 then return end
    local wasShown = current.opacity == nil or current.opacity > 0.001
    if wasShown ~= (opacity > 0.001) or current.opacity == nil then
        log(opacity > 0.001 and "HUD shown" or "HUD hidden")
    end
    current.opacity = opacity
    current.root:SetRenderOpacity(opacity)
    current.root:SetVisibility(opacity > 0.001 and 3 or 2) -- HitTestInvisible / Hidden
    dbg("HUD opacity " .. opacity)
end

-- WATCH_HUD: log every HUD widget that appears or disappears, to see what the
-- game actually changes when it shows or hides the cockpit.
local watchLinesLeft = 300
local function watchHud()
    local current = ui
    if current == nil or not valid(current.host) then return end
    local now = os.clock()
    if now < (current.nextWatch or 0) then return end
    current.nextWatch = now + 0.5

    if current.watched == nil then
        current.watched = {}
        current.watchedHidden = {}
        findWidget(current.host, function(widget)
            current.watched[#current.watched + 1] = widget
            return false
        end, 300)
        log("watch: " .. #current.watched .. " HUD widgets")
    end

    for index, widget in ipairs(current.watched) do
        if valid(widget) then
            local hidden = widgetOpacity(widget) < 0.01
            local previous = current.watchedHidden[index]
            current.watchedHidden[index] = hidden
            if previous ~= nil and previous ~= hidden and watchLinesLeft > 0 then
                watchLinesLeft = watchLinesLeft - 1
                log("watch: " .. (hidden and "HIDE " or "SHOW ") .. widgetName(widget)
                    .. " [" .. className(widget) .. "]")
            end
        end
    end
end

local function tickVisibility()
    syncVisibility()
    if CONFIG.WATCH_HUD then watchHud() end
end

-- Ctrl+F9: what the HUD and the bars look like right now, for the log.
local function describeWidget(widget)
    local visible, opacity, visibility, desired = "?", "?", "?", "?"
    pcall(function() visible = tostring(widget:IsVisible()) end)
    pcall(function() opacity = string.format("%.2f", widget:GetRenderOpacity()) end)
    pcall(function() visibility = tostring(widget:GetVisibility()) end)
    pcall(function()
        local size = widget:GetDesiredSize()
        desired = string.format("%.0fx%.0f", size.X, size.Y)
    end)
    return widgetName(widget) .. " [" .. className(widget) .. "] visible=" .. visible
        .. " vis=" .. visibility .. " opacity=" .. opacity .. " desired=" .. desired
end

local function dumpChildren(widget, depth, maxDepth)
    log(string.rep("  ", depth) .. describeWidget(widget))
    if depth >= maxDepth then return end
    local count = 0
    pcall(function() count = widget:GetChildrenCount() end)
    for index = 0, count - 1 do
        local child
        pcall(function() child = widget:GetChildAt(index) end)
        if valid(child) then dumpChildren(child, depth + 1, maxDepth) end
    end
end

local function dumpHud()
    local current = ui
    if current == nil or not valid(current.host) then
        log("dump: bars are not attached")
        return
    end
    log("=== dump: host children ===")
    dumpChildren(current.host, 0, 1)
    log("=== dump: bars ===")
    if valid(current.root) then dumpChildren(current.root, 0, 3) end
    local slot
    pcall(function() slot = current.root.Slot end)
    if valid(slot) then
        pcall(function()
            local position, alignment = slot:GetPosition(), slot:GetAlignment()
            log(string.format("slot position=(%.0f,%.0f) alignment=(%.2f,%.2f)",
                position.X, position.Y, alignment.X, alignment.Y))
        end)
    end
    log("=== dump: HP gauge chain ===")
    for _, widget in ipairs(current.chain or {}) do
        if valid(widget) then log(describeWidget(widget)) end
    end
    local gauge = findWidget(current.hostRoot, isHpGauge)
    local tree, inner
    if gauge ~= nil then pcall(function() tree = gauge.WidgetTree end) end
    if valid(tree) then pcall(function() inner = tree.RootWidget end) end
    log("=== dump: HP gauge inside ===")
    if valid(inner) then dumpChildren(inner, 0, 3) end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- A world change destroys the cockpit and the player state. Drop the cached
-- pointers before they dangle and pause until the new world has settled.
local pausedUntil = 0
local function onWorldChange()
    ui = nil
    cachedPlayerState = nil
    lastShown = {}
    pausedUntil = os.clock() + 3
end

for _, path in ipairs({
    "/Script/Engine.PlayerController:ClientRestart",
    "/Script/Engine.PlayerController:ClientTravelInternal",
}) do
    pcall(function() RegisterHook(path, onWorldChange) end)
end

-- Both loops stay on the game thread. LoopAsync + ExecuteInGameThread touches
-- the Lua state from two threads: at this rate it corrupted the registry and
-- UE4SS removed the mod's game-thread hook for good, freezing the bars.
local function loopInGame(seconds, callback)
    LoopInGameThreadWithDelay(math.floor(seconds * 1000), function()
        if os.clock() < pausedUntil then return end
        local ok, err = xpcall(callback, debug.traceback)
        if not ok then log("ERROR | " .. tostring(err)) end
    end)
end

loopInGame(CONFIG.REFRESH_SECONDS, update)
loopInGame(CONFIG.VISIBILITY_SECONDS, tickVisibility)

RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local ok, err = xpcall(dumpHud, debug.traceback)
        if not ok then log("ERROR | " .. tostring(err)) end
    end)
end)

local runDiscovery = dofile(SCRIPTS .. "\\discovery.lua")
RegisterKeyBind(Key.F8, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function() runDiscovery("Ctrl+F8") end)
end)

log("loaded v" .. MOD_VERSION)
