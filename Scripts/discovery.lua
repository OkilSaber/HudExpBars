-- HudExpBars discovery tool (Ctrl+F8, bound in main.lua).
-- Finds where the game keeps hero EXP and weapon proficiency, and how the
-- cockpit HUD is laid out, then writes everything to ../discovery.txt.
-- Kept to re-check the game data after a game update.

local MOD_NAME = "HudExpBars"
local MOD_VERSION = "discovery"

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function modDir()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    local scripts = source:match("^(.*)[\\/][^\\/]+$")
    return scripts:match("^(.*)[\\/][^\\/]+$")
end

local OUT_PATH = modDir() .. "\\discovery.txt"
local out = nil
local runs = 0

local function emit(line)
    if out ~= nil then
        out:write(line, "\n")
        -- The Windows CRT treats line buffering as full buffering, so flush by
        -- hand: a crash must still leave the lines written so far.
        out:flush()
    end
end

local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

-- UE4SS does not null-check: GetFName() on a null UObject (a class with no
-- super, an unset struct) reads address 0x18 and kills the game, which pcall
-- cannot catch. Every UObject must go through valid() first.
local function fname(object)
    if not valid(object) then return "null" end
    local ok, name = pcall(function() return object:GetFName():ToString() end)
    return ok and name or "?"
end

-- FProperty is not a UObject and has no IsValid; ForEachProperty never hands
-- out a null one.
local function propName(property)
    local ok, name = pcall(function() return property:GetFName():ToString() end)
    return ok and name or "?"
end

local function fullName(object)
    if not valid(object) then return "null" end
    local ok, name = pcall(function() return object:GetFullName() end)
    return ok and tostring(name) or "?"
end

local EXCLUDE = { "expan", "expir", "expr", "export", "expect", "expl", "expo", "exps" }
local INCLUDE = { "exp", "proficien", "weaponlevel", "herolevel", "currentlevel", "growthpoint" }

local function interesting(name)
    local lower = name:lower()
    if lower == "level" then return true end
    for _, word in ipairs(EXCLUDE) do
        if lower:find(word, 1, true) then
            -- "experience" contains "expe", not an excluded prefix; keep it.
            if not lower:find("experience", 1, true) then return false end
        end
    end
    for _, word in ipairs(INCLUDE) do
        if lower:find(word, 1, true) then return true end
    end
    return false
end

local function propertyType(property)
    local typeName = "?"
    pcall(function() typeName = property:GetClass():GetFName():ToString() end)
    if typeName == "StructProperty" then
        pcall(function() typeName = typeName .. "<" .. fname(property:GetStruct()) .. ">" end)
    elseif typeName == "ObjectProperty" then
        pcall(function() typeName = typeName .. "<" .. fname(property:GetPropertyClass()) .. ">" end)
    end
    return typeName
end

local function listProperties(struct)
    local list = {}
    pcall(function()
        struct:ForEachProperty(function(property)
            list[#list + 1] = { name = propName(property), type = propertyType(property), raw = property }
        end)
    end)
    return list
end

-- Formats a property value read from a live object, one struct level deep.
local function describeValue(value, depth)
    local kind = type(value)
    if kind == "number" or kind == "boolean" or kind == "string" or kind == "nil" then
        return tostring(value)
    end
    local ok, text = pcall(function() return value:ToString() end)
    if ok and type(text) == "string" then return '"' .. text .. '"' end
    local okNum, count = pcall(function() return value:GetArrayNum() end)
    if okNum and type(count) == "number" then return "TArray[" .. count .. "]" end
    if valid(value) then return fullName(value) end
    return "<" .. kind .. ">"
end

local function describeStruct(value, struct)
    local parts = {}
    for _, field in ipairs(listProperties(struct)) do
        local okField, fieldValue = pcall(function() return value[field.name] end)
        parts[#parts + 1] = field.name .. "=" .. (okField and describeValue(fieldValue) or "ERR")
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

-- Walking GUObjectArray with ForEachUObject crashed the game (null class on a
-- half-built object), so only look up the native ROD types by name instead.
local CANDIDATES = dofile(modDir() .. "\\Scripts\\candidates.lua")

local function discoverReflection()
    local matchedClasses = {}
    local structs = {}
    local functions = {}
    local found = 0

    for _, shortName in ipairs(CANDIDATES) do
        local object
        pcall(function() object = StaticFindObject("/Script/ROD." .. shortName) end)
        if valid(object) then
            found = found + 1
            -- Breadcrumb: if the game dies here, the last line names the type.
            emit("  scanning " .. shortName)
            local kind = fname(object:GetClass())
            local name = fullName(object)
            if kind == "ScriptStruct" and interesting(shortName) then
                structs[#structs + 1] = object
            elseif kind == "Class" or kind == "ScriptStruct" then
                local hits = {}
                for _, property in ipairs(listProperties(object)) do
                    if interesting(property.name) then hits[#hits + 1] = property end
                end
                if #hits > 0 then
                    matchedClasses[#matchedClasses + 1] = { object = object, name = name, short = shortName, hits = hits }
                end
                if kind == "Class" then
                    pcall(function()
                        object:ForEachFunction(function(func)
                            if interesting(fname(func)) then functions[#functions + 1] = func end
                        end)
                    end)
                end
            end
        end
    end

    emit("candidate names: " .. #CANDIDATES .. " | found: " .. found)
    emit("")
    emit("== CLASSES WITH MATCHING PROPERTIES ==")
    for _, entry in ipairs(matchedClasses) do
        local super = "?"
        pcall(function() super = fname(entry.object:GetSuperStruct()) end)
        emit(entry.name .. "  (super " .. super .. ")")
        for _, property in ipairs(entry.hits) do
            emit("    " .. property.name .. " : " .. property.type)
        end
    end

    emit("")
    emit("== MATCHING STRUCTS (all fields) ==")
    for _, struct in ipairs(structs) do
        emit(fullName(struct))
        for _, field in ipairs(listProperties(struct)) do
            emit("    " .. field.name .. " : " .. field.type)
        end
    end

    emit("")
    emit("== MATCHING FUNCTIONS (params) ==")
    for _, func in ipairs(functions) do
        local params = {}
        for _, param in ipairs(listProperties(func)) do
            params[#params + 1] = param.name .. ":" .. param.type
        end
        emit(fullName(func) .. " (" .. table.concat(params, ", ") .. ")")
    end

    return matchedClasses
end

local function dumpLiveValues(matchedClasses)
    emit("")
    emit("== LIVE VALUES ==")
    for _, entry in ipairs(matchedClasses) do
        local okAll, instances = pcall(function() return FindAllOf(entry.short) end)
        if okAll and type(instances) == "table" then
            local shown = 0
            for _, instance in ipairs(instances) do
                local name = fullName(instance)
                if shown < 3 and valid(instance) and not name:find("Default__", 1, true) then
                    shown = shown + 1
                    emit(name)
                    for _, property in ipairs(entry.hits) do
                        local okValue, value = pcall(function() return instance[property.name] end)
                        local text
                        if not okValue then
                            text = "ERR"
                        elseif property.type:find("^StructProperty") then
                            local struct
                            pcall(function() struct = property.raw:GetStruct() end)
                            text = valid(struct) and describeStruct(value, struct) or describeValue(value)
                        else
                            text = describeValue(value)
                        end
                        emit("    " .. property.name .. " = " .. text)
                    end
                end
            end
        end
    end
end

local function dumpWidget(widget, depth, maxDepth)
    if not valid(widget) or depth > maxDepth then return end
    local line = string.rep("  ", depth) .. fname(widget) .. " [" .. fname(widget:GetClass()) .. "]"
    pcall(function()
        local slot = widget.Slot
        if valid(slot) and fname(slot:GetClass()) == "CanvasPanelSlot" then
            local p, s, a = slot:GetPosition(), slot:GetSize(), slot:GetAlignment()
            local anchors = slot:GetAnchors()
            line = line .. string.format(" pos=(%.0f,%.0f) size=(%.0f,%.0f) align=(%.2f,%.2f) anchors=(%.2f,%.2f)-(%.2f,%.2f)",
                p.X, p.Y, s.X, s.Y, a.X, a.Y, anchors.Minimum.X, anchors.Minimum.Y, anchors.Maximum.X, anchors.Maximum.Y)
        end
    end)
    pcall(function() line = line .. " vis=" .. tostring(widget:GetVisibility()) end)
    emit(line)
    local count = 0
    pcall(function() count = widget:GetChildrenCount() end)
    for index = 0, count - 1 do
        local child
        pcall(function() child = widget:GetChildAt(index) end)
        dumpWidget(child, depth + 1, maxDepth)
    end
end

local function dumpCockpit()
    emit("")
    emit("== COCKPIT WIDGET TREE ==")
    local okAll, cockpits = pcall(function() return FindAllOf("WBP_Cockpit_C") end)
    if not okAll or type(cockpits) ~= "table" then
        emit("no WBP_Cockpit_C instance")
        return
    end
    for _, cockpit in ipairs(cockpits) do
        local name = fullName(cockpit)
        if valid(cockpit) and name:find("/Engine/Transient", 1, true) then
            emit(name)
            local root
            local tree
            pcall(function() tree = cockpit.WidgetTree end)
            if valid(tree) then pcall(function() root = tree.RootWidget end) end
            dumpWidget(root, 1, 4)
            return
        end
    end
    emit("no live WBP_Cockpit_C instance")
end

local function runDiscovery(reason)
    local okOpen, file = pcall(io.open, OUT_PATH, runs == 0 and "w" or "a")
    if not okOpen or file == nil then
        log("cannot write " .. OUT_PATH)
        return
    end
    out = file
    runs = runs + 1
    emit(string.format("##### %s %s | run %d | %s | %s #####", MOD_NAME, MOD_VERSION, runs, reason, os.date("%Y-%m-%d %H:%M:%S")))
    local ok, err = xpcall(function()
        local matched = discoverReflection()
        dumpLiveValues(matched)
        dumpCockpit()
    end, debug.traceback)
    if not ok then emit("ERROR: " .. tostring(err)) end
    emit("")
    out:close()
    out = nil
    log("discovery run " .. runs .. " written to " .. OUT_PATH .. (ok and "" or " (with errors)"))
end

return runDiscovery
