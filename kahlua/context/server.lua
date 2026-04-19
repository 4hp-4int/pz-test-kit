--[[
    PZ Test Kit — server context override
    ======================================
    Flips isServer()/isClient() to match a server endpoint. Loaded by
    buildEnv() for the DualVMSim server env; plain test runs default to
    the client context already set by mock_environment.lua.
]]

function isServer() return true end
function isClient() return false end
