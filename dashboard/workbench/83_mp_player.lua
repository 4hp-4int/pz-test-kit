--[[
    SousVide MP: the PLAYER's state crosses the Pass the way the engine moves it.

    The engine owns player state on the SERVER and pushes it to the owning
    client. A write a client makes to its own copy lasts until the next push.
    Source (42.21):
      NetworkPlayerManager.update (server):          every 1 s  NetworkPlayerAI.syncStats ->
          PlayerStats packet: Stats.save + Nutrition.save + timeSinceLastSmoke
          + BodyDamage.saveMainFields (PlayerStatsPacket.write)
                                                     every 2 s  syncDamage (injuries)
                                                     every 0.5 s syncHealth
      syncPlayerStats(player, mask)      SERVER only (LuaManager:9960): the
          masked stats, now (SyncPlayerStatsPacket, bit i = ORDERED_STATS[i])
      sendSyncPlayerFields(player, 2)    SERVER only (:3877): traits
          (SyncPlayerFieldsPacket PF_Traits: CharacterTraits.write/read)
      syncBodyPart(part, params)         SERVER only (:9952): one body part
      sendPlayerStat(player, stat)       CLIENT, and only for a role with
          Capability.CanModifyBodyStats (:9966); the packet requires it, so a
          normal player's client cannot push a stat up at all
    Everything rides the engine's own bytes (PZEngine.bytesSave/bytesLoad).

    Packets:  playerStats (down)   full or masked stats (+ body main fields when full)
              playerTraits (down)  traits
              bodyPart (down)      one part's health / stiffness
              playerStatUp (up)    a client's sendPlayerStat: refused without the capability
              playerHealth (down)  every body part's health        (PlayerHealthPacket, 0.5 s)
              playerDamage (down)  the whole BodyDamage            (PlayerDamagePacket, 2 s)
    Tool:     mpPlayerTick{seconds} on the SERVER: advance its network clock and
              send what NetworkPlayerManager.update would in that time: health
              every 0.5 s, stats every 1 s, damage every 2 s
]]

local try = WB.try
local M = WB.mp

local ORDERED = { "ANGER", "BOREDOM", "DISCOMFORT", "ENDURANCE", "FATIGUE", "FITNESS", "FOOD_SICKNESS", "HUNGER", "IDLENESS",
                  "INTOXICATION", "MORALE", "NICOTINE_WITHDRAWAL", "PAIN", "PANIC", "POISON", "SANITY", "SICKNESS", "STRESS",
                  "TEMPERATURE", "THIRST", "UNHAPPINESS", "WETNESS", "ZOMBIE_FEVER", "ZOMBIE_INFECTION" }

local function pidOf(p) return try(function() return p:getOnlineID() end) end
local function worldVersion() return PZEngine.static("zombie.iso.IsoWorld", "WorldVersion") or 249 end

local function playerByPid(pid)
    if M.role() == "server" then return M.byOnlineID(pid) end
    local me = M.players[1]
    if me and pidOf(me) == pid then return me end
end

-- masked stats as numbers (the masked packet writes each stat's value)
local function maskedStats(player, mask)
    local out = {}
    for i, name in ipairs(ORDERED) do
        if mask == -1 or math.floor(mask / (2 ^ (i - 1))) % 2 == 1 then
            local v = try(function() return player:getStats():get(CharacterStat[name]) end)
            if v then out[name] = v end
        end
    end
    return out
end

local function queueStats(player, mask, why)
    local pid = pidOf(player)
    local pkt = { kind = "playerStats", dir = "down", target = pid and (pid + 1) or nil, pid = pid, mask = mask,
                  module = "player", command = (mask == -1 and "PlayerStats" or "SyncPlayerStats") .. " " .. tostring(why or "") }
    if mask == -1 then
        pkt.stats = PZEngine.bytesSave(player:getStats(), "save")
        pkt.body = PZEngine.bytesSave(player:getBodyDamage(), "saveMainFields")
        pkt.size = math.floor(((pkt.stats and #pkt.stats or 0) + (pkt.body and #pkt.body or 0)) * 3 / 4)
    else
        pkt.values = maskedStats(player, mask)
        pkt.size = 8
    end
    M.queue(pkt)
end

M.installers[#M.installers + 1] = function(role)
    if role == "server" then
        syncPlayerStats = function(player, mask) queueStats(player, mask or -1, "syncPlayerStats") end
        sendSyncPlayerFields = function(player, params)
            local pid = pidOf(player)
            if math.floor((params or 0) / 2) % 2 == 1 then
                M.queue({ kind = "playerTraits", dir = "down", target = pid and (pid + 1) or nil, pid = pid,
                          traits = PZEngine.bytesSave(player:getCharacterTraits(), "write"),
                          module = "player", command = "SyncPlayerFields traits" })
            end
        end
        syncBodyPart = function(part, params)
            local owner = try(function() return part:getParentChar() end)
            local pid = owner and pidOf(owner)
            -- params is BodyPartSyncPacket's field mask (BD_Health = 1, BD_stiffness = 2^40): only those cross
            -- NOT %: Kahlua's % is wrong on numbers near 1e13 (vanilla masks like
            -- 0xFFFFFFFFFFF), so test bits with exact floor arithmetic
            local f = tonumber(params) or 0
            local function bit(v) return v - 2 * math.floor(v / 2) == 1 end
            local hasHealth = bit(f)
            local hasStiff = bit(math.floor(f / 1099511627776))
            M.queue({ kind = "bodyPart", dir = "down", target = pid and (pid + 1) or nil, pid = pid, fields = f,
                      index = try(function() return part:getIndex() end) or try(function() return BodyPartType.ToIndex(part:getType()) end),
                      health = hasHealth and try(function() return part:getHealth() end) or nil,
                      stiffness = hasStiff and try(function() return part:getStiffness() end) or nil,
                      module = "player", command = "BodyPartSync " .. string.format("%.0f", f) })
        end
        sendPlayerStat = function() end   -- client-only in game
    else
        -- the server-only pushes are no-ops on a client (each checks GameServer.server)
        syncPlayerStats = function() end
        sendSyncPlayerFields = function() end
        syncBodyPart = function() end
        sendPlayerStat = function(player, stat)
            M.queue({ kind = "playerStatUp", dir = "up", stat = tostring(stat), pid = pidOf(player),
                      value = try(function() return player:getStats():get(stat) end),
                      module = "player", command = "SyncPlayerStats (client)" })
        end
    end
end

local function result(events) return { listeners = 0, errors = {}, events = events } end

M.handlers.playerStats = function(p)
    local pl = playerByPid(p.pid)
    if not pl then return result({ "no player " .. tostring(p.pid) }) end
    local ev = {}
    if p.mask == -1 then
        local ok, err = PZEngine.bytesLoad(pl:getStats(), "load", p.stats, worldVersion())
        ev[#ev + 1] = ok and "stats loaded (all)" or ("stats load failed: " .. tostring(err))
        if p.body then
            local okb, errb = PZEngine.bytesLoad(pl:getBodyDamage(), "loadMainFields", p.body, worldVersion())
            ev[#ev + 1] = okb and "body main fields loaded" or ("body load failed: " .. tostring(errb))
        end
    else
        for name, v in pairs(p.values or {}) do
            pcall(function() pl:getStats():set(CharacterStat[name], v) end)
            ev[#ev + 1] = name .. " = " .. string.format("%.3f", v)
        end
    end
    return result(ev)
end

M.handlers.playerTraits = function(p)
    local pl = playerByPid(p.pid)
    if not pl then return result({ "no player " .. tostring(p.pid) }) end
    local ok, err = PZEngine.bytesLoad(pl:getCharacterTraits(), "read", p.traits)
    return result({ ok and "traits loaded" or ("traits load failed: " .. tostring(err)) })
end

M.handlers.bodyPart = function(p)
    local pl = playerByPid(p.pid)
    if not pl then return result({ "no player " .. tostring(p.pid) }) end
    local part = try(function() return pl:getBodyDamage():getBodyParts():get(p.index) end)
    if not part then return result({ "no body part " .. tostring(p.index) }) end
    if p.health then pcall(function() part:SetHealth(p.health) end) end
    if p.stiffness then pcall(function() part:setStiffness(p.stiffness) end) end
    return result({ "body part " .. tostring(p.index) .. " health " .. tostring(p.health) .. " stiffness " .. tostring(p.stiffness) })
end

M.handlers.playerStatUp = function(p)
    -- SyncPlayerStatsPacket requires Capability.CanModifyBodyStats; a normal
    -- player's packet is refused (and the anti-cheat treats it as suspicious)
    return result({ "REFUSED: SyncPlayerStats from a client needs CanModifyBodyStats (a normal player has none); server keeps its " ..
                    tostring(p.stat) })
end

local function queueHealth(player)
    local pid = pidOf(player)
    local parts = player:getBodyDamage():getBodyParts()
    local h = {}
    for i = 0, parts:size() - 1 do h[i + 1] = parts:get(i):getHealth() end
    M.queue({ kind = "playerHealth", dir = "down", target = pid and (pid + 1) or nil, pid = pid, health = h,
              size = 4 * #h, module = "player", command = "PlayerHealth periodic" })
end
local function queueDamage(player)
    local pid = pidOf(player)
    local b64 = PZEngine.bytesSave(player:getBodyDamage(), "save")
    M.queue({ kind = "playerDamage", dir = "down", target = pid and (pid + 1) or nil, pid = pid, body = b64,
              module = "player", command = "PlayerDamage periodic" })
end

M.handlers.playerHealth = function(p)
    local pl = playerByPid(p.pid)
    if not pl then return result({ "no player " .. tostring(p.pid) }) end
    local parts = pl:getBodyDamage():getBodyParts()
    for i, v in ipairs(p.health or {}) do pcall(function() parts:get(i - 1):SetHealth(v) end) end
    return result({ "health of " .. #(p.health or {}) .. " body parts loaded" })
end
M.handlers.playerDamage = function(p)
    local pl = playerByPid(p.pid)
    if not pl then return result({ "no player " .. tostring(p.pid) }) end
    local ok, err = PZEngine.bytesLoad(pl:getBodyDamage(), "load", p.body, worldVersion())
    return result({ ok and "body damage loaded" or ("body damage load failed: " .. tostring(err)) })
end

-- the server's network clock (NetworkPlayerManager's UpdateLimits)
M.netClock = M.netClock or { t = 0, lastStats = 0, lastHealth = 0, lastDamage = 0 }
WB.register("mpPlayerTick", function(a)
    if M.role() ~= "server" then error("mpPlayerTick runs on the server (the engine pushes from there)", 0) end
    local secs = tonumber(a and a.seconds) or 1
    local c = M.netClock
    local pushes = 0
    local target = c.t + secs
    while c.lastHealth + 0.5 <= target do
        c.lastHealth = c.lastHealth + 0.5
        for _, pl in ipairs(M.players or {}) do queueHealth(pl); pushes = pushes + 1 end
    end
    while c.lastStats + 1 <= target do
        c.lastStats = c.lastStats + 1
        for _, pl in ipairs(M.players or {}) do queueStats(pl, -1, "periodic"); pushes = pushes + 1 end
    end
    while c.lastDamage + 2 <= target do
        c.lastDamage = c.lastDamage + 2
        for _, pl in ipairs(M.players or {}) do queueDamage(pl); pushes = pushes + 1 end
    end
    c.t = target
    return { t = c.t, pushes = pushes }
end)
