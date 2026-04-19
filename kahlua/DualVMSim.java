/**
 * PZ Test Kit — Dual-VM Simulator
 * ================================
 * Spins up N+1 fully-isolated Kahlua environments (1 server + N clients)
 * sharing nothing except a command bus. Each env is set up identically to
 * a single-VM test run — same mocks, same require resolver, same config,
 * same mod modules — but with `isServer()` / `isClient()` flipped per role
 * and `sendServerCommand` / `sendClientCommand` routed through this simulator.
 *
 * Use case: MP sync tests. A mod fires `sendServerCommand` from the server;
 * this simulator queues the message, and `sim:flush()` fires `OnServerCommand`
 * on the target clients' envs. Tests can then assert what each client saw —
 * without launching the game.
 *
 * API (from Lua):
 *
 *     local sim = PZTestKit.Sim.new({ players = 2 })
 *
 *     sim.server:exec([[
 *         -- Runs with isServer()=true, isClient()=false
 *         local axe = instanceItem("Base.Axe")
 *         getPlayer():setPrimaryHandItem(axe)
 *         sendServerCommand("VorpallySauced", "weaponUpdate", { kills = 50 })
 *     ]])
 *
 *     sim:flush()  -- routes queued messages, fires OnServerCommand on clients
 *
 *     assert(sim.clients[1]:sawCommand("VorpallySauced", "weaponUpdate"))
 *     assert(#sim.clients[1]:received() == 1)
 *
 * Each endpoint is a KahluaTable (env) plus a command mailbox and a "sent"
 * log. The simulator owns routing: on flush, each queued message dispatches
 * to the appropriate endpoint(s) based on direction:
 *   - client → server: enqueued in server inbox; flush fires OnServerCommand
 *     on the server env with player attribution
 *   - server → specific client (4-arg sendServerCommand with player): routed
 *     to that client's inbox; flush fires OnServerCommand on that client
 *   - server → broadcast (3-arg on server): fanned out to all client inboxes
 */

import se.krka.kahlua.vm.*;
import se.krka.kahlua.luaj.compiler.LuaCompiler;

import java.nio.file.*;
import java.util.*;
import java.util.function.*;

/** Shared helpers for loading Lua from the kit's own kahlua/ directory
 *  (so Java never ships with inline multi-line Lua strings). */
class KitLua {
    /** Kit root; set once by KahluaTestRunner. */
    static Path root;

    /** Read a Lua file relative to the kit root, cache the source. */
    static String load(String relPath) {
        try {
            return Files.readString(root.resolve(relPath));
        } catch (java.io.IOException e) {
            throw new RuntimeException("cannot read " + relPath + ": " + e.getMessage(), e);
        }
    }

    /** Compile and run a Lua file in the given env. */
    static void run(KahluaThread thread, KahluaTable env, String relPath) {
        try {
            String src = load(relPath);
            LuaClosure c = LuaCompiler.loadstring(src, relPath, env);
            thread.pcall(c, new Object[0]);
        } catch (Exception e) {
            throw new RuntimeException("failed running " + relPath + ": " + e.getMessage(), e);
        }
    }
}

public class DualVMSim {

    /** Setup callback — builds a fresh env matching the single-VM runner. */
    public interface EnvBuilder {
        void build(KahluaThread thread, KahluaTable env, boolean isServer, int clientIndex) throws Exception;
    }

    private static class Endpoint {
        final String role;             // "server" or "client"
        final int index;               // 0 for server, 1..N for clients
        final TestPlatform platform;
        final KahluaTable env;
        final KahluaThread thread;
        final List<Command> sent = new ArrayList<>();
        final List<Command> inbox = new ArrayList<>();
        final List<Command> received = new ArrayList<>();

        Endpoint(String role, int index, TestPlatform p, KahluaTable env, KahluaThread t) {
            this.role = role; this.index = index; this.platform = p; this.env = env; this.thread = t;
        }
    }

    /** A single queued command. target=-1 means broadcast to all clients;
     *  target=0 means server; target=i>0 means clients[i]. */
    private static class Command {
        int sourceIndex;       // who sent it
        int target;            // destination (-1 broadcast, 0 server, i client)
        String module;
        String command;
        Object args;           // typically a KahluaTable

        @Override public String toString() {
            return "Command{" + module + "/" + command + " src=" + sourceIndex + " tgt=" + target + "}";
        }
    }

    private final EnvBuilder builder;
    private final int numClients;
    private final Endpoint server;
    private final Endpoint[] clients;

    public DualVMSim(int numClients, EnvBuilder builder) throws Exception {
        this.numClients = numClients;
        this.builder = builder;
        this.server = makeEndpoint("server", 0, true, 0);
        this.clients = new Endpoint[numClients];
        for (int i = 0; i < numClients; i++) {
            this.clients[i] = makeEndpoint("client", i + 1, false, i + 1);
        }
    }

    private Endpoint makeEndpoint(String role, int index, boolean isServer, int clientIdx) throws Exception {
        TestPlatform platform = new TestPlatform();
        KahluaTable env = platform.newEnvironment();
        KahluaThread thread = new KahluaThread(platform, env);
        thread.debugOwnerThread = Thread.currentThread();

        builder.build(thread, env, isServer, clientIdx);

        Endpoint ep = new Endpoint(role, index, platform, env, thread);
        installBusHooks(ep);
        return ep;
    }

    /** Install Lua-side sendServerCommand/sendClientCommand that queue into our bus. */
    private void installBusHooks(Endpoint ep) throws Exception {
        final int endpointIndex = ep.index;   // 0=server, 1..N=clients
        final boolean isServer = "server".equals(ep.role);
        final List<Command> outbox = ep.sent;
        final DualVMSim sim = this;

        // Register a Java function callable from Lua as `_pz_sim_send(...)`
        JavaFunction sendFn = new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                // Args: (a, b, c, d) — detect 3-arg vs 4-arg form
                Object a = nArguments >= 1 ? frame.get(0) : null;
                Object b = nArguments >= 2 ? frame.get(1) : null;
                Object c = nArguments >= 3 ? frame.get(2) : null;
                Object d = nArguments >= 4 ? frame.get(3) : null;

                Command cmd = new Command();
                cmd.sourceIndex = endpointIndex;

                if (a instanceof String) {
                    // 3-arg form: (module, command, args)
                    cmd.module = (String) a;
                    cmd.command = (b instanceof String) ? (String) b : String.valueOf(b);
                    cmd.args = c;
                    // If called on server, broadcast; if on client, goes to server
                    cmd.target = isServer ? -1 : 0;
                } else {
                    // 4-arg form: (player, module, command, args)
                    cmd.module = (b instanceof String) ? (String) b : String.valueOf(b);
                    cmd.command = (c instanceof String) ? (String) c : String.valueOf(c);
                    cmd.args = d;
                    // 4-arg from server = targeted client; from client it's
                    // unusual but we'll route to server (client→server form
                    // where player is self)
                    if (isServer) {
                        cmd.target = resolvePlayerTarget(a);
                    } else {
                        cmd.target = 0;
                    }
                }
                outbox.add(cmd);
                sim.pendingCommands.add(cmd);
                return 0;
            }
        };

        ep.env.rawset("sendServerCommand", sendFn);
        ep.env.rawset("sendClientCommand", sendFn);

        installSyncHooks(ep);
    }

    // ── Network sync model ───────────────────────────────────────────────
    //
    // Real PZ replicates weapon state across clients via:
    //   syncItemModData(player, item)     — ModData changes
    //   syncHandWeaponFields(player, item) — weapon stats (damage, crit, etc.)
    //   syncItemFields(player, item)       — item fields (condition, etc.)
    //
    // In single-client tests these are no-ops. For real MP fidelity in dual-VM,
    // we intercept them and push a sync message. On flush(), for each target
    // endpoint, we find the weapon by ID in the endpoint's inventory (or
    // primary hand) and copy the source's state over. This mirrors what the
    // real packet would do.
    //
    // For the copy to be safe across env boundaries (Kahlua tables from one
    // env are writable from another but sharing references causes cross-env
    // mutation surprises), we deep-copy the payload in the target env via a
    // Lua helper installed by each env's buildEnv.

    private static class SyncMessage {
        String kind;        // "moddata" | "handweapon" | "itemfields"
        int sourceIndex;
        int target;         // -1 broadcast, i = client i, 0 = server
        int weaponId;
        Object payload;     // ModData table (for moddata) or field snapshot
    }

    private final List<SyncMessage> pendingSyncs = new ArrayList<>();

    /** Install a Java bridge (_pz_sim_push_sync) plus pure-Lua wrappers for
     *  syncItemModData / syncHandWeaponFields / syncItemFields. The Lua side
     *  calls item:getID() and item:getModData() to extract values, then hands
     *  them to Java via the bridge. Works with ANY mock factory that exposes
     *  proper HandWeapon-style methods (closure-based or plain-table). */
    private void installSyncHooks(Endpoint ep) throws Exception {
        final int endpointIndex = ep.index;
        final boolean isServer = "server".equals(ep.role);
        final DualVMSim sim = this;

        JavaFunction pushSync = new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int n) {
                // Args: (kind, player, weaponId, payload)
                String kind = n >= 1 && frame.get(0) instanceof String ? (String) frame.get(0) : "moddata";
                Object player = n >= 2 ? frame.get(1) : null;
                Object rawId = n >= 3 ? frame.get(2) : null;
                Object payload = n >= 4 ? frame.get(3) : null;

                SyncMessage m = new SyncMessage();
                m.kind = kind;
                m.sourceIndex = endpointIndex;
                m.weaponId = rawId instanceof Number ? ((Number) rawId).intValue() : 0;

                if (isServer) {
                    if (player instanceof KahluaTable) {
                        Object idx = ((KahluaTable) player).rawget("_client_index");
                        m.target = idx instanceof Number ? ((Number) idx).intValue() : -1;
                    } else {
                        m.target = -1;
                    }
                } else {
                    m.target = 0;
                }

                m.payload = payload;
                sim.pendingSyncs.add(m);
                return 0;
            }
        };
        ep.env.rawset("_pz_sim_push_sync", pushSync);

        // Install the Lua-side sync wrappers from sim/sync_wrappers.lua.
        KitLua.run(ep.thread, ep.env, "sim/sync_wrappers.lua");
    }

    /** Try to map a Lua player-like object back to a client index. In v1,
     *  we inspect an optional `_client_index` field on the player table.
     *  Tests can set this explicitly via fixtures; otherwise, default to
     *  the first client as the conservative target. */
    private int resolvePlayerTarget(Object playerArg) {
        if (playerArg instanceof KahluaTable) {
            Object idx = ((KahluaTable) playerArg).rawget("_client_index");
            if (idx instanceof Number) return ((Number) idx).intValue();
        }
        return clients.length > 0 ? 1 : 0;  // fallback to client 1
    }

    /** Queue of all commands from any endpoint, in order of emission. Drained
     *  by flush(). */
    private final List<Command> pendingCommands = new ArrayList<>();

    /** Drain the pending-commands queue, routing each message to its target
     *  endpoint's inbox, then fire OnServerCommand/OnClientCommand on the
     *  target env's Events system. Sync messages drain FIRST so command
     *  handlers see up-to-date state. */
    public void flush() throws Exception {
        // Sync messages first (state propagation) then command messages
        // (event fires that may observe the synced state).
        List<SyncMessage> syncs = new ArrayList<>(pendingSyncs);
        pendingSyncs.clear();
        for (SyncMessage s : syncs) dispatchSync(s);

        List<Command> toDispatch = new ArrayList<>(pendingCommands);
        pendingCommands.clear();
        for (Command cmd : toDispatch) {
            if (cmd.target == 0) {
                deliver(server, cmd, "OnClientCommand");
            } else if (cmd.target == -1) {
                for (Endpoint c : clients) deliver(c, cmd, "OnServerCommand");
            } else if (cmd.target >= 1 && cmd.target <= clients.length) {
                deliver(clients[cmd.target - 1], cmd, "OnServerCommand");
            }
        }
    }

    /** Apply a sync message to its target endpoints: find the weapon with the
     *  matching ID in the target's inventory (or primary hand), then deep-copy
     *  the source's state into it. */
    private void dispatchSync(SyncMessage msg) throws Exception {
        List<Endpoint> targets = new ArrayList<>();
        if (msg.target == 0) {
            if (msg.sourceIndex != 0) targets.add(server);
        } else if (msg.target == -1) {
            for (Endpoint c : clients) if (c.index != msg.sourceIndex) targets.add(c);
        } else if (msg.target >= 1 && msg.target <= clients.length) {
            Endpoint t = clients[msg.target - 1];
            if (t.index != msg.sourceIndex) targets.add(t);
        }

        // Apply logic lives in sim/sync_apply.lua — read once, reuse.
        String applySrc = KitLua.load("sim/sync_apply.lua");

        for (Endpoint ep : targets) {
            ep.env.rawset("_pz_sync_weaponId", Double.valueOf(msg.weaponId));
            ep.env.rawset("_pz_sync_payload", msg.payload);
            ep.env.rawset("_pz_sync_kind", msg.kind);

            LuaClosure closure = LuaCompiler.loadstring(applySrc, "sim/sync_apply.lua", ep.env);
            Object[] res = ep.thread.pcall(closure, new Object[0]);
            if (res != null && res.length > 0 && Boolean.FALSE.equals(res[0])) {
                System.err.println("[Sim] sync dispatch error: " +
                    (res.length > 1 ? res[1] : "unknown"));
            }
        }
    }

    /** Record receipt + fire the matching Events.<eventName> on the endpoint. */
    private void deliver(Endpoint ep, Command cmd, String eventName) throws Exception {
        ep.inbox.add(cmd);
        ep.received.add(cmd);

        ep.env.rawset("_pz_sim_event_name", eventName);
        ep.env.rawset("_pz_sim_mod", cmd.module);
        ep.env.rawset("_pz_sim_cmd", cmd.command);
        ep.env.rawset("_pz_sim_args", cmd.args);

        KitLua.run(ep.thread, ep.env, "sim/event_dispatch.lua");
    }

    // ── Lua bindings ─────────────────────────────────────────────────────

    /** Build the Lua-facing `PZTestKit.Sim` table inside a host env that
     *  tests run in. The host env creates the DualVMSim instance and returns
     *  a handle with endpoints, :flush(), etc. */
    public static void installLuaAPI(KahluaTable hostEnv, EnvBuilder sharedBuilder) {
        KahluaTable pzTestKit = getOrCreateTable(hostEnv, "PZTestKit");
        KahluaTable simTable = new se.krka.kahlua.j2se.KahluaTableImpl(new HashMap<>());
        pzTestKit.rawset("Sim", simTable);

        simTable.rawset("new", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                int players = 1;
                if (nArguments >= 1) {
                    Object opts = frame.get(0);
                    if (opts instanceof KahluaTable) {
                        Object p = ((KahluaTable) opts).rawget("players");
                        if (p instanceof Number) players = ((Number) p).intValue();
                    }
                }
                try {
                    DualVMSim sim = new DualVMSim(players, sharedBuilder);
                    KahluaTable handle = buildHandle(hostEnv, sim);
                    frame.push(handle);
                    return 1;
                } catch (Exception e) {
                    throw new RuntimeException("Sim.new failed: " + e.getMessage(), e);
                }
            }
        });
    }

    private static KahluaTable buildHandle(KahluaTable hostEnv, DualVMSim sim) {
        KahluaTable handle = new se.krka.kahlua.j2se.KahluaTableImpl(new HashMap<>());
        handle.rawset("server", buildEndpointHandle(sim, sim.server));
        KahluaTable clients = new se.krka.kahlua.j2se.KahluaTableImpl(new HashMap<>());
        for (int i = 0; i < sim.clients.length; i++) {
            clients.rawset(i + 1, buildEndpointHandle(sim, sim.clients[i]));
        }
        handle.rawset("clients", clients);

        handle.rawset("flush", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                try { sim.flush(); return 0; }
                catch (Exception e) { throw new RuntimeException("flush failed: " + e.getMessage(), e); }
            }
        });

        // sim:spawnSyncedWeapon(fullType, opts) — spawns an `_wpn` global with
        // the same ID across the server and every client, skipping the usual
        // "run this setup on each endpoint" boilerplate. opts.id is optional
        // (generated if absent). opts.equip=true also calls setPrimaryHandItem.
        handle.rawset("spawnSyncedWeapon", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                String fullType = null;
                Object opts = null;
                if (nArguments >= 3) {
                    if (frame.get(1) instanceof String) fullType = (String) frame.get(1);
                    opts = frame.get(2);
                } else if (nArguments >= 2) {
                    if (frame.get(0) instanceof String) fullType = (String) frame.get(0);
                    opts = frame.get(1);
                } else if (nArguments >= 1 && frame.get(0) instanceof String) {
                    fullType = (String) frame.get(0);
                }
                if (fullType == null) return 0;

                int id = 0;
                boolean equip = false;
                if (opts instanceof KahluaTable) {
                    Object idObj = ((KahluaTable) opts).rawget("id");
                    if (idObj instanceof Number) id = ((Number) idObj).intValue();
                    Object eq = ((KahluaTable) opts).rawget("equip");
                    equip = Boolean.TRUE.equals(eq);
                }
                if (id == 0) {
                    // Derive a stable-ish ID from fullType hash so every endpoint
                    // agrees without needing explicit opts.id.
                    id = Math.abs(fullType.hashCode() % 900000) + 100000;
                }

                try {
                    String setupSrc = KitLua.load("sim/spawn_weapon.lua");
                    Endpoint[] allEndpoints = new Endpoint[sim.clients.length + 1];
                    allEndpoints[0] = sim.server;
                    System.arraycopy(sim.clients, 0, allEndpoints, 1, sim.clients.length);
                    for (Endpoint ep : allEndpoints) {
                        ep.env.rawset("_pz_spawn_fullType", fullType);
                        ep.env.rawset("_pz_spawn_id", Double.valueOf(id));
                        ep.env.rawset("_pz_spawn_equip", Boolean.valueOf(equip));
                        LuaClosure c = LuaCompiler.loadstring(setupSrc, "sim/spawn_weapon.lua", ep.env);
                        ep.thread.pcall(c, new Object[0]);
                    }
                } catch (Exception e) {
                    throw new RuntimeException("spawnSyncedWeapon failed: " + e.getMessage(), e);
                }
                return 0;
            }
        });

        return handle;
    }

    private static KahluaTable buildEndpointHandle(DualVMSim sim, Endpoint ep) {
        KahluaTable h = new se.krka.kahlua.j2se.KahluaTableImpl(new HashMap<>());
        h.rawset("role", ep.role);
        h.rawset("index", ep.index);

        h.rawset("exec", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                // Called as ep:exec(src) → self at arg 0, src at arg 1
                String src = null;
                if (nArguments >= 2 && frame.get(1) instanceof String) {
                    src = (String) frame.get(1);
                } else if (nArguments >= 1 && frame.get(0) instanceof String) {
                    src = (String) frame.get(0);
                }
                if (src == null) return 0;
                try {
                    LuaClosure c = LuaCompiler.loadstring(src, ep.role + "_exec", ep.env);
                    ep.thread.pcall(c, new Object[0]);
                } catch (Exception e) {
                    throw new RuntimeException(ep.role + ":exec failed: " + e.getMessage(), e);
                }
                return 0;
            }
        });

        h.rawset("received", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                KahluaTable out = new se.krka.kahlua.j2se.KahluaTableImpl(new HashMap<>());
                for (int i = 0; i < ep.received.size(); i++) {
                    Command c = ep.received.get(i);
                    KahluaTable entry = new se.krka.kahlua.j2se.KahluaTableImpl(new HashMap<>());
                    entry.rawset("module", c.module);
                    entry.rawset("command", c.command);
                    entry.rawset("args", c.args);
                    out.rawset(i + 1, entry);
                }
                frame.push(out);
                return 1;
            }
        });

        h.rawset("sawCommand", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                // Called as ep:sawCommand(module, command)
                // self at arg 0, module at 1, command at 2
                String module = null, command = null;
                if (nArguments >= 3) {
                    if (frame.get(1) instanceof String) module = (String) frame.get(1);
                    if (frame.get(2) instanceof String) command = (String) frame.get(2);
                } else if (nArguments >= 2) {
                    if (frame.get(0) instanceof String) module = (String) frame.get(0);
                    if (frame.get(1) instanceof String) command = (String) frame.get(1);
                }
                boolean seen = false;
                for (Command c : ep.received) {
                    if (c.module.equals(module) && c.command.equals(command)) {
                        seen = true;
                        break;
                    }
                }
                frame.push(Boolean.valueOf(seen));
                return 1;
            }
        });

        h.rawset("sent", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                KahluaTable out = new se.krka.kahlua.j2se.KahluaTableImpl(new HashMap<>());
                for (int i = 0; i < ep.sent.size(); i++) {
                    Command c = ep.sent.get(i);
                    KahluaTable entry = new se.krka.kahlua.j2se.KahluaTableImpl(new HashMap<>());
                    entry.rawset("module", c.module);
                    entry.rawset("command", c.command);
                    entry.rawset("args", c.args);
                    out.rawset(i + 1, entry);
                }
                frame.push(out);
                return 1;
            }
        });

        // :eval(source) → runs source as an expression and returns its value.
        // Source must use `return` explicitly. Return value is passed back to
        // the caller's env as-is (Java-level reference); tables may be shared
        // across envs — read-only use is safe, mutations should go through
        // :exec() or :set() instead.
        h.rawset("eval", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                // self at arg 0; source at arg 1 (from ep:eval(src) call syntax)
                String src = null;
                if (nArguments >= 2 && frame.get(1) instanceof String) {
                    src = (String) frame.get(1);
                } else if (nArguments >= 1 && frame.get(0) instanceof String) {
                    src = (String) frame.get(0);
                }
                if (src == null) return 0;
                // Wrap in a function so `return X` works regardless of whether
                // the source is a single expression or a multi-stmt block.
                String wrapped = "return (function()\n" + src + "\nend)()";
                try {
                    LuaClosure c = LuaCompiler.loadstring(wrapped, ep.role + "_eval", ep.env);
                    Object[] res = ep.thread.pcall(c, new Object[0]);
                    if (res != null && res.length >= 2 && Boolean.TRUE.equals(res[0])) {
                        frame.push(res[1]);
                        return 1;
                    } else if (res != null && res.length >= 2) {
                        throw new RuntimeException(ep.role + ":eval failed: " + res[1]);
                    }
                } catch (Exception e) {
                    throw new RuntimeException(ep.role + ":eval error: " + e.getMessage(), e);
                }
                return 0;
            }
        });

        // :get(name) → reads a global from the endpoint's env. Returns the
        // Java-level value (primitives pass-through, tables returned as-is).
        h.rawset("get", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                String name = null;
                if (nArguments >= 2 && frame.get(1) instanceof String) {
                    name = (String) frame.get(1);
                } else if (nArguments >= 1 && frame.get(0) instanceof String) {
                    name = (String) frame.get(0);
                }
                if (name == null) return 0;
                frame.push(ep.env.rawget(name));
                return 1;
            }
        });

        // :set(name, value) → writes a global into the endpoint's env.
        h.rawset("set", new JavaFunction() {
            @Override
            public int call(LuaCallFrame frame, int nArguments) {
                // self, name, value  OR  name, value
                String name = null; Object value = null;
                if (nArguments >= 3) {
                    if (frame.get(1) instanceof String) name = (String) frame.get(1);
                    value = frame.get(2);
                } else if (nArguments >= 2) {
                    if (frame.get(0) instanceof String) name = (String) frame.get(0);
                    value = frame.get(1);
                }
                if (name != null) ep.env.rawset(name, value);
                return 0;
            }
        });

        return h;
    }

    /** Execute source string on this endpoint, returning the captured return
     *  value. Shared by :eval and :spawnSyncedWeapon. */
    private static Object execReturning(Endpoint ep, String src, String name) {
        String wrapped = "return (function()\n" + src + "\nend)()";
        try {
            LuaClosure c = LuaCompiler.loadstring(wrapped, name, ep.env);
            Object[] res = ep.thread.pcall(c, new Object[0]);
            if (res != null && res.length >= 2 && Boolean.TRUE.equals(res[0])) {
                return res[1];
            } else if (res != null && res.length >= 2) {
                throw new RuntimeException(name + " failed: " + res[1]);
            }
        } catch (Exception e) {
            throw new RuntimeException(name + " error: " + e.getMessage(), e);
        }
        return null;
    }

    private static KahluaTable getOrCreateTable(KahluaTable parent, String key) {
        Object existing = parent.rawget(key);
        if (existing instanceof KahluaTable) return (KahluaTable) existing;
        KahluaTable t = new se.krka.kahlua.j2se.KahluaTableImpl(new HashMap<>());
        parent.rawset(key, t);
        return t;
    }
}
