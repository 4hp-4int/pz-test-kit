--[[
    UIView — pal_score (fuzzy match, Phase A extraction)
    ====================================================
    Direct unit tests of the pure scorer — no panel, no render. This is the kind
    of coverage the pal_ui refactor exists to enable.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_score"
local S = SP.Score

local tests = {}

tests["empty_query_matches"] = function()
    return Assert.equal(S.fuzzy("", "anything"), 1, "empty query matches with rank 1")
end

tests["substring_beats_subsequence"] = function()
    local sub = S.fuzzy("box", "Open Box")       -- substring
    local seq = S.fuzzy("oeb", "Open Box")       -- subsequence (o..e..b)
    if not Assert.isTrue(sub ~= nil and seq ~= nil, "both match") then return false end
    return Assert.isTrue(sub > seq, "a substring hit outranks a subsequence hit")
end

tests["earlier_substring_ranks_higher"] = function()
    local early = S.fuzzy("open", "Open Box")     -- pos 1
    local late  = S.fuzzy("box",  "Open Box")     -- pos 6
    return Assert.isTrue(early > late, "an earlier substring position ranks higher")
end

tests["no_match_is_nil"] = function()
    return Assert.isNil(S.fuzzy("zzz", "Open Box"), "no subsequence -> nil")
end

tests["subsequence_tier_is_100"] = function()
    return Assert.equal(S.fuzzy("opb", "Open Box"), 100, "an anchored subsequence scores 100")
end

tests["scattered_subsequence_is_rejected"] = function()
    -- "poop" must NOT scavenge p-o-o-p out of "Equip Primary Bottle of Brandy"
    -- (the false-positive the anchored matcher exists to kill).
    if not Assert.isNil(S.fuzzy("poop", "Equip Primary Bottle of Brandy"),
        "scattered cross-word letters don't match") then return false end
    -- but a within-word typo-run (dropped letter) still matches
    if not Assert.isTrue(S.fuzzy("opn", "Open Box") ~= nil, "'opn' still matches 'Open' (within-word run)") then return false end
    -- and an acronym of word-initials still matches
    return Assert.isTrue(S.fuzzy("ob", "Open Box") ~= nil, "'ob' still matches 'Open Box' (word initials)")
end

tests["synonym_whole_word_prefix"] = function()
    if not Assert.isTrue(S.synHit("stov", "stove range oven"), "'stov' is a word-prefix of 'stove'") then return false end
    return Assert.isFalse(S.synHit("tov", "stove range oven"), "'tov' is NOT a word-prefix (mid-word)")
end

tests["synonym_below_subsequence"] = function()
    return Assert.isTrue(S.SYN < 100, "a synonym-only hit ranks below any real subsequence match")
end

return tests
