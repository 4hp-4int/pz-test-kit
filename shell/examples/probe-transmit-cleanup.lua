-- Clean up the items spawned by probe-transmit-proof.lua.
local p = getOnlinePlayers() and getOnlinePlayers():size() > 0 and getOnlinePlayers():get(0)
if not p then return "needs a connected player" end

local ids = _G._probeTransmitIds or {}
local lines = {}

local function tryRemoveFromInv(id, label)
    if not id then return end
    local it = p:getInventory():getItemById(id)
    if it then
        p:getInventory():Remove(it)
        table.insert(lines, label .. " removed from player inv")
    else
        table.insert(lines, label .. " NOT in player inv")
    end
end

tryRemoveFromInv(ids.penId,    "pen")
tryRemoveFromInv(ids.pencilId, "pencil")

if ids.worldSqX then
    local sq = getCell():getGridSquare(ids.worldSqX, ids.worldSqY, ids.worldSqZ)
    if sq then
        for i = 0, sq:getObjects():size() - 1 do
            local o = sq:getObjects():get(i)
            local c = o.getContainer and o:getContainer()
            if c then
                for _, probeId in ipairs({ ids.notebookId, ids.paperclipId }) do
                    if probeId then
                        local it = c:getItemById(probeId)
                        if it then
                            c:Remove(it)
                            table.insert(lines, string.format("removed id=%s from world container %s", tostring(probeId), c:getType()))
                        end
                    end
                end
            end
        end
    end
end

_G._probeTransmitIds = nil
if #lines == 0 then table.insert(lines, "nothing to clean up") end
return table.concat(lines, "\n")
