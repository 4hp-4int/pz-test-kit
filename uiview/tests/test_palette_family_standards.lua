--[[
    UIView — Family standards (docs/FAMILY_STANDARDS.md)
    ====================================================
    Two jobs: (1) audit EVERY registered family for the §1 descriptor contract so a
    new/edited family can't drift out of parity, and (2) exercise the F.standard
    builder that makes the common-case family conformant by construction.
]]

local Assert = PZTestKit.Assert
-- load the family providers so their specs are registered
local SP = require "palette/pal_families"
require "palette/pal_loot"
require "palette/pal_tvradio"
require "palette/pal_moveables"
require "palette/pal_cookables"
require "palette/pal_makeup"
require "palette/pal_vehicle_mechanics"
require "palette/pal_drainable"
require "palette/pal_foraging"
local F = SP.Families

local tests = {}

-- ── §1 contract audit ───────────────────────────────────────────────────────
tests["families_registered"] = function()
    return Assert.isTrue(#F.specs >= 8, "all family adapters registered (>=8)")
end

tests["every_family_meets_the_descriptor_contract"] = function()
    for _, s in ipairs(F.specs) do
        local who = tostring(s.id)
        if not Assert.isTrue(type(s.id) == "string" and s.id ~= "", "family id is a non-empty string") then return false end
        if not Assert.isTrue(type(s.match) == "function", who .. ": match is a function") then return false end
        -- key/label/default are part of the standard for any real family
        if not Assert.isTrue(type(s.key) == "function", who .. ": key is a function") then return false end
        if not Assert.isTrue(type(s.label) == "function", who .. ": label is a function") then return false end
        if not Assert.isTrue(type(s.default) == "function", who .. ": default is a function") then return false end
        if s.rank ~= nil and not Assert.isTrue(type(s.rank) == "function", who .. ": rank, if set, is a function") then return false end
        if s.flavor ~= nil and not Assert.isTrue(type(s.flavor) == "function", who .. ": flavor, if set, is a function") then return false end
    end
    return true
end

tests["family_key_never_errors"] = function()
    -- key() must be total (string for a member, nil for a non-member) — never throw,
    -- since F.apply calls it on every command. Probe with an empty command.
    for _, s in ipairs(F.specs) do
        local ok, k = pcall(s.key, {})
        if not Assert.isTrue(ok and (k == nil or type(k) == "string"),
            tostring(s.id) .. ": key() returns string|nil without error") then return false end
    end
    return true
end

-- ── F.standard builder ──────────────────────────────────────────────────────
local function member(t)
    t.kind = "demo"; return t
end

tests["standard_builds_a_conformant_spec"] = function()
    local spec = F.standard({
        id = "demo", kind = "demo", keyField = "dKey", nameField = "dName",
        labelFallback = "Demo", tierField = "dTier", verbField = "dVerb",
    })
    if not Assert.equal(spec.id, "demo", "id carried") then return false end
    if not Assert.isTrue(spec.match({ kind = "demo" }) == true, "match by kind") then return false end
    if not Assert.isTrue(spec.match({ kind = "other" }) == false, "non-match by kind") then return false end
    return Assert.equal(spec.key({ dKey = "7" }), "demo:7", "key = id:instance")
end

tests["standard_label_name_then_fallback"] = function()
    local spec = F.standard({ id = "demo2", kind = "demo2", nameField = "dName", labelFallback = "Demo" })
    if not Assert.equal(spec.label({ { dName = "Crate" } }), "Crate", "label uses the name field") then return false end
    return Assert.equal(spec.label({ {} }), "Demo", "label falls back when unnamed")
end

tests["standard_default_is_lowest_tier"] = function()
    local spec = F.standard({ id = "demo3", kind = "demo3", tierField = "dTier" })
    local a, b, c = member({ dTier = 2, label = "a" }), member({ dTier = 0, label = "b" }), member({ dTier = 1, label = "c" })
    return Assert.equal(spec.default({ a, b, c }), b, "default = the lowest-tier member")
end

tests["standard_flavor_marks_blocked_verbs"] = function()
    local spec = F.standard({ id = "demo4", kind = "demo4", tierField = "dTier", verbField = "dVerb" })
    local on  = member({ dTier = 0, dVerb = "Open",  runnable = true,  label = "Open" })
    local off = member({ dTier = 1, dVerb = "Close", runnable = false, label = "Close" })
    return Assert.equal(spec.flavor({ on, off }), "Open, Close*", "flavor lists verbs, '*' on the blocked one")
end

tests["standard_custom_flavor_override_wins"] = function()
    local spec = F.standard({ id = "demo5", kind = "demo5", verbField = "dVerb",
        flavor = function() return "custom" end })
    return Assert.equal(spec.flavor({ {} }), "custom", "an explicit flavor fn overrides the generated one")
end

return tests
