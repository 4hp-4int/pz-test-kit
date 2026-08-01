-- TRANSMIT SEMANTICS EMPIRICAL PROOF
--
-- Three controlled spawns, one per client-visibility mechanism:
--   1. silent   — AddItem only.        Prediction: client NEVER sees it.
--   2. synched  — AddItem + SynchSpawn. Prediction: client SEES it.
--   3. in-place — put into a container the client already has a handle for
--                 (player's own inventory) via SynchSpawn. Prediction: sees it.
--
-- Spawns distinctive items (Base.Pen, Base.Pencil, Base.Notebook) so the
-- user can glance at their inventory/cart/world square and immediately
-- confirm which spawns replicated.
--
-- Items are NOT cleaned up automatically — the user needs to see them first.
-- Re-run probe-transmit-cleanup.lua afterwards to remove them.

local p = getOnlinePlayers() and getOnlinePlayers():size() > 0 and getOnlinePlayers():get(0)
if not p then return "FAIL: needs a connected player" end
local psq = p:getCurrentSquare()
if not psq then return "FAIL: no current square" end

local results = {}

-- === TEST 1: AddItem ONLY (silent spawn into player inventory) ===
-- Into the player's inventory: client has a live ref to this container.
-- If AddItem alone broadcasts, the pen appears. If not, it doesn't.
local pen = instanceItem("Base.Pen")
local penId = nil
if pen then
    p:getInventory():AddItem(pen)
    penId = pen:getID()
    table.insert(results, string.format("1. Base.Pen id=%s — AddItem-only into player inv", tostring(penId)))
else
    table.insert(results, "1. Base.Pen FAILED to instance")
end

-- === TEST 2: AddItem + SynchSpawn (broadcasted spawn into player inventory) ===
-- Same container, but SynchSpawn also fires sendAddItemToContainer.
local pencil = instanceItem("Base.Pencil")
local pencilId = nil
if pencil then
    p:getInventory():AddItem(pencil)
    pencil:SynchSpawn()
    pencilId = pencil:getID()
    table.insert(results, string.format("2. Base.Pencil id=%s — AddItem+SynchSpawn into player inv", tostring(pencilId)))
else
    table.insert(results, "2. Base.Pencil FAILED to instance")
end

-- === TEST 3: AddItem ONLY into a world container the client can see ===
-- Find a shelf / freezer / etc. within radius 3 of the player and dump a
-- notebook in it WITHOUT SynchSpawn. If the client fetches container
-- contents lazily (on first look), a notebook will appear when the user
-- opens that container. If not, it won't.
local worldCont, worldSq
for dy = -3, 3 do
    for dx = -3, 3 do
        local sq = getCell():getGridSquare(psq:getX() + dx, psq:getY() + dy, psq:getZ())
        if sq then
            for i = 0, sq:getObjects():size() - 1 do
                local o = sq:getObjects():get(i)
                local c = o.getContainer and o:getContainer()
                if c then worldCont = c; worldSq = sq; break end
            end
        end
        if worldCont then break end
    end
    if worldCont then break end
end

local notebookId = nil
if worldCont then
    local nb = instanceItem("Base.Notebook")
    if nb then
        worldCont:AddItem(nb)
        notebookId = nb:getID()
        table.insert(results, string.format("3. Base.Notebook id=%s — AddItem-only into %s at (%d,%d)",
            tostring(notebookId), worldCont:getType(), worldSq:getX(), worldSq:getY()))
    else
        table.insert(results, "3. Base.Notebook FAILED to instance")
    end
else
    table.insert(results, "3. SKIPPED: no world container within 3 tiles")
end

-- === TEST 4: AddItem + SynchSpawn into the same world container ===
-- Same container as 3. If SynchSpawn is what broadcasts, this one should
-- visibly appear whereas test 3 stays invisible until the player opens it.
local paperclipId = nil
if worldCont then
    local pc = instanceItem("Base.Paperclip")
    if pc then
        worldCont:AddItem(pc)
        pc:SynchSpawn()
        paperclipId = pc:getID()
        table.insert(results, string.format("4. Base.Paperclip id=%s — AddItem+SynchSpawn into %s at (%d,%d)",
            tostring(paperclipId), worldCont:getType(), worldSq:getX(), worldSq:getY()))
    end
end

table.insert(results, "")
table.insert(results, "CHECK YOUR CLIENT NOW:")
table.insert(results, "  - Inventory: do you see a Pen (test 1) AND a Pencil (test 2)?")
table.insert(results, "    Prediction: only Pencil. Pen is server-only.")
table.insert(results, "  - Open the nearby world container. Do you see Notebook AND Paperclip?")
table.insert(results, "    Prediction: both visible, because opening the container triggers")
table.insert(results, "    a client-side content fetch via RequestItemsForContainer.")

-- Stash IDs so cleanup can find them even if the probe ran long ago.
if not _G._probeTransmitIds then _G._probeTransmitIds = {} end
_G._probeTransmitIds.penId       = penId
_G._probeTransmitIds.pencilId    = pencilId
_G._probeTransmitIds.notebookId  = notebookId
_G._probeTransmitIds.paperclipId = paperclipId
if worldSq then
    _G._probeTransmitIds.worldSqX = worldSq:getX()
    _G._probeTransmitIds.worldSqY = worldSq:getY()
    _G._probeTransmitIds.worldSqZ = worldSq:getZ()
end

return table.concat(results, "\n")
