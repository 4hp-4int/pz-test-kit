#!/usr/bin/env python3
"""
Example: Run MyMod tests using PZ Test Kit
"""
import sys
from pathlib import Path

# Add pz-test-kit to path
KIT_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(KIT_ROOT / "lib"))

from pz_test_runner import PZTestRunner

# Some basic weapon scripts for testing
WEAPONS = {
    "Base.Axe": {
        "minDamage": 0.8, "maxDamage": 2.0, "criticalChance": 20.0,
        "critDmgMultiplier": 5.0, "maxRange": 1.2, "baseSpeed": 1.0,
        "conditionMax": 13, "conditionLowerChance": 35,
        "pushBackMod": 0.3, "maxHitCount": 2, "knockdownMod": 2.0,
        "treeDamage": 35, "doorDamage": 35,
        "_isRanged": False, "_name": "Axe", "_displayName": "Axe",
        "_hasHeadCondition": True, "_headConditionMax": 13,
        "_hasSharpness": True,
    },
    "Base.Pistol": {
        "minDamage": 0.6, "maxDamage": 1.0, "criticalChance": 20.0,
        "critDmgMultiplier": 4.0, "maxRange": 15.0,
        "conditionMax": 10, "conditionLowerChance": 200,
        "hitChance": 50, "recoilDelay": 12, "reloadTime": 30,
        "clipSize": 15, "maxAmmo": 15, "aimingTime": 25,
        "_isRanged": True, "_name": "Pistol", "_displayName": "Pistol",
    },
}

MOD_ROOT = Path(__file__).parent

runner = PZTestRunner(mod_root=MOD_ROOT)
runner.add_weapon_scripts(WEAPONS)

# Load mod modules
runner.load_module("media/lua/shared/MyMod/Core.lua")

# Run tests
sys.exit(runner.run())
