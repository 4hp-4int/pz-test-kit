--[[
    Real-wire transport fidelity (engine mode).

    PZEngine.wireRoundTrip and the DualVMSim engine_wire transport ride
    zombie.network.TableNetworkUtils — the exact serializer under real
    sendClientCommand / sendServerCommand. These tests pin the wire's
    semantics offline:

      * functions and non-string/number KEYS are silently dropped
        (vanilla logs an ERROR per top-level drop at send; the sim
        mirrors the line)
      * nested tables recurse; deep data survives
      * the receiver gets an independent COPY — mutation cannot travel
        backwards, unlike the legacy pass-by-reference mock transport

    KNOWN BOUNDARY: the wire's InventoryItem tag (real PZ serializes
    items in payloads via saveWithSize/loadItem) does NOT work in the
    harness — loadItem resolves items by WorldDictionary registry ID,
    which only a loaded world populates. A real item in a payload
    arrives nil here; on a live server it arrives whole. World-save
    layer, outside engine scope — pin item-payload behavior on the dedi
    (pz-shell), not offline.

    Engine-guarded: no PZ install (CI) contributes no tests.
]]

if not (PZEngine and PZEngine.available()) then return {} end

local Assert = PZTestKit.Assert

local tests = {}

tests["wire_drops_functions_keeps_data"] = function()
    local payload = {
        id = 42, name = "cart", ready = true,
        callback = function() end,
        nested = { x = 1.5, deep = { s = "ok" } },
    }
    local out, drops = PZEngine.wireRoundTrip(payload)
    Assert.notNil(out, "round trip produced a table")
    Assert.equal(out.id, 42, "number survives")
    Assert.equal(out.name, "cart", "string survives")
    Assert.isTrue(out.ready, "boolean survives")
    Assert.isNil(out.callback, "function dropped by the wire")
    Assert.equal(out.nested.x, 1.5, "nested number survives")
    Assert.equal(out.nested.deep.s, "ok", "deep nesting survives")
    Assert.equal(#drops, 1, "exactly one drop reported")
end

tests["wire_drops_exotic_keys"] = function()
    local payload = { good = 1 }
    payload[true] = "boolean-keyed"
    local out, drops = PZEngine.wireRoundTrip(payload)
    Assert.equal(out.good, 1, "sane entry survives")
    Assert.isNil(out[true], "boolean key dropped")
    Assert.equal(#drops, 1, "drop reported")
end

tests["wire_copy_is_disconnected"] = function()
    local payload = { v = 1 }
    local out = PZEngine.wireRoundTrip(payload)
    out.v = 99
    Assert.equal(payload.v, 1, "receiver mutation cannot reach the sender")
end

tests["sim_transport_rides_the_real_wire"] = function()
    local sim = PZTestKit.Sim.new({ players = 1 })

    sim.server:exec([[
        _wire_got = nil
        Events.OnClientCommand.Add(function(module, command, player, args)
            if module == "WireProbe" then _wire_got = args end
        end)
    ]])
    sim.clients[1]:exec([[
        _sent_probe = { num = 7, label = "cart", fn = function() end }
        sendClientCommand(getPlayer(), "WireProbe", "ping", _sent_probe)
    ]])
    sim:flush()

    -- The server reports what it actually received.
    sim.server:exec([[
        _wire_got.mutated_by_server = true
        sendServerCommand("WireProbe", "result", {
            num = _wire_got.num,
            label = _wire_got.label,
            fn_type = type(_wire_got.fn),
        })
    ]])
    local result = sim.server:sent()[1].args
    Assert.equal(result.num, 7, "number crossed the sim wire")
    Assert.equal(result.label, "cart", "string crossed the sim wire")
    Assert.equal(result.fn_type, "nil", "function did NOT cross the sim wire")

    -- And the server's mutation of its copy never reached the client.
    sim.clients[1]:exec([[
        sendClientCommand(getPlayer(), "WireProbe", "check",
            { intact = _sent_probe.mutated_by_server == nil })
    ]])
    local check = sim.clients[1]:sent()[2].args
    Assert.isTrue(check.intact, "server-side mutation never reached the client's table")
end

return tests
