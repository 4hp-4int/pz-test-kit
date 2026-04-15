-- Weapon script data for tests (same data as run_tests.py WEAPONS dict)
-- The Kahlua runner loads this automatically if present in mod root

_pz_weapon_scripts["Base.Axe"] = {
    minDamage = 0.8, maxDamage = 2.0, criticalChance = 20.0,
    critDmgMultiplier = 5.0, maxRange = 1.2, baseSpeed = 1.0,
    conditionMax = 13, conditionLowerChance = 35,
    pushBackMod = 0.3, maxHitCount = 2, knockdownMod = 2.0,
    treeDamage = 35, doorDamage = 35,
    _isRanged = false, _name = "Axe", _displayName = "Axe",
    _hasHeadCondition = true, _headConditionMax = 13,
    _hasSharpness = true,
}

_pz_weapon_scripts["Base.Pistol"] = {
    minDamage = 0.6, maxDamage = 1.0, criticalChance = 20.0,
    critDmgMultiplier = 4.0, maxRange = 15.0,
    conditionMax = 10, conditionLowerChance = 200,
    hitChance = 50, recoilDelay = 12, reloadTime = 30,
    clipSize = 15, maxAmmo = 15, aimingTime = 25,
    _isRanged = true, _name = "Pistol", _displayName = "Pistol",
}

print("[MyMod] Weapon scripts loaded")
