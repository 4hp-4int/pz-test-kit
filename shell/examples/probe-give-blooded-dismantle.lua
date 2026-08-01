-- Hand the connected player a controlled Blooded Axe + Hatchet (HandAxe) so we
-- can dismantle them in the real craft UI and watch the CraftTransfer hook fire
-- end-to-end (DIAG lines land in the server debug log).
local players = getOnlinePlayers()
if not players or players:size() == 0 then return "NO PLAYER CONNECTED — log onto the dedi first, then re-run." end

local player = players:get(0)
local WD = VorpallySauced.WeaponData
local SM = VorpallySauced.StatModifiers
local inv = player:getInventory()
local out = {}

local function giveBlooded(ft, kills)
  local w = inv:AddItem(ft)
  if not w then table.insert(out, "AddItem FAILED: " .. ft); return end
  local d = WD.getOrCreateModData(w)
  d.kills = kills
  d.isFirearm = false
  d.prefixThreshold, d.suffixThreshold, d.bondingThreshold = 0, 0, 0
  d.prefixId, d.suffixId, d.bondingId = 1, 1, 1   -- bondingId set => Blooded (the transfer gate)
  SM.reapplyUpgrades(w)
  local H = SM and SM.Helpers
  if H and H.rebuildWeaponName then pcall(function() H.rebuildWeaponName(w) end) end
  if syncItemModData then pcall(function() syncItemModData(player, w) end) end
  if syncHandWeaponFields then pcall(function() syncHandWeaponFields(player, w) end) end
  if syncItemFields then pcall(function() syncItemFields(player, w) end) end
  local md = WD.getModData(w)
  table.insert(out, string.format("gave %s  id=%s  name=%s  bondingId=%s  kills=%s",
    ft, tostring(w:getID()), tostring(w:getName()), tostring(md and md.bondingId), tostring(md and md.kills)))
end

giveBlooded("Base.Axe", 500)       -- DismantleLongImplement -> FireAxeHead + LongHandle_Broken
giveBlooded("Base.HandAxe", 500)   -- DismantleShortImplement -> HandAxeHead (no handle)
table.insert(out, "Dismantle BOTH in the craft menu (search 'dismantle'). Then I'll read the log.")
return table.concat(out, "\n")
