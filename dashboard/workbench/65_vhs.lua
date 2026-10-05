--[[
    VHS player: put a tape in a TV and watch what it does to the person in
    front of it.

    The tape registry is the game's own: ZomboidRadio's RecordedMedia, filled
    by vanilla ISRecordedMedia.init walking the global RecMedia table (vanilla
    recorded_media.lua plus every mod's additions), exactly as
    OnInitRecordedMedia does at boot. Playback follows DeviceData.
    updateMediaPlaying (DeviceData.java:1449-1497):
      * the first line comes after prePlayingMedia's 60*maxmod*0.5 counter;
      * each line then holds clamp(len/10*60, 60*minmod, 60*maxmod), the
        counter falling 1.25*multiplier per frame (TV: minmod 1.5, maxmod 5);
      * a line WITH codes fires OnDeviceText(guid, codes, x, y, z, text,
        device) -- IsoWaveSignal.AddDeviceText:199-212 for a set on the map,
        WaveSignalDevice:38-68 (x = y = z = -1) for an equipped device.
    Every OnDeviceText listener runs: vanilla ISRadioInteractions (BOR/STS/
    XP codes, RCP= recipes, the once-per-line isKnownMediaLine guard, the
    5-tile same-floor box, the indoor/outdoor rule) and whatever the mods
    hang there (VorpallySauced's sermon names). Between lines vanilla's own
    cooldown tick runs for the frames the line was on screen, so per-code
    cooldowns clear as they do in game.

    Tools:  vhsTapes{q}                  the registry (id, title, category, lines)
            vhsPlay{id | ref, tv?, dx?, dy?, dz?, volume?, asleep?, forget?, max?}
              tv     ref of a world IsoTelevision/IsoRadio (else: an equipped
                     device, no range or wall checks)
              dx/dy/dz  where the listener stands relative to the set
              forget clear the listener's heard-line memory for this tape first

    HEADLESS STAND-INS, scoped to one play and restored after:
      getSpecificPlayer / getPlayer   the workbench character (the kit's
                                      are mocks) -- listeners loop players 0-3
      getCell                         the real cell (listeners look up squares)
      getGameTime                     the engine's GameTime (vanilla's cooldown
                                      tick reads getMultiplier)
      HaloTextHelper                  RECORDS what the player would see float up
      addXp, getRecipeDisplayName     game globals, only if the VM lacks them
                                      (SP addXp = the local player's AddXP)
      sendClientCommand               recorded (and passed on)
]]

local try = WB.try
local V = WB.vhs or {}
WB.vhs = V

local function radio()
    if WB.tooltip and WB.tooltip.vanilla then WB.tooltip.vanilla() end   -- vanilla EN strings (halo notes, perks)
    if not (ZomboidRadio and RecordedMedia and MediaData) then
        error("this VM's engine bridge does not expose the radio classes yet: restart this mod's VM once (the bridge was updated)", 0)
    end
    local zr = ZomboidRadio.getInstance()
    local rm = zr:getRecordedMedia()
    if not V.registered then
        V.modIds = {}
        for id in pairs(RecMedia or {}) do V.modIds[id] = true end
        WB.vanilla("shared/RecordedMedia/recorded_media")    -- RecMedia = RecMedia or {}: mod tapes survive
        WB.vanilla("shared/RecordedMedia/ISRecordedMedia")
        if rm:getCategories():size() == 0 then ISRecordedMedia.init(rm) end
        V.registered = true
    end
    -- The game's global (LuaManager.GlobalObject.getZomboidRadio); mods call it.
    if not rawget(_G, "getZomboidRadio") then rawset(_G, "getZomboidRadio", function() return zr end) end
    return zr, rm
end

local function listenerSnapshot()
    local s = {}
    for _, fn in ipairs(Events.OnDeviceText._listeners or {}) do s[fn] = true end
    return s
end

-- Vanilla's handler (ISRadioInteractions registers on OnGameBoot, long past
-- here) and every mod module that listens for OnDeviceText. A test run clears
-- listeners between cases, so "wired" is re-checked each play.
local function wireListeners()
    WB.vanilla("shared/RadioCom/ISRadioInteractions")
    local inst = ISRadioInteractions:getInstance()
    local present = listenerSnapshot()
    if not present[inst.OnDeviceText] then Events.OnDeviceText.Add(inst.OnDeviceText) end
    local loaded = {}
    for name, src in pairs(_pz_module_sources or {}) do
        if type(src) == "string" and src:find("OnDeviceText", 1, true) then
            local rec = V.mods and V.mods[name]
            local alive = false
            if rec then for _, fn in ipairs(rec) do if listenerSnapshot()[fn] then alive = true end end end
            if not alive then
                local before = listenerSnapshot()
                _pz_package_loaded[name] = nil
                local ok, e = pcall(require, name)
                local added = {}
                for _, fn in ipairs(Events.OnDeviceText._listeners) do if not before[fn] then added[#added + 1] = fn end end
                V.mods = V.mods or {}
                V.mods[name] = added
                loaded[#loaded + 1] = { module = name, ok = ok, err = (not ok) and tostring(e) or nil, listeners = #added }
            else
                loaded[#loaded + 1] = { module = name, ok = true, listeners = #rec }
            end
        end
    end
    return inst, loaded
end

local function tapeOf(a, rm)
    if a.id and a.id ~= "" then
        local md = rm:getMediaData(a.id)
        if not md then error("no recorded media " .. tostring(a.id)) end
        return md
    end
    if a.ref then
        local it = WB.deref(a.ref)
        if not it then error("item $" .. tostring(a.ref) .. " is gone") end
        if not try(function() return it:isRecordedMedia() end) then
            error(tostring(it:getFullType()) .. " is a BLANK tape (not recorded media): the insert menu would not offer it")
        end
        return it:getMediaData()
    end
    error("pick a tape: id or ref")
end

-- Two string tables in this VM, each holding half: the engine's Java
-- Translator has vanilla's recorded-media strings (RM_<guid>), the Lua
-- getText table the dashboard sends has the mods' (it lacks vanilla RM_).
-- In game one Translator holds both. Take whichever resolves the key.
-- `java` is the engine getter's result (Translator.getText under the hood).
local function tr(key, java)
    if key == nil or key == "" then return nil end
    key = tostring(key)
    if java ~= nil and tostring(java) ~= key then return tostring(java) end
    local l = getText and try(function() return getText(key) end)
    if l and l ~= key then return tostring(l) end
    return key
end

local function rawOf(md) return (RecMedia and RecMedia[tostring(md:getId())]) or {} end

local function titleOf(md)
    local r = rawOf(md)
    return tr(r.title, try(function() return md:getTranslatedTitle() end))
        or tr(r.itemDisplayName, try(function() return md:getTranslatedItemDisplayName() end))
        or tostring(md:getId())
end

local function authorOf(md) return tr(rawOf(md).author, try(function() return md:getTranslatedAuthor() end)) end
local function subtitleOf(md) return tr(rawOf(md).subtitle, try(function() return md:getTranslatedSubTitle() end)) end

local function lineText(line)
    return tr(line:getTextGuid(), try(function() return line:getTranslatedText() end)) or ""
end

WB.register("vhsTapes", function(a)
    local _, rm = radio()
    local q = a.q and a.q:lower() or nil
    local out = {}
    for _, cat in ipairs(WB.list(rm:getCategories())) do
        for _, md in ipairs(WB.list(rm:getAllMediaForCategory(cat))) do
            local id = tostring(md:getId())
            local t = titleOf(md)
            if not q or id:lower():find(q, 1, true) or t:lower():find(q, 1, true) or tostring(cat):lower():find(q, 1, true) then
                out[#out + 1] = { id = id, title = t, category = tostring(cat), lines = md:getLineCount(),
                                  mediaType = md:getMediaType(), mod = V.modIds[id] and true or false,
                                  author = authorOf(md), subtitle = subtitleOf(md) }
            end
        end
    end
    table.sort(out, function(x, y)
        if x.mod ~= y.mod then return x.mod end
        if x.category ~= y.category then return x.category < y.category end
        if x.title ~= y.title then return x.title < y.title end
        return (x.subtitle or "") < (y.subtitle or "")
    end)
    return { tapes = out, count = #out }
end)

-- ── the listener, before and after each line ───────────────────────────────
local STATS = { "BOREDOM", "UNHAPPINESS", "STRESS", "PANIC", "ANGER", "SANITY", "FATIGUE", "ENDURANCE",
                "HUNGER", "THIRST", "PAIN", "SICKNESS", "INTOXICATION", "MORALE" }

local function flatten(t, prefix, out, depth, seen)
    if depth > 5 or seen[t] then return end
    seen[t] = true
    for k, v in pairs(t) do
        local key = prefix .. tostring(k)
        if type(v) == "table" then flatten(v, key .. ".", out, depth + 1, seen)
        else out[key] = tostring(v) end
    end
end

local function snapshot(p)
    local s = { stats = {}, xp = {}, recipes = {}, md = {} }
    local st = p:getStats()
    for _, n in ipairs(STATS) do
        local cs = CharacterStat and CharacterStat[n]
        local v = cs and try(function() return st:get(cs) end)
        if type(v) == "number" then s.stats[n] = v end
    end
    for _, perk in ipairs(WB.list(try(function() return PerkFactory.PerkList end))) do
        local v = try(function() return p:getXp():getXP(perk) end)
        if v then s.xp[tostring(perk)] = v end
    end
    for _, r in ipairs(WB.list(try(function() return p:getKnownRecipes() end))) do s.recipes[tostring(r)] = true end
    local md = try(function() return p:getModData() end)
    if type(md) == "table" then flatten(md, "", s.md, 0, {}) end
    return s
end

local function diff(a, b)
    local d = {}
    for k, v in pairs(b.stats) do local o = a.stats[k] or 0; if math.abs(v - o) > 1e-6 then d[#d + 1] = { kind = "stat", key = k, from = o, to = v } end end
    for k, v in pairs(b.xp) do local o = a.xp[k] or 0; if math.abs(v - o) > 1e-6 then d[#d + 1] = { kind = "xp", key = k, from = o, to = v } end end
    for k in pairs(b.recipes) do if not a.recipes[k] then d[#d + 1] = { kind = "recipe", key = k } end end
    for k, v in pairs(b.md) do if a.md[k] ~= v then d[#d + 1] = { kind = "modData", key = k, from = a.md[k], to = v } end end
    for k, v in pairs(a.md) do if b.md[k] == nil then d[#d + 1] = { kind = "modData", key = k, from = v } end end
    return d
end

-- Records what the game would float over the player's head.
local function haloRecorder(sink)
    local color = { r = 1, g = 1, b = 1, getR = function() return 1 end, getG = function() return 1 end, getB = function() return 1 end }
    return setmetatable({}, { __index = function(_, k)
        if type(k) == "string" and k:match("^add") then
            return function(_, text, _, up) sink[#sink + 1] = { text = tostring(text), kind = k, up = (type(up) == "boolean") and up or nil } end
        end
        return function() return color end
    end })
end

WB.register("vhsPlay", function(a)
    local _, rm = radio()
    local md = tapeOf(a, rm)
    local inst, modules = wireListeners()
    local player = WB.craft.setup()
    local n = md:getLineCount()
    local max = math.min(n, tonumber(a.max) or n)

    if a.forget then
        for i = 0, n - 1 do
            local guid = md:getLine(i):getTextGuid()
            if guid then try(function() player:removeKnownMediaLine(guid) end) end
        end
    end
    if a.asleep ~= nil then try(function() player:setAsleep(a.asleep and true or false) end) end

    -- The set: a real TV on the map, or an equipped device (-1,-1,-1).
    local x, y, z, device, source = -1, -1, -1, nil, { kind = "equipped device (no range, floor or wall checks)" }
    local cell = PZEngine.cell and PZEngine.cell()
    local prevServer = PZEngine.setServer and PZEngine.setServer(true)
    local okSetup, setupErr = pcall(function()
        if a.tv then
            device = WB.deref(a.tv)
            if not device then error("TV $" .. tostring(a.tv) .. " is gone - reload the square") end
            x, y, z = math.floor(device:getX()), math.floor(device:getY()), math.floor(device:getZ())
            local dd = try(function() return device:getDeviceData() end)
            if dd and a.volume then dd:setDeviceVolume(tonumber(a.volume)) end
            local lx, ly, lz = x + (tonumber(a.dx) or 1), y + (tonumber(a.dy) or 0), z + (tonumber(a.dz) or 0)
            local sq = cell:getGridSquare(lx, ly, lz)
            if not sq then error("no square at " .. lx .. "," .. ly .. "," .. lz .. " for the listener") end
            WB.standOn(sq)
            local src = cell:getGridSquare(x, y, z)
            source = { kind = tostring(device:getClass():getSimpleName()), x = x, y = y, z = z,
                       listener = { x = lx, y = ly, z = lz },
                       volumeRange = dd and try(function() return dd:getDeviceVolumeRange() end) or nil,
                       inVanillaBox = math.abs(lx - x) <= 5 and math.abs(ly - y) <= 5 and lz == z,
                       sameSide = src and sq and (src:isOutside() == sq:isOutside()) or nil,
                       sprite = try(function() return tostring(device:getSprite():getName()) end) }
        end
    end)
    if not okSetup then PZEngine.setServer(prevServer); error(setupErr, 0) end

    -- scoped stand-ins
    local saved = { getSpecificPlayer = getSpecificPlayer, getPlayer = getPlayer, getCell = getCell,
                    getGameTime = getGameTime, HaloTextHelper = rawget(_G, "HaloTextHelper"), sendClientCommand = sendClientCommand }
    local halos, commands = {}, {}
    local realGT = PZEngine.gameTime and PZEngine.gameTime()
    getSpecificPlayer = function(i) if i == 0 then return player end return nil end
    getPlayer = function() return player end
    if cell then getCell = function() return cell end end
    if realGT then getGameTime = function() return realGT end end
    local missing = {}
    for name, fn in pairs({
        -- SP addXp is getXp():AddXP(perk, amount) (LuaManager.java:9936), whose
        -- 2-arg form only acts for a LOCAL player and then calls the 5-arg
        -- form (IsoGameCharacter.java:18222-18226). The workbench character
        -- is not registered as local, so call that form directly.
        addXp = function(chr, perk, xp) chr:getXp():AddXP(perk, xp, true, true, false) end,
        getRecipeDisplayName = function(r) return tostring(r) end,
    }) do
        if rawget(_G, name) == nil then rawset(_G, name, fn); missing[#missing + 1] = name end
    end
    if not saved.HaloTextHelper then rawset(_G, "HaloTextHelper", haloRecorder(halos)) end
    sendClientCommand = function(...)
        local args = { ... }
        local off = (type(args[1]) == "string") and 0 or 1   -- (module, cmd, args) or (player, module, cmd, args)
        commands[#commands + 1] = { module = tostring(args[1 + off]), command = tostring(args[2 + off]) }
        if saved.sendClientCommand then return saved.sendClientCommand(...) end
    end

    local mult = (realGT and try(function() return realGT:getMultiplier() end)) or 1
    if mult <= 0 then mult = 1 end
    local MIN, MAX = 60 * 1.5, 60 * 5.0
    local frames = (60 * 5.0 * 0.5) / 1.25          -- prePlayingMedia
    local lines = {}
    local okRun, runErr = pcall(function()
        for i = 0, max - 1 do
            local line = md:getLine(i)
            local text = lineText(line)
            local codes = line:getCodes()
            local guid = line:getTextGuid()
            local hold = #text / 10 * 60
            if hold < MIN then hold = MIN elseif hold > MAX then hold = MAX end
            local rec = { i = i, text = text, r = line:getR(), g = line:getG(), b = line:getB(),
                          codes = codes, guid = guid, at = frames / 60, hold = hold / 1.25 / 60,
                          heardBefore = guid and try(function() return player:isKnownMediaLine(guid) end) or false }
            if codes and codes ~= "" then
                local before = snapshot(player)
                local h0, c0 = #halos, #commands
                local errs = {}
                local list = {}
                for _, fn in ipairs(Events.OnDeviceText._listeners or {}) do list[#list + 1] = fn end
                for _, fn in ipairs(list) do
                    local ok, e = pcall(fn, guid, codes, x, y, z, text, device)
                    if not ok then errs[#errs + 1] = tostring(e) end
                end
                rec.changes = diff(before, snapshot(player))
                rec.halos, rec.commands = {}, {}
                for k = h0 + 1, #halos do rec.halos[#rec.halos + 1] = halos[k] end
                for k = c0 + 1, #commands do rec.commands[#rec.commands + 1] = commands[k] end
                if #errs > 0 then rec.errors = errs end
            end
            lines[#lines + 1] = rec
            -- the line stays on screen; vanilla's cooldowns tick meanwhile
            local f = math.ceil(hold / (1.25 * mult))
            for _ = 1, f do pcall(inst.OnTick) end
            frames = frames + hold / 1.25
        end
    end)

    getSpecificPlayer, getPlayer, getCell, getGameTime = saved.getSpecificPlayer, saved.getPlayer, saved.getCell, saved.getGameTime
    for _, name in ipairs(missing) do rawset(_G, name, nil) end
    if not saved.HaloTextHelper then rawset(_G, "HaloTextHelper", nil) end
    sendClientCommand = saved.sendClientCommand
    if PZEngine.setServer then PZEngine.setServer(prevServer) end
    if not okRun then error(runErr, 0) end

    -- totals across the tape
    local totals = {}
    for _, l in ipairs(lines) do
        for _, c in ipairs(l.changes or {}) do
            local k = c.kind .. ":" .. c.key
            local t = totals[k] or { kind = c.kind, key = c.key, from = c.from, to = c.to }
            t.to = c.to
            totals[k] = t
        end
    end
    local tl = {}
    for _, t in pairs(totals) do tl[#tl + 1] = t end
    table.sort(tl, function(p, q) return p.kind .. p.key < q.kind .. q.key end)

    return { id = tostring(md:getId()), title = titleOf(md), category = tostring(md:getCategory()),
             author = authorOf(md), subtitle = subtitleOf(md),
             lineCount = n, played = #lines, seconds = frames / 60, multiplier = mult,
             source = source, lines = lines, totals = tl, listeners = #(Events.OnDeviceText._listeners or {}),
             modules = modules }
end)
