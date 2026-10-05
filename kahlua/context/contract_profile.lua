--[[
    PZ Test Kit — contract profile context
    =======================================
    Loaded by buildEnv() when runContract has set _pz_contract_profile, BEFORE
    config preloads run. A mod's preloaded module reads isServer() at file
    load (VorpallySauced MagazineSync registers its dedi hooks under
    `if isServer()`); under the default client context the dedi profile
    would miss them and report a bug that is not there.
]]

local CONTEXT = {
    sp     = { client = false, server = false },
    client = { client = true,  server = false },
    dedi   = { client = false, server = true },
}
local ctx = CONTEXT[_pz_contract_profile]
if ctx then
    function isClient() return ctx.client end
    function isServer() return ctx.server end
end
