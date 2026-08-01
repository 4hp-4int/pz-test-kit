-- Inspect capacity of the overhead world container the stress probe picks.
local p = getOnlinePlayers():get(0)
local psq = p:getCurrentSquare()

for dy = -3, 3 do
    for dx = -3, 3 do
        local sq = getCell():getGridSquare(psq:getX() + dx, psq:getY() + dy, psq:getZ())
        if sq then
            for i = 0, sq:getObjects():size() - 1 do
                local o = sq:getObjects():get(i)
                local c = o.getContainer and o:getContainer()
                if c then
                    return string.format("type=%s cap=%s weight=%s hasRoomForBottle=%s",
                        c:getType(),
                        tostring(c.getCapacity and c:getCapacity()),
                        tostring(c.getCapacityWeight and c:getCapacityWeight()),
                        tostring(c.hasRoomFor and c:hasRoomFor(p, instanceItem("Base.PopBottle"))))
                end
            end
        end
    end
end
return "no world container within 3 tiles"
