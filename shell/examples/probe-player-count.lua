local n = 0
if getOnlinePlayers() then n = getOnlinePlayers():size() end
return "players=" .. tostring(n)
