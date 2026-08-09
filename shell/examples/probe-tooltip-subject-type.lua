-- Reproduce (and then disprove) the 42.20.2 tooltip render crash:
--
--   Lua((MOD:VorpallySauced)).render(Tooltips.lua:1126)
--   java.lang.RuntimeException: Object tried to call nil in render
--
-- Claim under test: `ISToolTipInv.item` is not an InventoryItem field. Vanilla's
-- whole render body is `if self.item then self.item:DoTooltip(self.tooltip) end`,
-- so the contract is "implements DoTooltip". ISFluidBar:activateToolTip and
-- ISEnergyBar:activateToolTip both construct ISToolTipInv with a FluidContainer
-- or energy resource, which has DoTooltip and NO getModData. VPS's legacy hook
-- called getModData() unconditionally.
--
-- Runs in SP (isClient() is false there, so PZShell polls).
--   ./pz-shell eval -f examples/probe-tooltip-subject-type.lua
-- or, on a local client, drop it in Zomboid/Lua/pz-shell/queue.txt.

local out = {}
local function line(s) table.insert(out, s) end

line("VPS version:            " .. tostring(VorpallySauced and VorpallySauced.VERSION))
line("TooltipLib present:     " .. tostring(TooltipLib ~= nil)
    .. "   (legacy hook only installs when this is false)")
line("ISToolTipInv present:   " .. tostring(ISToolTipInv ~= nil))

-- 1. Get a real FluidContainer to use as the tooltip subject. Scan inventory
--    first; if nothing carries one, spawn a water bottle so the probe is
--    self-sufficient. The accessor is getFluidContainerFromSelfOrWorldItem()
--    (InventoryItem.txt:161) — there is no plain getFluidContainer().
local function fluidOf(it)
    local ok, comp = pcall(function() return it:getFluidContainerFromSelfOrWorldItem() end)
    if ok and comp then return comp end
    return nil
end

local subject, subjectWhat
local player = getSpecificPlayer(0)
local inv = player and player:getInventory()
if inv then
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        local comp = fluidOf(it)
        if comp then subject, subjectWhat = comp, it:getName(); break end
    end
    if not subject then
        for _, t in ipairs({ "Base.WaterBottleFull", "Base.Bowl", "Base.Pot" }) do
            local ok, spawned = pcall(function() return inv:AddItem(t) end)
            if ok and spawned then
                local comp = fluidOf(spawned)
                if comp then
                    subject, subjectWhat = comp, spawned:getName() .. " (spawned by probe)"
                    break
                end
            end
        end
    end
end
line("fluid container found:  " .. tostring(subject ~= nil)
    .. (subjectWhat and ("  (from " .. subjectWhat .. ")") or ""))

if not subject then
    line("")
    line("No FluidContainer reachable — could not find or spawn one.")
    return table.concat(out, "\n")
end

-- 2. The contract, measured rather than assumed.
line("subject:DoTooltip:      " .. tostring(subject.DoTooltip ~= nil))
line("subject:getModData:     " .. tostring(subject.getModData ~= nil)
    .. "   <-- the whole bug if false")

-- 3. The pre-fix line, executed verbatim. This is Tooltips.lua:1126 as shipped.
local okOld, errOld = pcall(function()
    local modData = subject:getModData()
    return modData and modData.VorpallySauced_Transfer
end)
line("")
line("PRE-FIX  item:getModData()   -> " .. (okOld and "no error (did NOT reproduce)"
    or ("THREW: " .. tostring(errOld))))

-- 4. The fixed path: the same subject through the guarded helper.
local okNew, resNew = true, nil
local T = VorpallySauced and VorpallySauced.Tooltips
if T and T._test and T._test.transferSnapshot then
    okNew, resNew = pcall(T._test.transferSnapshot, subject)
    line("POST-FIX transferSnapshot()  -> " .. (okNew
        and ("clean, returned " .. tostring(resNew)) or ("THREW: " .. tostring(resNew))))
else
    line("POST-FIX transferSnapshot()  -> helper absent (running pre-fix build)")
end

-- 5. End to end: build the real tooltip the way ISFluidBar does and render it.
--    This exercises whatever ISToolTipInv.render chain is actually installed,
--    including every other mod's wrapper.
if ISToolTipInv then
    local okR, errR = pcall(function()
        local tt = ISToolTipInv:new(subject)
        tt:initialise()
        tt:setCharacter(player)
        tt:render()
    end)
    line("full ISToolTipInv:render -> " .. (okR and "clean" or ("THREW: " .. tostring(errR))))
end

return table.concat(out, "\n")
