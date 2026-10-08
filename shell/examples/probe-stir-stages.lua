-- probe-stir-stages.lua: VorpallySauced's stage ladder and Stir capacity on
-- the live dedi (STIR_STAGES.md phases 1-2).
--   ./pz-shell eval -f examples/probe-stir-stages.lua
local out = {}
local function add(s) out[#out + 1] = s end
local VS = VorpallySauced
if not VS then return "VorpallySauced not loaded" end
local G, T = VS.Genome, VS.WeaponTraits
local Mu = G and G.Mutation

add("code: stageOf=" .. tostring(T and T.stageOf ~= nil) .. " getLadderInfo=" .. tostring(T and T.getLadderInfo ~= nil)
    .. " CAPACITY=" .. tostring(Mu and Mu.CAPACITY ~= nil) .. " Families=" .. tostring(G and G.Families ~= nil)
    .. " offers=" .. tostring(Mu and Mu.answer ~= nil))
local sv = SandboxVars.VorpallySauced or {}
add("sandbox: EnableGenome=" .. tostring(sv.EnableGenome) .. " StirChanges=" .. tostring(sv.StirChanges)
    .. " ThresholdMode=" .. tostring(sv.ThresholdMode) .. " families=" .. tostring(sv.StirWeaponBoosts) .. "/"
    .. tostring(sv.StirZombieChance) .. "/" .. tostring(sv.StirZombieControl) .. "/" .. tostring(sv.StirYourCondition))
if Mu and Mu.mode then add("mode: " .. tostring(Mu.mode())) end

local players = getOnlinePlayers()
for i = 0, (players and players:size() or 0) - 1 do
    local p = players:get(i)
    local w = p:getPrimaryHandItem()
    local line = "player " .. tostring(p:getUsername()) .. ": "
    if not (w and instanceof(w, "HandWeapon")) then
        add(line .. "no weapon in hand")
    else
        local d = VS.WeaponData.getModData(w)
        local info = T.getStageInfo(d, w)
        local stage = T.stageOf(d, w)
        local cap = Mu and Mu.capacity(Mu.stageOf(w, d))
        local e = G.Store.entry(w, false)
        local g = e and e[3] and G.Program.unpack(e[3])
        local latent = 0
        for _, x in ipairs((g and g.genes) or {}) do if x.latent then latent = latent + 1 end end
        add(line .. w:getName() .. " | kills " .. tostring(d and d.kills) .. " | affixes "
            .. ((d and d.prefixId) and "M" or "-") .. ((d and d.suffixId) and "B" or "-") .. ((d and d.bondingId) and "X" or "-")
            .. " | stage " .. tostring(info and info.name) .. " (" .. stage .. "/9), next " .. tostring(info and info.nextName)
            .. " at " .. tostring(info and info.nextKills)
            .. " | capacity " .. (cap and (cap.effects .. " effects, grade " .. cap.grade .. ", size x" .. cap.size) or "?")
            .. " | Stir " .. (g and (#(g.programs or {}) .. " effects, " .. latent .. " latent, " .. tostring(g.clock and g.clock.n or 0)
            .. " changes, offer " .. tostring(g.clock and g.clock.offerAt)) or "not born"))
    end
end
return table.concat(out, "\n")
