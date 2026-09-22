-- probe-sermon-heal.lua
-- Live dedi verification of the blank-sermon-tape self-heal (VPS f056363).
-- Walks the whole chain the field bug lives on: registry registration,
-- stamping a factually blank tape, and the healTapes walk + idempotence.
-- Run: ./pz-shell eval -f examples/probe-sermon-heal.lua

local out = {}
local function say(s) out[#out + 1] = s end

local Sermon = VorpallySauced and VorpallySauced.Sermon
if not (Sermon and Sermon.stampTape and Sermon.healTapes) then
    return "FAIL: VorpallySauced.Sermon incomplete (healTapes deployed? server restarted?)"
end

-- 1. Registry: all three sermons registered on this machine, with indexes.
local rm = getZomboidRadio() and getZomboidRadio():getRecordedMedia()
if not rm then return "FAIL: no RecordedMedia registry" end
for fullType, mediaId in pairs(Sermon.TAPE_MEDIA) do
    local data = rm:getMediaData(mediaId)
    if not data then
        say("REGISTRY FAIL: " .. mediaId .. " not registered")
    else
        say("registry ok: " .. mediaId .. " index=" .. tostring(data:getIndex()))
    end
end

-- 2. A factory-fresh tape is blank (the Item List Viewer / unstamped-spawn
--    state), and stampTape repairs it.
local tape = instanceItem("VorpallySauced.SermonTapeI")
if not tape then return "FAIL: cannot mint SermonTapeI (scripts loaded?)" end
say("fresh tape blank=" .. tostring(not tape:isRecordedMedia()))
local stamped = Sermon.stampTape(tape)
say("stampTape=" .. tostring(stamped)
    .. " recorded=" .. tostring(tape:isRecordedMedia())
    .. " index=" .. tostring(tape:getRecordedMediaIndex())
    .. " mediaType=" .. tostring(tape:getMediaType()))

-- 3. healTapes walk over a carrier holding one blank tape: heals exactly it,
--    and a second pass heals nothing (idempotence).
local tape2 = instanceItem("VorpallySauced.SermonTapeII")
local held = { ["VorpallySauced.SermonTapeII"] = { tape2 } }
local carrier = {
    getInventory = function()
        return {
            getAllTypeRecurse = function(_, fullType)
                local list = held[fullType] or {}
                return {
                    size = function() return #list end,
                    get = function(_, i) return list[i + 1] end,
                }
            end,
        }
    end,
}
local healed1 = Sermon.healTapes(carrier)
local healed2 = Sermon.healTapes(carrier)
say("healTapes pass1=" .. tostring(healed1)
    .. " pass2=" .. tostring(healed2)
    .. " tapeII recorded=" .. tostring(tape2:isRecordedMedia())
    .. " index=" .. tostring(tape2:getRecordedMediaIndex()))

local verdict = (stamped and tape:isRecordedMedia()
    and healed1 == 1 and healed2 == 0 and tape2:isRecordedMedia())
    and "PASS" or "FAIL"
return verdict .. "\n" .. table.concat(out, "\n")
