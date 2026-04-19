--[[
    Dual-VM Sim Tests
    =================
    Demonstrates PZTestKit.Sim — a 1-server + N-client multiplayer harness
    running on fully isolated Kahlua envs connected only by a command bus.

    Use case: testing sendServerCommand/sendClientCommand flows without
    launching the game. Each env has its own globals, own mocks, own mod
    modules loaded — communication happens exclusively through the bus.
]]

local Assert = PZTestKit.Assert

local tests = {}

-- ────────────────────────────────────────────────────────────────────────────
-- Basic topology
-- ────────────────────────────────────────────────────────────────────────────

tests["sim_creates_server_and_clients"] = function()
    local sim = PZTestKit.Sim.new({ players = 2 })
    if not Assert.notNil(sim, "sim handle") then return false end
    if not Assert.notNil(sim.server, "server endpoint") then return false end
    if not Assert.notNil(sim.clients, "clients list") then return false end
    if not Assert.notNil(sim.clients[1], "client 1") then return false end
    return Assert.notNil(sim.clients[2], "client 2")
end

tests["sim_endpoints_have_independent_globals"] = function()
    local sim = PZTestKit.Sim.new({ players = 2 })

    sim.server:exec([[ _my_marker = "server" ]])
    sim.clients[1]:exec([[ _my_marker = "c1" ]])
    sim.clients[2]:exec([[ _my_marker = "c2" ]])

    -- Readback via exec (sets a shared "outbox" we can inspect via sent())
    sim.server:exec([[ sendServerCommand("Probe", "readback", { value = _my_marker }) ]])
    sim.clients[1]:exec([[ sendServerCommand("Probe", "readback", { value = _my_marker }) ]])

    local serverSent = sim.server:sent()
    local client1Sent = sim.clients[1]:sent()

    if not Assert.equal(serverSent[1].args.value, "server", "server marker") then return false end
    return Assert.equal(client1Sent[1].args.value, "c1", "client1 marker")
end

tests["sim_isServer_isClient_per_endpoint"] = function()
    local sim = PZTestKit.Sim.new({ players = 1 })

    sim.server:exec([[ sendServerCommand("Probe", "ctx", { s = isServer(), c = isClient() }) ]])
    sim.clients[1]:exec([[ sendServerCommand("Probe", "ctx", { s = isServer(), c = isClient() }) ]])

    local serverCtx = sim.server:sent()[1].args
    local clientCtx = sim.clients[1]:sent()[1].args

    if not Assert.isTrue(serverCtx.s, "server: isServer true") then return false end
    if not Assert.isFalse(serverCtx.c, "server: isClient false") then return false end
    if not Assert.isFalse(clientCtx.s, "client: isServer false") then return false end
    return Assert.isTrue(clientCtx.c, "client: isClient true")
end

-- ────────────────────────────────────────────────────────────────────────────
-- Command bus routing
-- ────────────────────────────────────────────────────────────────────────────

tests["sim_broadcast_reaches_all_clients"] = function()
    local sim = PZTestKit.Sim.new({ players = 3 })

    -- Server broadcasts (3-arg form when called from server)
    sim.server:exec([[ sendServerCommand("MyMod", "announce", { text = "hi" }) ]])

    sim:flush()

    if not Assert.isTrue(sim.clients[1]:sawCommand("MyMod", "announce"), "c1 received") then return false end
    if not Assert.isTrue(sim.clients[2]:sawCommand("MyMod", "announce"), "c2 received") then return false end
    return Assert.isTrue(sim.clients[3]:sawCommand("MyMod", "announce"), "c3 received")
end

tests["sim_client_to_server_routes_to_server"] = function()
    local sim = PZTestKit.Sim.new({ players = 2 })

    sim.clients[1]:exec([[ sendServerCommand("MyMod", "upload", { payload = 42 }) ]])

    sim:flush()

    local srvReceived = sim.server:received()
    if not Assert.equal(#srvReceived, 1, "server got one") then return false end
    if not Assert.equal(srvReceived[1].command, "upload", "cmd name") then return false end
    return Assert.equal(srvReceived[1].args.payload, 42, "cmd payload")
end

tests["sim_OnServerCommand_fires_on_target_client"] = function()
    local sim = PZTestKit.Sim.new({ players = 2 })

    -- Register a listener on client 1 that records to a global
    sim.clients[1]:exec([[
        Events.OnServerCommand.Add(function(module, command, args)
            _last_sc = { module = module, command = command, args = args }
        end)
    ]])

    -- Server broadcasts
    sim.server:exec([[ sendServerCommand("MyMod", "update", { v = 7 }) ]])
    sim:flush()

    -- Probe client 1 for what its listener saw
    sim.clients[1]:exec([[
        sendServerCommand("Probe", "readback", _last_sc or { missing = true })
    ]])

    local probe = sim.clients[1]:sent()[1].args
    if not Assert.notNil(probe, "probe fired") then return false end
    if not Assert.equal(probe.command, "update", "listener saw command") then return false end
    return Assert.equal(probe.args.v, 7, "listener saw args")
end

return tests
