-- Example mod: simple weapon buff system
MyMod = MyMod or {}
MyMod.VERSION = "1.0.0"

--- Check if an item is a valid melee weapon
function MyMod.isValidWeapon(item)
    if not item then return false end
    if not instanceof(item, "HandWeapon") then return false end
    if item:isRanged() then return false end
    return true
end

--- Apply a damage buff to a weapon
function MyMod.applyDamageBuff(weapon, amount)
    if not MyMod.isValidWeapon(weapon) then return false end
    local current = weapon:getMaxDamage()
    weapon:setMaxDamage(current + amount)
    weapon:setMinDamage(weapon:getMinDamage() + amount)
    return true
end

--- Get the buff amount based on kill count
function MyMod.getBuffAmount(kills)
    if kills >= 100 then return 0.5
    elseif kills >= 50 then return 0.3
    elseif kills >= 10 then return 0.1
    else return 0 end
end

print("[MyMod] Core loaded v" .. MyMod.VERSION)
