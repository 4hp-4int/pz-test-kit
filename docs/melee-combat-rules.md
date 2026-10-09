# PZ B42 melee combat rules: fatigue, swing speed, damage, XP

Extracted from the decompiled B42 Java (`C:\Tools\ZomboidDecompiler\ZomboidDecompiler\bin\output\source\zombie\`) and vanilla
media (`...\ProjectZomboid\media\`). Citations are `File.java:line` relative to `zombie/`. Everything here is read from source;
nothing was measured on SousVide or in game. The swing durations in section 4 come from the clip files and the anim XML. They
were not timed.

Units: `CharacterStat.ENDURANCE` runs 0..1 (min 0, max 1, default 1) (`characters/CharacterStat.java:15`). `FATIGUE`
also runs 0..1.

Tick timing: `GameTime.getMultiplier()` = `multiplier(game speed) * fpsMultiplier * multiplierBias * perObjectMultiplier * slomo * 0.8`
(`GameTime.java:1292-1307`). `fpsMultiplier = 60 / fps` (`FPSTracking.java:40`). At 1x game speed **the per-tick multipliers
sum to 0.8 * 60 = 48 per real second**, whatever the frame rate. Anything that does not multiply by `getMultiplier()` depends on
the frame rate (flagged below).

Combat constants live in `combat/CombatConfigKey.java` (defaults, lines 8-67). `CombatConfig` only holds defaults plus a Lua
`set()` (`combat/CombatConfig.java:13-26`), and no sandbox option feeds it.

---

## 1. Endurance cost per swing

A melee swing pays endurance twice: once per swing whether or not it connects, and once for each character it hits.

### 1a. Per swing (hit or miss): `CombatManager.processWeaponEndurance`, `CombatManager.java:1267-1283`

Called from the attack collision check, `CombatManager.java:714`. In MP the server calls it from
`network/packets/hit/AttackCollisionCheckPacket.java:74`. It runs only if `weapon.isUseEndurance()` (script `UseEndurance`,
default true).

```
w      = max(weapon.Weight, 1.0)                                   (HandWeapon.getEffectiveWeight, HandWeapon.java:247)
twoH   = (TwoHandWeapon && not held in both hands) ? w / 1.5 / 10 : 0
cost   = (w * 0.18 * weapon.getFatigueMod(chr) * chr.getFatigueMod() * weapon.EnduranceMod * 0.3 + twoH) * 0.04
cost  *= 1.2 if Asthmatic else 1.0                                 (CharacterTraits.getTraitEnduranceLossModifier, characters/traits/CharacterTraits.java:153)
endurance -= cost
```

### 1b. Per character hit: `CombatManager.applyMeleeEnduranceLoss`, `CombatManager.java:3900-3936`

Called once per target hit, `CombatManager.java:1163`, with `hitDamage` = the return value of `target.Hit(...)` (MP:
`network/packets/hit/PlayerHitCharacter.java:84`). Melee and `UseEndurance` only.

```
twoH   = (TwoHandWeapon && not in both hands) ? Weight / 1.5 / 10 : 0          (uses raw Weight, not effective weight)
loss   = (Weight * 0.28 * weapon.getFatigueMod(chr) * chr.getFatigueMod() * EnduranceMod * 0.3 + twoH) * 0.04
loss  *= 2.0 if the attack is a floor stomp (aimAtFloor && doShove)
frac   = 1.0                       if hitDamage <= 0
       = 0.2                       if target.isCloseKilled()  (knife close kill)
       = min(min(hitDamage, target.health) / weapon.MaxDamage, 1.0) otherwise
endurance -= loss * frac
```

Note: `target.health` is read after the hit has been applied. No Asthmatic modifier on this path.

| CombatConfigKey | default | used in |
|---|---|---|
| ENDURANCE_LOSS_BASE_SCALE | 0.28 | 1b |
| ENDURANCE_LOSS_WEIGHT_MODIFIER | 0.3 | 1b |
| ENDURANCE_LOSS_FINAL_MULTIPLIER | 0.04 | 1b |
| ENDURANCE_LOSS_TWO_HANDED_PENALTY_DIVISOR / _SCALE | 1.5 / 10 | 1b |
| ENDURANCE_LOSS_FLOOR_SHOVE_MULTIPLIER | 2.0 | 1b |
| ENDURANCE_LOSS_CLOSE_KILL_MODIFIER | 0.2 | 1b |

(1a hardcodes 0.18 / 0.3 / 0.04 and the same 1.5 / 10.)

### Skill and fitness factors

`HandWeapon.getFatigueMod(chr)` (`inventory/types/HandWeapon.java:530-543`): 0.8 if the weapon has category BLUNT and Blunt >= 8,
or AXE and Axe >= 8, or SPEAR and Spear >= 8; otherwise 1.0. **No reduction below level 8, and none at all for
SmallBlunt/SmallBlade/LongBlade.**

`IsoGameCharacter.getFatigueMod()` by Fitness (`characters/IsoGameCharacter.java:5160-5182`):

| Fitness | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| mod | 1.0 | 0.95 | 0.92 | 0.89 | 0.87 | 0.85 | 0.83 | 0.81 | 0.79 | 0.77 | 0.75 |

Strength does **not** enter endurance cost. It enters muscle strain (below). Charge/heavy attacks: neither cost formula
reads the attack type or charge. Swinging and missing pays 1a only.

Sandbox: no sandbox multiplier on endurance *cost* was found. (`EndRegen` affects regen only, section 2.)

**Worked example:** Baseball Bat (Weight 2.0, EnduranceMod 1.0 default, two-handed in both hands), Blunt 0, Fitness 5, no traits:
1a = 2 * 0.18 * 1 * 0.85 * 1 * 0.3 * 0.04 = **0.00367** per swing. 1b = 2 * 0.28 * 0.85 * 0.3 * 0.04 = **0.00571** * frac per
target hit. A full-damage hit therefore costs about 0.0094 total.

### Related per-swing cost: arm muscle strain

`IsoGameCharacter.addCombatMuscleStrain` (`characters/IsoGameCharacter.java:17126-17207`) is called next to 1a
(`CombatManager.java:715`). For a melee weapon: `val = (Weight*0.15*EnduranceMod*0.3 + twoH)*4 * (hitCount+1) * (15-Strength)/10
* weapon.muscleStrainMod(chr) * 0.5(if two-handed) * 0.65`, then times sandbox `MuscleStrainFactor` (default 1.0). Here
`muscleStrainMod = (1 - weaponSkill*0.075) * StrainModifier` (`HandWeapon.java:819-824`). This is stiffness, not endurance. Listed so a
sim knows where Strength enters.

Where it lands and what it does (verified 2026-10-08, modelled in the Arena):

- `addArmMuscleStrain(val)` (`:17239`) multiplies by 2.5 and the sandbox factor and adds that much **stiffness** to Hand_R,
  ForeArm_R and UpperArm_R; a two-handed weapon also calls `addLeftArmMuscleStrain` (the same on the left). Stiffness is
  clamped to 0..100 (`BodyPart.addStiffness :1942`). The melee branch requires `isActuallyAttackingWithMeleeWeapon()`
  (a live attack animation), so headless callers must mirror it.
- A body part's pain includes `stiffness / 3.5` (`BodyPart.getAdditionalPain(true) :1110`, read by `getPain :1052`).
- Damage chain, right after the two-handed rule: if the summed `getPain()` of Hand_L..UpperArm_R exceeds 10,
  `damage /= clamp(pain / 10, 1, 30)` (`CombatManager.java:988-1000`; a shove reads the legs instead).
- Stiffness eases by `0.002 * GameTime.getMultiplier()` per tick (`BodyPart.java:471`), about 0.1 per real second at 1x,
  except while a Fitness exercise's stiffness is pending.
- Scale: a Sledgehammer (Weight 6, EnduranceMod 4, two-handed, MaxHitCount 3) adds about 7 stiffness to each of six arm
  parts per swing at Strength 5 and skill 0, past the pain-10 line in a swing or two. In the Arena a level-0 sledgehammer
  swings with sore arms 99% of the time and kills ~70% fewer zombies per life; a golf club, bat or axe stays under 1%
  (the axe 9-34% when underweight or emaciated, because the fighter rests less well).

### Hunger and food

The Hungry and Well Fed moodles are read by nothing in melee (damage, speed, endurance cost or regen). Hungry lowers carry
weight (`BodyDamage.UpdateStrength :2020`); Well Fed clears poison faster (`:2272`). Long hunger acts through
`getRecoveryMod` (endurance regen, `IsoGameCharacter.java:5294`): Very Underweight and Overweight x0.7, Emaciated x0.3,
Obese x0.4, and lipids or proteins under -1000 x0.5 (under -1500 x0.2). `Nutrition`'s setters are not exposed to Lua;
use the weight traits to model it.

---

## 2. Endurance recovery

`IsoPlayer.updateEndurance`, `characters/IsoPlayer.java:3251-3390`, runs every player update (`IsoPlayer.java:2283`,
`2502`), including mid-fight. It is skipped when `isSitting()/isResting()`, which use `updateEnduranceWhileSitting`, `:3225`.

Base constant: `ImobileEnduranceIncrease = 0.0000930/3 = 0.000031` (`media/lua/shared/defines.lua:7`, loaded at
`ZomboidGlobals.java:55`).

| state | per-tick change | cite |
|---|---|---|
| standing still (`!isPlayerMoving()`), HEAVY_LOAD moodle <= 1 | `+0.000031 * EndRegen * RecoveryMod * (1 - fatigue*0.85) * getMultiplier()` | IsoPlayer.java:3350-3362 |
| walking (not running/sprinting), Endurance moodle < 2, HEAVY_LOAD <= 1 | `+0.000031/4 * EndRegen * RecoveryMod * (1 - fatigue) * getMultiplier()` | :3365-3382 |
| walking, Endurance moodle >= 2 | `-RunningEnduranceReduce/7 * sneakMult` per tick (**no getMultiplier: frame-rate dependent**) | :3384 |
| running / sprinting | drain, see :3258-3346 (`RunningEnduranceReduce=0.000052`, `SprintingEnduranceReduce=0.000455`, defines.lua:5-6) | |
| sitting / in vehicle | `+0.000031 * EndRegen * RecoveryMod * 5 * (1 - fatigue*0.8) * getMultiplier()` | :3225-3233, ZomboidGlobals.java:12 |
| HEAVY_LOAD >= 2 | no standing/walking regen | |

`EndRegen` (`SandboxOptions.getEnduranceRegenMultiplier`, `SandboxOptions.java:398-406`; option default 3, `:143`):
1 → 1.8, 2 → 1.3, **3 → 1.0**, 4 → 0.7, 5 → 0.4.

`getRecoveryMod()` by Fitness (`characters/IsoGameCharacter.java:5294-5370`):

| Fitness | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| mod | 0.7 | 0.8 | 0.9 | 1.0 | 1.1 | 1.2 | 1.3 | 1.4 | 1.5 | 1.55 | 1.6 |

These are then multiplied by: Obese 0.4, Overweight 0.7, Very Underweight 0.7, Emaciated 0.3, lipids < -1000 → 0.5 (< -1500 → 0.2),
proteins < -1500 → 0.2, and so on (`:5342-5370`).

Per real second at 1x, standing still, Fitness 5, fatigue 0, EndRegen default: 0.000031 * 1.2 * 48 = **0.00179/s** (full
0→1 in about 560 s). Carry weight matters only through the HEAVY_LOAD moodle (gates regen, see the table). Being in an attack
animation does not stop regen. A player standing still while swinging regenerates on every tick of the fight.

---

## 3. Effects of low endurance / tiredness on melee

Endurance moodle level from raw endurance (`characters/Moodles/Moodle.java:100-113`, thresholds `MoodleStat.java:10`):

| endurance | > 0.75 | 0.5 < e <= 0.75 | 0.25 < e <= 0.5 | 0.1 < e <= 0.25 | <= 0.1 |
|---|---|---|---|---|---|
| level | 0 | 1 | 2 | 3 | 4 |

Tired moodle from FATIGUE (`Moodle.java:128-...`, `MoodleStat.java:12`): > 0.6 → 1, > 0.7 → 2, > 0.8 → 3, > 0.9 → 4.

| effect | per Endurance level L | per Tired level T | cite |
|---|---|---|---|
| melee damage multiplier (on damageSplit) | L0 1.0, L1 **0.5**, L2 0.2, L3 0.1, L4 0.05 | same table: T1 0.5, T2 0.2, T3 0.1, T4 0.05 | CombatManager.java:1055-1095 |
| swing speed (CombatSpeed) | `-0.07 * L` (before the random factor and clamp) | none | IsoGameCharacter.java:10379 |
| crit chance | `-5 * L` | none | IsoPlayer.java:3959 |
| shove crit chance | `-5 * L` | none | IsoPlayer.java:3889 |
| knockback (target hitForce) | `del = endurance * knockbackAttackMod`; if del < 0.5: `del = max(del*1.3, 0.4)`, hitForce *= del | none | IsoGameCharacter.java:6886-6895 |
| zombie-bite defend chance | `-2 * L` | `-3 * T` | IsoGameCharacter.java:14259-14261 |
| can attack at all | blocked at L4 only for weapons with `CantAttackWithLowestEndurance` | none | IsoGameCharacter.java:7138, 7147-7149 |
| hit chance | none (melee always hits, section 6) | none | |

The two damage tables multiply together. A level-1 Endurance moodle (endurance <= 0.75) **halves** melee damage.

---

## 4. Swing speed

### The CombatSpeed variable

`IsoGameCharacter.calculateCombatSpeed()`, `characters/IsoGameCharacter.java:10362-10400`. It is computed **once per attack** at
attack press (`CombatManager.pressedAttack`, `CombatManager.java:3212`) and stored in the anim variable `CombatSpeed`
(`IsoPlayer.java:703`):

```
s  = 0.8
s *= weapon.BaseSpeed                                    (script BaseSpeed, default 1.0; Item.java:371)
s *= 0.77   if TwoHandWeapon and secondary hand != weapon
s *= getChopTreeSpeed()  if weapon category AXE         (Axeman 1.0, else 0.8; IsoGameCharacter.java:14239)
s -= 0.07 * EnduranceMoodleLevel
s -= 0.07 * HeavyLoadMoodleLevel
s += 0.03 * getWeaponLevel()                             (see quirk below)
s += 0.02 * Fitness
s *= 0.95   if secondary hand holds an InventoryContainer (bag)
s *= Rand.Next(1.1, 1.2)
s *= combatSpeedModifier       (1 + sum of (clothing/bag CombatSpeedModifier - 1); IsoGameCharacter.java:10601-10611)
s *= getArmsInjurySpeedModifier()   (1 - injury terms of Hand_R, ForeArm_R, UpperArm_R; :10402-10423, calculateInjurySpeed :10445)
s *= thermoregulator.getCombatModifier()   (Hypothermia L2 0.66, L3 0.33, L4 0.1, plus hyperthermia; BodyDamage/Thermoregulator.java:354)
s  = clamp(s, 0.8, 1.6)
s *= 1.2    if TwoHandWeapon and WeaponType == HEAVY   (applied after the clamp, so it can reach 1.92)
```

On a critical hit: `CombatSpeed *= 1.1` (`CombatManager.java:3372-3374`).

Strength does not enter swing speed.

**`getWeaponLevel()` quirk** (`IsoGameCharacter.java:11863-11904`): it starts at -1. AXE *assigns* `level = Axe`. SPEAR,
SMALL_BLADE, LONG_BLADE, BLUNT and SMALL_BLUNT each *add* their perk to the running value. It is capped at 10, and -1 returns 0. So a
pure Blunt weapon at Blunt N gives N-1 (Blunt 0 → 0, Blunt 3 → 2), and an Axe gives Axe N → N. It returns 0 when the WeaponType is
UNARMED. The same function feeds damage (section 5) and bite defence.

**Dead code:** `HandWeapon.getSpeedMod(chr)` (`HandWeapon.java:550-668`, the per-level 0.95…0.65 table) and
`HandWeapon.getToHitMod(chr)` (`:670-...`) have **no callers** in the Java or the vanilla Lua. Neither one affects anything.

### From CombatSpeed to seconds

Only the `*Default.xml` attack nodes set `<m_SpeedScale>CombatSpeed</m_SpeedScale>`. Overhead, Uppercut, Miss and Crit variants
`x_extends` their Default node and inherit it (`media/AnimSets/player/melee/**`). Playback rate = CombatSpeed (`AnimNode.getSpeedScale`,
`core/skinnedmodel/advancedanimation/AnimNode.java:200`; applied in `AnimLayer.startLiveNodeTracks`, `AnimLayer.java:912-950`). The
`<m_SpeedScale>0.80</m_SpeedScale>` on the `m_2DBlends` entries is parsed into `Anim2DBlend.speedScale`
(`Anim2DBlend.java:17`), but no reader was found.

Clip lengths, read from `media/anims_X/Bob/*.X` (AnimTicksPerSecond 4800, last key tick):

| WeaponType (swing) | Default clip | length | others |
|---|---|---|---|
| ONE_HANDED | Bob_Attack1Hand01_Hit | 1.00 s | Overhead/Uppercut/Miss/Crit 1.00 s |
| TWO_HANDED (Bat) | Bob_AttackBat01_Hit | 1.00 s | Overhead/Uppercut/Miss/Crit 1.00 s |
| HEAVY | Bob_Attack2H_Heavy01_Hit | 2.50 s | Overhead 2.20 s, Crit 2.50 s |
| KNIFE (Stab) | Bob_AttackKnife01_Hit | 1.00 s | |
| SPEAR | Bob_AttackSpear02_Hit | 1.00 s | Spear01 CritHit 1.567 s |
| CHAINSAW | Bob_AttackChainsaw01_CritHit | 2.50 s | |
| floor attacks | Bat/1Hand 1.00 s, Heavy 2.00 s, Stab 1.367 s, Spear 1.10 s | | |

Attack mix (`inventory/types/WeaponType.java:12-21`, weighted): 1H/2H/Knife DEFAULT 20 : OVERHEAD 10 : UPPERCUT 10; Heavy DEFAULT 20 :
OVERHEAD 10; Spear/Chainsaw DEFAULT only. When no target is in reach the attack type becomes MISS (`CombatManager.java:3282-3284`).

Events inside the clip (`2HDefault.xml`, the same pattern in 1H/Heavy/Knife/Spear Default):
- `AttackCollisionCheck` at **25 % of the clip** (`SpearCharge` 20 %). Hits, damage and both endurance costs resolve here.
- `SetMeleeDelay` at clip end: **12** (1H, 2H, Heavy), **8** (Knife, Spear).

Cooldown: `meleeDelay -= 0.625 * getMultiplier()` per tick (`IsoGameCharacter.java:9620-9622`). That is 30/s at 1x, so
12 → 0.40 s and 8 → 0.27 s. The next attack needs `meleeDelay <= 0` (`IsoPlayer.java:2540, 2556, 2587`).

**Swing cycle (derived, not timed):** `clipLength / CombatSpeed + meleeDelay/30` s. Blend-in 0.15 s and
`EarlyTransitionOut` are ignored. Collision lands at `0.25 * clipLength / CombatSpeed` after the press.
Example, Baseball Bat, Blunt 0, Fitness 5, no moodles: s = 0.8 + 0.10 = 0.90, * U(1.1, 1.2) → 0.99–1.08. Swing 0.93–1.01 s, hit at
about 0.24 s, cycle about 1.33–1.41 s.

---

## 5. Damage chain (melee vs zombie), complete

Corrects the brief: the base roll is at `CombatManager.java:966-968` (not :930).

1. `damage = Rand.Next(MinDamage, MaxDamage)` (`CombatManager.java:966`).
2. `damage *= weapon.getDamageMod(chr) * chr.getHittingMod()` (`:968`).
   - `getDamageMod` (`HandWeapon.java:478-513`): **only BLUNT, AXE, SPEAR have branches**, each 1.1 at level 3-6 and 1.2 at 7+;
     the first matching category wins. SmallBlunt, SmallBlade and LongBlade always return 1.0.
   - `getHittingMod` by Strength (`IsoGameCharacter.java:5244-5267`): 0→0.75, 1→0.8, 2→0.85, 3→0.9, 4→0.95, 5→1.0, 6→1.05,
     7→1.1, 8→1.15, 9→1.2, 10→1.25.
3. A two-handed weapon not held in both hands with Max > Min: `damage -= MinDamage` (`:971-973`).
4. Arm pain (sum Hand_L..UpperArm_R pain) > 10: `damage /= clamp(pain/10, 1, 30)`. For a stomp, leg pain instead (`:975-1000`).
5. `damage *= traits.getTraitDamageDealtReductionModifier()` (`:1004`; e.g. Emaciated 0.4, `CharacterTraits.java:146`).
6. Multi-target split: `damageSplit = damage / (split * 0.5)`, with split starting at 1 (`:719`, `:1007-1010`). First target **x2**,
   second x1, third x0.667.
7. Panic level > 1: `damageSplit -= 0.1 * PanicLevel`. Stress level > 1: `-= 0.1 * StressLevel`. If negative, it becomes 0.1 (`:1031-1043`).
8. Endurance and Tired moodle multipliers (section 3 table) (`:1055-1095`).
9. `target.Hit(...)` (`IsoGameCharacter.java:6787`): zombie `hitTime++`; if hitTime >= 4, `damageSplit *= (hitTime - 2) * 1.5`
   (`:6789-6795`). A shove (not aimAtFloor) sets ignoreDamage.
10. `processHitDamage` (`:6862-6925`): `damage = damageSplit * rangeDel`. `rangeDel = 2 * dist / weapon.MaxRange(chr)`, and if
    that is < 0.3 it becomes 1.0 (`CombatManager.java:1017-1029`). A KnifeDeath close kill gives x1000 (`:1101`).
11. `damage *= 1.5` if the attacker is an IsoPlayer, not shoving, and the target is facing away
    (`dot(target - attacker, target forward) > -0.3`) (`:6900-6911`).
12. `applyPlayerReceivedDamageModifier`: target IsoPlayer x0.4, otherwise (zombie) **x1.5** (`:6914`; `CombatManager.java:3885`).
13. `applyWeaponLevelDamageModifier`: `x (0.3 + 0.1 * clamp(getWeaponLevel(), 0, 10))` (`:6915`; `CombatManager.java:3875-3883`).
    With the off-by-one above, Blunt 0 and Blunt 1 both give x0.3.
14. Floor attack (aimAtFloor, not shove): `x max(5, CritDmgMultiplier)` (`:6916-6918`).
15. Critical: `x max(2, CritDmgMultiplier)` (`:6920-6922`).
16. Two-handed weapon not in both hands: x0.5 (`:6924`; `CombatManager.java:3894-3898`). Hit returns this value.
17. `hitConsequences`: `x 0.15` (GLOBAL_MELEE_DAMAGE_REDUCTION_MULTIPLIER), then `health -= damage`, floored at 0
    (`IsoGameCharacter.java:6929-6931`, `:16971`; `CombatManager.java:3867-3873`).

Critical chance, melee (`IsoPlayer.calculateCritChance`, `characters/IsoPlayer.java:3873-3974`): `c = weapon.CriticalChance`.
A two-handed weapon held one-handed: `c -= c/3`. `chargeTime < 2`: `c -= c/5`. Then `c += 3 * categorySkill`, where the skill is Blunt
by default, overridden in order by Axe, LongBlade, Spear, SmallBlade, SmallBlunt. `c -= 5 * Endurance L`, `-5 * HeavyLoad`,
`-1.3 * Panic`. Sandbox zombie toughness 1: -6, toughness 3: +6. Clamp to [10, 90]. `pressedAttack` then adds +5 when attacking from
behind (+30 in the unaware-zombie case) (`CombatManager.java:3323-3331`). It forces a crit for a close kill from behind on an
unaware zombie and cancels knife non-close-kill crits (`:3344-3366`). Roll: `Rand.Next(100) < c` (`:3343`). A crit also
knocks the zombie down (`IsoZombie.java:4279`), sends it to the head 1/3 of the time (`IsoZombie.java:1365`), and gives
CombatSpeed x1.1.

`getKnockbackMod` (Axe >= 6 → 2.0) feeds only `getStaggerBackTimeMod` (`HandWeapon.java:545, 2775`). `getRangeMod` (1.2 at 7+ for
Blunt/Axe/Spear, `:515`) multiplies reach.

---

## 6. Hit chance / misses

**Melee always hits whatever is in its hit list.** `calculateHitChanceData` returns `MAXIMUM_TO_HIT_CHANCE = 100` for non-ranged
weapons (`CombatManager.java:2708, 2751`). The roll `Rand.Next(100) <= chance` (`:764`; Rand.Next(100) is 0..99) can never
fail. `HandWeapon.getToHitMod` is dead (section 4). A "miss" is purely spatial: nothing in range or arc, so the attack plays the
MISS animation (`:3282`) and pays only cost 1a. Targets per swing: `MaxHitCount`, forced to 1 unless sandbox `MultiHitZombies`
is on (default false; `CombatManager.java:2341-2343`, `SandboxOptions.java:198`).

---

## 7. XP

### Weapon skill, Fitness, Strength: `media/lua/server/XpSystem/XpUpdate.lua:50-108`, event `OnWeaponHitXp`

Fired once **per target hit**. In SP it comes from `CombatManager.java:1166-1170` (skipped on client and server). In MP the server
fires it from `network/fields/hit/WeaponHit.java:129`. The `damage` argument is `damageSplit` as of step 8 of section 5 (after the
moodle multipliers, before `Hit()`). `hitCount` is always 1.

```
exp = min(3, damageSplit * 0.9)
if endurance > 0.5 (Stats.getEnduranceWarning, characters/Stats.java:160) and melee:  addXp(Fitness, 1)
if melee and lastHitCount > 0:                                                        addXp(Strength, lastHitCount)
if hitCount > 0 and melee: addXp(<each category perk the weapon has: Axe/Blunt/Spear/LongBlade/SmallBlade/SmallBlunt>, exp)
```

Also: a non-killing hit with a `KnockBackOnNoDeath` weapon gives `+2 Strength` (`IsoGameCharacter.java:6950-6960`). A hit on a
tree gives +2 Strength (`XpUpdate.lua:43-47`).

### Maintenance: `CombatManager.processMaintenanceCheck`, `CombatManager.java:519-556`

Called per character hit (`:1187`), vehicle hit (`:1206`), object hit (`:1229`) and tree (`:1292`). With 50 % chance
(`Rand.NextBool(2)`), and not on a stomp, shove or `NoMaintenanceXp` weapon, it awards
`amount = 2.0`, or `2.0 * 10 / ConditionLowerChanceOneIn` when that value is > 10 (Baseball Bat, 20 → 1.0). A two-handed weapon
held one-handed skips it a further 1/3 of the time.

### XP multipliers: `IsoGameCharacter.XP.AddXP`, `characters/IsoGameCharacter.java:18262-18360`

The Lua global `addXp` (`Lua/LuaManager.java:9931`) → `AddXP(perk, amount)` with boosts applied:
- Strength only: proteins 50..300 → x1.5, proteins < -300 → x0.7. Fitness XP is blocked if `!nutrition.canAddFitnessXp()`.
- Profession/trait XP boost for that perk: **none → x0.25** (Fitness, Strength, Sprinting exempt), boost 1 → x1.0,
  2 → x1.33, 3+ → x1.66.
- Fast Learner x1.3, Slow Learner x0.7 (Fitness/Strength exempt). Pacifist x0.75 on weapon skills.
- Skill-book multiplier, if > 1.
- Sandbox `MultiplierConfig.Global` (default 1.0, global toggle default on) (`SandboxOptions.java:1839-1840`).
- Any XP is ignored while asleep.

### Level thresholds: `characters/skills/PerkFactory.java:100-134`, values x1.5 in `AddPerk` (`:81-90`), cumulative (`getTotalXpForLevel`, `:309`)

| level | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|
| Axe/Blunt/SmallBlunt/LongBlade/SmallBlade/Spear/Maintenance, per level | 75 | 150 | 300 | 750 | 1500 | 3000 | 4500 | 6000 | 7500 | 9000 |
| same, cumulative | 75 | 225 | 525 | 1275 | 2775 | 5775 | 10275 | 16275 | 23775 | 32775 |
| Fitness/Strength, per level | 1500 | 3000 | 6000 | 9000 | 18000 | 30000 | 60000 | 90000 | 120000 | 150000 |

(Fitness and Strength also decay passively. That is not covered here.)

---

## What a simulator needs

**Inputs:** weapon script (Weight, EnduranceMod, BaseSpeed, Min/MaxDamage, MaxRange, CriticalChance, CritDmgMultiplier,
ConditionLowerChanceOneIn, TwoHandWeapon, SwingAnim → WeaponType, Categories, UseEndurance, MaxHitcount); perks (Fitness,
Strength, each weapon category, Maintenance) + XP + XP boosts; traits (Asthmatic, Axeman, Fast/Slow Learner, Pacifist, body-weight
traits); start endurance, fatigue, panic, stress, heavy-load level, arm pain/injury; sandbox EndRegen, MultiHitZombies, XP
multiplier, zombie toughness; game speed (48 multiplier-units per real second at 1x); zombie health.

**Per swing:**
1. Compute moodle levels from endurance and fatigue (section 3 thresholds).
2. CombatSpeed = section 4 formula (draw U(1.1, 1.2)); swing time = clip / CombatSpeed. If the crit roll succeeds, CombatSpeed x1.1.
3. At 25 % of the swing: endurance -= cost 1a (always).
4. If a target is in reach (melee never misses a target in reach): roll the crit (section 5), compute damage (steps 1-17),
   subtract it from zombie health, then endurance -= cost 1b * frac.
5. Fire XP: weapon skill `min(3, 0.9*damageSplit_step8) * boosts`; Fitness +1 if endurance > 0.5; Strength +hitCount;
   Maintenance 50 % chance of 2.0 (or 20/ConditionLowerChance) * boosts. Level up against the cumulative table.
6. After the clip: meleeDelay = 12 (8 for knife/spear), draining 30/s → next swing allowed.
7. Every tick (including during the swing, if standing still): endurance += 0.000031 * EndRegen * RecoveryMod(Fitness)
   * (1 - 0.85*fatigue) * getMultiplier(), clamped to [0, 1].

## Swing arc and wear, verified in the Arena (2026-10-09)

- **Who a swing can hit** (`CombatManager.calcValidTargets :1440`,
  `removeUnhittableMeleeTargets :1629`): a target in range is hit only if the
  dot of the fighter's facing and the direction to it (nearest bone) lies in
  `[MinAngle, MaxAngle]`; prone targets use `MinAngle / 1.5`. Up to
  `MaxHitcount` of those, nearest first. The golf club's MinAngle 0.8 is a
  wide arc (about 37 degrees either side): a bunched group of three in front
  is all hit.
- **Wear**: one `damageCheck(0, 1)` per target hit (`processMaintenanceCheck
  :519`), rolling 1 in `CLC + maintenance mod`, where the mod is the
  Maintenance level + weapon level / 2, and 0 unless the weapon is equipped
  (`InventoryItem.getMaintenanceMod :4971`). `LOWER_CONDITION` on the swing
  state only cues music when a weapon breaks (`SwipeStatePlayer :117`): there
  is no second roll per swing. A hit on a world object (`objHit`, :1228) or a
  tree rolls too; the Arena has neither.
- Measured: the Arena's golf club loses a point 1 in 15.2 rolls (engine 1 in
  15), the bat 1 in 18.4 (1 in 20). Against groups of three at skill 0 a golf
  club hits 2.65 zombies a swing, 7.4 hits a kill, and lives about 10 kills;
  a bat 1.6, 12.5 and about 22.

## How zombies die: knockdowns, floor blows, stomps (2026-10-09)

- **Death is health <= 0, standing or not** (`IsoGameCharacter.hitConsequences
  :6928` -> `Kill`). No floor blow is required.
- **From a zombie's 4th hit on, damage x (hits - 2) x 1.5**
  (`IsoGameCharacter.Hit :6792`).
- **A crit knocks down** every zombie it hits; a zombie already on the floor
  stays down (`IsoZombie.hitConsequences :4278`). 1 in 30 hits make a crawler
  (`shouldBecomeCrawler :4336`).
- **Downed zombies are not standing targets.** Standing ones in reach always
  come first; only with none does the attack go to the floor (auto prone
  attack, `CombatManager:1369-1399`; prone targets use MinAngle / 1.5).
- **A weapon swung at the floor does x max(5, crit multiplier)**
  (`processHitDamage`, aimAtFloor and not shoving) and rolls wear as any hit.
  **A stomp** does 0.7-1.0 + Strength x 0.2, times the shoes' StompPower
  (0.5 barefoot) (`CombatManager:1045`), with bare hands: no weapon wear.
- **A downed zombie gets up** when its reanimate timer runs out: 30-90 ticks at
  30 a second after it lands (`ZombieOnGroundState :166`), each hit while down
  adding up to 10 (`CombatManager:957`).

The Arena (combat mode) models all of it: `self.down` keeps each downed
zombie's get-up time on the arena clock; `finisher = "weapon"` (default, the
auto prone attack) or `"stomp"`; the ledger counts `knockedDown`, `gotUp`,
`floorHits`, `stomps`, `crawlers` and `killBy` (standing, crit, floor, stomp).

Measured (groups of three, 30 s between, skill 0, until the weapon breaks):
golf club 12 kills a life, 2.4 swings and 5.5 wear rolls a kill, 53% of
kills on the floor; bat 59, 3.3, 5.0, 38%; axe 41, 6.1, 9.4, 29%. Stomping
the downed ones instead barely lengthens a life (golf club 12 -> 12, bat
59 -> 67): most of the wear is spent before the knockdown.
